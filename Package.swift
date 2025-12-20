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
            name: "MusicMiniPlayerCore",
            dependencies: [],
            path: "Sources/MusicMiniPlayerCore",
            resources: [
                .process("Resources"),
                .process("Shaders")
            ]
        ),
        .executableTarget(
            name: "MusicMiniPlayer",
            dependencies: ["MusicMiniPlayerCore"],
            path: "Sources/MusicMiniPlayerApp",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/MusicMiniPlayerApp/Info.plist"
                ])
            ]
        ),
    ]
)
