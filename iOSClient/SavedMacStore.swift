import Foundation
import Combine

/// App-owned paired-device data, shared by all windows. Main thread, like the clients' UI state.
/// Bonjour results, reconnects and live sessions belong to each StreamClient; none lives here.
/// Keeping one current list matters: a window learning a Mac's TLS door must not write back an
/// older snapshot that restores a Mac another window forgot, or drops one it just paired.
final class SavedMacStore: ObservableObject {
    struct Snapshot: Equatable {
        var macs: [SavedMac]
        var groups: [String: String]
    }

    @Published private(set) var snapshot: Snapshot
    let savedMacsSeeded: Bool
    let macGroupsSeeded: Bool
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, arguments: [String] = CommandLine.arguments) {
        self.defaults = defaults
        var macs = SavedMacs.decode(defaults.string(forKey: SavedMacs.defaultsKey))
        var groups = ConnectionList.decodeGroups(defaults.string(forKey: ConnectionList.groupsKey))
        var seededMacs = false, seededGroups = false
        #if DEBUG
        // Read JSON directly: UserDefaults' argument domain can drop a value starting with "[".
        // Seeded data is shared for this run, but never replaces the installation's stored data.
        if let i = arguments.firstIndex(of: "-" + SavedMacs.defaultsKey), i + 1 < arguments.count {
            macs = SavedMacs.decode(arguments[i + 1])
            seededMacs = true
        }
        if let i = arguments.firstIndex(of: "-" + ConnectionList.groupsKey), i + 1 < arguments.count {
            groups = ConnectionList.decodeGroups(arguments[i + 1])
            seededGroups = true
        }
        #endif
        savedMacsSeeded = seededMacs
        macGroupsSeeded = seededGroups
        snapshot = Snapshot(macs: macs, groups: groups)
    }

    /// Edits the current shared data, once. Record replacement can carry its group before pruning;
    /// publishing those changes together keeps every window from seeing a half-finished migration.
    func update(_ edit: (inout Snapshot) -> Void) {
        var next = snapshot
        edit(&next)
        if next.macs != snapshot.macs, !savedMacsSeeded {
            let kept = Set(next.macs.map(\.macID))
            next.groups = next.groups.filter { kept.contains($0.key) }
        }
        // A discovery refresh can learn TLS and notify the clients, which recompute discovery.
        // Same-value edits must stop here, or that refresh would keep publishing itself forever.
        guard next != snapshot else { return }
        if next.macs != snapshot.macs, !savedMacsSeeded {
            defaults.set(SavedMacs.encode(next.macs), forKey: SavedMacs.defaultsKey)
        }
        if next.groups != snapshot.groups, !macGroupsSeeded {
            defaults.set(ConnectionList.encodeGroups(next.groups), forKey: ConnectionList.groupsKey)
        }
        snapshot = next
    }

    func updateMacs(_ edit: (inout [SavedMac]) -> Void) {
        update { edit(&$0.macs) }
    }

    func setGroup(_ group: String?, for macID: String) {
        update { $0.groups = ConnectionList.settingGroup(group, for: macID, in: $0.groups) }
    }
}
