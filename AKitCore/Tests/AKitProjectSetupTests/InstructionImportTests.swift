import Foundation
import Testing
import AKitBrain
import AKitFoundation
import AKitInstructions
@testable import AKitProjectSetup

/// Import to Brain…: a section of an instruction file joins a layer's AGENTS.md text (committed),
/// and leaves the file only when asked.
struct InstructionImportTests {
    let f: GitProjectFixture

    init() throws { f = try GitProjectFixture("instruction-import") }

    func section(_ heading: String, in url: URL) throws -> InstructionSection {
        try #require(InstructionText.units(String(decoding: try Data(contentsOf: url), as: UTF8.self)).first { $0.heading == heading })
    }

    var agents: URL { f.project.appending(path: "AGENTS.md") }

    @Test func aSectionJoinsTheLayersTextInOneCommitAndTheFileKeepsIt() async throws {
        let brain = try await f.setUpBrain()
        try f.write("Projects/task/AGENTS.md", "## Commits\r\nShort lines.\r\n\r\n## Style\r\nTabs.\r\n")
        let commits = try await f.git("rev-list", "--count", "HEAD", in: f.brainRoot)

        let plan = try InstructionImport.plan(try section("Commits", in: agents), from: agents, into: "task", removeHere: false,
                                              brain: brain, rendered: [], env: f.env)
        #expect(plan.before == "# Task" && plan.after == "# Task\n\n## Commits\nShort lines." && plan.removal == nil)
        #expect(plan.notes.last?.contains("keeps its copy") == true)
        try await InstructionImport.apply(plan, brain: brain, env: f.env)

        #expect(f.read("layers/task/templates/agents.md", in: f.brainRoot) == "# Task\n\n## Commits\nShort lines.\n")
        #expect(try await f.git("log", "-1", "--format=%s", in: f.brainRoot) == "Add a section to layer task's AGENTS.md\n")
        #expect(Int(try await f.git("rev-list", "--count", "HEAD", in: f.brainRoot).trimmingCharacters(in: .whitespacesAndNewlines))
                == (Int(commits.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) + 1)
        #expect(f.read("AGENTS.md")?.contains("## Commits") == true)

        // Once there, the same section is refused.
        let again = try #require(Brain.load(from: f.brainRoot))
        #expect { try InstructionImport.plan(try section("Commits", in: agents), from: agents, into: "task", removeHere: false,
                                             brain: again, rendered: [], env: f.env) } throws: { error in
            (error as? InstructionImport.Failure)?.message == "The task layer's AGENTS.md text has this section already."
        }
    }

    @Test func alsoRemoveHereTakesItOutOfTheFileAfterTheCommit() async throws {
        let brain = try await f.setUpBrain()
        try f.write("Projects/task/AGENTS.md", "## Commits\nShort lines.\n\n## Style\nTabs.\n")
        let plan = try InstructionImport.plan(try section("Commits", in: agents), from: agents, into: "task", removeHere: true,
                                              brain: brain, rendered: [], env: f.env)
        #expect(plan.removal != nil && plan.notes.contains { $0.contains("loses the section now") })
        try await InstructionImport.apply(plan, brain: brain, env: f.env)
        #expect(f.read("AGENTS.md") == "## Style\nTabs.\n")
        #expect(f.read("layers/task/templates/agents.md", in: f.brainRoot)?.contains("## Commits") == true)
    }

    @Test func aStaleFileOrLayerIsRefused() async throws {
        let brain = try await f.setUpBrain()
        try f.write("Projects/task/AGENTS.md", "## Commits\nShort lines.\n")
        let old = try section("Commits", in: agents)
        let plan = try InstructionImport.plan(old, from: agents, into: "task", removeHere: false, brain: brain, rendered: [], env: f.env)
        try f.write(".akit/registry/layers/task/templates/agents.md", "# Task\nchanged\n")
        await #expect { try await InstructionImport.apply(plan, brain: brain, env: f.env) } throws: { error in
            (error as? InstructionImport.Failure)?.message.contains("changed since the preview") == true
        }
        try f.write("Projects/task/AGENTS.md", "## Commits\nLong lines.\n")
        #expect(throws: InstructionImport.Failure.self) {
            try InstructionImport.plan(old, from: agents, into: "task", removeHere: false, brain: brain, rendered: [], env: f.env)
        }
    }

    @Test func theSuggestedLayerIsCoreForGlobalFiles() async throws {
        let brain = try await f.setUpBrain()
        #expect(InstructionImport.suggestedLayer(for: .global, project: f.project, brain: brain, projects: [:]) == "core")
        #expect(InstructionImport.suggestedLayer(for: .project, project: f.project, brain: brain, projects: [:]) == "core")
    }

    // MARK: - Review round (2026-10-14)

    @Test func aHandEditOfTheLayerAfterTheScanIsKept() async throws {
        let brain = try await f.setUpBrain()
        try f.write("Projects/task/AGENTS.md", "## Commits\nShort lines.\n")
        let plan = try InstructionImport.plan(try section("Commits", in: agents), from: agents, into: "task", removeHere: false,
                                              brain: brain, rendered: [], env: f.env)
        // layer.yaml changes after the scan the plan came from.
        let manifest = ".akit/registry/layers/task/layer.yaml"
        let edited = "description: Hand edit\nrequires: [mcp]\n" + (f.read("layers/task/layer.yaml", in: f.brainRoot) ?? "")
        try f.write(manifest, edited)
        try await InstructionImport.apply(plan, brain: brain, env: f.env)
        #expect(f.read("layers/task/layer.yaml", in: f.brainRoot) == edited)
        #expect(try await f.git("show", "--name-only", "--format=", "HEAD", in: f.brainRoot) == "layers/task/templates/agents.md\n")
    }

    @Test func theTemplatesOwnBytesStay() async throws {
        let brain = try await f.setUpBrain()
        try f.write(".akit/registry/layers/task/templates/agents.md", "\n    indented first\r\n# Task\r\n\r\nline  \r\n\n\n")
        try f.write("Projects/task/AGENTS.md", "## Commits\nShort lines.\n")
        let plan = try InstructionImport.plan(try section("Commits", in: agents), from: agents, into: "task", removeHere: false,
                                              brain: brain, rendered: [], env: f.env)
        try await InstructionImport.apply(plan, brain: brain, env: f.env)
        #expect(f.read("layers/task/templates/agents.md", in: f.brainRoot)
                == "\n    indented first\r\n# Task\r\n\r\nline  \r\n\r\n## Commits\r\nShort lines.\r\n")
    }

    @Test func aChangedFileStopsTheImportBeforeTheCommit() async throws {
        let brain = try await f.setUpBrain()
        try f.write("Projects/task/AGENTS.md", "## Commits\nShort lines.\n\n## Style\nTabs.\n")
        let plan = try InstructionImport.plan(try section("Commits", in: agents), from: agents, into: "task", removeHere: true,
                                              brain: brain, rendered: [], env: f.env)
        try f.write("Projects/task/AGENTS.md", "## Commits\nShort lines.\n\n## Style\nSpaces.\n")
        let head = try await f.git("rev-parse", "HEAD", in: f.brainRoot)
        await #expect(throws: InstructionImport.Failure.self) { try await InstructionImport.apply(plan, brain: brain, env: f.env) }
        #expect(try await f.git("rev-parse", "HEAD", in: f.brainRoot) == head)
        #expect(f.read("layers/task/templates/agents.md", in: f.brainRoot) == "# Task\n")
    }

    @Test func leadsOpenFencesAndConditionalLayersAreRefused() async throws {
        let brain = try await f.setUpBrain()
        try f.write("Projects/task/AGENTS.md", "Always English.\n\n## Build\n```sh\nmake\n\n## Style\nTabs.\n")
        let units = InstructionText.units(f.read("AGENTS.md") ?? "")
        for unit in units.prefix(2) {
            #expect(throws: InstructionImport.Failure.self) {
                try InstructionImport.plan(unit, from: agents, into: "task", removeHere: false, brain: brain, rendered: [], env: f.env)
            }
        }
        try f.write(".akit/registry/layers/cond/layer.yaml", "files:\n  - template: AGENTS.md\n    to: AGENTS.md\n    when: x\n")
        try f.write("Projects/task/AGENTS.md", "## Style\nTabs.\n")
        let withCond = try #require(Brain.load(from: f.brainRoot))
        #expect { try InstructionImport.plan(try section("Style", in: agents), from: agents, into: "cond", removeHere: false,
                                             brain: withCond, rendered: [], env: f.env) } throws: { error in
            (error as? InstructionImport.Failure)?.message.contains("only under a when: condition") == true
        }
    }
}
