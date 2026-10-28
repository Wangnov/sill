import AppKit
import ApplicationServices

private struct BannerAXElement: @unchecked Sendable {
    let value: AXUIElement
}

private struct BannerAXEvent: @unchecked Sendable {
    let node: BannerAXElement
    let observer: AXObserver
}

private func notificationBannerCallback(_ observer: AXObserver, _ element: AXUIElement,
                                        _ notification: CFString, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let owner = Unmanaged<NotificationBannerObserver>.fromOpaque(context).takeUnretainedValue()
    let event = BannerAXEvent(node: BannerAXElement(value: element), observer: observer)
    Task { @MainActor [weak owner] in owner?.received(event) }
}

/// A public Accessibility event source for visible notification banners. The AXGroup identifier
/// is the notification UUID on the verified macOS 27 tree; widgets without that identity are
/// ignored. This is UI text, not an original UserNotifications payload: hidden banners/previews
/// cannot supply their full content, and the retained store still supplies the posting bundle ID.
///
/// Observer registration and callbacks belong to the main run loop. All AX traversal runs on one
/// utility queue with per-call timeouts and a short total budget, never on the app's UI thread.
/// This source neither logs notification text nor dismisses or otherwise changes notifications.
@MainActor
final class NotificationBannerObserver {
    enum Status: Equatable {
        case permissionRequired
        case waitingForHost
        /// At least one event registration succeeded; unsupported event names remain visible.
        case running(registrationErrors: [String: Int32])
        case registrationFailed([String: Int32])
    }

    var onObservation: ((NotificationBannerObservation) -> Void)?
    var onStatus: ((Status) -> Void)?

    private static let bundleID = "com.apple.notificationcenterui"
    private static let notifications = [kAXLayoutChangedNotification, kAXCreatedNotification,
                                        kAXWindowCreatedNotification]
    private let reader = NotificationBannerAXReader()
    private var observer: AXObserver?
    private var application: AXUIElement?
    private var pid: pid_t = 0
    private var generation = 0
    private var maintenance: Task<Void, Never>?
    private var reads: [CFHashCode: Task<Void, Never>] = [:]
    private var dirty: [CFHashCode: BannerAXElement] = [:]
    private var retries: [CFHashCode: (id: UUID, task: Task<Void, Never>)] = [:]
    private var lastStatus: Status?
    private var lastFields: [String: NotificationBannerParser.Fields] = [:]
    private var identities: [String] = []

    func start() {
        guard maintenance == nil else { return }
        connectIfNeeded()
        maintenance = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self else { return }
                self.connectIfNeeded()
            }
        }
    }

    func stop() {
        maintenance?.cancel()
        maintenance = nil
        disconnect()
        lastStatus = nil
        lastFields.removeAll()
        identities.removeAll()
    }

    private func connectIfNeeded() {
        // Query only: enabling the mirror never opens a permission prompt or changes TCC.
        guard AXIsProcessTrusted() else {
            disconnect()
            status(.permissionRequired)
            return
        }
        guard let host = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == Self.bundleID }) else {
            disconnect()
            status(.waitingForHost)
            return
        }
        guard observer == nil || host.processIdentifier != pid else { return }
        disconnect()
        pid = host.processIdentifier
        let app = AXUIElementCreateApplication(pid)
        var created: AXObserver?
        let result = AXObserverCreate(pid, notificationBannerCallback, &created)
        guard result == .success, let created else {
            status(.registrationFailed(["AXObserverCreate": result.rawValue]))
            return
        }
        var errors: [String: Int32] = [:]
        var successes = 0
        let context = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.notifications {
            let error = AXObserverAddNotification(created, app, name as CFString, context)
            if error == .success || error == .notificationAlreadyRegistered { successes += 1 }
            else { errors[name] = error.rawValue }
        }
        guard successes > 0 else {
            status(.registrationFailed(errors))
            return
        }
        application = app
        observer = created
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        status(.running(registrationErrors: errors))
    }

    private func disconnect() {
        generation += 1
        for task in reads.values { task.cancel() }
        for retry in retries.values { retry.task.cancel() }
        reads.removeAll()
        dirty.removeAll()
        retries.removeAll()
        if let observer, let application {
            for name in Self.notifications {
                AXObserverRemoveNotification(observer, application, name as CFString)
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        application = nil
        pid = 0
    }

    private func status(_ next: Status) {
        guard next != lastStatus else { return }
        lastStatus = next
        onStatus?(next)
    }

    fileprivate func received(_ event: BannerAXEvent) {
        // A callback already queued on the main actor can outlive stop/re-arm on the same PID.
        guard let observer, CFEqual(observer, event.observer) else { return }
        let node = event.node
        var sourcePID: pid_t = 0
        guard AXUIElementGetPid(node.value, &sourcePID) == .success, sourcePID == pid else { return }
        let key = CFHash(node.value)
        requestRead(node)
        retries[key]?.task.cancel()
        let id = UUID()
        let current = generation
        let task = Task { [weak self] in
            // The callback can precede population of title/body. These finite follow-ups also
            // catch a replacement made in the same AX group; there is no idle full-tree poll.
            for delay in [0.1, 0.2, 0.3] {
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard let self, self.generation == current else { return }
                self.requestRead(node)
            }
            if let self, self.retries[key]?.id == id { self.retries.removeValue(forKey: key) }
        }
        retries[key] = (id, task)
    }

    private func requestRead(_ node: BannerAXElement) {
        let key = CFHash(node.value)
        if reads[key] != nil { dirty[key] = node; return }
        // Bursts are coalesced by callback element, with a small bound on outstanding IPC work.
        guard reads.count < 32 else { return }
        let current = generation
        let sourcePID = pid
        reads[key] = Task { [weak self, reader] in
            let observations = await reader.read(node, pid: sourcePID)
            guard let self, !Task.isCancelled, self.generation == current else { return }
            self.reads.removeValue(forKey: key)
            for observation in observations {
                guard !Task.isCancelled, self.generation == current else { return }
                self.accept(observation)
            }
            guard self.generation == current else { return }
            if let next = self.dirty.removeValue(forKey: key) { self.requestRead(next) }
        }
    }

    private func accept(_ observation: NotificationBannerObservation) {
        let fields = NotificationBannerParser.Fields(title: observation.title, subtitle: observation.subtitle,
                                                     body: observation.body, displayAppName: observation.displayAppName)
        guard lastFields[observation.sourceUUID] != fields else { return }
        if lastFields[observation.sourceUUID] == nil { identities.append(observation.sourceUUID) }
        lastFields[observation.sourceUUID] = fields
        if identities.count > 512 { lastFields.removeValue(forKey: identities.removeFirst()) }
        // Compare the previous version, not a set of all text ever seen: A → B → A is observable.
        onObservation?(observation)
    }
}

/// Immutable AX handles cross to this serial queue; no UI or observer state is read there.
private final class NotificationBannerAXReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "sill.notification-banners", qos: .utility)

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.withLock { cancelled = true } }
        var isCancelled: Bool { lock.withLock { cancelled } }
    }

    func read(_ node: BannerAXElement, pid: pid_t) async -> [NotificationBannerObservation] {
        let cancellation = Cancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    continuation.resume(returning: Read(pid: pid, cancellation: cancellation).run(node.value))
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    private final class Read {
        let pid: pid_t
        let cancellation: Cancellation
        let deadline = ProcessInfo.processInfo.systemUptime + 0.15
        var remaining = 240
        var observations: [NotificationBannerObservation] = []
        var found: Set<String> = []
        init(pid: pid_t, cancellation: Cancellation) { self.pid = pid; self.cancellation = cancellation }
        var available: Bool {
            !cancellation.isCancelled && remaining > 0 && ProcessInfo.processInfo.systemUptime < deadline
        }

        func values(_ node: AXUIElement, _ names: [String]) -> [Any] {
            guard available else { return [] }
            remaining -= 1
            AXUIElementSetMessagingTimeout(node, 0.02)
            var output: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(node, names as CFArray,
                    AXCopyMultipleAttributeOptions(rawValue: 0), &output) == .success else { return [] }
            return output as? [Any] ?? []
        }

        func run(_ node: AXUIElement) -> [NotificationBannerObservation] {
            guard available else { return [] }
            var sourcePID: pid_t = 0
            guard AXUIElementGetPid(node, &sourcePID) == .success, sourcePID == pid else { return [] }
            var ancestor = node
            for _ in 0..<10 {
                let v = values(ancestor, [kAXRoleAttribute, kAXIdentifierAttribute, kAXParentAttribute])
                guard v.count == 3 else { break }
                if (v[0] as? String) == kAXGroupRole,
                   let id = v[1] as? String, let uuid = NotificationBannerParser.normalizedUUID(id) {
                    readGroup(ancestor, uuid: uuid)
                    return observations
                }
                if (v[0] as? String) == kAXApplicationRole { break }
                guard CFGetTypeID(v[2] as CFTypeRef) == AXUIElementGetTypeID() else { break }
                let parent = v[2] as! AXUIElement
                if CFEqual(parent, ancestor) { break }
                ancestor = parent
            }
            // LayoutChanged can name the list's scroll area instead of one group. Search only
            // that callback subtree, never the application's AXWindows or an unrelated widget tree.
            findGroups(node, depth: 0)
            return observations
        }

        func findGroups(_ node: AXUIElement, depth: Int) {
            guard depth < 10, available else { return }
            let v = values(node, [kAXRoleAttribute, kAXIdentifierAttribute, kAXChildrenAttribute])
            guard v.count == 3 else { return }
            if (v[0] as? String) == kAXGroupRole,
               let id = v[1] as? String, let uuid = NotificationBannerParser.normalizedUUID(id) {
                readGroup(node, uuid: uuid)
                return
            }
            if (v[0] as? String) == kAXApplicationRole { return }
            for child in v[2] as? [AXUIElement] ?? [] { findGroups(child, depth: depth + 1) }
        }

        func readGroup(_ group: AXUIElement, uuid: String) {
            guard found.insert(uuid).inserted else { return }
            var lines: [NotificationBannerParser.Line] = []
            var complete = true
            func visit(_ node: AXUIElement, depth: Int) {
                guard depth < 8, available else { complete = false; return }
                let v = values(node, [kAXRoleAttribute, kAXIdentifierAttribute, kAXValueAttribute, kAXChildrenAttribute])
                guard v.count == 4 else { complete = false; return }
                if depth > 0, (v[0] as? String) == kAXGroupRole,
                   let id = v[1] as? String, let nested = NotificationBannerParser.normalizedUUID(id), nested != uuid { return }
                if (v[0] as? String) == kAXStaticTextRole, let text = v[2] as? String {
                    lines.append(.init(identifier: v[1] as? String, value: text))
                }
                for child in v[3] as? [AXUIElement] ?? [] { visit(child, depth: depth + 1) }
            }
            visit(group, depth: 0)
            guard complete, let fields = NotificationBannerParser.fields(from: lines) else { return }
            observations.append(.init(sourceUUID: uuid, title: fields.title, subtitle: fields.subtitle,
                                      body: fields.body, observedAt: Date().timeIntervalSince1970,
                                      displayAppName: fields.displayAppName))
        }
    }
}
