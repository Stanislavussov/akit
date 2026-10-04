// swift-tools-version: 6.0
// AKit's logic, one module per area (docs/design/architecture.md). No UI.
import PackageDescription

let package = Package(
    name: "AKitCore",
    platforms: [.macOS(.v15)],
    products: [
        // One library per module the app imports (project.yml lists the same ones).
        .library(name: "AKitFoundation", targets: ["AKitFoundation"]),
        .library(name: "AKitModel", targets: ["AKitModel"]),
        .library(name: "AKitHarnesses", targets: ["AKitHarnesses"]),
        .library(name: "AKitSkills", targets: ["AKitSkills"]),
        .library(name: "AKitSkillsSh", targets: ["AKitSkillsSh"]),
        .library(name: "AKitSessions", targets: ["AKitSessions"]),
        .library(name: "AKitUsage", targets: ["AKitUsage"]),
        .library(name: "AKitMCP", targets: ["AKitMCP"]),
        .library(name: "AKitMCPCatalog", targets: ["AKitMCPCatalog"]),
        .library(name: "AKitBrain", targets: ["AKitBrain"]),
        .library(name: "AKitInsights", targets: ["AKitInsights"]),
        .library(name: "AKitProjectSetup", targets: ["AKitProjectSetup"]),
        .library(name: "AKitLab", targets: ["AKitLab"]),
        .library(name: "AKitErrorAnalysis", targets: ["AKitErrorAnalysis"]),
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
        // Public catalogs of MCP servers; fills the Add Server form (docs/design/mcp-catalog.md).
        .target(name: "AKitMCPCatalog", dependencies: ["AKitMCP"]),
        .target(name: "AKitBrain", dependencies: ["AKitFoundation", "AKitModel", "AKitSkills", "Yams"]),
        .target(name: "AKitInsights", dependencies: ["AKitFoundation", "AKitModel", "AKitHarnesses", "AKitSkills", "AKitSessions", "AKitBrain"]),
        // The rulesync seam: sees only the brain's ProjectBundle and RenderResult.
        .target(name: "AKitRender", dependencies: ["AKitBrain"]),
        // Lab: session metrics, runs in a terminal, replay tasks (docs/design/lab.md).
        // Lab → Brain for one thing: whether this Mac is a work Mac (the sending policy).
        .target(name: "AKitLab", dependencies: ["AKitFoundation", "AKitModel", "AKitSessions", "AKitBrain"]),
        // Error analysis: failure modes across many sessions (docs/design/error-analysis.md).
        .target(name: "AKitErrorAnalysis", dependencies: ["AKitFoundation", "AKitModel", "AKitSessions", "AKitLab", "AKitInsights", "AKitBrain"]),
        .target(name: "AKitProjectSetup", dependencies: ["AKitFoundation", "AKitBrain", "AKitRender", "AKitInsights"]),
        .target(name: "AKitCommandLine", dependencies: ["AKitFoundation", "AKitModel", "AKitHarnesses", "AKitSkills", "AKitBrain", "AKitInsights", "AKitProjectSetup", "AKitLab", "AKitErrorAnalysis"]),
        .executableTarget(name: "akit", dependencies: ["AKitCommandLine", "AKitInsights", "AKitHarnesses", "AKitBrain", "AKitFoundation"]),
        .testTarget(name: "AKitFoundationTests", dependencies: ["AKitFoundation"]),
        .testTarget(name: "AKitHarnessesTests", dependencies: ["AKitHarnesses", "AKitFoundation", "AKitModel", "AKitSkills"]),
        .testTarget(name: "AKitSkillsTests", dependencies: ["AKitSkills", "AKitFoundation", "AKitHarnesses"]),
        .testTarget(name: "AKitSkillsShTests", dependencies: ["AKitSkillsSh", "AKitFoundation", "AKitModel", "AKitHarnesses", "AKitSkills"]),
        .testTarget(name: "AKitSessionsTests", dependencies: ["AKitSessions", "AKitFoundation", "AKitModel", "AKitHarnesses"]),
        .testTarget(name: "AKitUsageTests", dependencies: ["AKitUsage", "AKitFoundation", "AKitModel", "AKitHarnesses"]),
        .testTarget(name: "AKitMCPTests", dependencies: ["AKitMCP", "AKitFoundation", "AKitModel", "AKitHarnesses"]),
        .testTarget(name: "AKitMCPCatalogTests", dependencies: ["AKitMCPCatalog", "AKitMCP"]),
        .testTarget(name: "AKitBrainTests", dependencies: ["AKitBrain", "AKitFoundation", "AKitModel", "AKitSkills", "AKitProjectSetup", "AKitCommandLine"]),
        .testTarget(name: "AKitInsightsTests", dependencies: ["AKitInsights", "AKitFoundation", "AKitModel", "AKitHarnesses", "AKitSkills", "AKitSessions", "AKitBrain", "AKitProjectSetup", "AKitCommandLine"]),
        .testTarget(name: "AKitRenderTests", dependencies: ["AKitRender", "AKitBrain"]),
        .testTarget(name: "AKitProjectSetupTests", dependencies: ["AKitProjectSetup", "AKitFoundation", "AKitBrain", "AKitRender"]),
        .testTarget(name: "AKitLabTests", dependencies: ["AKitLab", "AKitFoundation", "AKitModel", "AKitBrain"]),
        .testTarget(name: "AKitErrorAnalysisTests", dependencies: ["AKitErrorAnalysis", "AKitLab", "AKitFoundation", "AKitModel", "AKitSessions", "AKitInsights"]),
        .testTarget(name: "AKitCommandLineTests", dependencies: ["AKitCommandLine", "AKitFoundation", "AKitBrain", "AKitInsights", "AKitErrorAnalysis", "AKitLab"]),
    ]
)
