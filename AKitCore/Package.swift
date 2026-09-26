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
        .target(name: "AKitCore", dependencies: ["Yams"]),
        .executableTarget(name: "akit", dependencies: ["AKitCore"]),
        .testTarget(name: "AKitCoreTests", dependencies: ["AKitCore"]),
    ]
)
