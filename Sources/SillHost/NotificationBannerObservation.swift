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
    /// A system-owned group description identified an iPhone notification, never message text.
    var isFromIPhone: Bool = false
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
    private static let iPhoneDescriptionKeys = [
        "%@, %@, from iPhone", "%@, %@, stacked, from iPhone",
        "Summary: %@, from iPhone", "Stacked summary: %@, from iPhone",
    ]
    private static let formatSlot = try! NSRegularExpression(pattern: #"%(?:([1-9][0-9]*)\$)?@"#)
    private static let iPhoneDescriptionTemplates: [String] = {
        guard let bundle = Bundle(path: "/System/Library/CoreServices/NotificationCenter.app") else { return [] }
        var templates = Set(iPhoneDescriptionKeys.map {
            bundle.localizedString(forKey: $0, value: nil, table: "Localizable")
        })
        // NotificationCenter can use a different app language from Sill. Read only these four
        // known keys in its system resources rather than invent translations or guess its locale.
        if let url = bundle.url(forResource: "Localizable", withExtension: "loctable"),
           let data = try? Data(contentsOf: url),
           let table = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            for case let localized as [String: Any] in table.values {
                for key in iPhoneDescriptionKeys {
                    if let value = localized[key] as? String { templates.insert(value) }
                }
            }
        }
        return Array(templates)
    }()

    /// Pass only the notification UUID group's own system description/label. This description
    /// includes message text, so the entire separately parsed body must occupy the final content
    /// slot: the system's origin marker must follow the body, never be part of it. Empty bodies
    /// and reordered content slots remain unclassified until their AX shapes are established.
    static func isFromIPhone(groupMetadata: [String], body: String, templates: [String]? = nil) -> Bool {
        guard !body.isEmpty else { return false }
        for template in templates ?? iPhoneDescriptionTemplates {
            let text = template as NSString
            let slots = formatSlot.matches(in: template, range: NSRange(location: 0, length: text.length))
            guard (1...2).contains(slots.count), let last = slots.last,
                  slots.enumerated().allSatisfy({ index, slot in
                      slot.range(at: 1).location == NSNotFound ||
                          Int(text.substring(with: slot.range(at: 1))) == index + 1
                  }) else { continue }
            let suffix = text.substring(from: NSMaxRange(last.range))
            // This also avoids compiling a body-specific regex for unrelated system locales.
            let candidates = groupMetadata.filter { !$0.isEmpty && $0.hasSuffix(body + suffix) }
            guard !suffix.isEmpty, !candidates.isEmpty,
                  let pattern = descriptionPattern(template, slots: slots, body: body) else { continue }
            if candidates.contains(where: {
                pattern.firstMatch(in: $0, range: NSRange($0.startIndex..<$0.endIndex, in: $0)) != nil
            }) { return true }
        }
        return false
    }

    private static func descriptionPattern(_ template: String, slots: [NSTextCheckingResult],
                                           body: String) -> NSRegularExpression? {
        let text = template as NSString
        var pattern = #"\A"#
        var cursor = 0
        for (index, slot) in slots.enumerated() {
            pattern += NSRegularExpression.escapedPattern(for:
                text.substring(with: NSRange(location: cursor, length: slot.range.location - cursor)))
            pattern += index == slots.count - 1 ? NSRegularExpression.escapedPattern(for: body) : #"[\s\S]*?"#
            cursor = NSMaxRange(slot.range)
        }
        pattern += NSRegularExpression.escapedPattern(for: text.substring(from: cursor)) + #"\z"#
        return try? NSRegularExpression(pattern: pattern)
    }

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
