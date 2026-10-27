import Foundation

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    guard condition() else { fatalError("FAIL: \(message)") }
}
let suite = "Sill.background-session-check.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
let intent = BackgroundSessionIntent(macID: "paired-Mac", source: .window(42), launchID: "launch-A")
let second = BackgroundSessionIntent(macID: "another-Mac", source: .desktop, launchID: "launch-B")
BackgroundSessionPersistence.save(intent, scene: "window-A", defaults: defaults)
let reader = UserDefaults(suiteName: suite)!
check(BackgroundSessionPersistence.load(scene: "window-A", recoveringSingleScene: false, defaults: reader) == intent,
      "an independent reader restores the durable paired identity and source")
check(BackgroundSessionPersistence.load(scene: "new-window", recoveringSingleScene: false, defaults: defaults) == nil,
      "opening another window cannot adopt the first window's intent")
check(BackgroundSessionPersistence.load(scene: "restored-window", recoveringSingleScene: true, defaults: defaults) == intent,
      "the first scene after relaunch may adopt one unambiguous saved intent")
check(BackgroundSessionPersistence.load(scene: "window-A", recoveringSingleScene: false, defaults: defaults) == nil,
      "adoption removes the old scene slot")
BackgroundSessionPersistence.save(second, scene: "window-B", defaults: defaults)
check(BackgroundSessionPersistence.load(scene: "unknown-window", recoveringSingleScene: true, defaults: defaults) == nil,
      "multiple saved windows are never guessed by name or order")
BackgroundSessionPersistence.save(nil, scene: "restored-window", defaults: defaults)
check(BackgroundSessionPersistence.load(scene: "window-B", recoveringSingleScene: false, defaults: defaults) == second,
      "explicit disconnect clears only its scene's intent")

let windows = [WindowInfo(id: 42, title: "Document", appName: "Editor", bundleID: "test.Editor", width: 800, height: 600)]
check(intent.sourceToRestore(hostLaunchID: "launch-A", active: .none, windows: windows) == .window(42),
      "the same host launch and a live window can restore into an idle host")
check(intent.sourceToRestore(hostLaunchID: "launch-B", active: .none, windows: windows) == nil,
      "a reused CGWindowID after host restart never selects a different window")
check(intent.sourceToRestore(hostLaunchID: nil, active: .none, windows: windows) == nil,
      "a host without launch identity cannot prove the saved window is still the same")
check(intent.sourceToRestore(hostLaunchID: "launch-A", active: .desktop, windows: windows) == nil,
      "another viewer's current source wins")
check(intent.sourceToRestore(hostLaunchID: "launch-A", active: .none, windows: []) == nil,
      "a closed window is not requested again")

var held = BackgroundHeldInputs()
held.sent(.key(hidUsage: 4, down: true, modifiers: 0))
held.sent(.pointer(.leftDown, x: 0.2, y: 0.3))
held.sent(.scrollGesture(.began, x: 0.2, y: 0.3))
check(held.release() == [.key(hidUsage: 4, down: false, modifiers: 0), .pointer(.leftUp, x: 0.2, y: 0.3),
                         .scrollGesture(.ended, x: 0.2, y: 0.3)], "background release balances the outstanding inputs")
check(held.release().isEmpty, "repeated pause never releases an input twice")
held.sent(.key(hidUsage: 4, down: true, modifiers: 0))
held.sent(.key(hidUsage: 4, down: false, modifiers: 0))
held.sent(.scrollGesture(.momentumBegan, x: 0.4, y: 0.5))
check(held.release() == [.scrollGesture(.momentumEnded, x: 0.4, y: 0.5)],
      "completed keys stay released while a pending momentum is ended")
print("background-session: \(checks) checks passed")
