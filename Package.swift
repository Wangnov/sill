// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Sill",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "StreamProtocol", targets: ["StreamProtocol"]),
        // The CLI keeps the product name SillHost, so `swift run -c release SillHost …` and
        // .build/release/SillHost are what they always were.
        .executable(name: "SillHost", targets: ["SillHostCLI"]),
        // Xcode owns the Mac app bundle; the library keeps the AppKit host and its package access
        // to the core. The old executable stays as a thin entry for Scripts/make-app.sh.
        .library(name: "SillMac", targets: ["SillMac"]),
        .executable(name: "SillMenuBar", targets: ["SillMenuBar"]),
        // No product for SillHostCore: the iOS project links this package and must never see it.
    ],
    targets: [
        .target(name: "StreamProtocol"),
        // The Mac host itself (capture, encode, network, input, virtual display), shared by the CLI
        // and the menu bar app; they reach it through `package` access. The folder keeps its old
        // name (Sources/SillHost) so the paths in the docs and the VirtualDisplayProbe symlink to
        // ../SillHost/VirtualDisplay.swift stay valid.
        .target(name: "SillHostCore", dependencies: ["StreamProtocol"], path: "Sources/SillHost"),
        // The command-line host: flags, the run loop, the Terminal permission hint.
        .executableTarget(name: "SillHostCLI", dependencies: ["SillHostCore", "StreamProtocol"]),
        // Keep the UI's source paths stable while making its single startup entry available to
        // Xcode. No resources here: SwiftUI and String(localized:) read the owning app's bundle.
        .target(name: "SillMac", dependencies: ["SillHostCore", "StreamProtocol"], path: "Sources/SillMenuBar"),
        .executableTarget(name: "SillMenuBar", dependencies: ["SillMac"], path: "Sources/SillMenuBarCLI"),
        // Milestone 3 spike: virtual display + window move + capture. Its VirtualDisplay.swift
        // is a symlink to the host's copy. Not shipped.
        .executableTarget(name: "CaptureProbe"),
        .executableTarget(name: "VirtualDisplayProbe"),
    ]
)
