// swift-tools-version: 6.0
// AKit core: data model, harness adapters, file access. No UI.
import PackageDescription

let package = Package(
    name: "AKitCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AKitCore", targets: ["AKitCore"]),
        // `akit` command for agents and terminals (install: make install-cli).
        .executable(name: "akit", targets: ["akit"]),
    ],
    dependencies: [
        // layer.yaml in the brain repo: lists and nested maps, more than Frontmatter reads.
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.0.0"),
    ],
    targets: [
        .target(name: "AKitFoundation"),
        .target(name: "AKitModel"),
        // Umbrella: the files not moved into a module yet, plus Exports.swift.
        .target(name: "AKitCore", dependencies: ["AKitFoundation", "AKitModel", "Yams"]),
        .executableTarget(name: "akit", dependencies: ["AKitCore"]),
        .testTarget(name: "AKitFoundationTests", dependencies: ["AKitFoundation"]),
        .testTarget(name: "AKitCoreTests", dependencies: ["AKitCore", "AKitFoundation"]),
    ]
)
