// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MusicMiniPlayer",
    platforms: [
        .macOS(.v14)  // 最低支持 macOS 14 Sonoma
    ],
    products: [
        .executable(
            name: "MusicMiniPlayer",
            targets: ["MusicMiniPlayer"]),
        .executable(
            name: "MusicMiniPlayerFull",
            targets: ["MusicMiniPlayerFull"]),
        .library(
            name: "MusicMiniPlayerCore",
            targets: ["MusicMiniPlayerCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", exact: "3.0.1")
    ],
    targets: [
        .target(
            name: "ObjCSupport",
            path: "Sources/ObjCSupport",
            publicHeadersPath: "include"
        ),
        .target(
            name: "MusicMiniPlayerCore",
            dependencies: ["ObjCSupport", "KeyboardShortcuts"],
            path: "Sources/MusicMiniPlayerCore",
            exclude: [
                "Models/CLAUDE.md"
            ],
            // DEBUG-preview images only; release code never touches Bundle.module, so
            // the release binary references no MusicMiniPlayerCore resource bundle
            // (build_app.sh ships exactly the bundles the binary references).
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "LyricsVerifier",
            dependencies: ["MusicMiniPlayerCore"],
            path: "Sources/LyricsVerifier"
        ),
        .target(
            name: "MusicMiniPlayerAppKit",
            dependencies: ["MusicMiniPlayerCore", "KeyboardShortcuts"],
            path: "Sources/MusicMiniPlayerAppKit",
            exclude: ["CLAUDE.md"]
        ),
        .executableTarget(
            name: "MusicMiniPlayer",
            dependencies: ["MusicMiniPlayerAppKit"],
            path: "Sources/MusicMiniPlayerApp",
            exclude: [
                "Info.plist",
                "MusicMiniPlayer.entitlements",
                // Compiled by build_app.sh's actool step (into Assets.car), not by
                // SwiftPM's own resource pipeline — same treatment as the repo-root
                // AppIcon.icon catalog build_app.sh already compiles separately.
                "Resources/AppAssets.xcassets"
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/MusicMiniPlayerApp/Info.plist"
                ])
            ]
        ),
        .target(
            name: "NanoPodFullEdition",
            dependencies: ["MusicMiniPlayerCore"],
            path: "Sources/NanoPodFullEdition"
        ),
        .executableTarget(
            name: "MusicMiniPlayerFull",
            dependencies: ["MusicMiniPlayerAppKit", "NanoPodFullEdition"],
            path: "Sources/MusicMiniPlayerFullApp",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/MusicMiniPlayerApp/Info.plist"
                ])
            ]
        ),
        .testTarget(
            name: "MusicMiniPlayerTests",
            // MusicMiniPlayerAppKit added 2026-09-27 for the menu/settings redesign
            // (docs/design/2026-09-25-menu-settings/proposal.md §5) — its acceptance
            // criteria test `populateMenuBarMenu`'s NSMenuItems, `SettingsDemo`,
            // `DemoStage`, and `AboutPageView`, all of which live in that target.
            dependencies: ["MusicMiniPlayerCore", "MusicMiniPlayerAppKit", "KeyboardShortcuts"],
            resources: [
                .copy("Fixtures")
            ]
        ),
    ]
)
