import Foundation

@main
@MainActor
struct NotificationSourceCheck {
    static var checks = 0
    static func expect(_ value: @autoclosure () -> Bool, _ note: String) {
        checks += 1
        guard value() else { fatalError("notification-source: \(note)") }
    }

    // The exact synthetic message/path observed at 2026-10-28 13:28:20.935279+0800, macOS 27.0.
    static let message = "_removeDelivered: Removing [5ECC3E3C-441B-4547-847A-8F4813E22628] from local.sill.acceptance.notification"
    static let expected = NotificationSourceAttribution(uuid: "5ecc3e3c441b4547847a8f4813e22628", bundleID: "local.sill.acceptance.notification")
    static func record(_ message: String = message, extra: [String: Any] = [:]) -> Data {
        var object: [String: Any] = ["processImagePath": "/usr/sbin/usernoted", "subsystem": "com.apple.unc",
            "category": "application", "eventMessage": message, "messageType": "Default", "processID": 436]
        for (key, value) in extra { object[key] = value }
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    @MainActor
    static func main() async throws {
        expect(NotificationSourceParser.parse(message: message) == expected, "real exact fixture")
        expect(NotificationSourceParser.parse(line: record()) == expected, "real NDJSON metadata")
        expect(NotificationSourceParser.parse(message: message.replacingOccurrences(of: "5ECC3E3C-441B-4547-847A-8F4813E22628",
                with: "5ecc3e3c-441b-4547-847a-8f4813e22628")) == expected, "UUID case normalized")
        for bad in [
            "_removeDelivered: Removing [5ECC3E3C] from local.sill.acceptance.notification",
            "_removeDelivered: Removing [5ECC3E3C441B4547847A8F4813E22628] from local.sill.acceptance.notification",
            "_removeDelivered: Removing [GECC3E3C-441B-4547-847A-8F4813E22628] from local.sill.acceptance.notification",
            "_removeDelivered: Removing [5ECC3E3C-441B-4547-847A-8F4813E22628, 4D027B04-D694-4712-9117-ABD95D38BB3D] from local.sill.acceptance.notification",
            message.replacingOccurrences(of: "local.sill.acceptance.notification", with: "<private>"),
            message.replacingOccurrences(of: "local.sill.acceptance.notification", with: "local..notification"),
            message.replacingOccurrences(of: "local.sill.acceptance.notification", with: "Sill Notification Probe"),
            message.replacingOccurrences(of: "local.sill.acceptance.notification", with: "local.通知"),
            message.replacingOccurrences(of: "local.sill.acceptance.notification", with: "\"local.sill.acceptance.notification\""),
            "unrelated: " + message, message + " extra", message + "\n", "\n" + message,
            "NotificationRecord app:local.sill.acceptance.notification uuid:5ECC3E3C", ""
        ] { expect(NotificationSourceParser.parse(message: bad) == nil, "reject unverified or incomplete template") }
        for extra: [String: Any] in [
            ["processImagePath": "/tmp/usernoted"], ["processImagePath": "/usr/sbin/other"],
            ["subsystem": "different"], ["category": "UserNotifications"], ["eventMessage": NSNull()]
        ] { expect(NotificationSourceParser.parse(line: record(extra: extra)) == nil, "reject wrong provenance") }
        expect(NotificationSourceParser.parse(line: Data("not JSON".utf8)) == nil, "non-JSON log header")
        expect(NotificationSourceParser.parse(line: record(extra: ["unusedBody": "arbitrary unrelated content"])) == expected,
               "unrelated body cannot determine identity")

        // Exact list from our sender's public cleanup, 2026-10-28 13:43:28.709902+0800.
        let batchIDs = ["DFC58501-98E5-44F0-B9B3-2D7C69593C20", "4EC3F42D-7F59-492B-806C-4342C3AF64C8",
            "931F3E3F-89BF-473F-9AFA-746E384D77AB", "367D210F-62AE-4203-BF80-4FB466C09C93",
            "7CDC5670-38CB-4674-9FFB-C9F6AAFA74AB", "C77A174E-B031-4BDA-B439-1BEA5A4434A4",
            "F85BE627-F9B6-404C-AFBA-E58CAE4C7F99", "B6D4B7AA-4394-4484-BA32-45BBA2D7DA9D",
            "F4ADAF2A-1BF6-4407-B645-21510E9AD0A5", "B9FC1E10-FDE1-4A63-9F66-89AB28B83DD8",
            "2631B14E-0680-4265-9EE2-B60122189DA9"]
        let batch = "_removeDelivered: Removing [" + batchIDs.joined(separator: ", ") + "] from local.sill.acceptance.notification"
        var batchDecoder = NotificationSourceLineDecoder()
        expect(batchDecoder.append(record(batch) + Data([10])) == batchIDs.map {
            NotificationSourceAttribution(uuid: $0.replacingOccurrences(of: "-", with: "").lowercased(), bundleID: expected.bundleID)
        }, "real eleven-UUID batch shares one verified bundle")
        expect(NotificationSourceParser.parseAll(message: batch.replacingOccurrences(of: batchIDs[5], with: "C77A174E")).isEmpty,
               "one incomplete UUID rejects the entire batch")

        let line = record()
        var decoder = NotificationSourceLineDecoder()
        expect(decoder.append(line.prefix(31)).isEmpty, "split first chunk held")
        expect(decoder.append(line.dropFirst(31)).isEmpty, "no newline means incomplete record")
        expect(decoder.append(Data([10])) == [expected], "complete split record emitted once")
        expect(decoder.append(line + Data([10]) + line + Data([13, 10])) == [expected, expected], "multiple/CRLF lines")
        expect(decoder.append(Data(repeating: 65, count: 70_000)).isEmpty, "oversize line discarded")
        expect(decoder.append(Data([10]) + line + Data([10])) == [expected], "oversize line resynchronizes")

        // A short line must arrive while the writer is still running, before EOF or 16 KB.
        let json = String(decoding: line, as: UTF8.self)
        let live = NotificationSourceLogSession(executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '%s\\n' " + shellQuote(json) + "; exec /bin/sleep 3"])
        let stream = try live.start()
        let started = ProcessInfo.processInfo.systemUptime
        var firstElapsed: Double?
        var liveCount = 0
        for await event in stream {
            switch event {
            case .sources(let sources):
                expect(live.isRunning, "short line delivered before writer exit")
                expect(sources == [expected], "short live pipe line parsed")
                liveCount += sources.count
                firstElapsed = ProcessInfo.processInfo.systemUptime - started
                live.stop()
            case .ended:
                expect(liveCount == 1, "source precedes ordered end")
            }
        }
        expect(firstElapsed != nil && firstElapsed! < 2, "short line liveness")
        expect(!live.isRunning, "owned child stopped")

        // An immediate writer exit must not discard its final complete records.
        let immediate = NotificationSourceLogSession(executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '%s\\n%s\\n' " + shellQuote(json) + " " + shellQuote(json)])
        var count = 0
        var sawEnd = false
        for await event in try immediate.start() {
            switch event {
            case .sources(let sources):
                expect(!sawEnd, "no source after end")
                count += sources.count
            case .ended:
                sawEnd = true
                expect(count == 2, "drain final records before exit")
            }
        }
        expect(sawEnd && !immediate.isRunning, "immediate child reaped")
        print("notification-source: \(checks) offline checks passed; short pipe line in \(Int((firstElapsed ?? 0) * 1000)) ms; no system log stream or DB access")
    }
}
