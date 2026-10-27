import Foundation
import Combine

var checks = 0
func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    checks += 1
    guard condition() else { print("FAIL: \(name)"); exit(1) }
}

func mac(_ byte: UInt8) -> SavedMac {
    let key = Data(repeating: byte, count: 32)
    return SavedMac(macID: MacID.make(fingerprint: key), fingerprint: Base64URL.encode(key), name: "Mac \(byte)",
                    recognitionKey: Base64URL.encode(key), remotePort: 7455, addresses: [], infoIssuedAt: 0,
                    pairedAt: Date(timeIntervalSince1970: Double(byte)), method: "code")
}

let suite = "Sill.saved-mac-store-check.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
let a = mac(1), b = mac(2), c = mac(3), d = mac(4)
defaults.set(SavedMacs.encode([a, b]), forKey: SavedMacs.defaultsKey)

// The original two-window failure, with a real device-list writer: Bonjour's TLS observation.
// Group-only writes cannot reproduce this. Each old client loaded once, then saved its whole list.
var oldA = SavedMacs.decode(defaults.string(forKey: SavedMacs.defaultsKey))
var oldB = oldA
oldA.removeAll { $0.macID == a.macID }
oldA = SavedMacs.adding(c, to: oldA)
defaults.set(SavedMacs.encode(oldA), forKey: SavedMacs.defaultsKey)
oldB = SavedMacs.seenOverTLS([b.macID], in: oldB)!
defaults.set(SavedMacs.encode(oldB), forKey: SavedMacs.defaultsKey)
let overwritten = SavedMacs.decode(defaults.string(forKey: SavedMacs.defaultsKey))
check("old independent snapshots restore A and lose newly paired C", overwritten.map(\.macID) == [a.macID, b.macID])

defaults.set(SavedMacs.encode([a, b]), forKey: SavedMacs.defaultsKey)
defaults.set(ConnectionList.encodeGroups([a.macID: "Work", b.macID: "Home"]), forKey: ConnectionList.groupsKey)
let store = SavedMacStore(defaults: defaults, arguments: [])

// The same subscription contract as StreamClient: no initial callback, and discovery reads the
// assigned canonical state on main. Re-observing TLS from either window must settle after one edit.
final class Window {
    let store: SavedMacStore
    var notifications = 0
    var tlsIDs: Set<String> = []
    private var changes: AnyCancellable?
    var macs: [SavedMac] { store.snapshot.macs }
    init(_ store: SavedMacStore) {
        self.store = store
        changes = store.$snapshot.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self else { return }
            self.notifications += 1
            self.store.updateMacs { $0 = SavedMacs.seenOverTLS(self.tlsIDs, in: $0) ?? $0 }
        }
    }
}

let windowA = Window(store), windowB = Window(store)
check("subscription does not call a partially initialized window", windowA.notifications == 0 && windowB.notifications == 0)
windowA.store.update {
    $0.macs.removeAll { $0.macID == a.macID }
    $0.macs = SavedMacs.adding(c, to: $0.macs)
}
windowB.store.updateMacs { $0 = SavedMacs.seenOverTLS([b.macID], in: $0) ?? $0 }
check("B's Bonjour save keeps A forgotten and C paired", windowB.macs.map(\.macID) == [b.macID, c.macID])
check("both windows read the same current data", windowA.macs == windowB.macs && windowA.macs.first?.homeTLS == true)
check("forget prunes only the removed Mac's group", store.snapshot.groups == [b.macID: "Home"])

windowA.store.setGroup("Home Office", for: b.macID)
windowB.store.setGroup("home office", for: c.macID)
check("group edits use other windows' current names", store.snapshot.groups == [b.macID: "Home Office", c.macID: "Home Office"])
windowA.store.updateMacs { $0 = SavedMacs.markingNewKey(b.macID, in: $0) ?? $0 }
windowB.store.update {
    $0.macs = SavedMacs.adding(d, to: $0.macs)
    $0.macs = SavedMacs.replacingNewKey(old: b.macID, new: d.macID, in: $0.macs)
    $0.groups = ConnectionList.carryingGroup(from: b.macID, to: d.macID, in: $0.groups)
}
check("home re-pair carries a group before pruning its retired record", store.snapshot.groups[d.macID] == "Home Office" && store.snapshot.groups[b.macID] == nil)
windowA.store.update {
    $0.macs = SavedMacs.superseding(old: c.macID, by: d.macID, proof: "mac.local|7455", in: $0.macs)
    $0.groups = ConnectionList.carryingGroup(from: c.macID, to: d.macID, in: $0.groups)
}
check("remote supersede keeps the successor's group", store.snapshot.macs.map(\.macID) == [d.macID] && store.snapshot.groups == [d.macID: "Home Office"])
check("the unchanged JSON keys decode the complete latest records", SavedMacs.decode(defaults.string(forKey: SavedMacs.defaultsKey)) == store.snapshot.macs
      && ConnectionList.decodeGroups(defaults.string(forKey: ConnectionList.groupsKey)) == store.snapshot.groups)

windowA.tlsIDs = [d.macID]
windowB.tlsIDs = [d.macID]
RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
let before = (windowA.notifications, windowB.notifications)
windowB.store.updateMacs { $0 = SavedMacs.seenOverTLS([d.macID], in: $0) ?? $0 }
windowA.store.setGroup("Home Office", for: d.macID)
RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
check("discovery notifications settle; equal TLS and group edits publish nothing", before.0 > 0 && before.1 > 0
      && before.0 == windowA.notifications && before.1 == windowB.notifications)

let persisted = defaults.persistentDomain(forName: suite)!
let seeded = SavedMacStore(defaults: defaults, arguments: ["-Sill.savedMacs", SavedMacs.encode([a]), "-Sill.macGroups", "{}"])
seeded.updateMacs { $0 = SavedMacs.adding(b, to: $0) }
seeded.setGroup("Work", for: b.macID)
check("DEBUG seeds are editable shared memory", seeded.savedMacsSeeded && seeded.macGroupsSeeded && seeded.snapshot.macs.count == 2
      && seeded.snapshot.groups[b.macID] == "Work")
check("DEBUG seeds never write their JSON keys", NSDictionary(dictionary: persisted).isEqual(to: defaults.persistentDomain(forName: suite)!))
print("saved-mac-store: \(checks) checks passed; legacy snapshot overwrite reproduced, shared edits preserved")
