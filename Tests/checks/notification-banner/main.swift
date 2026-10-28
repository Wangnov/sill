import Foundation

var passes = 0
@MainActor
func check(_ condition: Bool, _ label: String) {
    guard condition else { fatalError(label) }
    passes += 1
}
func requireSendable<T: Sendable>(_ value: T) {}
typealias Parser = NotificationBannerParser
typealias Line = Parser.Line
typealias Fields = Parser.Fields

// AXGroup identifiers captured by the synthetic probe on macOS 27, 2026-10-28. The
// first request's original and redelivered versions had distinct group identities;
// text, callback element identity, and the app's request identifier are not this UUID.
let groupFixtures: [(String, String)] = [
    ("4D027B04-D694-4712-9117-ABD95D38BB3D", "4d027b04d69447129117abd95d38bb3d"),
    ("0ACC6B7D-A769-494D-8C59-DC4FFA2D4F46", "0acc6b7da769494d8c59dc4ffa2d4f46"),
    ("08D06987-F857-4FAE-8ACC-CEFF55DBD046", "08d06987f8574fae8accceff55dbd046"),
    ("0B8FC55C-ECB2-43A9-8123-FBAE68B31E0A", "0b8fc55cecb243a98123fbae68b31e0a"),
    ("9B48C824-E980-4EFD-BCC0-F17CB001DBB8", "9b48c824e9804efdbcc0f17cb001dbb8"),
    ("EA9DD15C-DB22-4BBF-8899-61F93EC40F97", "ea9dd15cdb224bbf889961f93ec40f97"),
    ("E58677BD-2A9B-4F7F-BA16-74EA920253FF", "e58677bd2a9b4f7fba1674ea920253ff"),
    ("8C68564A-5996-452A-ACC0-59AD2C09CEA4", "8c68564a5996452aacc059ad2c09cea4")
]
for (identifier, expected) in groupFixtures {
    check(Parser.normalizedUUID(identifier) == expected, "captured AXGroup UUID normalizes")
    check(Parser.normalizedUUID(identifier.lowercased()) == expected, "lowercase canonical UUID")
    check(Parser.normalizedUUID(expected.uppercased()) == expected, "32 uppercase hex digits")
    check(Parser.normalizedUUID(expected) == expected, "32 lowercase hex digits")
}
check(Set(groupFixtures.compactMap { Parser.normalizedUUID($0.0) }).count == 8,
      "separate deliveries retain separate group identities")
check(Parser.normalizedUUID("4d027B04-D694-4712-9117-abD95d38bB3d") == groupFixtures[0].1,
      "mixed-case ASCII hex")
check(Parser.normalizedUUID("00000000-0000-0000-0000-000000000000") == String(repeating: "0", count: 32),
      "UUID shape imposes no version or variant policy")

let canonical = groupFixtures[0].0
let hex = groupFixtures[0].1
let rejected = [
    "", "title", "body", "AXNotificationListItems", "me.saffer.sill.mac",
    "notification:" + canonical, canonical + ":body", "{" + canonical + "}",
    " " + canonical, canonical + " ", canonical + "\n", "\n" + canonical,
    String(hex.dropFirst()), hex + "0", String(canonical.dropLast()), canonical + "0",
    "4D027B04D-694-4712-9117-ABD95D38BB3D", // same byte count, misplaced hyphen
    "4D027B04_D694-4712-9117-ABD95D38BB3D",
    "4D027B04-D694-4712-9117-ABD95D38BB3G",
    "4D027B04D69447129117ABD95D38BB3-",
    "4D027B04–D694-4712-9117-ABD95D38BB3D", // Unicode dash
    "４D027B04-D694-4712-9117-ABD95D38BB3D", // Unicode lookalike
    String(repeating: "é", count: 16), String(repeating: "g", count: 32)
]
for identifier in rejected {
    check(Parser.normalizedUUID(identifier) == nil, "reject non-UUID identifier")
}

let probeBody = "SILL-PROBE-20261028: run C53C522D-B36F-4B13-B03A-E5AFD37A69CB; body only, no title or subtitle."
let bodyOnly = Fields(title: "", subtitle: "", body: probeBody, displayAppName: nil)
check(Parser.fields(from: [Line(identifier: "body", value: probeBody)]) == bodyOnly,
      "captured synthetic body-only field retains punctuation")
check(Parser.fields(from: []) == nil, "empty snapshot has no payload")
check(Parser.fields(from: [Line(identifier: "title", value: ""), Line(identifier: "body", value: "")]) == nil,
      "known empty fields have no payload")
check(Parser.fields(from: [Line(identifier: nil, value: "Unidentified private text"),
                          Line(identifier: "appName", value: "Some App"),
                          Line(identifier: "message", value: "Unrecognized message")]) == nil,
      "unidentified and unknown fields never become fallback payload")

let exact = Fields(title: "Title, with commas\nand another line",
                   subtitle: "  Subtitle, kept verbatim  ",
                   body: "First, second\n第三行\n", displayAppName: nil)
check(Parser.fields(from: [Line(identifier: "TiTlE", value: exact.title),
                          Line(identifier: "SUBTITLE", value: exact.subtitle),
                          Line(identifier: "bOdY", value: exact.body)]) == exact,
      "case-insensitive known identifiers preserve spaces, commas, Unicode and newlines")
let repeated = Fields(title: "First title\nSecond title", subtitle: "First subtitle\nSecond subtitle",
                      body: "First body\ncontinued\nSecond body", displayAppName: nil)
check(Parser.fields(from: [Line(identifier: "body", value: "First body\ncontinued"),
                          Line(identifier: "title", value: "First title"),
                          Line(identifier: "subtitle", value: "First subtitle"),
                          Line(identifier: "body", value: ""),
                          Line(identifier: "title", value: ""),
                          Line(identifier: "TITLE", value: "Second title"),
                          Line(identifier: "BODY", value: "Second body"),
                          Line(identifier: "SUBTITLE", value: "Second subtitle")]) == repeated,
      "repeated fields join in encounter order, ignoring empty values")

let foreignLines = [Line(identifier: nil, value: "Unidentified private text"),
                    Line(identifier: "appName", value: "An App"),
                    Line(identifier: " title", value: "Wrong title"),
                    Line(identifier: "title ", value: "Wrong title"),
                    Line(identifier: "body.label", value: "Wrong body"),
                    Line(identifier: "subtitleLabel", value: "Wrong subtitle"),
                    Line(identifier: "AXNotificationListItems", value: "Wrong list"),
                    Line(identifier: canonical, value: "Wrong group")]
check(Parser.fields(from: foreignLines + [Line(identifier: "body", value: probeBody)]) == bodyOnly,
      "unknown node text cannot contaminate a recognized payload or app name")
check(Parser.fields(from: foreignLines) == nil, "identifier matching accepts only complete field names")
check(Parser.fields(from: [Line(identifier: "title", value: "Only title")]) ==
      Fields(title: "Only title", subtitle: "", body: "", displayAppName: nil), "title-only payload")
check(Parser.fields(from: [Line(identifier: "subtitle", value: "Only subtitle")]) ==
      Fields(title: "", subtitle: "Only subtitle", body: "", displayAppName: nil), "subtitle-only payload")
check(Parser.fields(from: [Line(identifier: "body", value: " \n ")]) ==
      Fields(title: "", subtitle: "", body: " \n ", displayAppName: nil),
      "nonempty whitespace remains verbatim rather than silently rewritten")

let observation = NotificationBannerObservation(sourceUUID: hex, title: exact.title,
    subtitle: exact.subtitle, body: exact.body, observedAt: 1_793_154_173.125, displayAppName: nil)
let same = NotificationBannerObservation(sourceUUID: hex, title: exact.title,
    subtitle: exact.subtitle, body: exact.body, observedAt: 1_793_154_173.125, displayAppName: nil)
let otherDelivery = NotificationBannerObservation(sourceUUID: groupFixtures[1].1, title: exact.title,
    subtitle: exact.subtitle, body: exact.body, observedAt: 1_793_154_173.125, displayAppName: nil)
check(observation == same, "observation value equality")
check(observation != otherDelivery, "identical payloads from distinct UUIDs remain distinct observations")
check(observation.observedAt == 1_793_154_173.125, "observation keeps Unix timestamp precision")
requireSendable(observation)
requireSendable(bodyOnly)
requireSendable(Line(identifier: "body", value: probeBody))

print("notification-banner: \(passes) offline UUID/field checks passed; no AX or system store access")
