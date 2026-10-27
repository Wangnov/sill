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

    public init(enabled: Bool, pushToken: String? = nil, topic: String? = nil, environment: String? = nil) {
        self.enabled = enabled
        self.pushToken = pushToken
        self.topic = topic
        self.environment = environment
    }
}

/// Host → device (fork kind 202), also carried as APNs `sill.event`. `date` is Unix seconds when the
/// host observed the notification, not an inferred delivery time. The ID stays the same on the
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

    public init(id: String = UUID().uuidString, appBundleID: String, appName: String, title: String,
                subtitle: String? = nil, body: String, date: Double = Date().timeIntervalSince1970) {
        self.id = id
        self.appBundleID = appBundleID
        self.appName = appName
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.date = date
    }
}
