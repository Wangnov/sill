import Foundation
import Combine
import Network
import UIKit
import StreamProtocol

/// A window's subscription to the App inbox. It owns no notification history or APNs token.
/// All accesses are on main; StreamClient's send keeps wire ordering through SessionLink.
final class NotificationSessionRelay {
    weak var client: StreamClient?
    weak var inbox: NotificationInbox?
    var generation: Int?
    private var changes: [AnyCancellable] = []
    private var lastSettings: NotificationSubscription?
    private weak var lastConnection: NWConnection?

    init(client: StreamClient, inbox: NotificationInbox) {
        self.client = client
        self.inbox = inbox
        // Inbox rows and their saved checkpoint change during replay. Observing objectWillChange
        // would resubscribe from each new checkpoint and start overlapping replay loops.
        changes.append(inbox.$enabled.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.update() })
        changes.append(inbox.$pushRegistration.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.update() })
        changes.append(client.savedMacStore.$snapshot.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.update() })
    }

    func update() {
        guard let client, let inbox, (generation ?? 0) >= 1, client.connected,
              let connection = client.connection, let key = RemoteTLS.peerFingerprint(connection) else { return }
        let paired = client.session?.macID.flatMap { client.savedMac($0)?.fingerprintData } == key
        var subscription: NotificationSubscription
        if inbox.enabled, paired {
            let push = inbox.pushRegistration
            subscription = NotificationSubscription(enabled: true, pushToken: push?.token,
                                                    topic: push?.topic, environment: push?.environment)
        } else {
            // A switch turned off, or this App forgot the Mac while its TLS session was open.
            // Disabling uses that authenticated session; it never registers an unpaired peer.
            guard lastSettings?.enabled == true || paired else { return }
            subscription = NotificationSubscription(enabled: false)
        }
        guard lastConnection !== connection || lastSettings != subscription else { return }
        lastConnection = connection
        lastSettings = subscription
        if subscription.enabled, let macID = client.session?.macID {
            // Pairing or inbox attachment can follow the catalog. Prewarm those icons too,
            // so an app's first background alert need not wait for another connection.
            for (bundleID, image) in client.icons {
                inbox.cacheIcon(image, bundleID: bundleID, macID: macID)
            }
            if let cursor = inbox.historyCursor(for: macID) {
                subscription.historyID = cursor.historyID
                subscription.afterSequence = cursor.lastSequence
            }
        }
        client.send(.notificationSubscription, payload: Wire.encode(subscription))
    }

    func reset() {
        generation = nil
        lastSettings = nil
        lastConnection = nil
        // Ending a stream does not disable push. The Mac's registration belongs to its paired
        // device, so notifications can reach iOS after this window/socket is gone.
    }

    func moved() {
        lastConnection = nil
        lastSettings = nil
        update()
    }
}

extension StreamClient {
    func attachNotificationInbox(_ inbox: NotificationInbox) {
        guard notificationRelay?.inbox !== inbox else { return }
        notificationRelay = NotificationSessionRelay(client: self, inbox: inbox)
    }

    func hostNotificationsChanged(_ generation: Int?) {
        notificationRelay?.generation = generation
        notificationRelay?.update()
    }

    func notificationSessionEnded() { notificationRelay?.reset() }
    func notificationSessionMoved() { notificationRelay?.moved() }

    func receiveMirroredNotification(_ data: Data, connectionKey: Data?) {
        // StreamClient already enforces the wire's 4 MiB non-video message cap. Notification
        // bodies use that same bound; a legitimate full body must not disappear at 16 KiB.
        guard let id = session?.macID, let saved = savedMac(id),
              saved.fingerprintData == connectionKey, connectionKey != nil,
              let event = Wire.decode(MirroredNotification.self, from: data) else { return }
        // Pairing can happen after this session's catalog arrived. Reuse its already-decoded
        // icon too, rather than waiting for another kind 4 just to decorate this event.
        if let image = icons[event.appBundleID] {
            notificationRelay?.inbox?.cacheIcon(image, bundleID: event.appBundleID, macID: id)
        }
        notificationRelay?.inbox?.receive(event, from: id, direct: true)
    }

    func cacheNotificationIcon(_ image: UIImage, bundleID: String) {
        guard let id = session?.macID, let saved = savedMac(id), let connection,
              let key = RemoteTLS.peerFingerprint(connection), key == saved.fingerprintData else { return }
        notificationRelay?.inbox?.cacheIcon(image, bundleID: bundleID, macID: id)
    }
}
