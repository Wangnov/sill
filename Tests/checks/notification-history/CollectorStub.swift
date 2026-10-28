import Foundation

/// Keep the mirror's persistence/consent checks offline; never open the person's system database.
@MainActor
final class NotificationMirrorCollector {
    static weak var latest: NotificationMirrorCollector?
    var onSnapshot: ((NotificationStoreSnapshot) -> Void)?
    var onBanner: ((NotificationBannerObservation) -> Void)?
    var onSource: ((NotificationSourceAttribution, String) -> Void)?
    var onStatus: ((String) -> Void)?
    init() { Self.latest = self }
    func start() {}
    func stop() {}
}
