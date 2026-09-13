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
            resources: [
                .process("Resources"),
                .process("Shaders")
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
                "MusicMiniPlayer.entitlements"
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
            dependencies: ["MusicMiniPlayerCore", "KeyboardShortcuts"]
        ),
    ]
)
