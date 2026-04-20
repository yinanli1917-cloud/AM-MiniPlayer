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
        .library(
            name: "MusicMiniPlayerCore",
            targets: ["MusicMiniPlayerCore"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "ObjCSupport",
            path: "Sources/ObjCSupport",
            publicHeadersPath: "include"
        ),
        .target(
            name: "MusicMiniPlayerCore",
            dependencies: ["ObjCSupport"],
            path: "Sources/MusicMiniPlayerCore",
            resources: [
                .process("Resources"),
                .process("Shaders")
            ]
        ),
        .executableTarget(
            name: "LyricsVerifier",
            dependencies: ["MusicMiniPlayerCore"],
            path: "Sources/LyricsVerifier"
        ),
        .executableTarget(
            name: "MusicMiniPlayer",
            dependencies: ["MusicMiniPlayerCore"],
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
        .testTarget(
            name: "MusicMiniPlayerTests",
            dependencies: ["MusicMiniPlayerCore"]
        ),
    ]
)
