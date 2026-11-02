// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Winnow",
    platforms: [.macOS(.v15)],
    targets: [
        // Read-only access to a Photos library's own database and its score columns.
        .target(name: "WinnowCore", path: "Sources/WinnowCore"),
        // Phase 0 spike app: pick a library, map its scores, time PhotoKit + Vision, try batch delete.
        .executableTarget(name: "WinnowSpike", dependencies: ["WinnowCore"], path: "Sources/WinnowSpike"),
        // Command-line front end to WinnowCore, for automated testing.
        .executableTarget(name: "winnow-scores", dependencies: ["WinnowCore"], path: "Sources/WinnowScores"),
    ],
    swiftLanguageModes: [.v5]
)
