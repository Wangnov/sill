import Foundation

/// Two complementary sources: AX events capture visible banners before the system persists them,
/// while retained snapshots recover banners that never appeared. The durable history merges
/// their exact system UUIDs; this collector never guesses identity from notification text.
@MainActor
final class NotificationMirrorCollector {
    var onSnapshot: ((NotificationStoreSnapshot) -> Void)?
    var onBanner: ((NotificationBannerObservation) -> Void)?
    var onStatus: ((String) -> Void)?
    private let banners = NotificationBannerObserver()
    private var task: Task<Void, Never>?
    private var bannerStatus = ""
    private var storeStatus = ""

    func start() {
        guard task == nil else { return }
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
        banners.start()
        publishStatus()
        let excludedBundleIDs = Set([Bundle.main.bundleIdentifier].compactMap { $0 })
        task = Task { [weak self] in
            // InstalledApps uses FileManager and Bundle only. Keep discovery and all SQLite/plist
            // work off the main actor; a locked or busy store must never stall Sill's settings UI.
            let appNames = await Task.detached(priority: .utility) {
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                return Dictionary(InstalledApps.find(in: ["/Applications", "/System/Applications", home + "/Applications"])
                    .map { ($0.bundleID, $0.name) }, uniquingKeysWith: { first, _ in first })
            }.value
            let reader = NotificationStoreReader(url: NotificationStoreReader.defaultURL,
                                                 appNames: appNames, excludedBundleIDs: excludedBundleIDs)
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
        banners.stop()
        task?.cancel()
        task = nil
    }

    private func publishStatus() {
        onStatus?([bannerStatus, storeStatus].filter { !$0.isEmpty }.joined(separator: " "))
    }
}
