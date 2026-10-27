import AppKit
import ApplicationServices
import CryptoKit
import Foundation
import StreamProtocol

/// Experimental, public-AX-only observation. macOS has no public API that streams every other
/// app's notifications. This does not read Notification Center's database, open its UI, request
/// TCC permission, or claim to see hidden/suppressed banners. In particular, an OS update can
/// change the accessible text enough that nothing is collected; the explicit test path in
/// NotificationMirror remains useful without this collector.
@MainActor
final class NotificationMirrorCollector {
    var onNotification: ((MirroredNotification) -> Void)?
    var onStatus: ((String) -> Void)?
    private var task: Task<Void, Never>?
    private var visibleKeys: Set<String> = []
    private var hasBaseline = false

    func start() {
        guard task == nil else { return }
        visibleKeys = []
        hasBaseline = false
        let catalog = NotificationApplicationCatalog.installed()
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !AXIsProcessTrusted() {
                    self.onStatus?(String(localized: "Accessibility permission is required to observe exposed notification text."))
                } else if let process = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first {
                    // AX calls can wait on another process. Keep them off the main actor and bound
                    // both the walk and each call; one slow Notification Center must not stall UI.
                    let pid = process.processIdentifier
                    let snapshot = await Task.detached(priority: .utility) {
                        NotificationAXSnapshot.read(pid: pid, catalog: catalog)
                    }.value
                    guard !Task.isCancelled else { return }
                    if snapshot.available {
                        self.onStatus?(String(localized: "Experimental AX observation is running. Hidden, grouped or short-lived notifications may be missed."))
                        let previousKeys = self.visibleKeys
                        var currentKeys: Set<String> = []
                        for candidate in snapshot.notifications {
                            guard currentKeys.insert(candidate.key).inserted else { continue }
                            if self.hasBaseline, !previousKeys.contains(candidate.key) {
                                self.onNotification?(candidate.event)
                            }
                        }
                        // Deduplicate only while this content stays exposed. Once it disappears,
                        // the same app/title/body can be a new notification and must pass again.
                        self.visibleKeys = currentKeys
                        // Do not replay the notifications already exposed when observation starts.
                        self.hasBaseline = true
                    } else {
                        self.onStatus?(String(localized: "Notification Center did not expose readable notification windows. The test notification is still available."))
                    }
                } else {
                    self.visibleKeys = []
                    self.onStatus?(String(localized: "Waiting for Notification Center. The test notification is still available."))
                }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        visibleKeys = []
        hasBaseline = false
    }
}

/// Resolve names only when the installed applications give one unambiguous bundle ID. We never
/// manufacture an identifier from a name, and never forward Sill's own notifications.
private struct NotificationApplicationCatalog: Sendable {
    struct App: Sendable { let bundleID: String; let name: String }
    let names: [String: App]

    static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    static func installed() -> Self {
        let roots = [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications"),
                     FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        var matches: [String: [String: App]] = [:]
        for root in roots {
            guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in files where url.pathExtension == "app" {
                guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
                      id != Bundle.main.bundleIdentifier, !id.hasPrefix("me.saffer.sill") else { continue }
                let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                let app = App(bundleID: id, name: name)
                let aliases = [name, url.deletingPathExtension().lastPathComponent,
                               bundle.infoDictionary?["CFBundleDisplayName"] as? String,
                               bundle.infoDictionary?["CFBundleName"] as? String].compactMap { $0 }
                for alias in aliases { matches[normalized(alias), default: [:]][id] = app }
            }
        }
        return Self(names: matches.compactMapValues { $0.count == 1 ? $0.values.first : nil })
    }
}

/// A generic AX tree walk, not a private Notification Center hierarchy contract. A candidate
/// must be a small group whose first exposed text/image label names exactly one installed app.
/// We take the smallest such group and its remaining static text. Anything ambiguous is skipped;
/// names/contents are never logged. This heuristic needs real-banner verification on each OS.
private struct NotificationAXSnapshot: Sendable {
    struct Candidate: Sendable { let key: String; let event: MirroredNotification }
    let available: Bool
    let notifications: [Candidate]

    static func read(pid: pid_t, catalog: NotificationApplicationCatalog) -> Self {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.04)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return Self(available: false, notifications: []) }
        var reader = Reader(catalog: catalog)
        for window in windows.prefix(8) { _ = reader.walk(window, depth: 0) }
        return Self(available: true, notifications: Array(reader.candidates.prefix(12)))
    }

    private struct Reader {
        let catalog: NotificationApplicationCatalog
        let deadline = Date().addingTimeInterval(0.3)
        var remaining = 160
        var candidates: [Candidate] = []

        mutating func walk(_ element: AXUIElement, depth: Int) -> [String] {
            guard depth < 14, remaining > 0, Date() < deadline else { return [] }
            remaining -= 1
            AXUIElementSetMessagingTimeout(element, 0.04)
            let role = string(element, kAXRoleAttribute)
            if role == kAXStaticTextRole {
                if let text = string(element, kAXValueAttribute) ?? string(element, kAXTitleAttribute), !text.isEmpty {
                    return [String(text.prefix(1000))]
                }
                return []
            }
            if role == kAXImageRole {
                // An image's description is used only if it is an exact installed-app name.
                let label = string(element, kAXDescriptionAttribute) ?? string(element, kAXTitleAttribute) ?? ""
                return catalog.names[NotificationApplicationCatalog.normalized(label)] == nil ? [] : [label]
            }
            let before = candidates.count
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
                  let children = value as? [AXUIElement] else { return [] }
            var texts: [String] = []
            for child in children.prefix(40) {
                texts += walk(child, depth: depth + 1)
                if texts.count > 8 { break }
            }
            // Never combine sibling notifications into a single event. Child candidates win.
            guard candidates.count == before, role == kAXGroupRole, (2...8).contains(texts.count),
                  let first = texts.first,
                  let source = catalog.names[NotificationApplicationCatalog.normalized(first)] else { return texts }
            let remainingTexts = texts.dropFirst().filter { NotificationApplicationCatalog.normalized($0) != NotificationApplicationCatalog.normalized(first) }
            guard !remainingTexts.isEmpty else { return texts }
            let title = String(remainingTexts.first!.prefix(240))
            let body = String(remainingTexts.dropFirst().joined(separator: "\n").prefix(1800))
            let signature = [source.bundleID, title, body].joined(separator: "\u{0}")
            let key = SHA256.hash(data: Data(signature.utf8)).map { String(format: "%02x", $0) }.joined()
            let event = MirroredNotification(appBundleID: source.bundleID, appName: source.name, title: title, body: body)
            candidates.append(Candidate(key: key, event: event))
            return texts
        }

        private func string(_ element: AXUIElement, _ attribute: String) -> String? {
            guard Date() < deadline else { return nil }
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
                  let string = value as? String else { return nil }
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
