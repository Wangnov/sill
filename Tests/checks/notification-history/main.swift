import Foundation
import SQLite3
import StreamProtocol

func check(_ condition: Bool, _ label: String) {
    guard condition else { fatalError(label) }
}

func sql(_ url: URL, _ query: String) {
    var db: OpaquePointer?
    precondition(sqlite3_open(url.path, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }
    precondition(sqlite3_exec(db, query, nil, nil, nil) == SQLITE_OK)
}

func count(_ url: URL, _ query: String) -> Int {
    var db: OpaquePointer?
    precondition(sqlite3_open(url.path, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    precondition(sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK)
    defer { sqlite3_finalize(statement) }
    precondition(sqlite3_step(statement) == SQLITE_ROW)
    return Int(sqlite3_column_int64(statement, 0))
}

func event(_ id: String, body: String = "Same body") -> MirroredNotification {
    MirroredNotification(id: id, appBundleID: "test.source", appName: "Source", title: "Fixture", body: body, date: 42)
}
func record(_ id: String, revision: String = "one", body: String = "Same body") -> NotificationStoreRecord {
    NotificationStoreRecord(sourceID: id, fingerprint: revision, event: event(id, body: body))
}
func snapshot(_ records: [NotificationStoreRecord]) -> NotificationStoreSnapshot {
    NotificationStoreSnapshot(records: records, skippedRecordCount: 0)
}

let root = FileManager.default.temporaryDirectory.appendingPathComponent("sill-history-check-" + UUID().uuidString)
defer { try? FileManager.default.removeItem(at: root) }
let url = root.appendingPathComponent("private/history.sqlite")
var store: NotificationHistoryStore? = try NotificationHistoryStore(url: url)
let historyID = store!.historyID
check(!historyID.isEmpty, "history has a stable identity")
let directoryMode = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as! Int
let fileMode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! Int
check(directoryMode == 0o700 && fileMode == 0o600, "private history filesystem permissions")

// Even the initial baseline marker rolls back if any observation cannot be committed.
sql(url, "CREATE TRIGGER fail_baseline BEFORE INSERT ON source_seen BEGIN SELECT RAISE(ABORT,'fixture'); END")
do { _ = try store!.ingest(snapshot([record("old")]), fingerprints: ["a"]); fatalError("baseline must fail") } catch {}
sql(url, "DROP TRIGGER fail_baseline")
let baseline = try store!.ingest(snapshot([record("old")]), fingerprints: ["a"])
check(baseline.isEmpty, "first successful snapshot suppresses historical alerts")
check(count(url, "SELECT count(*) FROM metadata WHERE key='baseline'") == 1, "baseline persisted")

// A failure late in a multi-event transaction preserves neither archive nor source observations.
sql(url, "CREATE TRIGGER fail_late BEFORE INSERT ON archive WHEN NEW.event_id='c' BEGIN SELECT RAISE(ABORT,'fixture'); END")
do { _ = try store!.ingest(snapshot([record("b"), record("c")]), fingerprints: ["a", "b"]); fatalError("archive must fail") } catch {}
check(count(url, "SELECT count(*) FROM archive") == 0, "archive transaction rollback")
check(count(url, "SELECT count(*) FROM source_seen WHERE source_id IN ('b','c')") == 0, "source cursor transaction rollback")
sql(url, "DROP TRIGGER fail_late")
let captured = try store!.ingest(snapshot([record("b"), record("c")]), fingerprints: ["a", "b"])
check(captured.map(\.sequence) == [1, 2], "failed transaction consumes no sequence")
check(captured[0].body == captured[1].body && captured[0].id != captured[1].id, "same text from separate deliveries remains distinct")
let initialAttempts = try store!.duePushes(at: Date(), fingerprints: ["a"])
check(initialAttempts.count == 2, "pending work is per fingerprint")
check(try store!.duePushes(at: Date(), fingerprints: ["unregistered"]).isEmpty, "unregistered work cannot starve registered recipients")

let updated = try store!.ingest(snapshot([record("b", revision: "two", body: "Updated"), record("c")]), fingerprints: ["a", "b"])
check(updated.count == 1 && updated[0].id == captured[0].id && updated[0].sequence == 3, "body revision preserves ID and advances sequence")
try store!.finish(initialAttempts[0], state: "accepted")
check(try store!.duePushes(at: Date(), fingerprints: ["a"]).map { $0.event.id } == ["c"], "in-flight APNs acceptance belongs to the occurrence, avoiding a second alert for revised text")
_ = try store!.ingest(snapshot([record("b", revision: "three", body: "Updated again"), record("c")]), fingerprints: ["a", "b"])
check(try store!.duePushes(at: Date(), fingerprints: ["a"]).map { $0.event.id } == ["c"], "accepted occurrence never rearms on body revision")
store = nil
store = try NotificationHistoryStore(url: url)
check(store!.historyID == historyID, "history identity survives restart")
check(try store!.ingest(snapshot([record("b", revision: "three", body: "Updated again"), record("c")]), fingerprints: ["a"]).isEmpty, "source fingerprints survive restart")
check(try store!.ingest(snapshot([]), fingerprints: []).isEmpty, "empty system store does not erase history")
check(try store!.events(after: 0).map(\.id) == ["c", "b"], "replay follows sequence, including latest body revision")
check(try store!.replayStart(historyID: historyID, afterSequence: 2) == 2, "matching history resumes")
check(try store!.replayStart(historyID: "different", afterSequence: 999) == 0, "different history replays from start")
check(try store!.replayStart(historyID: nil, afterSequence: nil) == 0, "old clients replay from start")
check(try store!.events(after: 2).map(\.id) == ["b"], "resume includes a changed notification")

let pending = try store!.duePushes(at: Date(), fingerprints: ["a"])
let retry = pending[0]
try store!.finish(retry, state: "retry", nextAttempt: Date().addingTimeInterval(3600), problem: "temporary")
check(try store!.duePushes(at: Date(), fingerprints: ["a"]).isEmpty, "transient retry respects persisted deadline")
store = nil
store = try NotificationHistoryStore(url: url)
check(try store!.duePushes(at: Date(), fingerprints: ["a"]).isEmpty, "retry deadline survives restart")
let secondTarget = try store!.duePushes(at: Date(), fingerprints: ["b"])
try store!.finish(secondTarget[1], state: "permanent", problem: "configuration")
check(try store!.duePushes(at: Date(), fingerprints: ["b"]).map { $0.event.id } == ["c"], "permanent failures never busy-loop")
check(count(url, "SELECT count(*) FROM push_outbox") == 4, "failures never delete pending records")
try store!.retryFailures(fingerprint: "b")
let repaired = try store!.duePushes(at: Date(), fingerprints: ["b"])
check(repaired.count == 2, "a renewed registration rearms permanent failures")
for attempt in repaired { try store!.finish(attempt, state: "accepted") }
check(try store!.duePushes(at: Date(), fingerprints: ["b"]).isEmpty, "accepted APNs request no longer resends")
check(count(url, "SELECT count(*) FROM archive") == 2, "acceptance never deletes inbox history")

// More than previous 30/200 limits must remain recoverable. Append while paging to exercise
// the contract used when live collection interleaves with a yielded replay batch.
for i in 0..<255 { _ = try store!.append(event("bulk-\(i)"), fingerprints: []) }
var cursor: Int64 = 0
var ordered: [MirroredNotification] = []
while true {
    let page = try store!.events(after: cursor)
    if page.isEmpty { break }
    check(page.count <= 50, "bounded replay batch")
    ordered += page
    cursor = page.last!.sequence!
    if ordered.count == 50 { _ = try store!.append(event("arrived-during-replay"), fingerprints: []) }
}
check(ordered.count == 258, "no silent pruning at 30 or 200, including an event collected during replay")
check(zip(ordered, ordered.dropFirst()).allSatisfy { $0.sequence! < $1.sequence! }, "strict replay ordering across yielded batches")
check(ordered.last?.id == "arrived-during-replay", "live arrival remains after lower sequences")

let oldJSON = Data(#"{"enabled":true,"environment":"sandbox"}"#.utf8)
let legacy = try JSONDecoder().decode(NotificationSubscription.self, from: oldJSON)
check(legacy.historyID == nil && legacy.afterSequence == nil, "legacy subscription decoding")
let oldEventJSON = Data(#"{"id":"old","appBundleID":"test","appName":"Test","title":"Title","body":"Body","date":42}"#.utf8)
let oldEvent = try JSONDecoder().decode(MirroredNotification.self, from: oldEventJSON)
check(oldEvent.historyID == nil && oldEvent.sequence == nil, "legacy event decoding")
check(APNsProvider.classify(statusCode: 200, reason: nil) == .accepted, "APNs accepted")
check(APNsProvider.classify(statusCode: 410, reason: "Unregistered") == .invalidToken, "APNs invalid token")
check(APNsProvider.classify(statusCode: 400, reason: "BadDeviceToken") == .invalidToken, "APNs bad token")
for status in [429, 500, 503] {
    if case .transientFailure = APNsProvider.classify(statusCode: status, reason: nil) {} else { fatalError("APNs transient classification") }
}
for (status, reason) in [(400, "DeviceTokenNotForTopic"), (403, "InvalidProviderToken"), (413, "PayloadTooLarge")] {
    if case .permanentFailure = APNsProvider.classify(statusCode: status, reason: reason) {} else { fatalError("APNs permanent classification") }
}
Task { @MainActor in
    do {
        let suite = "sill.notification-history-check." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let isolated = root.appendingPathComponent("mirror/history.sqlite")
        let mirror = NotificationMirror(defaults: defaults, historyURL: isolated)
        var wakes = 0
        mirror.enabled = true
        mirror.start(macID: "test-mac", isPaired: { _ in true }, onHistoryAvailable: { wakes += 1 })
        mirror.receive(event("first-live"))
        mirror.receive(event("second-live"))
        check(try mirror.replay(after: 0).map(\.sequence) == [1, 2], "live drain reads committed archive sequence")
        mirror.enabled = false
        let start = try mirror.replayStart(for: NotificationSubscription(enabled: true))
        check(try mirror.replay(after: start).isEmpty, "disabled mirroring sends no saved history")
        let beforeResume = wakes
        mirror.enabled = true
        check(wakes == beforeResume + 1, "off to on explicitly wakes paused subscription drains")
        check(try mirror.replay(after: start).count == 2, "resuming recovers backlog without advancing the paused cursor")
        mirror.stop()
        let reloaded = NotificationMirror(defaults: defaults, historyURL: isolated)
        check(try reloaded.replay(after: 0).map(\.id) == ["first-live", "second-live"], "stop/restart retains recoverable history")
        reloaded.stop()
        print("notification-history: atomic baseline/archive, reload/idempotence, delivery identity, revisions, ordered replay, durable outbox, disabled privacy/resume and APNs classification passed (offline)")
        try? FileManager.default.removeItem(at: root)
        exit(0)
    } catch {
        fatalError("Offline mirror history persistence check failed")
    }
}
dispatchMain()
