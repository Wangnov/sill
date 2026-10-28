import AppKit

/// AX preserves live text, retained snapshots recover hidden banners, and usernoted's removal
/// metadata identifies replaced banners that never reached the store. Joins use full UUIDs.
@MainActor
final class NotificationMirrorCollector {
    var onSnapshot: ((NotificationStoreSnapshot) -> Void)?
    var onBanner: ((NotificationBannerObservation) -> Void)?
    var onSource: ((NotificationSourceAttribution, String) -> Void)?
    var onStatus: ((String) -> Void)?
    private let banners = NotificationBannerObserver()
    private let sources = NotificationSourceObserver()
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
        banners.onObservation = { [weak self] in self?.onBanner?($0) }
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
        sources.onSource = { [weak self] source in
            guard let self else { return }
            Task { [weak self] in
                // Launch Services also knows development apps outside /Applications. Resolve a
                // name from an already identified bundle; never infer the bundle from body text.
                let name = await Task.detached(priority: .utility) {
                    Self.applicationName(bundleID: source.bundleID)
                }.value
                guard let self, self.generation == current else { return }
                self.onSource?(source, name ?? self.appNames[source.bundleID] ?? source.bundleID)
            }
        }
        sources.onStatus = { [weak self] status in
            guard let self else { return }
            switch status {
            case .running:
                self.sourceStatus = String(localized: "Source recovery for replaced notifications is connected.")
            case .unavailable:
                self.sourceStatus = String(localized: "Source recovery is unavailable. Live banners and stored notifications still work.")
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
        task?.cancel()
        task = nil
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
