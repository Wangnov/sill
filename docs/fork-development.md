# Fork development

Use Xcode 27.1 or newer. Open `Sill.xcworkspace` for the Mac and existing iOS projects. The
Mac app scheme is **SillMacApp** (`MacApp/Sill.xcodeproj`); the iOS scheme remains **Sill**.

```sh
xcodebuild -workspace Sill.xcworkspace -scheme SillMacApp -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath .build/native-mac build
```

For the daily build/run loop, use `./script/build_and_run.sh` or the Codex Run action. It
builds into `.build/DerivedData`, stops only the development executable from this checkout,
and writes its log to `~/Library/Logs/Sill-Development/Sill.log`. `--verify` checks that it stays running;
`--debug` starts LLDB and `--logs` follows that log. Extra arguments go to the app, for example:

```sh
./script/build_and_run.sh --verify --synthetic
```

Debug builds `Sill Development.app`, with bundle ID `local.sill.fork.mac.debug` and ad hoc
signing by default. `CODE_SIGNING_ALLOWED=NO` also builds without a certificate. Settings,
permissions and login items follow this development bundle ID. Its explicit
`SillIdentityNamespace` is `$(PRODUCT_BUNDLE_IDENTIFIER).remote`, for a separate pairing
identity through the fork's namespace support. Preview and `--synthetic` launches
never use the production identity. No step installs over `/Applications/Sill.app`.

If Accessibility appears enabled for the development app but `AXIsProcessTrusted()` is false,
a previous ad hoc build's authorization may no longer match the current binary. For this symptom,
reset only the development app's Accessibility authorization with
`tccutil reset Accessibility local.sill.fork.mac.debug`, then allow the exact current
`Sill Development.app` again in System Settings. This does not reset Screen Recording. A stable
Apple Development signing identity can reduce authorization loss across rebuilds; without a
certificate, keep the same binary throughout device testing.

Release builds `Sill.app` with bundle ID `local.sill.fork.mac`. Override
`PRODUCT_BUNDLE_IDENTIFIER`, `DEVELOPMENT_TEAM` and `CODE_SIGN_IDENTITY` for your own release
identity. The project has no upstream team ID or restricted keychain entitlement. A local
unsigned archive can check the archive layout; distributing it still needs your own signing,
provisioning when applicable, and notarization. Existing release scripts are unchanged.

The Xcode app owns `Packaging/Info.plist`, the two String Catalogs and `Packaging/AppIcon.icon`.
A small build phase copies the shared Info.plist to Xcode's derived directory and sets the fork
identity, display name and pairing namespace; shared version numbers stay in Packaging. Xcode
then processes this Info.plist, compiles resources and signs the bundle.
The package's `SillMac` library retains AppKit startup, self-tests and shutdown restoration;
its only public entry is `SillMacApp.run()`. `swift build --product SillMenuBar` and
`Scripts/make-app.sh` continue to use a thin executable entry over the same library. Catalog
extraction from package sources remains the explicit localization sync step.

`feat/i18n` contains the upstream-compatible localization contribution. The fork's main
branch also carries the app project and data-ownership refactors; use `upstream/main` as the
comparison base when preparing further contributions. The iOS app still needs your own team
and bundle identifier in Signing & Capabilities for an actual device build.

Session backgrounding, the experimental notification inbox and personal APNs configuration are
documented in [session and notification continuity](session-and-notification-continuity.md).
The fork's iOS targets use separate Debug/Release bundle IDs and have no upstream development
team. Their push entitlement requires your own matching App ID and provisioning profile.
