import Foundation
import SQLite3
import StreamProtocol

var failures = 0
func check(_ value: Bool, _ message: String) {
    print((value ? "ok   " : "FAIL ") + message)
    if !value { failures += 1 }
}

let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sill-notification-store-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let url = folder.appendingPathComponent("db")
var writer: OpaquePointer?
precondition(sqlite3_open(url.path, &writer) == SQLITE_OK)
func execute(_ sql: String) {
    precondition(sqlite3_exec(writer, sql, nil, nil, nil) == SQLITE_OK, "fixture SQL failed")
}
execute("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0")
execute("CREATE TABLE app (app_id INTEGER PRIMARY KEY, identifier VARCHAR, badge INTEGER NULL)")
execute("CREATE TABLE record (rec_id INTEGER PRIMARY KEY, app_id INTEGER, uuid BLOB, data BLOB, request_date REAL, request_last_date REAL, delivered_date REAL, presented Bool, style INTEGER, snooze_fire_date REAL)")
execute("INSERT INTO app(app_id, identifier) VALUES(1, 'org.example.notification-fixture'), (2, 'me.saffer.sill.mac')")
let reader = NotificationStoreReader(url: url, appNames: ["org.example.notification-fixture": "Fixture App"])
func plist(_ body: Any = "Synthetic fixture body", bundleID: String = "org.example.notification-fixture") -> Data {
    try! PropertyListSerialization.data(fromPropertyList: ["app": bundleID, "req": [
        "titl": "Synthetic fixture", "subt": "Synthetic subtitle", "body": body]], format: .binary, options: 0)
}
func add(_ id: Int, uuid: Int, payload: Data = plist(), date: Double? = 800_000_000, appID: Int = 1) {
    var statement: OpaquePointer?
    precondition(sqlite3_prepare_v2(writer, "INSERT INTO record(rec_id,app_id,uuid,data,delivered_date,presented) VALUES(?,?,?,?,?,0)", -1, &statement, nil) == SQLITE_OK)
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_int(statement, 1, Int32(id)); sqlite3_bind_int(statement, 2, Int32(appID))
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    let uuidData = Data(repeating: UInt8(uuid), count: 16)
    _ = uuidData.withUnsafeBytes { sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32($0.count), transient) }
    _ = payload.withUnsafeBytes { sqlite3_bind_blob(statement, 4, $0.baseAddress, Int32($0.count), transient) }
    if let date { sqlite3_bind_double(statement, 5, date) } else { sqlite3_bind_null(statement, 5) }
    precondition(sqlite3_step(statement) == SQLITE_DONE)
}

// 1. Real WAL commits, filtering and binary plist decoding. presented=0 remains eligible.
check(try reader.read().records.isEmpty, "empty store is a successful empty snapshot")
add(1, uuid: 1)
add(2, uuid: 2, date: nil)
add(3, uuid: 3, date: 0)
add(4, uuid: 4, payload: Data("bad synthetic plist".utf8))
add(5, uuid: 5, payload: plist(["unsupported": "localization descriptor"]))
add(6, uuid: 6, payload: plist(bundleID: "me.saffer.sill.mac"), appID: 2)
let first = try reader.read()
check(first.records.count == 1 && first.skippedRecordCount == 2,
      "WAL reader includes delivered presented=0; excludes pending/zero/self and counts malformed content")
let event = first.records.first!.event
check(event.appBundleID == "org.example.notification-fixture" && event.appName == "Fixture App"
      && event.title == "Synthetic fixture" && event.subtitle == "Synthetic subtitle"
      && event.body == "Synthetic fixture body" && event.date == 800_000_000 + 978_307_200,
      "binary plist fields and source delivery time reach the actual wire model")
check(FileManager.default.fileExists(atPath: url.path + "-wal"), "writer commits remain in a live WAL")

// 2. Identity is separate from text and integer row ID, and updates change only the fingerprint.
add(7, uuid: 7)
let repeated = try reader.read()
check(repeated.records.count == 2 && Set(repeated.records.map(\.sourceID)).count == 2,
      "identical text with different source UUIDs remains two notifications")
check(repeated.records.first?.fingerprint == first.records.first?.fingerprint,
      "poll time does not change a notification content fingerprint")
let updated = plist("Updated synthetic fixture body")
var update: OpaquePointer?
precondition(sqlite3_prepare_v2(writer, "UPDATE record SET data=? WHERE rec_id=1", -1, &update, nil) == SQLITE_OK)
let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
_ = updated.withUnsafeBytes { sqlite3_bind_blob(update, 1, $0.baseAddress, Int32($0.count), transient) }
precondition(sqlite3_step(update) == SQLITE_DONE); sqlite3_finalize(update)
let changed = try reader.read()
check(changed.records.first?.sourceID == first.records.first?.sourceID
      && changed.records.first?.event.id == first.records.first?.event.id
      && changed.records.first?.fingerprint != first.records.first?.fingerprint,
      "same-row updates retain stable identity and change the fingerprint")
execute("UPDATE record SET delivered_date=800000010 WHERE rec_id=1")
let redelivered = try reader.read().records.first { $0.event.body == "Updated synthetic fixture body" }!
check(redelivered.sourceID != changed.records.first?.sourceID
      && redelivered.event.id != changed.records.first?.event.id
      && redelivered.fingerprint == changed.records.first?.fingerprint,
      "same UUID delivered again has a new occurrence identity without a spurious content revision")
add(8, uuid: 8, payload: plist(bundleID: "org.example.extension-origin"))
check(try reader.read().records.first { $0.event.body == "Synthetic fixture body" && $0.sourceID.hasPrefix(String(repeating: "08", count: 16)) }?.event.appBundleID == "org.example.notification-fixture",
      "joined app identifier wins over an extension or web-app payload origin")
let soundOnly = try PropertyListSerialization.data(fromPropertyList: ["app": "org.example.notification-fixture", "req": ["soun": ["name": "fixture"]]], format: .binary, options: 0)
add(9, uuid: 9, payload: soundOnly)
check(try reader.read().records.contains { $0.event.appBundleID == "org.example.notification-fixture" && $0.event.title.isEmpty && $0.event.subtitle == nil && $0.event.body.isEmpty },
      "attachment- or sound-only delivery is retained with its source even without text")
execute("DELETE FROM record")
check(try reader.read().records.isEmpty, "clearing the store produces a successful empty snapshot")
add(1, uuid: 8)
let reused = try reader.read()
check(reused.records.count == 1 && reused.records.first?.sourceID != first.records.first?.sourceID,
      "new source UUID after clearing is visible despite reusing a lower row ID")

// 3. Reopen detects a replaced store, and failures never masquerade as an empty snapshot.
sqlite3_close(writer); writer = nil
try FileManager.default.removeItem(at: url)
precondition(sqlite3_open(url.path, &writer) == SQLITE_OK)
execute("CREATE TABLE app (app_id INTEGER PRIMARY KEY, identifier VARCHAR)")
execute("CREATE TABLE record (rec_id INTEGER PRIMARY KEY, app_id INTEGER, uuid BLOB, data BLOB, delivered_date REAL, presented Bool)")
execute("INSERT INTO app VALUES(1, 'org.example.notification-fixture')")
add(1, uuid: 9)
let replacement = try reader.read()
check(replacement.records.count == 1 && replacement.records.first?.sourceID != reused.records.first?.sourceID,
      "the next poll opens the new store after file replacement")
execute("DROP TABLE record")
do {
    _ = try reader.read()
    check(false, "unsupported schema throws")
} catch NotificationStoreReader.ReadError.unsupportedSchema {
    check(true, "unsupported schema throws instead of advancing an empty baseline")
}
sqlite3_close(writer); writer = nil
let missingURL = folder.appendingPathComponent("missing")
do {
    _ = try NotificationStoreReader(url: missingURL).read()
    check(false, "missing source throws")
} catch {
    check(!FileManager.default.fileExists(atPath: missingURL.path), "read-only missing source throws without creating a database")
}
try FileManager.default.removeItem(at: folder)
if failures > 0 { exit(1) }
print("notification-store: every check passed")
