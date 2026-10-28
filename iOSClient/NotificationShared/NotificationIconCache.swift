import CryptoKit
import Foundation

/// The paired TLS session supplies these PNGs. The notification extension only reads them;
/// neither APNs nor the extension downloads an icon or guesses one from an application name.
struct NotificationIconCache {
    private let directory: URL

    init?(bundle: Bundle = .main) {
        guard let group = bundle.object(forInfoDictionaryKey: "SillNotificationAppGroup") as? String,
              !group.isEmpty, !group.contains("$("),
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            return nil
        }
        directory = container.appendingPathComponent("NotificationIcons", isDirectory: true)
    }

    func pngData(macID: String, bundleID: String) -> Data? {
        guard let url = iconURL(macID: macID, bundleID: bundleID) else { return nil }
        return try? Data(contentsOf: url)
    }

    func containsIcon(macID: String, bundleID: String) -> Bool {
        guard let url = iconURL(macID: macID, bundleID: bundleID) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    func storePNG(_ data: Data, macID: String, bundleID: String) throws {
        guard let url = iconURL(macID: macID, bundleID: bundleID), !data.isEmpty else { return }
        let protection: [FileAttributeKey: Any] = [
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
        ]
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: protection)
        var root = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                    attributes: protection)
        // An atomic replacement is safe while the extension reads. After first unlock, both
        // directories and PNGs remain accessible to an extension delivering a locked alert.
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Forgetting a Mac removes its entire catalog. Clearing the visible inbox must not call
    /// this: the next alert may need an app icon before another TLS connection can happen.
    func retainMacs(_ macIDs: Set<String>) {
        let kept = Set(macIDs.map(Self.component))
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil)) ?? []
        for folder in folders where !kept.contains(folder.lastPathComponent) {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// Separate digests keep arbitrary source identifiers out of paths and avoid ambiguous
    /// concatenations when the same bundle ID exists on more than one paired Mac.
    static func sourceIdentifier(macID: String, bundleID: String) -> String {
        component(macID) + "." + component(bundleID)
    }

    private func iconURL(macID: String, bundleID: String) -> URL? {
        guard !macID.isEmpty, !bundleID.isEmpty else { return nil }
        return directory.appendingPathComponent(Self.component(macID), isDirectory: true)
            .appendingPathComponent(Self.component(bundleID) + ".png")
    }

    private static func component(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
