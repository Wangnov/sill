import Foundation

/// Values copied from one visible notification group. Its UUID can identify the same request
/// in the retained store; text from an unrelated AX node must never fill a missing field.
struct NotificationBannerObservation: Sendable, Equatable {
    let sourceUUID: String
    let title: String
    let subtitle: String
    let body: String
    let observedAt: TimeInterval
    let displayAppName: String?
}

/// Arrival uses a short-lived unique prefix/time match; exact uses a full UUID or the database.
/// Ambiguous withdraws only an arrival candidate. These levels stay internal to source handling.
enum NotificationSourceEvidence: String, Codable, Sendable {
    case arrival, exact, ambiguous
}

/// An identity hint for an existing AX UUID, never a new notification occurrence.
struct NotificationSourceAttribution: Equatable, Sendable {
    let uuid: String
    let bundleID: String
    let evidence: NotificationSourceEvidence

    init(uuid: String, bundleID: String, evidence: NotificationSourceEvidence = .exact) {
        self.uuid = uuid
        self.bundleID = bundleID
        self.evidence = evidence
    }
}

struct NotificationArrivalObservation: Equatable, Sendable {
    let uuidPrefix8: String
    let bundleID: String
    let occurredAt: TimeInterval
}

/// Pure parsing shared by the live banner adapter and offline fixtures.
enum NotificationBannerParser {
    struct Line: Sendable, Equatable {
        let identifier: String?
        let value: String
    }

    struct Fields: Sendable, Equatable {
        let title: String
        let subtitle: String
        let body: String
        let displayAppName: String?
    }

    /// Accept only a complete canonical UUID or its 32 hexadecimal digits. In particular,
    /// finding a UUID inside another AX identifier does not make that node a notification.
    static func normalizedUUID(_ identifier: String) -> String? {
        let bytes = Array(identifier.utf8)
        guard bytes.count == 32 || bytes.count == 36 else { return nil }
        var normalized: [UInt8] = []
        normalized.reserveCapacity(32)
        for (index, byte) in bytes.enumerated() {
            if bytes.count == 36 && [8, 13, 18, 23].contains(index) {
                guard byte == 45 else { return nil }
                continue
            }
            switch byte {
            case 48...57, 97...102: normalized.append(byte)
            case 65...70: normalized.append(byte + 32)
            default: return nil
            }
        }
        return String(decoding: normalized, as: UTF8.self)
    }

    static func fields(from lines: [Line]) -> Fields? {
        var title: [String] = []
        var subtitle: [String] = []
        var body: [String] = []
        for line in lines where !line.value.isEmpty {
            switch line.identifier?.lowercased() {
            case "title": title.append(line.value)
            case "subtitle": subtitle.append(line.value)
            case "body": body.append(line.value)
            default: continue
            }
        }
        guard !title.isEmpty || !subtitle.isEmpty || !body.isEmpty else { return nil }
        // A display name or unidentified static text is not reliable evidence of the source app.
        return Fields(title: title.joined(separator: "\n"),
                      subtitle: subtitle.joined(separator: "\n"),
                      body: body.joined(separator: "\n"),
                      displayAppName: nil)
    }
}
