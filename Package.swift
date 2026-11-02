// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Winnow",
    platforms: [.macOS(.v15)],
    targets: [
        // Phase 0 spike: maps Apple Photos' internal score columns and compares them with Vision.
        .executableTarget(name: "winnow-scores", path: "Sources/WinnowScores"),
        // Phase 0 spike: PhotoKit access, Vision aesthetics timing, batch delete flow.
        .executableTarget(name: "WinnowSpike", path: "Sources/WinnowSpike"),
    ],
    swiftLanguageModes: [.v5]
)
