import Foundation

/// Keep the mirror's persistence/consent checks offline; never open the person's system database.
@MainActor
final class NotificationMirrorCollector {
    var onSnapshot: ((NotificationStoreSnapshot) -> Void)?
    var onStatus: ((String) -> Void)?
    func start() {}
    func stop() {}
}
