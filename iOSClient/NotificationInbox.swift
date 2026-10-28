import Foundation
import Combine
import CryptoKit
import UIKit
import UserNotifications
import StreamProtocol

/// App-owned notification history and the iOS delivery endpoint. The App delegate retains this
/// before a window exists; every window sees the same inbox. StreamClient only supplies events
/// and icons from its authenticated session, and never owns the APNs token or notification history.
final class NotificationInbox: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    struct Entry: Codable, Equatable, Identifiable {
        var macID: String
        var macName: String
        var event: MirroredNotification
        var read: Bool
        var id: String { macID + ":" + event.id }
    }

    struct PushRegistration: Equatable {
        var token: String
        var topic: String
        var environment: String
    }

    struct HistoryCursor: Codable, Equatable {
        var historyID: String
        var lastSequence: Int64
    }

    /// A cleared APNs summary can be ahead of TLS. Hide only that revision while replay fills
    /// the gap; once TLS reaches it, the normal cursor makes this temporary tombstone redundant.
    private struct ClearedRevision: Codable {
        var macID: String
        var historyID: String
        var sequence: Int64
    }

    private struct History: Codable {
        var entries: [Entry]
        var cursors: [String: HistoryCursor]
        var clearedRevisions: [String: ClearedRevision]?
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var enabled: Bool
    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined
    @Published private(set) var pushRegistration: PushRegistration?
    @Published private(set) var registrationProblem: String?
    @Published private(set) var persistenceProblem: String?
    @Published private(set) var icons: [String: UIImage] = [:]
    /// Consumed by one foreground window's inbox button after a system notification was tapped.
    @Published private(set) var presentationRequest: UUID?

    private static let enabledKey = "Sill.mirrorNotifications"
    private let defaults: UserDefaults
    private let center: UNUserNotificationCenter
    private let historyURL: URL?
    /// The pending cursor belongs to the in-memory entries. Only the cursor from a successful
    /// atomic save may be sent on reconnect; an interrupted/failed save must replay that batch.
    private var cursors: [String: HistoryCursor] = [:]
    private var savedCursors: [String: HistoryCursor] = [:]
    private var clearedRevisions: [String: ClearedRevision] = [:]
    private var persistenceScheduled = false
    private var savedMacStore: SavedMacStore?
    private var savedMacChanges: AnyCancellable?
    private var activation: NSObjectProtocol?
    private var installed = false
    private var token: String?
    private var pendingPushes: [(event: MirroredNotification, macID: String, tapped: Bool)] = []

    init(defaults: UserDefaults = .standard, center: UNUserNotificationCenter = .current(),
         historyURL: URL? = NotificationInbox.defaultHistoryURL) {
        self.defaults = defaults
        self.center = center
        self.historyURL = historyURL
        enabled = defaults.bool(forKey: Self.enabledKey)
        super.init()
        if let url = historyURL, let data = try? Data(contentsOf: url) {
            if let history = try? JSONDecoder().decode(History.self, from: data) {
                entries = history.entries
                cursors = history.cursors
                savedCursors = history.cursors
                clearedRevisions = history.clearedRevisions ?? [:]
            } else if let legacy = try? JSONDecoder().decode([Entry].self, from: data) {
                // Upgrade the original inbox without discarding any of its surviving entries.
                entries = legacy
            }
        }
    }

    var unreadCount: Int { entries.filter { !$0.read }.count }

    func historyCursor(for macID: String) -> HistoryCursor? { savedCursors[macID] }

    /// Called during didFinishLaunching, before iOS can deliver a cold-start notification action.
    /// Permission is requested only by setEnabled(true), after the person's explicit choice.
    func install() {
        guard !installed else { return }
        installed = true
        center.delegate = self
        if !enabled { stopPushRegistration() }
        activation = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                            object: nil, queue: .main) { [weak self] _ in
            self?.refreshAuthorization()
            self?.importDeliveredNotifications()
        }
        refreshAuthorization()
    }

    /// Attaches the App's canonical paired-device data once its SwiftUI scene is ready. A push
    /// tapped before then waits here; a forgotten Mac's events never recreate its paired record.
    func attach(to store: SavedMacStore) {
        guard savedMacStore !== store else { return }
        savedMacStore = store
        pruneForgottenMacs()
        savedMacChanges = store.$snapshot.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.pruneForgottenMacs()
        }
        let pending = pendingPushes
        pendingPushes = []
        for item in pending {
            if receive(item.event, from: item.macID), item.tapped { presentationRequest = UUID() }
        }
        importDeliveredNotifications()
    }

    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        enabled = value
        defaults.set(value, forKey: Self.enabledKey)
        if !value {
            stopPushRegistration()
            return
        }
        // No launch-time prompt: this request follows only the inbox's opt-in switch.
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error { self.registrationProblem = error.localizedDescription }
                self.refreshAuthorization()
            }
        }
    }

    private func refreshAuthorization() {
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self else { return }
                self.authorization = settings.authorizationStatus
                guard self.enabled else { return }
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral:
                    // Apple asks for registration at each launch; tokens can change. Keep the
                    // returned token in memory, then let each paired TLS session register it.
                    UIApplication.shared.registerForRemoteNotifications()
                    self.updatePushRegistration()
                default:
                    self.pushRegistration = nil
                }
            }
        }
    }

    func registeredForPush(_ data: Data) {
        // A registration already in flight may finish after the person turned mirroring off.
        // Unregister again then, rather than letting that late callback restore remote delivery.
        guard enabled else { stopPushRegistration(); return }
        token = data.map { String(format: "%02x", $0) }.joined()
        registrationProblem = nil
        updatePushRegistration()
    }

    func failedToRegisterForPush(_ error: Error) {
        token = nil
        pushRegistration = nil
        registrationProblem = error.localizedDescription
    }

    private func stopPushRegistration() {
        UIApplication.shared.unregisterForRemoteNotifications()
        token = nil
        pushRegistration = nil
        // Connected relays also send enabled:false. System unregistration covers the offline
        // case; it cannot retract an alert that has already been handed to iOS for presentation.
    }

    private func updatePushRegistration() {
        guard enabled, let token else { return }
        guard [.authorized, .provisional, .ephemeral].contains(authorization) else {
            pushRegistration = nil
            return
        }
        // An explicit signing/build configuration supplies this value. Debug vs. Release does
        // not establish which APNs environment the provisioning profile actually permits.
        guard let environment = Bundle.main.object(forInfoDictionaryKey: "SillAPNSEnvironment") as? String,
              ["sandbox", "production"].contains(environment), let topic = Bundle.main.bundleIdentifier else {
            registrationProblem = String(localized: "This build has no APNs environment configured. Live notifications still work while connected.")
            pushRegistration = nil
            return
        }
        pushRegistration = PushRegistration(token: token, topic: topic, environment: environment)
    }

    /// Direct TLS and APNs carry the same event ID. An event is stored once, regardless of the
    /// number of windows or delivery paths that received it. Direct delivery never schedules a
    /// second local notification: iOS presents the Mac provider's APNs alert itself.
    @discardableResult
    func receive(_ event: MirroredNotification, from macID: String, direct: Bool = false) -> Bool {
        guard enabled, let store = savedMacStore, let mac = store.snapshot.macs.first(where: { $0.macID == macID }),
              !event.id.isEmpty else { return false }
        let id = macID + ":" + event.id
        let index = entries.firstIndex(where: { $0.id == id })
        let incomingCursor: HistoryCursor?
        if let historyID = event.historyID, !historyID.isEmpty,
           let sequence = event.sequence, sequence > 0 {
            incomingCursor = HistoryCursor(historyID: historyID, lastSequence: sequence)
        } else {
            incomingCursor = nil
        }
        let cleared = clearedRevisions[id]
        let wasCleared = incomingCursor.map {
            cleared?.historyID == $0.historyID && $0.lastSequence <= (cleared?.sequence ?? 0)
        } ?? false
        if let incomingCursor, let cursor = cursors[macID],
           cursor.historyID == incomingCursor.historyID,
           incomingCursor.lastSequence <= cursor.lastSequence, index == nil {
            // A reconnect (or Notification Center import) cannot resurrect a cleared entry.
            if direct, persistenceProblem != nil { persist() }
            return true
        }
        if direct, let incomingCursor {
            let old = cursors[macID]
            if old?.historyID != incomingCursor.historyID || incomingCursor.lastSequence > (old?.lastSequence ?? 0) {
                // Host replay/live delivery is ordered. APNs summaries never enter this path:
                // receiving push #20 says nothing about whether TLS #1...19 were saved.
                cursors[macID] = incomingCursor
                clearedRevisions = clearedRevisions.filter {
                    $0.value.macID != macID || ($0.value.historyID == incomingCursor.historyID &&
                                               $0.value.sequence > incomingCursor.lastSequence)
                }
            }
        }
        if wasCleared {
            if direct { persist() }
            return true
        }
        if let i = index {
            // APNs may carry a size-limited summary. A later direct event supplies its full text,
            // preserving read state and position; a later push never downgrades the direct text.
            if direct {
                let old = entries[i].event
                let olderRevision = old.historyID == event.historyID &&
                    (old.sequence ?? 0) > (event.sequence ?? 0)
                if !olderRevision, old != event { entries[i].event = event }
                persist()
            }
            return true
        }
        entries.insert(Entry(macID: macID, macName: mac.name, event: event, read: false), at: 0)
        persist()
        syncSavedIcons()
        return true
    }

    func cacheIcon(_ image: UIImage, bundleID: String, macID: String) {
        guard !bundleID.isEmpty else { return }
        let key = macID + ":" + bundleID
        icons[key] = image
        if entries.contains(where: { iconKey(for: $0) == key }) { persistIcon(image, key: key) }
    }

    func icon(for entry: Entry) -> UIImage? { icons[entry.macID + ":" + entry.event.appBundleID] }

    func markAllRead() {
        guard unreadCount > 0 else { return }
        entries = entries.map { var entry = $0; entry.read = true; return entry }
        persist()
    }

    func clearHistory() {
        for entry in entries {
            guard let historyID = entry.event.historyID, !historyID.isEmpty,
                  let sequence = entry.event.sequence, sequence > 0 else { continue }
            let cursor = cursors[entry.macID]
            if cursor?.historyID != historyID || sequence > (cursor?.lastSequence ?? 0) {
                clearedRevisions[entry.id] = ClearedRevision(macID: entry.macID, historyID: historyID,
                                                            sequence: sequence)
            }
        }
        entries = []
        // Keep the checkpoint even though its visible events were deliberately removed.
        persistNow()
        syncSavedIcons()
        // Otherwise the next foreground import would restore the alerts the person just cleared.
        center.removeAllDeliveredNotifications()
    }

    func consumePresentationRequest() -> Bool {
        guard presentationRequest != nil else { return false }
        presentationRequest = nil
        return true
    }

    private func pruneForgottenMacs() {
        guard let store = savedMacStore else { return }
        let kept = Set(store.snapshot.macs.map(\.macID))
        let next = entries.filter { kept.contains($0.macID) }
        let nextCursors = cursors.filter { kept.contains($0.key) }
        let nextCleared = clearedRevisions.filter { kept.contains($0.value.macID) }
        if next != entries || nextCursors != cursors || nextCleared.count != clearedRevisions.count {
            entries = next
            cursors = nextCursors
            clearedRevisions = nextCleared
            savedCursors = savedCursors.filter { kept.contains($0.key) }
            persistNow()
        }
        syncSavedIcons()
    }

    private static var defaultHistoryURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SillNotifications", isDirectory: true).appendingPathComponent("inbox.json")
    }

    private func persist() {
        guard !persistenceScheduled else { return }
        persistenceScheduled = true
        // Replay can contain many events. Save each short batch once, with its checkpoint in
        // the same JSON transaction, instead of rewriting an ever-growing inbox for every row.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.persistenceScheduled = false
            self.persistNow()
        }
    }

    private func persistNow() {
        guard savedMacStore?.savedMacsSeeded != true else { return }
        do {
            guard let url = historyURL else { throw CocoaError(.fileNoSuchFile) }
            let data = try JSONEncoder().encode(History(entries: entries, cursors: cursors,
                                                       clearedRevisions: clearedRevisions))
            var directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            // After first unlock, background delivery may save while the device is locked.
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            savedCursors = cursors
            persistenceProblem = nil
        } catch {
            // Retain the batch in memory, but reconnect from the last successful checkpoint.
            persistenceProblem = String(localized: "Notification history could not be saved. Reconnect to recover it from your Mac.")
        }
    }

    private func iconKey(for entry: Entry) -> String { entry.macID + ":" + entry.event.appBundleID }

    private var iconsDirectory: URL? {
        historyURL?.deletingLastPathComponent().appendingPathComponent("icons", isDirectory: true)
    }

    private static func iconFile(_ key: String) -> String {
        // A fixed filename keeps the wire's bundle ID out of filesystem paths.
        Base64URL.encode(Data(SHA256.hash(data: Data(key.utf8)))) + ".png"
    }

    private func persistIcon(_ image: UIImage, key: String) {
        guard savedMacStore?.savedMacsSeeded != true, let directory = iconsDirectory,
              let png = image.pngData() else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        try? png.write(to: directory.appendingPathComponent(Self.iconFile(key)),
                       options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Only source icons referenced by the inbox belong on disk. Reuse the App Support
    /// directory's backup exclusion and file protection; cold launches need no active stream to
    /// show these icons. Forget and Clear remove icons with no remaining entries.
    private func syncSavedIcons() {
        let keys = Set(entries.filter { !$0.event.appBundleID.isEmpty }.map(iconKey))
        var shown = icons.filter { keys.contains($0.key) }
        guard savedMacStore?.savedMacsSeeded != true, let directory = iconsDirectory else {
            icons = shown
            return
        }
        for key in keys {
            let url = directory.appendingPathComponent(Self.iconFile(key))
            if let image = shown[key] {
                if !FileManager.default.fileExists(atPath: url.path) { persistIcon(image, key: key) }
            } else if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                shown[key] = image
            }
        }
        icons = shown
        let kept = Set(keys.map(Self.iconFile))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for file in files where file.hasSuffix(".png") && !kept.contains(file) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
        }
    }

    private func pushEvent(_ userInfo: [AnyHashable: Any]) -> (event: MirroredNotification, macID: String)? {
        guard let envelope = userInfo["sill"] as? [String: Any], let macID = envelope["macID"] as? String,
              let event = envelope["event"] as? [String: Any], JSONSerialization.isValidJSONObject(event),
              let data = try? JSONSerialization.data(withJSONObject: event),
              let decoded = Wire.decode(MirroredNotification.self, from: data) else { return nil }
        return (decoded, macID)
    }

    @discardableResult
    private func receivePush(_ userInfo: [AnyHashable: Any], tapped: Bool) -> Bool {
        guard let item = pushEvent(userInfo), enabled else { return false }
        guard savedMacStore != nil else {
            pendingPushes.append((item.event, item.macID, tapped))
            return false
        }
        let accepted = receive(item.event, from: item.macID)
        if accepted, tapped { presentationRequest = UUID() }
        return accepted
    }

    private func importDeliveredNotifications() {
        // Alert pushes do not promise execution while the App is suspended or terminated. On
        // return, recover what is still in Notification Center; cleared notifications are gone.
        center.getDeliveredNotifications { [weak self] notifications in
            DispatchQueue.main.async {
                for notification in notifications.sorted(by: { $0.date < $1.date }) {
                    self?.receivePush(notification.request.content.userInfo, tapped: false)
                }
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        DispatchQueue.main.async {
            let accepted = self.receivePush(notification.request.content.userInfo, tapped: false)
            completionHandler(accepted ? [.banner, .list, .sound] : [])
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async {
            self.receivePush(response.notification.request.content.userInfo,
                             tapped: response.actionIdentifier == UNNotificationDefaultActionIdentifier)
            completionHandler()
        }
    }
}
