import SwiftUI

@main
struct SillApp: App {
    /// Paired-device data outlives a window; each ContentView still owns its own stream session.
    @StateObject private var savedMacStore = SavedMacStore()
    /// Only `buildMenu(with:)`: the Mac's menus in the iPad's menu bar on iPadOS 26 (SillAppDelegate).
    @UIApplicationDelegateAdaptor(SillAppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            // iOS 27.1 on the iPhone Duo: the hinge for the layouts (DuoPostureReader); nothing
            // before iOS 27.1 or on a device without a hinge.
            ContentView(savedMacStore: savedMacStore)
                .readsDuoPosture()
        }
    }
}
