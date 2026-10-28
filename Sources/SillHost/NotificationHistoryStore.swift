import Foundation
import SQLite3
import StreamProtocol

/// Sill's own archive and APNs outbox. No system SQLite blobs, provider keys or tokens are stored
/// here. Source observations and their archived events commit together, so a failed write cannot
/// silently advance the source cursor. Callers serialize access on the main actor.
final class NotificationHistoryStore {
    struct PushAttempt {
        let fingerprint: String
        let event: MirroredNotification
        let attempts: Int
    }

    enum StoreError: LocalizedError {
        case database(Int32)
        case invalidEvent
        var errorDescription: String? {
            switch self {
            case .database(let code):
                return String(localized: "Notification history could not be saved (SQLite error \(code)). Collection will retry without advancing its cursor.")
            case .invalidEvent:
                return String(localized: "Notification history contains an unreadable event. Reconnect after restoring its local database.")
            }
        }
    }

    static var defaultURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "me.saffer.sill.host", isDirectory: true)
            .appendingPathComponent("NotificationMirror", isDirectory: true)
        return directory.appendingPathComponent("history.sqlite")
    }

    private var database: OpaquePointer?
    private(set) var historyID = ""
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL = NotificationHistoryStore.defaultURL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.deletingLastPathComponent().path)
        // Pre-create privately, including the first open; sqlite3_open itself honors the umask.
        if !manager.fileExists(atPath: url.path) {
            guard manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw StoreError.database(SQLITE_CANTOPEN)
            }
        }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let result = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK else { sqlite3_close(database); database = nil; throw StoreError.database(result) }
        sqlite3_busy_timeout(database, 250)
        do {
            // DELETE journaling keeps private transient journals beside the already-private file.
            try execute("PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON;")
            try execute("""
                CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS source_seen (source_id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, event_id TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS archive (event_id TEXT PRIMARY KEY, sequence INTEGER NOT NULL UNIQUE, event BLOB NOT NULL);
                CREATE TABLE IF NOT EXISTS notification_alias (uuid TEXT PRIMARY KEY, event_id TEXT NOT NULL, source_id TEXT);
                CREATE TABLE IF NOT EXISTS notification_source (uuid TEXT PRIMARY KEY, bundle_id TEXT, app_name TEXT,
                    evidence TEXT NOT NULL DEFAULT 'exact');
                CREATE TABLE IF NOT EXISTS push_outbox (
                    fingerprint TEXT NOT NULL, event_id TEXT NOT NULL, sequence INTEGER NOT NULL,
                    state TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, next_attempt REAL NOT NULL DEFAULT 0,
                    problem TEXT, PRIMARY KEY(fingerprint, event_id), FOREIGN KEY(event_id) REFERENCES archive(event_id));
                CREATE INDEX IF NOT EXISTS push_due ON push_outbox(state, next_attempt);
                """)
            if try !sourceHasEvidenceColumn() {
                // Every pre-evidence mapping came from the full-UUID exact path. Preserve that
                // authority, including its durable NULL conflict, rather than downgrading it.
                try execute("ALTER TABLE notification_source ADD COLUMN evidence TEXT NOT NULL DEFAULT 'exact'")
            }
            try execute("INSERT OR IGNORE INTO metadata(key,value) VALUES('history_id', ?)", [.text(UUID().uuidString)])
            try execute("INSERT OR IGNORE INTO metadata(key,value) VALUES('sequence', '0')")
            historyID = try scalarText("SELECT value FROM metadata WHERE key='history_id'")!
        } catch {
            sqlite3_close(database); database = nil
            throw error
        }
    }

    deinit { sqlite3_close(database) }

    /// The first *successful* snapshot is a baseline. A normal restart never repeats that step.
    /// Missing system rows are deliberately retained: clearing Notification Center cannot erase
    /// an event already captured by Sill, and source identities must not become new again.
    func ingest(_ snapshot: NotificationStoreSnapshot, fingerprints: [String]) throws -> [MirroredNotification] {
        try transaction {
            let baseline = try scalarText("SELECT value FROM metadata WHERE key='baseline'") == nil
            var occurrences: [String: Set<String>] = [:]
            for record in snapshot.records {
                if let uuid = sourceUUID(in: record.sourceID) { occurrences[uuid, default: []].insert(record.sourceID) }
            }
            var added: [MirroredNotification] = []
            for record in snapshot.records {
                let previous = try scalarText("SELECT fingerprint FROM source_seen WHERE source_id=?", [.text(record.sourceID)])
                let previousID = try scalarText("SELECT event_id FROM source_seen WHERE source_id=?", [.text(record.sourceID)])
                let uuid = sourceUUID(in: record.sourceID)
                let alias = try uuid.flatMap { try notificationAlias(uuid: $0) }
                // An existing source occurrence keeps its historical ID. Only one exact UUID
                // candidate may claim a banner; multiple delivery times cannot be disambiguated
                // from AX's UUID alone, so retain their independent database events without guessing.
                let claimsBanner = previousID == nil && alias != nil && alias?.sourceID == nil
                    && uuid.map { occurrences[$0]?.count == 1 } == true
                let eventID = previousID ?? (claimsBanner ? alias!.eventID : record.event.id)
                if let uuid {
                    if claimsBanner {
                        try execute("UPDATE notification_alias SET source_id=? WHERE uuid=? AND source_id IS NULL",
                                    [.text(record.sourceID), .text(uuid)])
                    } else {
                        // Baseline records also bind their UUID, although they have no archive
                        // event. A later AX callback must not import that old notification anew.
                        try execute("INSERT OR IGNORE INTO notification_alias(uuid,event_id,source_id) VALUES(?,?,?)",
                                    [.text(uuid), .text(eventID), .text(record.sourceID)])
                    }
                }
                guard previous != record.fingerprint else { continue }
                // A live banner already archived before the first DB snapshot is enriched even
                // during baseline. Other pre-existing database records remain baseline-only.
                if !baseline || claimsBanner {
                    var event = record.event
                    event.id = eventID
                    added.append(try archive(event, fingerprints: fingerprints))
                }
                try execute("INSERT OR REPLACE INTO source_seen(source_id,fingerprint,event_id) VALUES(?,?,?)",
                            [.text(record.sourceID), .text(record.fingerprint), .text(eventID)])
            }
            if baseline { try execute("INSERT INTO metadata(key,value) VALUES('baseline','1')") }
            return added
        }
    }

    /// AX supplies an exact system UUID but no delivery timestamp. An exact source observation
    /// may already identify its app; the database still owns the eventual delivery occurrence.
    func ingestBanner(_ observation: NotificationBannerObservation, fingerprints: [String]) throws -> MirroredNotification? {
        try transaction {
            let uuid = observation.sourceUUID
            let alias = try notificationAlias(uuid: uuid)
            if alias?.sourceID != nil { return nil } // Bound database metadata is authoritative.
            let source = try bannerSource(uuid: uuid)
            let bundleID = source?.bundleID ?? ""
            let appName = source?.appName ?? observation.displayAppName.flatMap { $0.isEmpty ? nil : $0 } ?? "Mac"
            let subtitle = observation.subtitle.isEmpty ? nil : observation.subtitle
            if let alias {
                guard var existing = try archivedEvent(id: alias.eventID) else { throw StoreError.invalidEvent }
                let attributedName = existing.appBundleID.isEmpty ? appName : existing.appName
                guard existing.title != observation.title || existing.subtitle != subtitle ||
                        existing.body != observation.body || existing.appName != attributedName else { return nil }
                // AX may initially expose only part of a tree. Fill changed fields under the
                // same ID; repeated callbacks with identical content consume no new sequence.
                existing.title = observation.title
                existing.subtitle = subtitle
                existing.body = observation.body
                existing.appName = attributedName
                return try archive(existing, fingerprints: existing.appBundleID.isEmpty ? [] : fingerprints)
            }
            // Older Sill databases predate aliases. Do not replay an old visible banner merely
            // because its exact UUID has not yet been backfilled into the additive alias table.
            if try scalarText("SELECT event_id FROM source_seen WHERE source_id GLOB ? LIMIT 1", [.text(uuid + ":*")]) != nil {
                return nil
            }
            let event = MirroredNotification(id: "notification-ax:" + uuid, appBundleID: bundleID, appName: appName,
                                             title: observation.title, subtitle: subtitle, body: observation.body,
                                             date: observation.observedAt)
            let archived = try archive(event, fingerprints: bundleID.isEmpty ? [] : fingerprints)
            try execute("INSERT INTO notification_alias(uuid,event_id,source_id) VALUES(?,?,NULL)",
                        [.text(uuid), .text(event.id)])
            return archived
        }
    }

    /// A source observation contains no message body. Save its UUID mapping even before AX,
    /// but only enrich an existing banner. Arrival candidates are provisional; exact evidence
    /// can confirm/correct them. Never bind source_id here: the database stays authoritative.
    func enrichBannerSource(uuid: String, bundleID: String, appName: String,
                            evidence: NotificationSourceEvidence = .exact,
                            fingerprints: [String]) throws -> MirroredNotification? {
        guard evidence == .ambiguous || !bundleID.isEmpty else { return nil }
        return try transaction {
            let alias = try notificationAlias(uuid: uuid)
            guard alias?.sourceID == nil else { return nil } // No log evidence can replace DB metadata.
            let previous = try bannerSource(uuid: uuid)
            let name = appName.isEmpty ? bundleID : appName
            let next: BannerSource
            switch evidence {
            case .arrival:
                guard previous == nil || previous?.evidence == .arrival else { return nil }
                if let previous, previous.bundleID != bundleID {
                    next = BannerSource(bundleID: nil, appName: nil, evidence: .ambiguous)
                } else {
                    next = BannerSource(bundleID: bundleID, appName: name, evidence: .arrival)
                }
            case .ambiguous:
                guard previous == nil || previous?.evidence == .arrival else { return nil }
                // Persist the withdrawal so a delayed candidate cannot reopen its pending push.
                next = BannerSource(bundleID: nil, appName: nil, evidence: .ambiguous)
            case .exact:
                if let previous, previous.evidence == .exact,
                   previous.bundleID == nil || previous.bundleID != bundleID {
                    // Two conflicting exact mappings remain unknown until DB evidence arrives.
                    next = BannerSource(bundleID: nil, appName: nil, evidence: .exact)
                } else {
                    next = BannerSource(bundleID: bundleID, appName: name, evidence: .exact)
                }
            }
            try execute("""
                INSERT INTO notification_source(uuid,bundle_id,app_name,evidence) VALUES(?,?,?,?)
                ON CONFLICT(uuid) DO UPDATE SET bundle_id=excluded.bundle_id,app_name=excluded.app_name,evidence=excluded.evidence
                """, [.text(uuid), next.bundleID.map(Value.text) ?? .null,
                      next.appName.map(Value.text) ?? .null, .text(next.evidence.rawValue)])
            guard let alias,
                  var existing = try archivedEvent(id: alias.eventID) else { return nil }
            if next.bundleID == nil {
                try execute("""
                    UPDATE push_outbox SET state='suppressed',next_attempt=0,problem='Unconfirmed notification source'
                    WHERE event_id=? AND state IN ('pending','retry')
                    """, [.text(existing.id)])
                guard !existing.appBundleID.isEmpty else { return nil }
                existing.appBundleID = ""
                existing.appName = "Mac"
                return try archive(existing, fingerprints: [])
            }
            guard existing.appBundleID != next.bundleID || existing.appName != next.appName else { return nil }
            existing.appBundleID = next.bundleID ?? ""
            existing.appName = next.appName ?? "Mac"
            return try archive(existing, fingerprints: fingerprints)
        }
    }

    func append(_ event: MirroredNotification, fingerprints: [String]) throws -> MirroredNotification {
        try transaction { try archive(event, fingerprints: fingerprints) }
    }

    func replayStart(historyID requestedID: String?, afterSequence: Int64?) throws -> Int64 {
        guard requestedID == historyID else { return 0 }
        let latest = Int64(try scalarText("SELECT value FROM metadata WHERE key='sequence'") ?? "0") ?? 0
        return min(latest, max(0, afterSequence ?? 0))
    }

    func events(after sequence: Int64, limit: Int = 50) throws -> [MirroredNotification] {
        let statement = try prepare("SELECT event FROM archive WHERE sequence>? ORDER BY sequence LIMIT ?",
                                    [.integer(sequence), .integer(Int64(limit))])
        defer { sqlite3_finalize(statement) }
        var events: [MirroredNotification] = []
        while try step(statement) { events.append(try event(at: statement, column: 0)) }
        return events
    }

    func duePushes(at now: Date, fingerprints: [String], limit: Int = 50) throws -> [PushAttempt] {
        guard !fingerprints.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: fingerprints.count).joined(separator: ",")
        let statement = try prepare("""
            SELECT p.fingerprint,a.event,p.attempts FROM push_outbox p JOIN archive a ON a.event_id=p.event_id
            WHERE p.state IN ('pending','retry') AND p.next_attempt<=? AND p.sequence=a.sequence
            AND p.fingerprint IN (\(placeholders))
            ORDER BY p.sequence,p.fingerprint LIMIT ?
            """, [.real(now.timeIntervalSince1970)] + fingerprints.map(Value.text) + [.integer(Int64(limit))])
        defer { sqlite3_finalize(statement) }
        var attempts: [PushAttempt] = []
        while try step(statement) {
            attempts.append(PushAttempt(fingerprint: text(statement, 0), event: try event(at: statement, column: 1),
                                        attempts: Int(sqlite3_column_int64(statement, 2))))
        }
        return attempts
    }

    /// Sending an earlier batch item awaits the network. A later item's source may have been
    /// corrected meanwhile, so validate its archive/outbox revision again before using it.
    func isCurrent(_ attempt: PushAttempt, at now: Date = Date()) throws -> Bool {
        try scalarText("""
            SELECT p.event_id FROM push_outbox p JOIN archive a ON a.event_id=p.event_id
            WHERE p.fingerprint=? AND p.event_id=? AND p.sequence=? AND a.sequence=p.sequence
            AND p.state IN ('pending','retry') AND p.next_attempt<=?
            """, [.text(attempt.fingerprint), .text(attempt.event.id),
                  .integer(attempt.event.sequence ?? 0), .real(now.timeIntervalSince1970)]) != nil
    }

    /// Acceptance belongs to one delivery occurrence, including a request for its older body.
    /// A late failed request cannot change the retry state of a newer body revision.
    func finish(_ attempt: PushAttempt, state: String, nextAttempt: Date? = nil, problem: String? = nil) throws {
        let revisionCondition = state == "accepted" ? "" : " AND sequence=?"
        let revisionValues: [Value] = state == "accepted" ? [] : [.integer(attempt.event.sequence ?? 0)]
        try execute("""
            UPDATE push_outbox SET state=?,attempts=attempts+1,next_attempt=?,problem=?
            WHERE fingerprint=? AND event_id=?\(revisionCondition)
            """, [.text(state), .real(nextAttempt?.timeIntervalSince1970 ?? 0), problem.map(Value.text) ?? .null,
                  .text(attempt.fingerprint), .text(attempt.event.id)] + revisionValues)
    }

    /// Changed provider settings or a renewed device registration may repair a permanent failure.
    /// Accepted requests stay accepted; no reconfiguration deletes archive/outbox rows.
    func retryFailures(fingerprint: String? = nil) throws {
        let suffix = fingerprint == nil ? "" : " AND fingerprint=?"
        try execute("UPDATE push_outbox SET state='pending',attempts=0,next_attempt=0,problem=NULL WHERE state IN ('permanent','paused')" + suffix,
                    fingerprint.map { [.text($0)] } ?? [])
    }

    private func archive(_ original: MirroredNotification, fingerprints: [String]) throws -> MirroredNotification {
        try execute("UPDATE metadata SET value=CAST(value AS INTEGER)+1 WHERE key='sequence'")
        guard let sequenceText = try scalarText("SELECT value FROM metadata WHERE key='sequence'"),
              let sequence = Int64(sequenceText), sequence > 0 else { throw StoreError.invalidEvent }
        var event = original
        event.historyID = historyID
        event.sequence = sequence
        let encoded = try JSONEncoder().encode(event)
        try execute("""
            INSERT INTO archive(event_id,sequence,event) VALUES(?,?,?)
            ON CONFLICT(event_id) DO UPDATE SET sequence=excluded.sequence,event=excluded.event
            """, [.text(event.id), .integer(sequence), .blob(encoded)])
        // A revision updates one delivery occurrence. Preserve acceptance and explicit failure
        // states: changed text must not show a second alert or repair unrelated provider errors.
        try execute("UPDATE push_outbox SET sequence=? WHERE event_id=?",
                    [.integer(sequence), .text(event.id)])
        for fingerprint in Set(fingerprints) {
            // Explicit recipients can resume a source-suppressed occurrence after exact/DB
            // attribution repairs it. Acceptance and provider/token failures remain untouched.
            try execute("""
                UPDATE push_outbox SET state='pending',attempts=0,next_attempt=0,problem=NULL
                WHERE fingerprint=? AND event_id=? AND state='suppressed'
                """, [.text(fingerprint), .text(event.id)])
            try execute("""
                INSERT INTO push_outbox(fingerprint,event_id,sequence,state) VALUES(?,?,?,'pending')
                ON CONFLICT(fingerprint,event_id) DO UPDATE SET sequence=excluded.sequence
                """, [.text(fingerprint), .text(event.id), .integer(sequence)])
        }
        return event
    }

    private func event(at statement: OpaquePointer, column: Int32) throws -> MirroredNotification {
        guard let bytes = sqlite3_column_blob(statement, column) else { throw StoreError.invalidEvent }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
        guard let event = try? JSONDecoder().decode(MirroredNotification.self, from: data) else { throw StoreError.invalidEvent }
        return event
    }

    private struct NotificationAlias {
        let eventID: String
        let sourceID: String?
    }

    private struct BannerSource {
        let bundleID: String?
        let appName: String?
        let evidence: NotificationSourceEvidence
    }

    private func bannerSource(uuid: String) throws -> BannerSource? {
        let statement = try prepare("SELECT bundle_id,app_name,evidence FROM notification_source WHERE uuid=?", [.text(uuid)])
        defer { sqlite3_finalize(statement) }
        guard try step(statement) else { return nil }
        guard let evidence = NotificationSourceEvidence(rawValue: text(statement, 2)) else { throw StoreError.invalidEvent }
        return BannerSource(bundleID: sqlite3_column_type(statement, 0) == SQLITE_NULL ? nil : text(statement, 0),
                            appName: sqlite3_column_type(statement, 1) == SQLITE_NULL ? nil : text(statement, 1), evidence: evidence)
    }

    private func sourceHasEvidenceColumn() throws -> Bool {
        let statement = try prepare("PRAGMA table_info(notification_source)", [])
        defer { sqlite3_finalize(statement) }
        while try step(statement) { if text(statement, 1) == "evidence" { return true } }
        return false
    }

    private func notificationAlias(uuid: String) throws -> NotificationAlias? {
        let statement = try prepare("SELECT event_id,source_id FROM notification_alias WHERE uuid=?", [.text(uuid)])
        defer { sqlite3_finalize(statement) }
        guard try step(statement) else { return nil }
        return NotificationAlias(eventID: text(statement, 0),
                                 sourceID: sqlite3_column_type(statement, 1) == SQLITE_NULL ? nil : text(statement, 1))
    }

    private func archivedEvent(id: String) throws -> MirroredNotification? {
        let statement = try prepare("SELECT event FROM archive WHERE event_id=?", [.text(id)])
        defer { sqlite3_finalize(statement) }
        return try step(statement) ? event(at: statement, column: 0) : nil
    }

    private func sourceUUID(in sourceID: String) -> String? {
        guard let separator = sourceID.firstIndex(of: ":") else { return nil }
        let uuid = sourceID[..<separator]
        guard uuid.utf8.count == 32, uuid.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return String(uuid)
    }

    private enum Value { case text(String), integer(Int64), real(Double), blob(Data), null }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ query: String, _ values: [Value] = []) throws {
        // Schema creation contains multiple statements; all parameterized writes are single SQL.
        if values.isEmpty {
            let result = sqlite3_exec(database, query, nil, nil, nil)
            guard result == SQLITE_OK else { throw StoreError.database(result) }
            return
        }
        let statement = try prepare(query, values)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.database(sqlite3_errcode(database)) }
    }

    private func scalarText(_ query: String, _ values: [Value] = []) throws -> String? {
        let statement = try prepare(query, values)
        defer { sqlite3_finalize(statement) }
        return try step(statement) ? text(statement, 0) : nil
    }

    private func prepare(_ query: String, _ values: [Value]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, query, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else { sqlite3_finalize(statement); throw StoreError.database(result) }
        do {
            for (offset, value) in values.enumerated() {
                let index = Int32(offset + 1)
                let bound: Int32
                switch value {
                case .text(let value): bound = sqlite3_bind_text(statement, index, value, -1, transient)
                case .integer(let value): bound = sqlite3_bind_int64(statement, index, value)
                case .real(let value): bound = sqlite3_bind_double(statement, index, value)
                case .blob(let value): bound = value.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient) }
                case .null: bound = sqlite3_bind_null(statement, index)
                }
                guard bound == SQLITE_OK else { throw StoreError.database(bound) }
            }
            return statement
        } catch { sqlite3_finalize(statement); throw error }
    }

    private func step(_ statement: OpaquePointer) throws -> Bool {
        let result = sqlite3_step(statement)
        if result == SQLITE_ROW { return true }
        guard result == SQLITE_DONE else { throw StoreError.database(result) }
        return false
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }
}
