import Foundation

/// Device → host (fork kind 201). Sent only after explicit opt-in. A push token is useful only with
/// its app topic and APNs environment; the host binds it to the authenticated TLS peer's key,
/// never to an identity claimed in this JSON. A nil token still subscribes the live connection.
public struct NotificationSubscription: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var pushToken: String?
    public var topic: String?
    /// Exactly "sandbox" or "production", from the iOS app's signing entitlement/build setting.
    public var environment: String?
    /// The durable host history being resumed. Missing or changed history starts at its beginning.
    public var historyID: String?
    public var afterSequence: Int64?

    public init(enabled: Bool, pushToken: String? = nil, topic: String? = nil, environment: String? = nil,
                historyID: String? = nil, afterSequence: Int64? = nil) {
        self.enabled = enabled
        self.pushToken = pushToken
        self.topic = topic
        self.environment = environment
        self.historyID = historyID
        self.afterSequence = afterSequence
    }
}

/// Host → device (fork kind 202), also carried as APNs `sill.event`. `date` is the source's delivery
/// time in Unix seconds, or creation time for an explicit test. The ID stays the same on the
/// live connection and APNs, so the device can deduplicate by (macID, id).
public struct MirroredNotification: Codable, Equatable, Sendable {
    public var id: String
    /// Empty when a source cannot be resolved; never guess a bundle ID from an application name.
    public var appBundleID: String
    public var appName: String
    public var title: String
    public var subtitle: String?
    public var body: String
    public var date: Double
    /// APNs preserves these fields for deduplication, but only ordered TLS history advances a cursor.
    public var historyID: String?
    public var sequence: Int64?

    public init(id: String = UUID().uuidString, appBundleID: String, appName: String, title: String,
                subtitle: String? = nil, body: String, date: Double = Date().timeIntervalSince1970,
                historyID: String? = nil, sequence: Int64? = nil) {
        self.id = id
        self.appBundleID = appBundleID
        self.appName = appName
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.date = date
        self.historyID = historyID
        self.sequence = sequence
    }
}
