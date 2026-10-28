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

func checkBannerHistory(root: URL) throws {
    func banner(_ uuid: String, body: String = "Banner body", name: String? = "Banner App") -> NotificationBannerObservation {
        NotificationBannerObservation(sourceUUID: uuid, title: "Banner title", subtitle: "Banner subtitle",
                                      body: body, observedAt: 1_000, displayAppName: name)
    }
    func dbRecord(_ uuid: String, deliveredAt: TimeInterval = 42, body: String = "Full database body") -> NotificationStoreRecord {
        let sourceID = uuid + ":" + String(deliveredAt.bitPattern, radix: 16)
        let notification = MirroredNotification(id: "notification-store:" + sourceID, appBundleID: "test.database",
                                               appName: "Database App", title: "Database title", subtitle: "Database subtitle",
                                               body: body, date: deliveredAt)
        return NotificationStoreRecord(sourceID: sourceID, fingerprint: body, event: notification)
    }
    func location(_ name: String) -> URL { root.appendingPathComponent("banner-" + name + "/history.sqlite") }

    // An early banner keeps one occurrence identity when the authoritative retained row arrives.
    let uuid = String(repeating: "a", count: 32)
    let mergedURL = location("merge")
    var merged: NotificationHistoryStore? = try NotificationHistoryStore(url: mergedURL)
    _ = try merged!.ingest(snapshot([]), fingerprints: ["device"])
    let first = try merged!.ingestBanner(banner(uuid), fingerprints: ["device"])!
    check(first.id == "notification-ax:" + uuid && first.sequence == 1, "AX occurrence gets its own stable ID and sequence")
    check(first.appBundleID.isEmpty && first.appName == "Banner App" && first.date == 1_000,
          "unattributed AX event preserves display app name and observation time")
    check(try merged!.ingestBanner(banner(uuid), fingerprints: ["device"]) == nil, "identical unbound AX observation is idempotent")
    let changed = try merged!.ingestBanner(banner(uuid, body: "Revised banner"), fingerprints: ["device"])!
    check(changed.id == first.id && changed.sequence == 2 && changed.body == "Revised banner", "unbound AX content revision advances the same occurrence")
    let accepted = try merged!.duePushes(at: Date(), fingerprints: ["device"])
    check(accepted.count == 1, "AX revisions have one per-device outbox occurrence")
    try merged!.finish(accepted[0], state: "accepted")
    let full = dbRecord(uuid)
    let enriched = try merged!.ingest(snapshot([full]), fingerprints: ["device"])
    check(enriched.count == 1 && enriched[0].id == first.id && enriched[0].sequence == 3,
          "AX to DB enrichment preserves occurrence ID and advances replay sequence")
    check(enriched[0].appBundleID == full.event.appBundleID && enriched[0].appName == full.event.appName &&
          enriched[0].title == full.event.title && enriched[0].subtitle == full.event.subtitle &&
          enriched[0].body == full.event.body && enriched[0].date == full.event.date, "DB enrichment supplies authoritative attribution and full content")
    check(try merged!.duePushes(at: Date(), fingerprints: ["device"]).isEmpty, "accepted AX occurrence does not alert again after DB enrichment")
    check(try merged!.ingestBanner(banner(uuid, body: "Late stale banner"), fingerprints: ["device"]) == nil,
          "bound AX alias cannot overwrite authoritative DB content")
    merged = nil
    merged = try NotificationHistoryStore(url: mergedURL)
    check(try merged!.ingest(snapshot([full]), fingerprints: ["device"]).isEmpty, "bound DB identity and fingerprints survive restart")
    check(try merged!.ingestBanner(banner(uuid), fingerprints: ["device"]) == nil, "bound AX alias survives restart")
    check(try merged!.events(after: 0).map(\.id) == [first.id], "AX and DB replay as one event after restart")
    check(try merged!.duePushes(at: Date(), fingerprints: ["device"]).isEmpty, "enriched acceptance survives restart")

    let unboundUUID = String(repeating: "b", count: 32)
    let unboundURL = location("unbound-restart")
    var unbound: NotificationHistoryStore? = try NotificationHistoryStore(url: unboundURL)
    let unnamed = try unbound!.ingestBanner(banner(unboundUUID, name: nil), fingerprints: [])!
    check(unnamed.appBundleID.isEmpty && unnamed.appName == "Mac", "AX without a display app name uses neutral Mac attribution")
    unbound = nil
    unbound = try NotificationHistoryStore(url: unboundURL)
    check(try unbound!.ingestBanner(banner(unboundUUID, name: nil), fingerprints: []) == nil, "unbound alias fingerprint survives restart")
    let resumed = try unbound!.ingestBanner(banner(unboundUUID, body: "Changed after restart", name: nil), fingerprints: [])!
    check(resumed.id == unnamed.id && resumed.sequence == 2, "unbound occurrence identity survives restart")

    // A DB observation before AX binds its UUID; reusing that UUID at a new delivery time is
    // a separate source occurrence and must not replace the earlier event.
    let dbUUID = String(repeating: "c", count: 32)
    let dbFirst = try NotificationHistoryStore(url: location("db-first"))
    _ = try dbFirst.ingest(snapshot([]), fingerprints: [])
    let original = dbRecord(dbUUID)
    let originalEvents = try dbFirst.ingest(snapshot([original]), fingerprints: [])
    check(originalEvents.map(\.id) == [original.event.id], "DB-first occurrence retains its original event ID")
    check(try dbFirst.ingestBanner(banner(dbUUID), fingerprints: []) == nil, "DB-first bound alias suppresses a later AX observation")
    let reused = dbRecord(dbUUID, deliveredAt: 84)
    let reusedEvents = try dbFirst.ingest(snapshot([original, reused]), fingerprints: [])
    check(reusedEvents.map(\.id) == [reused.event.id] && reusedEvents[0].id != originalEvents[0].id,
          "UUID reuse at a different DB delivery time creates a distinct occurrence")
    check(try dbFirst.events(after: 0).count == 2, "UUID reuse preserves both DB occurrences")

    // The first retained snapshot may enrich a banner already captured during startup, while
    // unrelated retained history remains a baseline. A failed claim must roll back everything.
    let baselineURL = location("baseline")
    let baselineStore = try NotificationHistoryStore(url: baselineURL)
    let baselineUUID = String(repeating: "d", count: 32)
    let oldUUID = String(repeating: "e", count: 32)
    let early = try baselineStore.ingestBanner(banner(baselineUUID), fingerprints: ["device"])!
    try baselineStore.finish(try baselineStore.duePushes(at: Date(), fingerprints: ["device"])[0], state: "accepted")
    let baselineMatch = dbRecord(baselineUUID)
    let unrelated = dbRecord(oldUUID)
    sql(baselineURL, "CREATE TRIGGER fail_banner_claim BEFORE INSERT ON source_seen WHEN NEW.source_id='\(baselineMatch.sourceID)' BEGIN SELECT RAISE(ABORT,'fixture'); END")
    do {
        _ = try baselineStore.ingest(snapshot([unrelated, baselineMatch]), fingerprints: ["device"])
        fatalError("baseline AX claim must fail")
    } catch {}
    check(count(baselineURL, "SELECT count(*) FROM metadata WHERE key='baseline'") == 0, "failed baseline claim does not establish baseline")
    check(count(baselineURL, "SELECT count(*) FROM source_seen") == 0, "failed baseline claim rolls back other source observations")
    check(try baselineStore.events(after: 0).first?.sequence == 1 && count(baselineURL, "SELECT CAST(value AS INTEGER) FROM metadata WHERE key='sequence'") == 1,
          "failed DB enrichment preserves the AX event without consuming a sequence")
    sql(baselineURL, "DROP TRIGGER fail_banner_claim")
    let baselineEnriched = try baselineStore.ingest(snapshot([unrelated, baselineMatch]), fingerprints: ["device"])
    check(baselineEnriched.count == 1 && baselineEnriched[0].id == early.id && baselineEnriched[0].sequence == 2,
          "first successful DB baseline enriches only an existing AX occurrence")
    check(try baselineStore.events(after: 0).count == 1, "unrelated old DB baseline rows do not become archived alerts")
    check(try baselineStore.ingestBanner(banner(oldUUID), fingerprints: []) == nil, "baseline DB row suppresses a later historical AX observation")
    check(try baselineStore.duePushes(at: Date(), fingerprints: ["device"]).isEmpty, "baseline enrichment never rearms an accepted occurrence")

    let equalStore = try NotificationHistoryStore(url: location("equal-text"))
    let equalOne = try equalStore.ingestBanner(banner(String(repeating: "1", count: 32)), fingerprints: [])!
    let equalTwo = try equalStore.ingestBanner(banner(String(repeating: "2", count: 32)), fingerprints: [])!
    check(equalOne.body == equalTwo.body && equalOne.id != equalTwo.id && equalTwo.sequence == 2,
          "equal AX text with distinct UUIDs remains separate deliveries")

    // Upgrade compatibility: old source_seen entries predate the alias table. Their UUID
    // prefix is still sufficient to suppress AX; the complete source ID retains its old ID.
    let legacyURL = location("legacy")
    let legacyStore = try NotificationHistoryStore(url: legacyURL)
    _ = try legacyStore.ingest(snapshot([]), fingerprints: [])
    let legacyUUID = String(repeating: "3", count: 32)
    let legacyRecord = dbRecord(legacyUUID)
    sql(legacyURL, "INSERT INTO source_seen(source_id,fingerprint,event_id) VALUES('\(legacyRecord.sourceID)','old-fingerprint','preserved-legacy-id')")
    check(try legacyStore.ingestBanner(banner(legacyUUID), fingerprints: []) == nil, "legacy source_seen UUID prefix suppresses AX without an alias")
    let legacyChanged = try legacyStore.ingest(snapshot([legacyRecord]), fingerprints: [])
    check(legacyChanged.map(\.id) == ["preserved-legacy-id"], "existing full source_seen identity takes precedence over new DB IDs")

    // Two candidate DB source IDs in one snapshot are ambiguous, even when the UUID matches
    // AX exactly. Neither row may claim the unbound banner based on traversal order.
    let ambiguousStore = try NotificationHistoryStore(url: location("ambiguous"))
    _ = try ambiguousStore.ingest(snapshot([]), fingerprints: [])
    let ambiguousUUID = String(repeating: "4", count: 32)
    let ambiguousAX = try ambiguousStore.ingestBanner(banner(ambiguousUUID), fingerprints: [])!
    let candidateOne = dbRecord(ambiguousUUID, deliveredAt: 100)
    let candidateTwo = dbRecord(ambiguousUUID, deliveredAt: 200)
    let ambiguousDB = try ambiguousStore.ingest(snapshot([candidateTwo, candidateOne]), fingerprints: [])
    check(Set(ambiguousDB.map(\.id)) == Set([candidateOne.event.id, candidateTwo.event.id]),
          "multiple DB occurrences sharing a UUID retain their own original IDs")
    let stillUnbound = try ambiguousStore.ingestBanner(banner(ambiguousUUID, body: "Still independently observed"), fingerprints: [])
    check(stillUnbound?.id == ambiguousAX.id && stillUnbound?.sequence == 4,
          "ambiguous DB candidates leave the AX alias unbound")
    check(try ambiguousStore.events(after: 0).count == 3, "ambiguous matching preserves all three independent events")

    let rollbackURL = location("rollback")
    let rollbackStore = try NotificationHistoryStore(url: rollbackURL)
    let rollbackUUID = String(repeating: "5", count: 32)
    sql(rollbackURL, "CREATE TRIGGER fail_banner_archive BEFORE INSERT ON archive BEGIN SELECT RAISE(ABORT,'fixture'); END")
    do {
        _ = try rollbackStore.ingestBanner(banner(rollbackUUID), fingerprints: ["device"])
        fatalError("new AX archive must fail")
    } catch {}
    check(count(rollbackURL, "SELECT count(*) FROM archive") == 0 && count(rollbackURL, "SELECT count(*) FROM push_outbox") == 0,
          "failed AX transaction leaves no archive or outbox rows")
    sql(rollbackURL, "DROP TRIGGER fail_banner_archive")
    let recovered = try rollbackStore.ingestBanner(banner(rollbackUUID), fingerprints: ["device"])!
    check(recovered.sequence == 1 && recovered.id == "notification-ax:" + rollbackUUID,
          "failed AX transaction neither consumes a sequence nor leaves a dedup alias")
    check(try rollbackStore.duePushes(at: Date(), fingerprints: ["device"]).count == 1, "retried AX transaction creates exactly one outbox item")
}

@MainActor
func checkMirrorBannerRetry(root: URL) async throws {
    let suite = "sill.banner-retry-check." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let blockedDirectory = root.appendingPathComponent("banner-retry-blocked")
    precondition(FileManager.default.createFile(atPath: blockedDirectory.path, contents: Data()))
    let historyURL = blockedDirectory.appendingPathComponent("history.sqlite")
    let mirror = NotificationMirror(defaults: defaults, historyURL: historyURL)
    defer { mirror.stop() }
    let collector = NotificationMirrorCollector.latest!
    var commits = 0
    mirror.enabled = true
    mirror.start(macID: "retry-mac", isPaired: { _ in true }, onHistoryAvailable: { commits += 1 })
    let peer = Data([1, 2, 3])
    check(mirror.subscribe(NotificationSubscription(enabled: true, pushToken: "0102", topic: "test.ios.apns",
                                                   environment: "sandbox"), fingerprint: peer),
          "offline mirror integration registers a paired push recipient without creating a provider")
    let before = commits
    let uuid = String(repeating: "f", count: 32)
    collector.onBanner?(NotificationBannerObservation(sourceUUID: uuid, title: "Retry fixture", subtitle: "",
                                                      body: "Retained after failed write", observedAt: 1_000,
                                                      displayAppName: nil))
    check(commits == before && !FileManager.default.fileExists(atPath: historyURL.path),
          "blocked history path makes the first AX write fail without announcing a commit")
    try FileManager.default.removeItem(at: blockedDirectory)
    try FileManager.default.createDirectory(at: blockedDirectory, withIntermediateDirectories: true)
    // No second banner or DB snapshot is emitted. Allow scheduler tolerance around the 2s timer,
    // and wait on its commit callback rather than opening a store that could mask a missed retry.
    let deadline = Date().addingTimeInterval(3)
    while commits == before && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
    check(commits == before + 1, "failed AX write retries once on the two-second timer without another observation")
    let ledger = try NotificationHistoryStore(url: historyURL)
    let retained = try ledger.events(after: 0)
    check(retained.count == 1 && retained[0].sequence == 1 && retained[0].id == "notification-ax:" + uuid,
          "retried banner consumes exactly one sequence and one archive occurrence")
    check(count(historyURL, "SELECT count(*) FROM push_outbox") == 0,
          "unattributed AX capture creates no APNs outbox work even with a registered peer")

    let sourceID = uuid + ":" + String(TimeInterval(42).bitPattern, radix: 16)
    let known = MirroredNotification(id: "notification-store:" + sourceID, appBundleID: "test.known.source",
                                     appName: "Known source", title: "Retry fixture", body: "Full retained body", date: 42)
    collector.onSnapshot?(snapshot([NotificationStoreRecord(sourceID: sourceID, fingerprint: "known-content", event: known)]))
    let enriched = try ledger.events(after: 0)
    check(enriched.count == 1 && enriched[0].id == retained[0].id && enriched[0].sequence == 2 &&
          enriched[0].appBundleID == "test.known.source", "DB attribution enriches the retried AX occurrence under its original ID")
    let pending = try ledger.duePushes(at: Date(), fingerprints: [peer.base64EncodedString()])
    check(pending.count == 1 && pending[0].event.id == retained[0].id && pending[0].event.sequence == 2,
          "only authoritative DB source attribution creates a single pending APNs delivery")
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
try checkBannerHistory(root: root)
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
        try await checkMirrorBannerRetry(root: root)
        print("notification-history: atomic baseline/archive, AX/DB alias merge, mirror write retry/source-gated outbox, reload/idempotence, UUID reuse/ambiguity, revisions, ordered replay, durable outbox, disabled privacy/resume and APNs classification passed (offline)")
        try? FileManager.default.removeItem(at: root)
        exit(0)
    } catch {
        fatalError("Offline mirror history persistence check failed")
    }
}
dispatchMain()
