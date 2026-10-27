import Foundation
#if canImport(StreamProtocol)
import StreamProtocol
#endif

/// A foreground session the person left temporarily. It stores no socket or key: every reconnect
/// still uses the current paired record and its normal TLS checks. Scene IDs keep windows apart.
struct BackgroundSessionIntent: Codable, Equatable {
    var macID: String
    var source: StreamSource
    var launchID: String? = nil

    /// CGWindowIDs are only meaningful during one host launch. A restarted Mac can reuse an ID
    /// for another app, and another viewer's current pick must always take precedence.
    func sourceToRestore(hostLaunchID: String?, active: StreamSource, windows: [WindowInfo]) -> StreamSource? {
        guard let launchID, launchID == hostLaunchID, active == .none, source != .none else { return nil }
        if case .window(let id) = source, !windows.contains(where: { $0.id == id }) { return nil }
        return source
    }
}

enum BackgroundSessionPersistence {
    static let key = "Sill.backgroundSessions"

    static func load(scene: String, recoveringSingleScene: Bool, defaults: UserDefaults = .standard) -> BackgroundSessionIntent? {
        var intents = read(defaults)
        if let intent = intents[scene] { return intent }
        // A killed single-window app may receive a new scene ID when relaunched. Only the first
        // scene in a new process can adopt that sole record; opening another window must not.
        guard recoveringSingleScene, intents.count == 1, let previous = intents.first else { return nil }
        intents.removeValue(forKey: previous.key)
        intents[scene] = previous.value
        write(intents, defaults)
        return previous.value
    }

    static func save(_ intent: BackgroundSessionIntent?, scene: String, defaults: UserDefaults = .standard) {
        var intents = read(defaults)
        intents[scene] = intent
        write(intents, defaults)
    }

    private static func read(_ defaults: UserDefaults) -> [String: BackgroundSessionIntent] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: BackgroundSessionIntent].self, from: data)) ?? [:]
    }

    private static func write(_ intents: [String: BackgroundSessionIntent], _ defaults: UserDefaults) {
        if intents.isEmpty {
            defaults.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(intents) {
            defaults.set(data, forKey: key)
        }
    }
}

/// Inputs already sent, on the client's network queue. Going away releases only this client's
/// outstanding presses, before its pause message, so another viewer never inherits a stuck drag.
struct BackgroundHeldInputs {
    private var keys = Set<UInt16>()
    private var left = false
    private var right = false
    private var x = 0.5
    private var y = 0.5
    private var scroll: ScrollPhase?

    mutating func sent(_ event: InputEvent) {
        switch event {
        case .key(let usage, let down, _):
            if down { keys.insert(usage) } else { keys.remove(usage) }
        case .pointer(let action, let x, let y):
            self.x = x; self.y = y
            switch action {
            case .leftDown: left = true
            case .leftUp: left = false
            case .rightDown: right = true
            case .rightUp: right = false
            case .move: break
            }
        case .scrollGesture(let phase, let x, let y):
            self.x = x; self.y = y
            switch phase {
            case .began, .momentumBegan: scroll = phase
            case .ended, .momentumEnded: scroll = nil
            }
        case .scroll, .text: break
        }
    }

    mutating func release() -> [InputEvent] {
        var events = keys.sorted().map { InputEvent.key(hidUsage: $0, down: false, modifiers: 0) }
        if left { events.append(.pointer(.leftUp, x: x, y: y)) }
        if right { events.append(.pointer(.rightUp, x: x, y: y)) }
        if let scroll {
            events.append(.scrollGesture(scroll == .momentumBegan ? .momentumEnded : .ended, x: x, y: y))
        }
        self = Self()
        return events
    }
}
