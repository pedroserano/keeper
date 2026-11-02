// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Winnow",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        // Read-only access to a Photos library's own database and its score columns.
        .target(name: "WinnowCore", path: "Sources/WinnowCore"),
        // Culling model with no PhotoKit or UI: decisions, their store, undo history.
        .target(name: "WinnowKit", dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
                path: "Sources/WinnowKit"),
        // The app.
        .executableTarget(name: "Winnow", dependencies: ["WinnowCore", "WinnowKit"], path: "Sources/Winnow"),
        // Phase 0 spike app: pick a library, map its scores, time PhotoKit + Vision, try batch delete.
        .executableTarget(name: "WinnowSpike", dependencies: ["WinnowCore"], path: "Sources/WinnowSpike"),
        // Command-line front end to WinnowCore, for automated testing.
        .executableTarget(name: "winnow-scores", dependencies: ["WinnowCore"], path: "Sources/WinnowScores"),
        .testTarget(name: "WinnowKitTests", dependencies: ["WinnowKit"], path: "Tests/WinnowKitTests"),
    ],
    swiftLanguageModes: [.v5]
)
