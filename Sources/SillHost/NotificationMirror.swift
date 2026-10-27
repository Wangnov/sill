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
            apply()
        }
    }
    package private(set) var collectorStatus = String(localized: "Notification mirroring is off.")
    package private(set) var deliveryStatus = String(localized: "Live inbox only. APNs delivery is off.")
    package private(set) var registeredDeviceCount = 0

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let collector = NotificationMirrorCollector()
    @ObservationIgnored private var provider: APNsProvider?
    @ObservationIgnored private var macID = ""
    @ObservationIgnored private var isPaired: (@MainActor (Data) -> Bool)?
    @ObservationIgnored private var onNotification: (@MainActor (MirroredNotification) -> Void)?
    @ObservationIgnored private var registrations: [String: Registration] = [:]
    @ObservationIgnored private var pending: [MirroredNotification] = []
    @ObservationIgnored private var deliveryTask: Task<Void, Never>?
    @ObservationIgnored private var deliveryGeneration = 0

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

    package init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
                       onNotification: @escaping @MainActor (MirroredNotification) -> Void) {
        self.macID = macID
        self.isPaired = isPaired
        self.onNotification = onNotification
        collector.onNotification = { [weak self] in self?.receive($0) }
        collector.onStatus = { [weak self] in self?.collectorStatus = $0 }
        pruneUnpairedRegistrations()
        apply()
    }

    package func stop() {
        collector.stop()
        deliveryGeneration += 1
        deliveryTask?.cancel()
        deliveryTask = nil
        pending = []
        macID = ""
        isPaired = nil
        onNotification = nil
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
        if pushEnabled, (topic != apns.topic || environment != apns.environment) {
            deliveryStatus = String(localized: "A paired device's APNs topic or environment does not match this Mac's provider settings.")
        }
        return true
    }

    /// A future public notification source can use the same path. This method never attempts to
    /// read hidden system data; the experimental AX collector and the explicit test button use it.
    package func receive(_ notification: MirroredNotification) {
        guard enabled, !macID.isEmpty else { return }
        onNotification?(notification)
        guard pushEnabled, provider != nil else { return }
        pending.append(notification)
        if pending.count > 30 { pending.removeFirst(pending.count - 30) }
        deliverPending()
    }

    package func sendTestNotification() {
        receive(MirroredNotification(appBundleID: Bundle.main.bundleIdentifier ?? "me.saffer.sill.mac",
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
        pending = []
        provider = nil
        guard enabled else {
            collector.stop()
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
        guard pushEnabled else {
            deliveryStatus = String(localized: "Live inbox only. APNs delivery is off.")
            return
        }
        if let problem = apns.problem {
            deliveryStatus = problem
            return
        }
        provider = APNsProvider(configuration: apns)
        deliveryStatus = String(localized: "APNs configured; awaiting a paired device registration and a notification. Delivery is not verified yet.")
    }

    private func saveRegistrations() {
        registeredDeviceCount = registrations.count
        if let data = try? JSONEncoder().encode(registrations) { defaults.set(data, forKey: Key.registrations) }
    }

    private func deliverPending() {
        guard deliveryTask == nil, let provider else { return }
        let generation = deliveryGeneration
        deliveryTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.deliveryGeneration == generation, self.enabled, self.pushEnabled, !self.pending.isEmpty {
                let event = self.pending.removeFirst()
                self.pruneUnpairedRegistrations()
                let targets = self.registrations.values.filter { $0.topic == self.apns.topic && $0.environment == self.apns.environment }
                if targets.isEmpty { self.deliveryStatus = String(localized: "No paired device has registered for this APNs topic and environment.") }
                for target in targets {
                    // Recheck immediately before each request, including after another target's
                    // asynchronous send. A forgotten device receives no later queued events.
                    guard !Task.isCancelled, self.deliveryGeneration == generation, self.enabled, self.pushEnabled else { break }
                    let key = target.fingerprint.base64EncodedString()
                    guard self.isPaired?(target.fingerprint) == true,
                          let sending = self.registrations[key], sending.token == target.token,
                          sending.topic == target.topic, sending.environment == target.environment else { continue }
                    // A prior target's await may have refreshed this same token. Use the current
                    // revision for this request; the snapshot selects recipients, not revisions.
                    let result = await provider.send(event, macID: self.macID, token: sending.token)
                    guard !Task.isCancelled, self.deliveryGeneration == generation else { break }
                    switch result {
                    case .accepted:
                        self.deliveryStatus = String(localized: "Apple accepted the last APNs request. Device display is not confirmed.")
                    case .invalidToken:
                        if self.registrations[key]?.token == sending.token,
                           self.registrations[key]?.revision == sending.revision {
                            self.registrations[key] = nil
                            self.saveRegistrations()
                        }
                        self.deliveryStatus = String(localized: "Apple rejected an expired or invalid device token; waiting for that device to register again.")
                    case .failure(let problem):
                        self.deliveryStatus = problem
                    }
                }
            }
            if self.deliveryGeneration == generation { self.deliveryTask = nil }
        }
    }
}
