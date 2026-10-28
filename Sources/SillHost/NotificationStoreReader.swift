import CryptoKit
import Foundation
import SQLite3
import StreamProtocol

/// Values only: the SQLite connection and its read transaction are already closed before the
/// collector hands this snapshot to its durable cursor. Never use rec_id as a high-water mark:
/// Notification Center can update a row or reuse its integer ID after notifications are cleared.
struct NotificationStoreSnapshot: Sendable {
    let records: [NotificationStoreRecord]
    let skippedRecordCount: Int
}

struct NotificationStoreRecord: Sendable {
    let sourceID: String
    let fingerprint: String
    let event: MirroredNotification
}

/// An adapter for the Notification Center schema verified on macOS 27. The store is private OS
/// data, so a failed open/schema/read is a failed snapshot, never an empty successful one. Access
/// belongs to the actual Sill app's system permission; this reader never changes TCC or the store.
struct NotificationStoreReader: Sendable {
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db")
    }

    let url: URL
    var appNames: [String: String] = [:]
    var excludedBundleIDs: Set<String> = []
    /// The mirror consumes its own source metadata only to identify an already captured banner.
    /// Other callers retain the original exclusion policy; no own notification becomes new mail.
    var includeMirrorSources = false

    enum ReadError: LocalizedError {
        case accessDenied
        case unavailable
        case unsupportedSchema
        case database(Int32)

        var errorDescription: String? {
            switch self {
            case .accessDenied:
                return String(localized: "Sill cannot read the notification store. Allow Sill in Full Disk Access, then restart Sill.")
            case .unavailable:
                return String(localized: "The notification store could not be opened. Check Sill’s Full Disk Access permission and try again.")
            case .unsupportedSchema:
                return String(localized: "This macOS notification store format is not supported. No notifications were collected.")
            case .database(let code):
                return String(localized: "The notification store could not be read (SQLite error \(code)). Sill will retry.")
            }
        }
    }

    func read() throws -> NotificationStoreSnapshot {
        let raw = try loadRows()
        return try decode(raw.rows, skipped: raw.skipped)
    }

    private struct RawRecord {
        let uuid: Data
        let payload: Data
        let deliveredAt: Double
        let bundleID: String?
    }

    /// Both deferred cleanups run before read() begins property-list decoding or external work.
    private func loadRows() throws -> (rows: [RawRecord], skipped: Int) {
        var connection: OpaquePointer?
        // The system daemon may have recent commits only in db-wal. Open the live database with
        // SQLite's normal WAL/locking machinery; immutable or a db-only copy can miss them.
        let result = sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let connection else {
            let systemError = connection.map { sqlite3_system_errno($0) } ?? 0
            sqlite3_close(connection)
            if systemError == EPERM || systemError == EACCES { throw ReadError.accessDenied }
            throw ReadError.unavailable
        }
        defer { sqlite3_close(connection) }
        sqlite3_busy_timeout(connection, 250)

        // A single fully fetched SELECT is one consistent, short read snapshot. Pending requests
        // have no positive delivered_date. presented is deliberately not filtered: stored test
        // notifications on macOS 27 have presented=0 even after actual system delivery.
        let query = """
            SELECT record.uuid, record.data, record.delivered_date, app.identifier
            FROM record LEFT JOIN app ON app.app_id = record.app_id
            WHERE record.delivered_date > 0
            ORDER BY record.delivered_date, record.rec_id
            """
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(connection, query, -1, &statement, nil)
        guard prepared == SQLITE_OK, let queryStatement = statement else {
            sqlite3_finalize(statement)
            if prepared == SQLITE_ERROR { throw ReadError.unsupportedSchema }
            throw ReadError.database(prepared)
        }
        defer { sqlite3_finalize(statement) }

        var raw: [RawRecord] = []
        var skipped = 0
        while true {
            let step = sqlite3_step(queryStatement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw ReadError.database(step) }
            guard sqlite3_column_type(queryStatement, 0) == SQLITE_BLOB,
                  let uuid = blob(queryStatement, 0), uuid.count == 16,
                  sqlite3_column_type(queryStatement, 1) == SQLITE_BLOB,
                  let payload = blob(queryStatement, 1) else { skipped += 1; continue }
            let deliveredAt = sqlite3_column_double(queryStatement, 2)
            guard deliveredAt.isFinite, deliveredAt > 0 else { skipped += 1; continue }
            let bundleID = sqlite3_column_type(queryStatement, 3) == SQLITE_TEXT
                ? sqlite3_column_text(queryStatement, 3).map { String(cString: $0) } : nil
            raw.append(RawRecord(uuid: uuid, payload: payload, deliveredAt: deliveredAt, bundleID: bundleID))
        }
        return (raw, skipped)
    }

    private func decode(_ rows: [RawRecord],
                        skipped: Int) throws -> NotificationStoreSnapshot {
        var records: [NotificationStoreRecord] = []
        var skipped = skipped
        for row in rows {
            guard let root = try? PropertyListSerialization.propertyList(from: row.payload, options: [], format: nil) as? [String: Any],
                  let request = root["req"] as? [String: Any] else { skipped += 1; continue }
            let payloadBundleID = root["app"] as? String
            // The system app table is authoritative. A web app or extension may name a different
            // originating app in its payload; use that only when the joined identifier is absent.
            guard let bundleID = row.bundleID ?? payloadBundleID, !bundleID.isEmpty else { skipped += 1; continue }
            if excludedBundleIDs.contains(bundleID) || (!includeMirrorSources &&
                (bundleID == "me.saffer.sill" || bundleID.hasPrefix("me.saffer.sill."))) { continue }
            // Some Apple notifications contain localization descriptors instead of plain text.
            // Do not stringify an archive/dictionary into a message or leak it into diagnostics.
            guard let title = text(request, "titl"), let subtitle = text(request, "subt"),
                  let body = text(request, "body") else { skipped += 1; continue }
            // Attachment- or sound-only notifications still carry their source, even when all
            // text fields are absent. Do not silently discard a legitimate stored delivery.
            // A retained request can be delivered again with the same UUID. Delivery time defines
            // its occurrence; request/presentation state and body revisions do not. This private
            // schema mapping is covered by fixtures and must be rechecked on future macOS versions.
            let sourceID = row.uuid.map { String(format: "%02x", $0) }.joined()
                + ":" + String(row.deliveredAt.bitPattern, radix: 16)
            let content = Content(bundleID: bundleID, title: title, subtitle: subtitle, body: body)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let digest = SHA256.hash(data: try encoder.encode(content)).map { String(format: "%02x", $0) }.joined()
            let event = MirroredNotification(id: "notification-store:" + sourceID,
                                             appBundleID: bundleID, appName: appNames[bundleID] ?? bundleID,
                                             title: title, subtitle: subtitle.isEmpty ? nil : subtitle,
                                             body: body, date: Date(timeIntervalSinceReferenceDate: row.deliveredAt).timeIntervalSince1970)
            records.append(NotificationStoreRecord(sourceID: sourceID, fingerprint: digest, event: event))
        }
        return NotificationStoreSnapshot(records: records, skippedRecordCount: skipped)
    }

    private struct Content: Encodable {
        let bundleID: String
        let title: String
        let subtitle: String
        let body: String
    }

    private func blob(_ statement: OpaquePointer, _ column: Int32) -> Data? {
        guard let pointer = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, column)))
    }

    private func text(_ request: [String: Any], _ key: String) -> String? {
        guard let value = request[key] else { return "" }
        return value as? String
    }
}
