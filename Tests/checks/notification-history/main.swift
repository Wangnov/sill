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

func checkSourceEvidence(root: URL) throws {
    func observation(_ uuid: String, body: String = "Evidence fixture body") -> NotificationBannerObservation {
        NotificationBannerObservation(sourceUUID: uuid, title: "Evidence fixture title", subtitle: "",
                                      body: body, observedAt: 1_500, displayAppName: nil)
    }
    func location(_ name: String) -> URL { root.appendingPathComponent("source-evidence-" + name + "/history.sqlite") }

    // An arrival candidate can precede AX. Confirming that same attribution is an evidence
    // upgrade, not a second occurrence or another alert to an already accepted recipient.
    let sameURL = location("same-exact")
    let same = try NotificationHistoryStore(url: sameURL)
    let sameUUID = String(repeating: "16", count: 16)
    check(try same.enrichBannerSource(uuid: sameUUID, bundleID: "test.candidate", appName: "Candidate App", evidence: .arrival,
                                     fingerprints: ["pending", "accepted"]) == nil && same.events(after: 0).isEmpty &&
          count(sameURL, "SELECT CAST(value AS INTEGER) FROM metadata WHERE key='sequence'") == 0,
          "source-first arrival evidence stores metadata without inventing an event or sequence")
    let candidate = try same.ingestBanner(observation(sameUUID), fingerprints: ["pending", "accepted"])!
    check(try candidate.appBundleID == "test.candidate" && candidate.appName == "Candidate App" &&
          same.duePushes(at: Date(), fingerprints: ["pending"]).count == 1, "arrival evidence can attribute and enqueue its later AX occurrence")
    try same.finish(try same.duePushes(at: Date(), fingerprints: ["accepted"])[0], state: "accepted")
    _ = try same.enrichBannerSource(uuid: sameUUID, bundleID: "test.candidate", appName: "Candidate App", evidence: .exact,
                                   fingerprints: ["pending", "accepted"])
    let confirmed = try same.events(after: 0)
    check(confirmed.count == 1 && confirmed[0].id == candidate.id && confirmed[0].body == candidate.body && confirmed[0].date == candidate.date &&
          count(sameURL, "SELECT count(*) FROM notification_source WHERE uuid='\(sameUUID)' AND evidence='exact'") == 1,
          "same-source exact confirmation upgrades stored evidence while preserving one AX occurrence")
    check(try same.duePushes(at: Date(), fingerprints: ["pending"]).count == 1 && same.duePushes(at: Date(), fingerprints: ["accepted"]).isEmpty,
          "arrival to exact confirmation neither duplicates pending work nor rearms acceptance")
    let confirmedSequence = confirmed[0].sequence
    check(try same.enrichBannerSource(uuid: sameUUID, bundleID: "", appName: "", evidence: .ambiguous, fingerprints: ["new"]) == nil &&
          same.enrichBannerSource(uuid: sameUUID, bundleID: "test.late-arrival", appName: "Late App", evidence: .arrival, fingerprints: ["new"]) == nil &&
          same.events(after: 0).first?.sequence == confirmedSequence && same.duePushes(at: Date(), fingerprints: ["new"]).isEmpty,
          "ambiguous or late arrival evidence cannot downgrade an exact source or add recipients")

    // A stronger exact source may correct a different arrival candidate without creating
    // an exact/exact conflict. A subsequent retained DB row remains authoritative over both.
    let corrected = try NotificationHistoryStore(url: location("corrected"))
    _ = try corrected.ingest(snapshot([]), fingerprints: [])
    let correctedUUID = String(repeating: "27", count: 16)
    _ = try corrected.enrichBannerSource(uuid: correctedUUID, bundleID: "test.guessed-arrival", appName: "Arrival App", evidence: .arrival, fingerprints: [])
    let before = try corrected.ingestBanner(observation(correctedUUID), fingerprints: ["pending", "accepted"])!
    let staleCandidate = try corrected.duePushes(at: Date(), fingerprints: ["pending"])[0]
    try corrected.finish(try corrected.duePushes(at: Date(), fingerprints: ["accepted"])[0], state: "accepted")
    let exact = try corrected.enrichBannerSource(uuid: correctedUUID, bundleID: "test.correct-exact", appName: "Exact App", evidence: .exact,
                                                fingerprints: ["pending", "accepted"])!
    check(exact.id == before.id && exact.sequence == 2 && exact.appBundleID == "test.correct-exact" && exact.appName == "Exact App" &&
          exact.title == before.title && exact.body == before.body && exact.date == before.date,
          "different-bundle exact evidence corrects arrival attribution under the same body, date and ID")
    check(try !corrected.isCurrent(staleCandidate) && corrected.duePushes(at: Date(), fingerprints: ["accepted"]).isEmpty &&
          corrected.duePushes(at: Date(), fingerprints: ["pending"]).first?.event.appBundleID == exact.appBundleID,
          "source correction invalidates old pending attempts and preserves accepted delivery")
    let dbSourceID = correctedUUID + ":" + String(TimeInterval(700).bitPattern, radix: 16)
    let dbEvent = MirroredNotification(id: "notification-store:" + dbSourceID, appBundleID: "test.bound-database", appName: "Database App",
                                       title: "Database title", body: "Authoritative DB body", date: 700)
    let bound = try corrected.ingest(snapshot([NotificationStoreRecord(sourceID: dbSourceID, fingerprint: "bound", event: dbEvent)]), fingerprints: ["pending", "accepted"])[0]
    check(try corrected.enrichBannerSource(uuid: correctedUUID, bundleID: "", appName: "", evidence: .ambiguous, fingerprints: ["new"]) == nil &&
          corrected.enrichBannerSource(uuid: correctedUUID, bundleID: "test.untrusted-arrival", appName: "Untrusted", evidence: .arrival, fingerprints: ["new"]) == nil &&
          corrected.events(after: 0) == [bound] && corrected.duePushes(at: Date(), fingerprints: ["new"]).isEmpty,
          "ambiguous and arrival evidence cannot change a DB-bound event or its recipients")

    // Both revocation of arrival evidence and an exact/exact conflict withdraw unsent alerts.
    // Acceptance cannot be recalled, and an attempt captured before withdrawal is no longer current.
    for reason in ["ambiguous", "exact-conflict"] {
        let withdrawalURL = location(reason)
        var withdrawal: NotificationHistoryStore? = try NotificationHistoryStore(url: withdrawalURL)
        let withdrawalUUID = String(repeating: "38", count: 16)
        _ = try withdrawal!.enrichBannerSource(uuid: withdrawalUUID, bundleID: "test.initial-source", appName: "Initial App",
                                               evidence: reason == "ambiguous" ? .arrival : .exact, fingerprints: [])
        let original = try withdrawal!.ingestBanner(observation(withdrawalUUID), fingerprints: ["pending", "accepted"])!
        let stale = try withdrawal!.duePushes(at: Date(), fingerprints: ["pending"])[0]
        try withdrawal!.finish(try withdrawal!.duePushes(at: Date(), fingerprints: ["accepted"])[0], state: "accepted")
        let unknown = try withdrawal!.enrichBannerSource(uuid: withdrawalUUID,
                                                        bundleID: reason == "ambiguous" ? "" : "test.conflicting-exact",
                                                        appName: reason == "ambiguous" ? "" : "Conflicting App",
                                                        evidence: reason == "ambiguous" ? .ambiguous : .exact,
                                                        fingerprints: ["pending", "accepted", "new"])!
        check(unknown.id == original.id && unknown.sequence == 2 && unknown.appBundleID.isEmpty && unknown.appName == "Mac" &&
              unknown.body == original.body && unknown.date == original.date,
              "source withdrawal preserves occurrence identity/content while clearing attribution (\(reason))")
        check(try !withdrawal!.isCurrent(stale) && withdrawal!.duePushes(at: Date(), fingerprints: ["pending", "new"]).isEmpty &&
              count(withdrawalURL, "SELECT count(*) FROM push_outbox WHERE fingerprint='pending' AND state='suppressed'") == 1 &&
              count(withdrawalURL, "SELECT count(*) FROM push_outbox WHERE fingerprint='accepted' AND state='accepted'") == 1,
              "source withdrawal suppresses unsent work, rejects stale attempts and retains acceptance (\(reason))")
        try withdrawal!.retryFailures()
        check(try withdrawal!.duePushes(at: Date(), fingerprints: ["pending"]).isEmpty, "provider retry cannot revive withdrawn source attribution (\(reason))")
        withdrawal = nil
        withdrawal = try NotificationHistoryStore(url: withdrawalURL)
        check(try withdrawal!.enrichBannerSource(uuid: withdrawalUUID, bundleID: "test.initial-source", appName: "Initial App", evidence: .arrival,
                                                 fingerprints: ["pending", "new"]) == nil,
              "withdrawn evidence persists across restart and ignores a late arrival (\(reason))")
        let laterAX = try withdrawal!.ingestBanner(observation(withdrawalUUID, body: "AX after source withdrawal"), fingerprints: ["pending", "new"])!
        check(try laterAX.sequence == 3 && laterAX.appBundleID.isEmpty && withdrawal!.duePushes(at: Date(), fingerprints: ["pending", "new"]).isEmpty,
              "later AX content remains unknown and suppressed after withdrawal (\(reason))")
        if reason == "ambiguous" {
            let repaired = try withdrawal!.enrichBannerSource(uuid: withdrawalUUID, bundleID: "test.repaired-exact", appName: "Repaired App", evidence: .exact,
                                                              fingerprints: ["pending", "accepted", "new"])!
            check(try repaired.id == original.id && repaired.sequence == 4 && repaired.appBundleID == "test.repaired-exact" &&
                  withdrawal!.duePushes(at: Date(), fingerprints: ["pending", "new"]).count == 2 &&
                  withdrawal!.duePushes(at: Date(), fingerprints: ["accepted"]).isEmpty,
                  "exact evidence repairs ambiguous arrival, resumes eligible recipients and preserves acceptance")
        }
    }

    // Reproduce the deployed three-column table before opening the new store. Existing rows,
    // including NULL conflicts, carry exact evidence and must never be weakened by arrival data.
    let legacyURL = location("legacy-schema")
    try FileManager.default.createDirectory(at: legacyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let legacyUUID = String(repeating: "49", count: 16)
    let legacyConflictUUID = String(repeating: "5a", count: 16)
    sql(legacyURL, """
        CREATE TABLE notification_source(uuid TEXT PRIMARY KEY,bundle_id TEXT,app_name TEXT);
        INSERT INTO notification_source VALUES('\(legacyUUID)','test.legacy-exact','Legacy Exact App');
        INSERT INTO notification_source VALUES('\(legacyConflictUUID)',NULL,NULL);
        """)
    let legacy = try NotificationHistoryStore(url: legacyURL)
    check(count(legacyURL, "SELECT count(*) FROM notification_source WHERE evidence='exact'") == 2,
          "three-column source schema migrates every existing row, including NULL conflicts, to exact evidence")
    for legacyID in [legacyUUID, legacyConflictUUID] {
        check(try legacy.enrichBannerSource(uuid: legacyID, bundleID: "test.late-arrival", appName: "Late Arrival", evidence: .arrival, fingerprints: ["device"]) == nil &&
              legacy.enrichBannerSource(uuid: legacyID, bundleID: "", appName: "", evidence: .ambiguous, fingerprints: ["device"]) == nil,
              "migrated exact evidence ignores weaker arrival and ambiguity observations")
    }
    let legacyExact = try legacy.ingestBanner(observation(legacyUUID), fingerprints: ["device"])!
    let legacyUnknown = try legacy.ingestBanner(observation(legacyConflictUUID), fingerprints: ["device"])!
    check(try legacyExact.appBundleID == "test.legacy-exact" && legacyExact.appName == "Legacy Exact App" && legacyUnknown.appBundleID.isEmpty &&
          legacy.duePushes(at: Date(), fingerprints: ["device"]).map { $0.event.id } == [legacyExact.id] &&
          count(legacyURL, "SELECT count(*) FROM notification_source WHERE uuid='\(legacyConflictUUID)' AND bundle_id IS NULL AND evidence='exact'") == 1,
          "migrated exact attribution stays usable while its legacy conflict remains unknown and cannot alert")
}

func checkBannerSourceHistory(root: URL) throws {
    func observation(_ uuid: String, body: String = "AX original body", observedAt: TimeInterval = 1_234) -> NotificationBannerObservation {
        NotificationBannerObservation(sourceUUID: uuid, title: "AX title", subtitle: "AX subtitle",
                                      body: body, observedAt: observedAt, displayAppName: nil)
    }
    func location(_ name: String) -> URL { root.appendingPathComponent("banner-source-" + name + "/history.sqlite") }

    let uuid = String(repeating: "6", count: 32)
    let url = location("enrichment")
    let store = try NotificationHistoryStore(url: url)
    _ = try store.ingest(snapshot([]), fingerprints: [])
    let original = try store.ingestBanner(observation(uuid), fingerprints: [])!
    let enriched = try store.enrichBannerSource(uuid: uuid, bundleID: "test.exact-source", appName: "Exact App",
                                               fingerprints: ["pending", "accepted", "recover", "withheld"])!
    check(enriched.id == original.id && enriched.sequence == 2 && enriched.appBundleID == "test.exact-source" && enriched.appName == "Exact App",
          "exact log source enriches the existing AX occurrence")
    check(enriched.title == original.title && enriched.subtitle == original.subtitle && enriched.body == original.body && enriched.date == original.date,
          "source enrichment preserves AX content and observation time")
    check(count(url, "SELECT count(*) FROM notification_alias WHERE uuid='\(uuid)' AND source_id IS NULL") == 1,
          "exact source metadata does not bind an AX alias to a DB delivery occurrence")
    check(try store.duePushes(at: Date(), fingerprints: ["pending"]).map { $0.event.id } == [original.id],
          "newly attributed AX occurrence enters the requested recipient outbox")
    let staleAttempt = try store.duePushes(at: Date(), fingerprints: ["pending"])[0]
    check(try store.isCurrent(staleAttempt), "current pending source revision is eligible before send")
    let acceptedAttempt = try store.duePushes(at: Date(), fingerprints: ["accepted"])[0]
    try store.finish(acceptedAttempt, state: "accepted")
    check(try !store.isCurrent(acceptedAttempt), "accepted request cannot be sent again from an old batch")
    for fingerprint in ["recover", "withheld"] {
        try store.finish(try store.duePushes(at: Date(), fingerprints: [fingerprint])[0], state: "suppressed")
    }
    check(try store.enrichBannerSource(uuid: uuid, bundleID: "test.exact-source", appName: "Exact App", fingerprints: ["pending", "accepted"]) == nil,
          "identical source attribution is idempotent")
    check(count(url, "SELECT CAST(value AS INTEGER) FROM metadata WHERE key='sequence'") == 2,
          "identical source attribution consumes no sequence")
    let renamed = try store.enrichBannerSource(uuid: uuid, bundleID: "test.exact-source", appName: "Exact App Renamed", fingerprints: ["pending", "accepted", "recover"])!
    check(try !store.isCurrent(staleAttempt), "a source revision invalidates an attempt held while another request awaited its response")
    check(try renamed.id == original.id && renamed.sequence == 3 && renamed.appName == "Exact App Renamed" &&
          store.duePushes(at: Date(), fingerprints: ["accepted"]).isEmpty,
          "same-bundle source name enrichment preserves accepted delivery")
    check(try store.duePushes(at: Date(), fingerprints: ["recover"]).count == 1 &&
          store.duePushes(at: Date(), fingerprints: ["withheld"]).isEmpty,
          "confirmed source enrichment rearms only explicitly included suppressed recipients")
    let revised = try store.ingestBanner(observation(uuid, body: "AX updated body", observedAt: 9_999), fingerprints: ["pending", "accepted"])!
    check(revised.id == original.id && revised.sequence == 4 && revised.body == "AX updated body" && revised.date == original.date &&
          revised.appBundleID == renamed.appBundleID && revised.appName == renamed.appName,
          "later AX text revision retains exact source attribution and original observation time")
    check(try store.duePushes(at: Date(), fingerprints: ["accepted"]).isEmpty, "source or AX enrichment never rearms an accepted occurrence")
    let dbSourceID = uuid + ":" + String(TimeInterval(500).bitPattern, radix: 16)
    let dbEvent = MirroredNotification(id: "notification-store:" + dbSourceID, appBundleID: "test.authoritative-db", appName: "Database App",
                                       title: "DB title", subtitle: "DB subtitle", body: "Full DB body", date: 500)
    let authoritative = try store.ingest(snapshot([NotificationStoreRecord(sourceID: dbSourceID, fingerprint: "db-source", event: dbEvent)]), fingerprints: ["pending", "accepted"])
    check(authoritative.count == 1 && authoritative[0].id == original.id && authoritative[0].sequence == 5 &&
          authoritative[0].appBundleID == dbEvent.appBundleID && authoritative[0].appName == dbEvent.appName &&
          authoritative[0].body == dbEvent.body && authoritative[0].date == dbEvent.date,
          "later DB row authoritatively corrects exact-log attribution and delivery date under the same ID")
    check(try store.enrichBannerSource(uuid: uuid, bundleID: "test.exact-source", appName: "Exact App", fingerprints: ["pending", "accepted"]) == nil,
          "a DB-bound occurrence ignores later log source enrichment")
    check(try store.events(after: 0).first?.appBundleID == dbEvent.appBundleID && store.duePushes(at: Date(), fingerprints: ["accepted"]).isEmpty,
          "bound DB attribution and accepted state remain authoritative")

    let sourceFirstUUID = String(repeating: "7", count: 32)
    let unrelatedUUID = String(repeating: "8", count: 32)
    let sourceFirstURL = location("source-first")
    var sourceFirst: NotificationHistoryStore? = try NotificationHistoryStore(url: sourceFirstURL)
    check(try sourceFirst!.enrichBannerSource(uuid: sourceFirstUUID, bundleID: "test.source-first", appName: "Source First", fingerprints: ["device"]) == nil,
          "source metadata arriving first does not manufacture an empty event")
    check(try sourceFirst!.events(after: 0).isEmpty && sourceFirst!.duePushes(at: Date(), fingerprints: ["device"]).isEmpty &&
          count(sourceFirstURL, "SELECT CAST(value AS INTEGER) FROM metadata WHERE key='sequence'") == 0,
          "source-only metadata creates neither archive, outbox nor sequence")
    sourceFirst = nil
    sourceFirst = try NotificationHistoryStore(url: sourceFirstURL)
    let unrelated = try sourceFirst!.ingestBanner(observation(unrelatedUUID), fingerprints: ["device"])!
    check(unrelated.appBundleID.isEmpty && unrelated.appName == "Mac", "exact source mapping cannot cross into another UUID")
    check(try sourceFirst!.duePushes(at: Date(), fingerprints: ["device"]).isEmpty, "unknown AX source never enters an outbox even when recipients are supplied")
    let mapped = try sourceFirst!.ingestBanner(observation(sourceFirstUUID), fingerprints: ["device"])!
    check(mapped.sequence == 2 && mapped.appBundleID == "test.source-first" && mapped.appName == "Source First",
          "source-first mapping survives restart and supplies attribution to the later AX event")
    check(try sourceFirst!.duePushes(at: Date(), fingerprints: ["device"]).map { $0.event.id } == [mapped.id],
          "source-first mapped AX event enqueues only its confirmed occurrence")
    check(try sourceFirst!.enrichBannerSource(uuid: sourceFirstUUID, bundleID: "test.source-first", appName: "Source First", fingerprints: ["device"]) == nil,
          "reloaded exact source mapping remains idempotent")

    let conflictUUID = String(repeating: "a6", count: 16)
    let conflictURL = location("conflict")
    var conflict: NotificationHistoryStore? = try NotificationHistoryStore(url: conflictURL)
    _ = try conflict!.ingest(snapshot([]), fingerprints: [])
    let provisional = try conflict!.ingestBanner(observation(conflictUUID), fingerprints: ["existing"])!
    _ = try conflict!.enrichBannerSource(uuid: conflictUUID, bundleID: "test.first-source", appName: "First App", fingerprints: ["existing"])
    try conflict!.finish(try conflict!.duePushes(at: Date(), fingerprints: ["existing"])[0], state: "accepted")
    let withdrawn = try conflict!.enrichBannerSource(uuid: conflictUUID, bundleID: "test.conflicting-source", appName: "Conflicting App", fingerprints: ["new"])!
    check(withdrawn.id == provisional.id && withdrawn.sequence == 3 && withdrawn.appBundleID.isEmpty && withdrawn.appName == "Mac" &&
          withdrawn.body == provisional.body && withdrawn.date == provisional.date,
          "conflicting log bundle IDs withdraw AX-only attribution without guessing or changing its content")
    check(try conflict!.duePushes(at: Date(), fingerprints: ["new"]).isEmpty, "source conflict never enqueues the unknown occurrence for new recipients")
    let conflictRevision = try conflict!.ingestBanner(observation(conflictUUID, body: "Changed while source is conflicted"), fingerprints: ["new"])!
    check(try conflictRevision.sequence == 4 && conflictRevision.appBundleID.isEmpty && conflictRevision.appName == "Mac" &&
          conflict!.duePushes(at: Date(), fingerprints: ["new"]).isEmpty,
          "later AX revisions remain unknown and do not alert new recipients after source conflict")
    conflict = nil
    conflict = try NotificationHistoryStore(url: conflictURL)
    check(try conflict!.enrichBannerSource(uuid: conflictUUID, bundleID: "test.first-source", appName: "First App", fingerprints: ["new"]) == nil &&
          count(conflictURL, "SELECT CAST(value AS INTEGER) FROM metadata WHERE key='sequence'") == 4,
          "source conflict persists across restart and cannot be repaired by another log line")
    let recoveredSourceID = conflictUUID + ":" + String(TimeInterval(600).bitPattern, radix: 16)
    let recoveredEvent = MirroredNotification(id: "notification-store:" + recoveredSourceID, appBundleID: "test.confirmed-database",
                                              appName: "Confirmed Database App", title: "DB title", body: "DB body", date: 600)
    let recoveredDB = try conflict!.ingest(snapshot([NotificationStoreRecord(sourceID: recoveredSourceID, fingerprint: "confirmed-db", event: recoveredEvent)]), fingerprints: ["existing", "new"])
    check(recoveredDB.count == 1 && recoveredDB[0].id == provisional.id && recoveredDB[0].sequence == 5 &&
          recoveredDB[0].appBundleID == recoveredEvent.appBundleID && recoveredDB[0].date == recoveredEvent.date,
          "authoritative DB observation can resolve a conflicted AX occurrence under its original ID")
    check(try conflict!.duePushes(at: Date(), fingerprints: ["existing"]).isEmpty &&
          conflict!.duePushes(at: Date(), fingerprints: ["new"]).map { $0.event.id } == [provisional.id],
          "DB resolution preserves accepted delivery and enqueues the newly confirmed recipient once")
    check(try conflict!.enrichBannerSource(uuid: conflictUUID, bundleID: "test.another-source", appName: "Another App", fingerprints: ["new"]) == nil &&
          conflict!.events(after: 0).first?.appBundleID == recoveredEvent.appBundleID,
          "later conflicting logs cannot replace a DB-bound attribution")

    // Fail before the archive write and late in outbox creation. Both failures must roll back
    // the exact-source mapping as well as archive/outbox state and the replay sequence.
    for failure in ["archive", "outbox"] {
        let rollbackURL = location("rollback-" + failure)
        let rollback = try NotificationHistoryStore(url: rollbackURL)
        let rollbackUUID = String(repeating: "9", count: 32)
        let early = try rollback.ingestBanner(observation(rollbackUUID), fingerprints: [])!
        let trigger = failure == "archive"
            ? "CREATE TRIGGER fail_source_enrichment BEFORE INSERT ON archive BEGIN SELECT RAISE(ABORT,'fixture'); END"
            : "CREATE TRIGGER fail_source_enrichment BEFORE INSERT ON push_outbox WHEN NEW.fingerprint='fail' BEGIN SELECT RAISE(ABORT,'fixture'); END"
        sql(rollbackURL, trigger)
        do {
            _ = try rollback.enrichBannerSource(uuid: rollbackUUID, bundleID: "test.rollback-source", appName: "Rollback App", fingerprints: ["good", "fail"])
            fatalError("source enrichment transaction must fail")
        } catch {}
        let unchanged = try rollback.events(after: 0)
        check(unchanged.count == 1 && unchanged[0] == early && count(rollbackURL, "SELECT count(*) FROM push_outbox") == 0 &&
              count(rollbackURL, "SELECT CAST(value AS INTEGER) FROM metadata WHERE key='sequence'") == 1,
              "failed source enrichment preserves archive/outbox and consumes no sequence (\(failure))")
        sql(rollbackURL, "DROP TRIGGER fail_source_enrichment")
        let afterFailure = try rollback.ingestBanner(observation(rollbackUUID, body: "AX after failed source write"), fingerprints: [])!
        check(afterFailure.sequence == 2 && afterFailure.appBundleID.isEmpty && afterFailure.appName == "Mac",
              "failed source mapping does not leak into a later AX revision (\(failure))")
        let recovered = try rollback.enrichBannerSource(uuid: rollbackUUID, bundleID: "test.rollback-source", appName: "Rollback App", fingerprints: ["good"])!
        check(try recovered.id == early.id && recovered.sequence == 3 && recovered.appBundleID == "test.rollback-source" &&
              rollback.duePushes(at: Date(), fingerprints: ["good"]).count == 1,
              "source enrichment retries as one committed occurrence after rollback (\(failure))")
    }
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
    check(try merged!.duePushes(at: Date(), fingerprints: ["device"]).isEmpty, "unknown AX revisions never enqueue recipient alerts")
    _ = try merged!.enrichBannerSource(uuid: uuid, bundleID: "test.banner-source", appName: "Exact Banner App", fingerprints: ["device"])
    let accepted = try merged!.duePushes(at: Date(), fingerprints: ["device"])
    check(accepted.count == 1, "confirmed AX source creates one per-device outbox occurrence")
    try merged!.finish(accepted[0], state: "accepted")
    let full = dbRecord(uuid)
    let enriched = try merged!.ingest(snapshot([full]), fingerprints: ["device"])
    check(enriched.count == 1 && enriched[0].id == first.id && enriched[0].sequence == 4,
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
    _ = try baselineStore.enrichBannerSource(uuid: baselineUUID, bundleID: "test.baseline-source", appName: "Baseline Source App", fingerprints: ["device"])
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
    check(try baselineStore.events(after: 0).first?.sequence == 2 && count(baselineURL, "SELECT CAST(value AS INTEGER) FROM metadata WHERE key='sequence'") == 2,
          "failed DB enrichment preserves the AX event without consuming a sequence")
    sql(baselineURL, "DROP TRIGGER fail_banner_claim")
    let baselineEnriched = try baselineStore.ingest(snapshot([unrelated, baselineMatch]), fingerprints: ["device"])
    check(baselineEnriched.count == 1 && baselineEnriched[0].id == early.id && baselineEnriched[0].sequence == 3,
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
    check(try rollbackStore.duePushes(at: Date(), fingerprints: ["device"]).isEmpty, "retried unknown AX transaction still creates no outbox item")
}

@MainActor
func checkMirrorPendingWithdrawal(root: URL) async throws {
    let suite = "sill.pending-withdrawal-check." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let historyURL = root.appendingPathComponent("mirror-pending-withdrawal/history.sqlite")
    let mirror = NotificationMirror(defaults: defaults, historyURL: historyURL)
    defer { mirror.stop() }
    let collector = NotificationMirrorCollector.latest!
    var commits = 0
    mirror.enabled = true
    mirror.start(macID: "withdrawal-mac", isPaired: { _ in true }, onHistoryAvailable: { commits += 1 })
    let peer = Data([4, 5, 6])
    check(mirror.subscribe(NotificationSubscription(enabled: true, pushToken: "0304", topic: "test.ios.apns",
                                                   environment: "sandbox"), fingerprint: peer),
          "withdrawal fixture registers a recipient without starting an APNs provider")
    let uuid = String(repeating: "b7", count: 16)
    let arrival = NotificationSourceAttribution(uuid: uuid, bundleID: "test.arrival.fixture", evidence: .arrival)
    collector.onSource?(arrival, "Arrival Fixture")
    collector.onBanner?(NotificationBannerObservation(sourceUUID: uuid, title: "Withdrawal fixture", subtitle: "",
                                                      body: "Synthetic candidate body", observedAt: 1_750, displayAppName: nil))
    let ledger = try NotificationHistoryStore(url: historyURL)
    let stale = try ledger.duePushes(at: Date(), fingerprints: [peer.base64EncodedString()])[0]
    check(stale.event.sequence == 1 && stale.event.appBundleID == arrival.bundleID, "candidate starts as one pending occurrence")
    sql(historyURL, """
        CREATE TRIGGER fail_pending_withdrawal BEFORE INSERT ON notification_source
        WHEN NEW.uuid='\(uuid)' AND NEW.evidence='ambiguous' BEGIN SELECT RAISE(ABORT,'fixture'); END
        """)
    let before = commits
    collector.onSource?(NotificationSourceAttribution(uuid: uuid, bundleID: "", evidence: .ambiguous), "")
    check(try commits == before && ledger.isCurrent(stale) &&
          count(historyURL, "SELECT count(*) FROM notification_source WHERE uuid='\(uuid)' AND evidence='arrival'") == 1,
          "first ambiguous write fails atomically and remains queued in the mirror")
    // The same candidate, rather than another bundle, makes this catch a lost withdrawal:
    // replacing the pending ambiguous entry would otherwise succeed as an unchanged arrival.
    collector.onSource?(arrival, "Arrival Fixture")
    sql(historyURL, "DROP TRIGGER fail_pending_withdrawal")
    let deadline = Date().addingTimeInterval(3)
    while commits == before && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
    let events = try ledger.events(after: 0)
    check(commits == before + 1 && events.count == 1 && events[0].id == stale.event.id && events[0].sequence == 2 &&
          events[0].appBundleID.isEmpty && events[0].body == stale.event.body && events[0].date == stale.event.date,
          "pending ambiguous withdrawal survives late arrival and retries under the original ID/content")
    check(try !ledger.isCurrent(stale) && ledger.duePushes(at: Date(), fingerprints: [peer.base64EncodedString()]).isEmpty &&
          count(historyURL, "SELECT count(*) FROM notification_source WHERE uuid='\(uuid)' AND evidence='ambiguous'") == 1 &&
          count(historyURL, "SELECT count(*) FROM push_outbox WHERE state='suppressed'") == 1,
          "retried withdrawal stores ambiguous evidence and suppresses its unsent outbox occurrence")
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

@MainActor
func checkMirrorReplayExclusion(root: URL) throws {
    let suite = "sill.mirror-replay-check." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let historyURL = root.appendingPathComponent("mirror-replay-exclusion/history.sqlite")
    let mirror = NotificationMirror(defaults: defaults, historyURL: historyURL)
    defer { mirror.stop() }
    mirror.enabled = true
    mirror.apns = APNsConfiguration(teamID: "", keyID: "", topic: "test.configured.sill", keyPath: "", environment: "sandbox")
    mirror.start(macID: "replay-mac", isPaired: { _ in true }, onHistoryAvailable: {})
    mirror.subscribe(NotificationSubscription(enabled: true, pushToken: "0102", topic: "test.registered.sill",
                                              environment: "sandbox"), fingerprint: Data([1, 2, 3]))
    let collector = NotificationMirrorCollector.latest!
    let uuid = String(repeating: "c8", count: 16)
    collector.onSource?(NotificationSourceAttribution(uuid: uuid, bundleID: "me.saffer.sill", evidence: .exact), "Sill")
    collector.onBanner?(NotificationBannerObservation(sourceUUID: uuid, title: "Sill AX fixture", subtitle: "",
                                                      body: "An already mirrored notification", observedAt: 2_000,
                                                      displayAppName: nil))
    let ledger = try NotificationHistoryStore(url: historyURL)
    let ownSources = ["me.saffer.sill", "me.saffer.sill.mac", "test.configured.sill", "test.registered.sill"]
    // Existing archives need the same exclusion as new AX captures. Fill one bounded page with
    // both forms, without touching the person's history or any system notification database.
    for index in 1..<50 {
        var own = event("old-self-\(index)")
        own.appBundleID = ownSources[index % ownSources.count]
        _ = try ledger.append(own, fingerprints: [])
    }
    let first = try mirror.replay(after: 0)
    check(try first.events.isEmpty && first.nextSequence == 50 && ledger.events(after: 0).count == 50,
          "self-origin AX and archived sources stay saved but an entirely excluded replay page advances")
    var ordinary = event("ordinary-after-self-page")
    ordinary.appBundleID = "me.saffer.sillish"
    _ = try ledger.append(ordinary, fingerprints: [])
    mirror.sendTestNotification()
    let next = try mirror.replay(after: first.nextSequence!)
    let end = try mirror.replay(after: next.nextSequence!)
    check(next.events.count == 2 && next.events[0].id == ordinary.id && next.events[1].id.hasPrefix("sill-test:") &&
          next.events.map(\.sequence) == [51, 52] && next.nextSequence == 52 && end.events.isEmpty && end.nextSequence == nil,
          "replay continues past excluded history, preserves unrelated sources and the explicit Sill test, then ends at exhaustion")
}

@MainActor
func checkMirrorIPhoneOrigin(root: URL) throws {
    let suite = "sill.iphone-origin-check." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let historyURL = root.appendingPathComponent("mirror-iphone-origin/history.sqlite")
    let mirror = NotificationMirror(defaults: defaults, historyURL: historyURL)
    defer { mirror.stop() }
    mirror.enabled = true
    mirror.start(macID: "origin-mac", isPaired: { _ in true }, onHistoryAvailable: {})
    let peers = [Data([1]), Data([2])]
    for peer in peers {
        mirror.subscribe(NotificationSubscription(enabled: true, pushToken: "0102", topic: "test.ios.apns",
                                                  environment: "sandbox"), fingerprint: peer)
    }
    let collector = NotificationMirrorCollector.latest!
    let uuid = String(repeating: "d9", count: 16)
    var banner = NotificationBannerObservation(sourceUUID: uuid, title: "Origin fixture", subtitle: "",
                                               body: "Synthetic iPhone origin fixture", observedAt: 2_100, displayAppName: nil)
    collector.onBanner?(banner)
    let unknown = try mirror.replay(after: 0)
    collector.onSource?(NotificationSourceAttribution(uuid: uuid, bundleID: "test.original", evidence: .exact), "Original App")
    let attributed = try mirror.replay(after: unknown.nextSequence!)
    check(unknown.events.isEmpty && unknown.nextSequence == 1 && attributed.events.count == 1 &&
          attributed.events[0].sequence == 2 && attributed.events[0].id == "notification-ax:" + uuid,
          "unknown AX text waits on the Mac; a source revision releases its same occurrence to TLS")

    let ledger = try NotificationHistoryStore(url: historyURL)
    let stale = try ledger.duePushes(at: Date(), fingerprints: [peers[0].base64EncodedString()])[0]
    let accepted = try ledger.duePushes(at: Date(), fingerprints: [peers[1].base64EncodedString()])[0]
    try ledger.finish(accepted, state: "accepted")
    sql(historyURL, "CREATE TRIGGER fail_origin BEFORE INSERT ON notification_excluded BEGIN SELECT RAISE(ABORT,'fixture'); END")
    banner.isFromIPhone = true
    collector.onBanner?(banner) // Origin can arrive after the message text and source.
    let paused = try mirror.replay(after: 0)
    banner.isFromIPhone = false
    collector.onBanner?(banner) // A later incomplete AX read must not weaken failed origin evidence.
    sql(historyURL, "DROP TRIGGER fail_origin")
    collector.onBanner?(banner)
    try ledger.finish(stale, state: "retry", nextAttempt: Date()) // A failed in-flight response arrives late.
    try ledger.retryFailures()
    check(try paused.events.isEmpty && paused.nextSequence == nil && !ledger.isCurrent(stale) &&
          ledger.duePushes(at: Date(), fingerprints: peers.map { $0.base64EncodedString() }).isEmpty &&
          count(historyURL, "SELECT count(*) FROM push_outbox WHERE state='suppressed'") == 1 &&
          count(historyURL, "SELECT count(*) FROM push_outbox WHERE state='accepted'") == 1,
          "late iPhone origin survives a failed write and weaker AX read, pauses TLS, withdraws unsent retries and preserves Apple acceptance")

    collector.onSource?(NotificationSourceAttribution(uuid: uuid, bundleID: "test.original", evidence: .exact), "Renamed Original App")
    let sourceID = uuid + ":" + String(TimeInterval(42).bitPattern, radix: 16)
    var databaseEvent = event("notification-store:" + sourceID)
    databaseEvent.appBundleID = "test.authoritative"
    collector.onSnapshot?(snapshot([NotificationStoreRecord(sourceID: sourceID, fingerprint: "origin-db", event: databaseEvent)]))
    mirror.stop()
    let reloaded = NotificationMirror(defaults: defaults, historyURL: historyURL)
    defer { reloaded.stop() }
    check(try reloaded.replay(after: 0).events.isEmpty && ledger.events(after: 0).count == 1 &&
          ledger.events(after: 0)[0].appBundleID == databaseEvent.appBundleID &&
          ledger.duePushes(at: Date(), fingerprints: peers.map { $0.base64EncodedString() }).isEmpty &&
          count(historyURL, "SELECT count(*) FROM notification_excluded") == 1 &&
          count(historyURL, "SELECT count(*) FROM push_outbox WHERE state='accepted'") == 1,
          "iPhone origin persists across source/DB enrichment and restart, retaining history without TLS or APNs redelivery")
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
try checkBannerSourceHistory(root: root)
try checkSourceEvidence(root: root)
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
        check(try mirror.replay(after: 0).events.map(\.sequence) == [1, 2], "live drain reads committed archive sequence")
        mirror.enabled = false
        let start = try mirror.replayStart(for: NotificationSubscription(enabled: true))
        check(try mirror.replay(after: start).events.isEmpty, "disabled mirroring sends no saved history")
        let beforeResume = wakes
        mirror.enabled = true
        check(wakes == beforeResume + 1, "off to on explicitly wakes paused subscription drains")
        check(try mirror.replay(after: start).events.count == 2, "resuming recovers backlog without advancing the paused cursor")
        mirror.stop()
        let reloaded = NotificationMirror(defaults: defaults, historyURL: isolated)
        check(try reloaded.replay(after: 0).events.map(\.id) == ["first-live", "second-live"], "stop/restart retains recoverable history")
        reloaded.stop()
        try checkMirrorReplayExclusion(root: root)
        try checkMirrorIPhoneOrigin(root: root)
        try await checkMirrorBannerRetry(root: root)
        try await checkMirrorPendingWithdrawal(root: root)
        print("notification-history: atomic archive, AX/DB aliases, source evidence/retry, durable origin exclusion, source-gated delivery, ordered replay and APNs classification passed (offline)")
        try? FileManager.default.removeItem(at: root)
        exit(0)
    } catch {
        fatalError("Offline mirror history persistence check failed")
    }
}
dispatchMain()
