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
        .library(name: "AKitInstructions", targets: ["AKitInstructions"]),
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
        .library(name: "AKitDoctor", targets: ["AKitDoctor"]),
        .library(name: "AKitHelp", targets: ["AKitHelp"]),
        .library(name: "AKitReview", targets: ["AKitReview"]),
        .library(name: "AKitKnowledge", targets: ["AKitKnowledge"]),
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
        .target(name: "AKitInstructions", dependencies: ["AKitFoundation", "AKitModel", "AKitHarnesses"]),
        .target(name: "AKitSkillsSh", dependencies: ["AKitFoundation", "AKitModel", "AKitHarnesses", "AKitSkills", "AKitSessions"]),
        .target(name: "AKitSessions", dependencies: ["AKitFoundation", "AKitModel"]),
        .target(name: "AKitUsage", dependencies: ["AKitFoundation", "AKitModel", "AKitSessions"]),
        .target(name: "AKitMCP", dependencies: ["AKitFoundation", "AKitModel", "AKitHarnesses"]),
        // Public catalogs of MCP servers; fills the Add Server form (docs/design/mcp-catalog.md).
        .target(name: "AKitMCPCatalog", dependencies: ["AKitMCP"]),
        .target(name: "AKitBrain", dependencies: ["AKitFoundation", "AKitModel", "AKitSkills", "Yams"]),
        .target(name: "AKitInsights", dependencies: ["AKitFoundation", "AKitModel", "AKitHarnesses", "AKitSkills", "AKitSessions", "AKitBrain"]),
        // The rulesync seam: sees only the brain's ProjectBundle and RenderResult.
        .target(name: "AKitRender", dependencies: ["AKitFoundation", "AKitBrain"]),
        // Lab: session metrics, runs in a terminal, replay tasks (docs/design/lab.md).
        // Lab → Brain for one thing: whether this Mac is a work Mac (the sending policy).
        // Lab → Knowledge: the knowledge base's check model call (KnowledgeChecker), for the CLI and the app.
        .target(name: "AKitLab", dependencies: ["AKitFoundation", "AKitModel", "AKitSessions", "AKitBrain", "AKitKnowledge"]),
        // Error analysis: failure modes across many sessions (docs/design/error-analysis.md).
        // → Render: layer evals render a brain layer into a control cell (docs/design/layer-evals.md).
        .target(name: "AKitErrorAnalysis", dependencies: ["AKitFoundation", "AKitModel", "AKitSessions", "AKitLab", "AKitInsights", "AKitBrain", "AKitRender", "AKitInstructions"]),
        // → MCP: Pi project files of MCP switches stay out of git (MCPProjectSwitch).
        .target(name: "AKitProjectSetup", dependencies: ["AKitFoundation", "AKitModel", "AKitSkills", "AKitInstructions", "AKitBrain", "AKitRender", "AKitInsights", "AKitMCP", "AKitSessions"]),
        // akit doctor and Help → Copy Diagnostics: a read-only report of this Mac (docs/design/machine-setup.md);
        // akit doctor pi / Check Pi…: Pi's setup (→ Instructions: the global AGENTS.md Pi loads);
        // → Knowledge: the knowledge base line (a remote is a problem).
        .target(name: "AKitDoctor", dependencies: ["AKitFoundation", "AKitModel", "AKitHarnesses", "AKitSkills", "AKitInstructions", "AKitMCP", "AKitBrain", "AKitInsights", "AKitProjectSetup", "AKitKnowledge"]),
        // Ask AKit: questions about a screen, answered from the in-app guides (docs/design/ask-akit.md).
        .target(name: "AKitHelp", dependencies: ["AKitFoundation"]),
        // AI review of GitLab merge requests: AKit gathers, Pi reads, AKit posts drafts after approval (docs/design/review.md).
        .target(name: "AKitReview", dependencies: ["AKitFoundation", "AKitModel", "AKitHarnesses", "AKitSessions", "AKitLab", "AKitBrain", "AKitKnowledge", "Yams"]),
        // Knowledge base: areas, notes, links and git of a base folder (docs/design/knowledge.md).
        // → Brain: this Mac's kind (work or personal), the brain's root and project ids.
        .target(name: "AKitKnowledge", dependencies: ["AKitFoundation", "AKitModel", "AKitBrain", "Yams"]),
        .target(name: "AKitCommandLine", dependencies: ["AKitReview", "AKitKnowledge", "AKitFoundation", "AKitModel", "AKitHarnesses", "AKitSkills", "AKitInstructions", "AKitMCP", "AKitBrain", "AKitInsights", "AKitProjectSetup", "AKitLab", "AKitErrorAnalysis", "AKitDoctor"]),
        .executableTarget(name: "akit", dependencies: ["AKitCommandLine", "AKitInsights", "AKitHarnesses", "AKitBrain", "AKitFoundation"]),
        .testTarget(name: "AKitFoundationTests", dependencies: ["AKitFoundation"]),
        .testTarget(name: "AKitHarnessesTests", dependencies: ["AKitHarnesses", "AKitFoundation", "AKitModel", "AKitSkills"]),
        .testTarget(name: "AKitSkillsTests", dependencies: ["AKitSkills", "AKitFoundation", "AKitHarnesses"]),
        .testTarget(name: "AKitInstructionsTests", dependencies: ["AKitInstructions", "AKitFoundation", "AKitHarnesses", "AKitModel"]),
        .testTarget(name: "AKitSkillsShTests", dependencies: ["AKitSkillsSh", "AKitFoundation", "AKitModel", "AKitHarnesses", "AKitSkills", "AKitSessions"]),
        .testTarget(name: "AKitSessionsTests", dependencies: ["AKitSessions", "AKitFoundation", "AKitModel", "AKitHarnesses"]),
        .testTarget(name: "AKitUsageTests", dependencies: ["AKitUsage", "AKitFoundation", "AKitModel", "AKitHarnesses"]),
        .testTarget(name: "AKitMCPTests", dependencies: ["AKitMCP", "AKitFoundation", "AKitModel", "AKitHarnesses"]),
        .testTarget(name: "AKitMCPCatalogTests", dependencies: ["AKitMCPCatalog", "AKitMCP"]),
        .testTarget(name: "AKitBrainTests", dependencies: ["AKitBrain", "AKitFoundation", "AKitModel", "AKitSkills", "AKitProjectSetup", "AKitCommandLine"]),
        .testTarget(name: "AKitInsightsTests", dependencies: ["AKitInsights", "AKitFoundation", "AKitModel", "AKitHarnesses", "AKitSkills", "AKitSessions", "AKitBrain", "AKitProjectSetup", "AKitCommandLine"]),
        .testTarget(name: "AKitRenderTests", dependencies: ["AKitRender", "AKitBrain", "AKitFoundation"]),
        .testTarget(name: "AKitProjectSetupTests", dependencies: ["AKitProjectSetup", "AKitFoundation", "AKitBrain", "AKitRender", "AKitMCP", "AKitModel", "AKitHarnesses", "AKitSkills", "AKitSessions"]),
        .testTarget(name: "AKitLabTests", dependencies: ["AKitLab", "AKitFoundation", "AKitModel", "AKitBrain", "AKitKnowledge"]),
        .testTarget(name: "AKitErrorAnalysisTests", dependencies: ["AKitErrorAnalysis", "AKitHelp", "AKitLab", "AKitFoundation", "AKitModel", "AKitSessions", "AKitInsights", "AKitBrain", "AKitRender"]),
        .testTarget(name: "AKitDoctorTests", dependencies: ["AKitDoctor", "AKitKnowledge", "AKitInsights", "AKitMCP", "AKitFoundation", "AKitBrain", "AKitProjectSetup"]),
        .testTarget(name: "AKitReviewTests", dependencies: ["AKitReview", "AKitFoundation", "AKitLab", "AKitBrain", "AKitKnowledge"]),
        .testTarget(name: "AKitHelpTests", dependencies: ["AKitHelp", "AKitFoundation"]),
        .testTarget(name: "AKitKnowledgeTests", dependencies: ["AKitKnowledge", "AKitFoundation", "AKitBrain"],
                    // Read by path (#filePath): a base layout with Excalidraw 0.17.6 maps, not bundle resources.
                    exclude: ["Fixtures"]),
        .testTarget(name: "AKitCommandLineTests", dependencies: ["AKitCommandLine", "AKitKnowledge", "AKitDoctor", "AKitReview", "AKitFoundation", "AKitBrain", "AKitInsights", "AKitErrorAnalysis", "AKitLab"]),
    ]
)
