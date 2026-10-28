import Foundation
import Observation
import StreamProtocol

/// The Mac's opt-in notification mirror. Live delivery is handed to the coordinator; APNs is
/// independent of a streaming socket, so an opted-in paired device can receive alerts when iOS
/// suspends Sill. Tokens are indexed by the TLS peer's fingerprint, never a JSON device ID.
/// The current trust list is consulted immediately before every APNs request. A request already
/// handed to Apple cannot be recalled when a pairing is removed.
@MainActor @Observable
package final class NotificationMirror {
    package var enabled: Bool {
        didSet { guard enabled != oldValue else { return }; defaults.set(enabled, forKey: Key.enabled); apply() }
    }
    package var pushEnabled: Bool {
        didSet { guard pushEnabled != oldValue else { return }; defaults.set(pushEnabled, forKey: Key.pushEnabled); apply() }
    }
    /// Non-secret provider settings only. The p8 stays at this external path; its contents are
    /// never copied into defaults, bundled resources or logs.
    package var apns: APNsConfiguration {
        didSet {
            guard apns != oldValue else { return }
            if let data = try? JSONEncoder().encode(apns) { defaults.set(data, forKey: Key.apns) }
            do { try historyStore().retryFailures() } catch { historyFailure(error) }
            apply()
        }
    }
    package private(set) var collectorStatus = String(localized: "Notification mirroring is off.")
    package private(set) var deliveryStatus = String(localized: "Live inbox only. APNs delivery is off.")
    package private(set) var registeredDeviceCount = 0

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let historyURL: URL
    @ObservationIgnored private let collector = NotificationMirrorCollector()
    @ObservationIgnored private var provider: APNsProvider?
    @ObservationIgnored private var macID = ""
    @ObservationIgnored private var isPaired: (@MainActor (Data) -> Bool)?
    @ObservationIgnored private var onHistoryAvailable: (@MainActor () -> Void)?
    @ObservationIgnored private var registrations: [String: Registration] = [:]
    @ObservationIgnored private var history: NotificationHistoryStore?
    @ObservationIgnored private var deliveryTask: Task<Void, Never>?
    @ObservationIgnored private var deliveryGeneration = 0
    @ObservationIgnored private var pendingBanners: [String: NotificationBannerObservation] = [:]
    @ObservationIgnored private var pendingSources: [String: (source: NotificationSourceAttribution, appName: String)] = [:]
    @ObservationIgnored private var bannerRetry: Task<Void, Never>?

    private enum Key {
        static let enabled = "notificationMirror.enabled"
        static let pushEnabled = "notificationMirror.pushEnabled"
        static let apns = "notificationMirror.apns"
        static let registrations = "notificationMirror.registrations"
    }
    private struct Registration: Codable {
        let fingerprint: Data
        let token: String
        let topic: String
        let environment: String
        /// A refresh may reuse its token while an older APNs request is in flight. Optional only
        /// for decoding earlier local settings; every new subscription gets a fresh revision.
        let revision: UUID?
    }

    package init(defaults: UserDefaults = .standard, historyURL: URL = NotificationHistoryStore.defaultURL) {
        self.defaults = defaults
        self.historyURL = historyURL
        enabled = defaults.bool(forKey: Key.enabled)
        pushEnabled = defaults.bool(forKey: Key.pushEnabled)
        apns = defaults.data(forKey: Key.apns).flatMap { try? JSONDecoder().decode(APNsConfiguration.self, from: $0) }
            ?? APNsConfiguration(teamID: "", keyID: "", topic: "", keyPath: "", environment: "sandbox")
        if let data = defaults.data(forKey: Key.registrations),
           let saved = try? JSONDecoder().decode([String: Registration].self, from: data) {
            registrations = saved
        }
        registeredDeviceCount = registrations.count
    }

    /// Called once the coordinator has its host identity. The closure must consult RemoteAccess's
    /// current list, rather than capture a snapshot taken when the client first connected.
    package func start(macID: String, isPaired: @escaping @MainActor (Data) -> Bool,
                       onHistoryAvailable: @escaping @MainActor () -> Void) {
        self.macID = macID
        self.isPaired = isPaired
        self.onHistoryAvailable = onHistoryAvailable
        collector.onSnapshot = { [weak self] in self?.receiveSnapshot($0) }
        collector.onBanner = { [weak self] in self?.receiveBanner($0) }
        collector.onSource = { [weak self] in self?.receiveSource($0, appName: $1) }
        collector.onStatus = { [weak self] in self?.collectorStatus = $0 }
        pruneUnpairedRegistrations()
        apply()
    }

    package func stop() {
        collector.stop()
        bannerRetry?.cancel()
        bannerRetry = nil
        deliveryGeneration += 1
        deliveryTask?.cancel()
        deliveryTask = nil
        macID = ""
        isPaired = nil
        onHistoryAvailable = nil
    }

    /// The server passes only a fingerprint from an authenticated TLS ClientRoute. This second
    /// trust check also rejects a paired-at-handshake device removed before its message arrived.
    /// Returning true subscribes the live connection even if no usable push token is available.
    @discardableResult
    package func subscribe(_ subscription: NotificationSubscription, fingerprint: Data?) -> Bool {
        pruneUnpairedRegistrations()
        guard let fingerprint, isPaired?(fingerprint) == true else { return false }
        let key = fingerprint.base64EncodedString()
        guard subscription.enabled else {
            registrations[key] = nil
            saveRegistrations()
            return true
        }
        guard let token = subscription.pushToken?.lowercased(), !token.isEmpty else {
            // Live-only also withdraws a previous push registration (for example after iOS
            // notification permission changed). A later APNs registration can add it again.
            registrations[key] = nil
            saveRegistrations()
            return true
        }
        guard token.count <= 512, token.count.isMultiple(of: 2), token.allSatisfy({ $0.isHexDigit }),
              let topic = subscription.topic, !topic.isEmpty,
              let environment = subscription.environment, ["sandbox", "production"].contains(environment) else {
            deliveryStatus = String(localized: "A paired device supplied incomplete APNs registration settings. Live inbox delivery remains available.")
            return true
        }
        registrations[key] = Registration(fingerprint: fingerprint, token: token, topic: topic,
                                          environment: environment, revision: UUID())
        saveRegistrations()
        do { try historyStore().retryFailures(fingerprint: key) } catch { historyFailure(error) }
        deliverPending()
        if pushEnabled, (topic != apns.topic || environment != apns.environment) {
            deliveryStatus = String(localized: "A paired device's APNs topic or environment does not match this Mac's provider settings.")
        }
        return true
    }

    /// The explicit test follows the same durable path as a collected notification.
    package func receive(_ notification: MirroredNotification) {
        guard enabled, !macID.isEmpty else { return }
        do {
            _ = try historyStore().append(notification, fingerprints: pushRecipients())
            onHistoryAvailable?()
            deliverPending()
        } catch { historyFailure(error) }
    }

    package func sendTestNotification() {
        receive(MirroredNotification(id: "sill-test:" + UUID().uuidString,
                                     appBundleID: Bundle.main.bundleIdentifier ?? "me.saffer.sill.mac",
                                     appName: "Sill", title: String(localized: "Notification mirroring test"),
                                     body: String(localized: "This test came from your Mac. Live delivery updates Sill’s inbox; configured APNs can also show an iOS alert.")))
    }

    /// Pair removal can call this to update the count immediately. Delivery also calls it for
    /// every event, so correctness never depends on that optional UI/status hook.
    package func pruneUnpairedRegistrations() {
        guard let isPaired else { return }
        let oldCount = registrations.count
        registrations = registrations.filter { isPaired($0.value.fingerprint) }
        if registrations.count != oldCount { saveRegistrations() }
    }

    private func apply() {
        deliveryGeneration += 1
        deliveryTask?.cancel()
        deliveryTask = nil
        provider = nil
        guard enabled else {
            collector.stop()
            bannerRetry?.cancel()
            bannerRetry = nil
            collectorStatus = String(localized: "Notification mirroring is off.")
            deliveryStatus = String(localized: "Notification delivery is off.")
            return
        }
        guard !macID.isEmpty, isPaired != nil else {
            collectorStatus = String(localized: "Waiting for the Mac's paired TLS identity.")
            deliveryStatus = String(localized: "A paired TLS identity is required.")
            return
        }
        collector.start()
        flushPendingBanners()
        onHistoryAvailable?()
        guard pushEnabled else {
            deliveryStatus = String(localized: "Live inbox only. APNs delivery is off.")
            return
        }
        if let problem = apns.problem {
            deliveryStatus = problem
            return
        }
        provider = APNsProvider(configuration: apns)
        deliveryStatus = String(localized: "APNs configured; pending notifications will be retried. Apple acceptance does not confirm device display.")
        deliverPending()
    }

    private func saveRegistrations() {
        registeredDeviceCount = registrations.count
        if let data = try? JSONEncoder().encode(registrations) { defaults.set(data, forKey: Key.registrations) }
    }

    private func historyStore() throws -> NotificationHistoryStore {
        if let history { return history }
        let opened = try NotificationHistoryStore(url: historyURL)
        history = opened
        return opened
    }

    private func historyFailure(_ error: Error) {
        deliveryStatus = (error as? LocalizedError)?.errorDescription
            ?? String(localized: "Notification history could not be saved. Collection will retry without advancing its cursor.")
    }

    private func pushRecipients() -> [String] {
        pruneUnpairedRegistrations()
        // Retain pending events even while push is off or the provider configuration is incomplete.
        return Array(registrations.keys)
    }

    private func receiveSnapshot(_ snapshot: NotificationStoreSnapshot) {
        guard enabled, !macID.isEmpty else { return }
        do {
            // Own-client notifications must not push back to that client. Still identify an AX
            // copy already captured before the database appeared, instead of leaving it unknown.
            var changed = false
            for record in snapshot.records where isMirrorSource(record.event.appBundleID) {
                guard let uuid = NotificationBannerParser.normalizedUUID(String(record.sourceID.prefix(32))) else { continue }
                if try historyStore().enrichBannerSource(uuid: uuid, bundleID: record.event.appBundleID,
                        appName: record.event.appName, fingerprints: []) != nil { changed = true }
            }
            let filtered = NotificationStoreSnapshot(records: snapshot.records.filter {
                !isMirrorSource($0.event.appBundleID)
            }, skippedRecordCount: snapshot.skippedRecordCount)
            let events = try historyStore().ingest(filtered, fingerprints: pushRecipients())
            if changed || !events.isEmpty { onHistoryAvailable?() }
            deliverPending()
        } catch { historyFailure(error) }
    }

    /// A banner can vanish before the system writes its notification store. Persist it immediately;
    /// the later database observation enriches this same archived event instead of alerting twice.
    private func receiveBanner(_ banner: NotificationBannerObservation) {
        guard enabled, !macID.isEmpty else { return }
        // The banner may disappear before another AX event or a database snapshot. Retain a
        // failed write in memory and retry; the observer's duplicate cache is not a durable ACK.
        var pending = banner
        pending.isFromIPhone = banner.isFromIPhone || pendingBanners[banner.sourceUUID]?.isFromIPhone == true
        pendingBanners[banner.sourceUUID] = pending
        flushPendingBanners()
    }

    private func receiveSource(_ source: NotificationSourceAttribution, appName: String) {
        guard enabled, !macID.isEmpty else { return }
        // Preserve stronger evidence while a failed write waits for retry. In particular, a
        // late arrival must not undo a conflict withdrawal which has not reached SQLite yet.
        let pendingEvidence = pendingSources[source.uuid]?.source.evidence
        if pendingEvidence == .exact && source.evidence != .exact { return }
        if pendingEvidence == .ambiguous && source.evidence == .arrival { return }
        pendingSources[source.uuid] = (source, appName)
        flushPendingBanners()
    }

    private func flushPendingBanners() {
        guard enabled, !macID.isEmpty, !pendingBanners.isEmpty || !pendingSources.isEmpty else { return }
        var changed = false
        do {
            // Arrival matches can send immediately; later full-UUID evidence confirms or fixes
            // the same event. A log line never creates message text. Keep failed writes for retry.
            for (uuid, entry) in Array(pendingSources) {
                let recipients = isMirrorSource(entry.source.bundleID) ? [] : pushRecipients()
                if try historyStore().enrichBannerSource(uuid: uuid, bundleID: entry.source.bundleID,
                        appName: entry.appName, evidence: entry.source.evidence,
                        fingerprints: recipients) != nil { changed = true }
                pendingSources.removeValue(forKey: uuid)
            }
            for banner in Array(pendingBanners.values) {
                // The store queues only attributed sources. The send-time check below also
                // suppresses Sill itself, including source metadata received before its banner.
                if try historyStore().ingestBanner(banner, fingerprints: pushRecipients()) != nil || banner.isFromIPhone { changed = true }
                pendingBanners.removeValue(forKey: banner.sourceUUID)
            }
        } catch {
            historyFailure(error)
            if bannerRetry == nil {
                bannerRetry = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    guard let self else { return }
                    self.bannerRetry = nil
                    self.flushPendingBanners()
                }
            }
        }
        if changed { onHistoryAvailable?() }
        deliverPending()
    }

    private func isMirrorSource(_ bundleID: String) -> Bool {
        bundleID == Bundle.main.bundleIdentifier || bundleID == "me.saffer.sill"
            || bundleID.hasPrefix("me.saffer.sill.")
            || (!apns.topic.isEmpty && bundleID == apns.topic)
            || registrations.values.contains { $0.topic == bundleID }
    }

    private func canForward(_ event: MirroredNotification) -> Bool {
        let explicitTest = event.id.hasPrefix("sill-test:")
            && event.appBundleID == (Bundle.main.bundleIdentifier ?? "me.saffer.sill.mac")
        return explicitTest || (!event.appBundleID.isEmpty && !isMirrorSource(event.appBundleID))
    }

    package struct ReplayBatch {
        package let events: [MirroredNotification]
        /// The last examined archive sequence, including excluded sources; nil pauses the drain.
        package let nextSequence: Int64?
    }

    /// Per-connection replay calls this in bounded batches. Persistence failure throws instead of
    /// making an unreadable history look empty and switching that client to live delivery.
    package func replayStart(for subscription: NotificationSubscription) throws -> Int64 {
        try historyStore().replayStart(historyID: subscription.historyID, afterSequence: subscription.afterSequence)
    }

    package func replay(after sequence: Int64) throws -> ReplayBatch {
        // Keep the cursor while disabled or while a known origin exclusion waits for retry.
        guard enabled, !hasPendingOriginExclusion else { return ReplayBatch(events: [], nextSequence: nil) }
        let history = try historyStore()
        let events = try history.events(after: sequence)
        // AX-only captures and older history can already contain Sill. Keep the archive, but
        // apply the same source exclusion on TLS replay as on APNs delivery. Advance even when
        // a whole page is excluded, so later ordinary notifications still reach the subscriber.
        return ReplayBatch(events: try events.filter {
            try !history.isExcluded($0) && canForward($0)
        },
                           nextSequence: events.last?.sequence)
    }

    package func replayFailed(_ error: Error) { historyFailure(error) }

    private var hasPendingOriginExclusion: Bool {
        pendingBanners.values.contains { $0.isFromIPhone }
    }

    private func deliverPending() {
        guard deliveryTask == nil, let provider, enabled, pushEnabled, !hasPendingOriginExclusion else { return }
        let generation = deliveryGeneration
        deliveryTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.deliveryGeneration == generation, self.enabled, self.pushEnabled,
                  !self.hasPendingOriginExclusion {
                do {
                    self.pruneUnpairedRegistrations()
                    let targets = self.registrations.filter {
                        $0.value.topic == self.apns.topic && $0.value.environment == self.apns.environment
                    }
                    let attempts = try self.historyStore().duePushes(at: Date(), fingerprints: Array(targets.keys))
                    for attempt in attempts {
                        // No await occurs between these checks and entering provider.send. Each
                        // request uses the current registration revision, never a stale token snapshot.
                        // A known origin waiting for a failed SQLite write also pauses unsent
                        // work; the banner retry resumes this drain after exclusion is durable.
                        guard !Task.isCancelled, self.deliveryGeneration == generation, self.enabled, self.pushEnabled,
                              !self.hasPendingOriginExclusion else { break }
                        let key = attempt.fingerprint
                        guard let sending = self.registrations[key], self.isPaired?(sending.fingerprint) == true,
                              sending.topic == self.apns.topic, sending.environment == self.apns.environment else { continue }
                        guard try self.historyStore().isCurrent(attempt) else { continue }
                        guard self.canForward(attempt.event) else {
                            // Terminal suppression also handles older queued events without a busy
                            // retry loop. Provider reconfiguration must not revive a mirror loop.
                            try self.historyStore().finish(attempt, state: "suppressed", problem: "Unconfirmed or mirrored notification source")
                            continue
                        }
                        let result = await provider.send(attempt.event, macID: self.macID, token: sending.token)
                        guard !Task.isCancelled, self.deliveryGeneration == generation else { break }
                        // A newer registration owns pending delivery now; an old request's result
                        // must neither remove that registration nor settle its pending retry.
                        guard self.registrations[key]?.revision == sending.revision,
                              self.registrations[key]?.token == sending.token else { continue }
                        switch result {
                        case .accepted:
                            try self.historyStore().finish(attempt, state: "accepted")
                            self.deliveryStatus = String(localized: "Apple accepted the last APNs request. Device display is not confirmed.")
                        case .invalidToken:
                            try self.historyStore().finish(attempt, state: "permanent", problem: "Invalid device token")
                            if self.registrations[key]?.token == sending.token,
                               self.registrations[key]?.revision == sending.revision {
                                self.registrations[key] = nil
                                self.saveRegistrations()
                            }
                            self.deliveryStatus = String(localized: "Apple rejected an expired or invalid device token; waiting for that device to register again.")
                        case .permanentFailure(let problem):
                            try self.historyStore().finish(attempt, state: "permanent", problem: problem)
                            self.deliveryStatus = problem
                        case .transientFailure(let problem):
                            let delays: [TimeInterval] = [5, 15, 60, 300, 900, 3600]
                            if attempt.attempts < delays.count {
                                let retry = Date().addingTimeInterval(delays[attempt.attempts])
                                try self.historyStore().finish(attempt, state: "retry", nextAttempt: retry, problem: problem)
                                self.deliveryStatus = String(localized: "APNs delivery failed temporarily. The notification is saved and will be retried.")
                            } else {
                                try self.historyStore().finish(attempt, state: "paused", problem: problem)
                                self.deliveryStatus = String(localized: "APNs retries are paused after repeated failures. The notification remains saved; renew the registration or provider settings to retry. Reconnecting Sill can recover its inbox history.")
                            }
                        }
                    }
                    if !attempts.isEmpty { continue }
                } catch { self.historyFailure(error) }
                // A bounded polling interval also notices pairing/configuration changes without
                // one timer per notification. Retry deadlines and failure states live in SQLite.
                do { try await Task.sleep(for: .seconds(5)) } catch { break }
            }
            if self.deliveryGeneration == generation { self.deliveryTask = nil }
        }
    }
}
