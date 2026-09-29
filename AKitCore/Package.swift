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
        .target(name: "AKitHarnesses", dependencies: ["AKitFoundation", "AKitModel"]),
        .target(name: "AKitSkills", dependencies: ["AKitFoundation", "AKitModel", "AKitHarnesses"]),
        .target(name: "AKitSkillsSh", dependencies: ["AKitFoundation", "AKitModel", "AKitHarnesses", "AKitSkills"]),
        .target(name: "AKitSessions", dependencies: ["AKitFoundation", "AKitModel"]),
        .target(name: "AKitUsage", dependencies: ["AKitFoundation", "AKitModel", "AKitSessions"]),
        .target(name: "AKitMCP", dependencies: ["AKitFoundation", "AKitModel", "AKitHarnesses"]),
        .target(name: "AKitBrain", dependencies: ["AKitFoundation", "AKitModel", "AKitSkills", "Yams"]),
        // Umbrella: the files not moved into a module yet, plus Exports.swift.
        .target(name: "AKitCore", dependencies: ["AKitFoundation", "AKitModel", "AKitHarnesses", "AKitSkills", "AKitSkillsSh", "AKitSessions", "AKitUsage", "AKitMCP", "AKitBrain"]),
        .executableTarget(name: "akit", dependencies: ["AKitCore"]),
        .testTarget(name: "AKitFoundationTests", dependencies: ["AKitFoundation"]),
        .testTarget(name: "AKitHarnessesTests", dependencies: ["AKitHarnesses", "AKitFoundation", "AKitCore"]),
        .testTarget(name: "AKitSkillsTests", dependencies: ["AKitSkills", "AKitFoundation", "AKitHarnesses"]),
        .testTarget(name: "AKitSkillsShTests", dependencies: ["AKitSkillsSh", "AKitFoundation", "AKitModel", "AKitHarnesses", "AKitSkills"]),
        .testTarget(name: "AKitSessionsTests", dependencies: ["AKitSessions", "AKitFoundation", "AKitModel", "AKitHarnesses"]),
        .testTarget(name: "AKitUsageTests", dependencies: ["AKitUsage", "AKitFoundation", "AKitModel", "AKitHarnesses"]),
        .testTarget(name: "AKitMCPTests", dependencies: ["AKitMCP", "AKitFoundation", "AKitModel", "AKitHarnesses"]),
        .testTarget(name: "AKitBrainTests", dependencies: ["AKitBrain", "AKitFoundation", "AKitModel", "AKitSkills", "AKitCore"]),
        .testTarget(name: "AKitCoreTests", dependencies: ["AKitCore", "AKitFoundation", "AKitHarnesses", "AKitSkills", "AKitSessions", "AKitBrain"]),
    ]
)
