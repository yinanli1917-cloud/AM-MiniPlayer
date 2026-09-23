// swift-tools-version: 5.9
import PackageDescription

// v3 (2026-09-20): depends on the real nanoPod core so the card hosts the
// real MiniPlayerView (real artwork, colour extraction, lyrics page) instead
// of a placeholder gradient — founder asked to judge the collapse against a
// real cover. Path dependency on the repo root; the spike itself stays out
// of the app's Package.swift.
let package = Package(
    name: "EdgeCollapseSpike",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(name: "MusicMiniPlayer", path: "../../..")
    ],
    targets: [
        .executableTarget(
            name: "EdgeCollapseSpike",
            dependencies: [
                .product(name: "MusicMiniPlayerCore", package: "MusicMiniPlayer")
            ],
            path: "Sources/EdgeCollapseSpike"
        ),
        .testTarget(
            name: "EdgeCollapseSpikeTests",
            dependencies: ["EdgeCollapseSpike"],
            path: "Tests/EdgeCollapseSpikeTests"
        ),
    ]
)
