import Foundation

/// Poll the system's retained notification store instead of the visible Notification Center UI.
/// Every successful snapshot reaches the durable cursor, including the first and an empty store;
/// only that cursor decides what is new. Failed reads never look like a successful empty snapshot.
/// This private database adapter requires Sill's own system file-access authorization and cannot
/// recover notifications removed entirely between polls, or ones the system never stored.
@MainActor
final class NotificationMirrorCollector {
    var onSnapshot: ((NotificationStoreSnapshot) -> Void)?
    var onStatus: ((String) -> Void)?
    private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        onStatus?(String(localized: "Opening the Mac notification store…"))
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
                        self.onStatus?(String(localized: "Notification store access is working. Stored notifications are checked every 2 seconds."))
                    } else {
                        self.onStatus?(String(localized: "Notification store access is working. \(snapshot.skippedRecordCount) stored notifications have unsupported content and were skipped."))
                    }
                } catch {
                    guard !Task.isCancelled, let self else { return }
                    // Error descriptions contain status/codes only, never notification payloads.
                    self.onStatus?((error as? LocalizedError)?.errorDescription
                        ?? String(localized: "The notification store could not be read. Sill will retry."))
                }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
