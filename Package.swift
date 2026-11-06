// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Keeper",
    // macOS 27: PhotoKit ratings (PHAsset.rating). Keeper is a personal app on a macOS 27 Mac.
    platforms: [.macOS("27.0")],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        // Read-only access to a Photos library's own database and its score columns.
        .target(name: "KeeperCore", path: "Sources/KeeperCore"),
        // Culling model with no PhotoKit or UI: decisions, their store, undo history, suggestions.
        .target(name: "KeeperKit", dependencies: ["KeeperCore", .product(name: "GRDB", package: "GRDB.swift")],
                path: "Sources/KeeperKit"),
        // Which way up a photo is (Vision cues and the orientation network), for Sideways Photos.
        .target(name: "KeeperOrientation", dependencies: ["KeeperKit"], path: "Sources/KeeperOrientation"),
        // The app.
        .executableTarget(name: "Keeper", dependencies: ["KeeperCore", "KeeperKit", "KeeperOrientation"],
                          path: "Sources/Keeper"),
        // Measures the orientation cues on a folder of upright photos, each turned all four ways.
        .executableTarget(name: "orientation-eval", dependencies: ["KeeperKit", "KeeperOrientation"],
                          path: "Sources/OrientationEval"),
        // Command-line front end to KeeperCore, for automated testing.
        .executableTarget(name: "keeper-scores", dependencies: ["KeeperCore"], path: "Sources/KeeperScores"),
        .testTarget(name: "KeeperKitTests", dependencies: ["KeeperKit", "KeeperCore"], path: "Tests/KeeperKitTests"),
    ],
    swiftLanguageModes: [.v5]
)
