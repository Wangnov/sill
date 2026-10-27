# Fork development

Use Xcode 27.1 or newer. Open `Sill.xcworkspace` for the Mac and existing iOS projects. The
Mac app scheme is **SillMacApp** (`MacApp/Sill.xcodeproj`); the iOS scheme remains **Sill**.

```sh
xcodebuild -workspace Sill.xcworkspace -scheme SillMacApp -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath .build/native-mac build
```

Debug builds `Sill Development.app`, with bundle ID `local.sill.fork.mac.debug` and ad hoc
signing by default. `CODE_SIGNING_ALLOWED=NO` also builds without a certificate. Settings,
permissions and login items follow this development bundle ID. Its explicit
`SillIdentityNamespace` is `$(PRODUCT_BUNDLE_IDENTIFIER).remote`, for a separate pairing
identity once the fork's namespace support is included. Preview and `--synthetic` launches
never use the production identity. No step installs over `/Applications/Sill.app`.

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
