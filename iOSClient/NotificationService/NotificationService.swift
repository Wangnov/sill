import Intents
import UserNotifications

/// iOS owns the small Sill badge. A cached source-app icon decorates the communication avatar;
/// missing icons or any enrichment failure leave the original APNs alert available to iOS.
final class NotificationService: UNNotificationServiceExtension {
    private let completionLock = NSLock()
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var originalContent: UNNotificationContent?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        completionLock.lock()
        self.contentHandler = contentHandler
        originalContent = request.content
        completionLock.unlock()

        let content = request.content
        guard let envelope = content.userInfo["sill"] as? [String: Any],
              let macID = envelope["macID"] as? String, !macID.isEmpty,
              let event = envelope["event"] as? [String: Any],
              let bundleID = event["appBundleID"] as? String, !bundleID.isEmpty,
              let png = NotificationIconCache()?.pngData(macID: macID, bundleID: bundleID) else {
            finish(with: content)
            return
        }

        let identity = NotificationIconCache.sourceIdentifier(macID: macID, bundleID: bundleID)
        let image = INImage(imageData: png)
        let sender = INPerson(personHandle: INPersonHandle(value: identity, type: .unknown),
                              nameComponents: nil, displayName: content.title, image: image,
                              contactIdentifier: nil, customIdentifier: identity)
        // Communication alerts hide the normal subtitle row. Fold it into the presentation
        // body before updating; the original event in userInfo keeps its separate fields.
        let presentation = content.mutableCopy() as! UNMutableNotificationContent
        if !content.subtitle.isEmpty {
            presentation.body = [content.subtitle, content.body].filter { !$0.isEmpty }.joined(separator: "\n")
            presentation.subtitle = ""
        }
        // Communication formatting uses the sender as its title. Supplying the existing APNs
        // title preserves the source app + title text instead of replacing it with a person name.
        let intent = INSendMessageIntent(recipients: nil, outgoingMessageType: .outgoingMessageText,
                                         content: presentation.body, speakableGroupName: nil,
                                         conversationIdentifier: content.threadIdentifier,
                                         serviceName: nil, sender: sender, attachments: nil)
        intent.setImage(image, forParameterNamed: \INSendMessageIntent.sender)
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        // Follow Apple's incoming-communication sequence. Donation needs no Siri permission
        // prompt; this records neither an outgoing message nor a system contact.
        interaction.donate { [weak self] error in
            guard let self else { return }
            guard error == nil, let updated = try? presentation.updating(from: intent) else {
                self.finish(with: content)
                return
            }
            // Apple requires passing the returned content directly, without mutating it.
            self.finish(with: updated)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        completionLock.lock()
        let content = originalContent
        completionLock.unlock()
        if let content { finish(with: content) }
    }

    private func finish(with content: UNNotificationContent) {
        completionLock.lock()
        let handler = contentHandler
        contentHandler = nil
        originalContent = nil
        completionLock.unlock()
        // Expiration and a late donation callback can race. Only one owns the handler.
        handler?(content)
    }
}
