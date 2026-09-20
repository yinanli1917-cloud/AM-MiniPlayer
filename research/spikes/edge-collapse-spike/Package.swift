// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EdgeCollapseSpike",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "EdgeCollapseSpike",
            path: "Sources/EdgeCollapseSpike"
        ),
        .testTarget(
            name: "EdgeCollapseSpikeTests",
            dependencies: ["EdgeCollapseSpike"],
            path: "Tests/EdgeCollapseSpikeTests"
        ),
    ]
)
