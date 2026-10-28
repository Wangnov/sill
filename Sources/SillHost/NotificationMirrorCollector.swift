import AppKit

/// AX preserves live text. Arrival metadata provides a short-window source match immediately;
/// full-UUID removal metadata and retained snapshots confirm or correct that provisional source.
@MainActor
final class NotificationMirrorCollector {
    var onSnapshot: ((NotificationStoreSnapshot) -> Void)?
    var onBanner: ((NotificationBannerObservation) -> Void)?
    var onSource: ((NotificationSourceAttribution, String) -> Void)?
    var onStatus: ((String) -> Void)?
    private let banners = NotificationBannerObserver()
    private let sources = NotificationSourceObserver()
    private var arrivals = NotificationArrivalMatcher()
    private var sourceQueue: [(source: NotificationSourceAttribution, epoch: Int)] = []
    private var sourceTask: Task<Void, Never>?
    private var sourceEpoch = 0
    private var task: Task<Void, Never>?
    private var bannerStatus = ""
    private var storeStatus = ""
    private var sourceStatus = ""
    private var appNames: [String: String] = [:]
    private var generation = 0

    func start() {
        guard task == nil else { return }
        generation += 1
        let current = generation
        storeStatus = String(localized: "Opening the Mac notification store…")
        banners.onObservation = { [weak self] banner in
            guard let self, self.generation == current else { return }
            // Persist the text without waiting for attribution. Either the log or AX may arrive
            // first; the matcher joins their metadata without comparing notification contents.
            self.onBanner?(banner)
            self.enqueueSources(self.arrivals.receiveBanner(uuid: banner.sourceUUID,
                observedAt: banner.observedAt, now: Date().timeIntervalSince1970))
        }
        banners.onStatus = { [weak self] status in
            guard let self else { return }
            switch status {
            case .running(let errors):
                self.bannerStatus = errors.isEmpty
                    ? String(localized: "Live notification banners are connected.")
                    : String(localized: "Some live notification events are unavailable. Stored notifications still fill gaps.")
            case .permissionRequired:
                self.bannerStatus = String(localized: "Allow Sill in Accessibility to mirror visible banners.")
            case .waitingForHost:
                self.bannerStatus = String(localized: "Waiting for the Mac notification interface.")
            case .registrationFailed:
                self.bannerStatus = String(localized: "The Mac notification interface could not be observed.")
            }
            self.publishStatus()
        }
        sources.onSource = { [weak self] in self?.enqueueSources([$0]) }
        sources.onArrival = { [weak self] arrival in
            guard let self, self.generation == current else { return }
            self.enqueueSources(self.arrivals.receiveArrival(arrival, now: Date().timeIntervalSince1970))
        }
        sources.onReset = { [weak self] in
            guard let self else { return }
            self.arrivals.reset()
            self.sourceEpoch += 1
            // A restarted log stream must not join new arrivals to observations from a previous
            // session. Complete full-UUID evidence already read before EOF remains useful.
            self.sourceQueue.removeAll { $0.source.evidence == .arrival }
        }
        sources.onStatus = { [weak self] status in
            guard let self else { return }
            switch status {
            case .running:
                self.sourceStatus = String(localized: "Live notification source matching and recovery are connected.")
            case .unavailable:
                self.sourceStatus = String(localized: "Notification source matching is unavailable. Live banners and stored notifications still work.")
            case .stopped: self.sourceStatus = ""
            }
            self.publishStatus()
        }
        banners.start()
        sources.start()
        publishStatus()
        task = Task { [weak self] in
            // InstalledApps uses FileManager and Bundle only. Keep discovery and all SQLite/plist
            // work off the main actor; a locked or busy store must never stall Sill's settings UI.
            let appNames = await Task.detached(priority: .utility) {
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                return Dictionary(InstalledApps.find(in: ["/Applications", "/System/Applications", home + "/Applications"])
                    .map { ($0.bundleID, $0.name) }, uniquingKeysWith: { first, _ in first })
            }.value
            guard !Task.isCancelled, self?.generation == current else { return }
            self?.appNames = appNames
            let reader = NotificationStoreReader(url: NotificationStoreReader.defaultURL, appNames: appNames,
                                                 includeMirrorSources: true)
            while !Task.isCancelled {
                do {
                    let snapshot = try await Task.detached(priority: .utility) { try reader.read() }.value
                    guard !Task.isCancelled, let self else { return }
                    self.onSnapshot?(snapshot)
                    guard !Task.isCancelled else { return }
                    if snapshot.skippedRecordCount == 0 {
                        self.storeStatus = String(localized: "Notification store access is working. Stored notifications are checked every 2 seconds.")
                    } else {
                        self.storeStatus = String(localized: "Notification store access is working. \(snapshot.skippedRecordCount) stored notifications have unsupported content and were skipped.")
                    }
                    self.publishStatus()
                } catch {
                    guard !Task.isCancelled, let self else { return }
                    // Error descriptions contain status/codes only, never notification payloads.
                    self.storeStatus = (error as? LocalizedError)?.errorDescription
                        ?? String(localized: "The notification store could not be read. Sill will retry.")
                    self.publishStatus()
                }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    func stop() {
        generation += 1
        banners.stop()
        sources.stop()
        sourceTask?.cancel()
        sourceTask = nil
        sourceQueue.removeAll()
        task?.cancel()
        task = nil
    }

    private func enqueueSources(_ updates: [NotificationSourceAttribution]) {
        sourceQueue.append(contentsOf: updates.map { ($0, sourceEpoch) })
        guard !sourceQueue.isEmpty, sourceTask == nil else { return }
        let current = generation
        sourceTask = Task { [weak self] in
            guard let self else { return }
            // Resolve uncommon app names off-main, but preserve source-update order. Otherwise
            // a slow name lookup could reapply an arrival match after its conflict was received.
            while !self.sourceQueue.isEmpty {
                let entry = self.sourceQueue.removeFirst()
                let source = entry.source
                var name = self.appNames[source.bundleID]
                if name == nil && !source.bundleID.isEmpty {
                    name = await Task.detached(priority: .utility) {
                        Self.applicationName(bundleID: source.bundleID)
                    }.value ?? source.bundleID
                }
                guard !Task.isCancelled, self.generation == current else { return }
                guard source.evidence != .arrival || entry.epoch == self.sourceEpoch else { continue }
                if !source.bundleID.isEmpty { self.appNames[source.bundleID] = name }
                self.onSource?(source, name ?? "")
                guard !Task.isCancelled, self.generation == current else { return }
            }
            self.sourceTask = nil
        }
    }

    private func publishStatus() {
        onStatus?([bannerStatus, storeStatus, sourceStatus].filter { !$0.isEmpty }.joined(separator: " "))
    }

    nonisolated private static func applicationName(bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              let bundle = Bundle(url: url), bundle.bundleIdentifier == bundleID else { return nil }
        return (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
    }
}
