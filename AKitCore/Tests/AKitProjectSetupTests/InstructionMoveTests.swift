import Foundation
import Testing
import AKitBrain
import AKitFoundation
import AKitInstructions
@testable import AKitProjectSetup

/// Move to Global… (a project's section → core → the home folder's core blocks → out of the
/// project) and Move to Project… (a global section → projects' own files → out of the global file).
struct InstructionMoveTests {
    let move: SkillMoveTests
    var f: GitProjectFixture { move.f }

    init() throws { move = try SkillMoveTests() }

    func section(_ heading: String, in url: URL) throws -> InstructionSection {
        try #require(InstructionText.units(String(decoding: try Data(contentsOf: url), as: UTF8.self)).first { $0.heading == heading })
    }

    func toGlobal(_ heading: String, in file: URL, brain: Brain) throws -> InstructionMove.GlobalPlan {
        try InstructionMove.toGlobal(try section(heading, in: file), from: file, level: .project, brain: brain, rendered: [], env: f.env)
    }

    @Test func toGlobalRendersTheCoreBlocksBeforeTheProjectLosesTheSection() async throws {
        try move.harnesses()
        let brain = try await f.setUpBrain()
        try f.write("Projects/task/AGENTS.md", "## Commits\nShort lines.\n\n## Style\nTabs.\n")
        let file = f.project.appending(path: "AGENTS.md")
        let plan = try toGlobal("Commits", in: file, brain: brain)
        #expect(plan.core.layer == "core" && plan.removal.file == file)

        try await InstructionMove.commit(plan, brain: brain, env: f.env)
        #expect(f.read("AGENTS.md")?.contains("## Commits") == true, "step 1 changes only the brain")
        let blocks = InstructionMove.blocks(for: plan, project: f.project, context: move.context(), brainRoot: f.brainRoot)
        #expect(blocks.canRemove, "\(blocks.uncovered) \(blocks.warnings)")
        #expect(Set(blocks.diffs.map(\.path)) == ["~/.claude/CLAUDE.md", "~/.pi/agent/AGENTS.md"])

        var held: [String] = []
        try await InstructionMove.finish(plan, blocks: blocks, removeSource: true, project: f.project, context: move.context(),
                                         trash: f.trash, hold: { id, work in
            held.append(id)
            return try await work()
        })
        #expect(held == [move.homeID])
        let claude = try #require(f.read(".claude/CLAUDE.md", in: f.home))
        #expect(claude.contains(InstructionText.akitStart) && claude.contains("## Commits\nShort lines."))
        #expect(f.read("AGENTS.md") == "## Style\nTabs.\n")
        // Only the blocks changed in the home folder: no skills were rendered there.
        #expect(!FileManager.default.fileExists(atPath: f.home.appending(path: ".agents/skills/tdd").path))
    }

    @Test func aReaderWithoutACoreBlockKeepsTheProjectCopy() async throws {
        try move.harnesses()
        let brain = try await f.setUpBrain()
        // Claude Code and Pi both read the project's CLAUDE.md; the home render goes to Pi only.
        try f.write("Projects/task/CLAUDE.md", "## Commits\nShort lines.\n")
        let file = f.project.appending(path: "CLAUDE.md")
        let plan = try toGlobal("Commits", in: file, brain: brain)
        try await InstructionMove.commit(plan, brain: brain, env: f.env)
        var context = move.context()
        context.targets = ["pi"]
        let blocks = InstructionMove.blocks(for: plan, project: f.project, context: context, brainRoot: f.brainRoot)
        #expect(blocks.uncovered == [.claudeCode] && !blocks.canRemove)
        await #expect(throws: InstructionMove.Failure.self) {
            try await InstructionMove.finish(plan, blocks: blocks, removeSource: true, project: f.project, context: context, trash: f.trash,
                                             hold: { _, work in try await work() })
        }
        #expect(f.read("CLAUDE.md") == "## Commits\nShort lines.\n")
        #expect(f.read(".pi/agent/AGENTS.md", in: f.home)?.contains("## Commits") == true)
    }

    @Test func toGlobalStopsBeforeTheCommitWhenTheFileChanged() async throws {
        try move.harnesses()
        let brain = try await f.setUpBrain()
        try f.write("Projects/task/AGENTS.md", "## Commits\nShort lines.\n")
        let file = f.project.appending(path: "AGENTS.md")
        let plan = try toGlobal("Commits", in: file, brain: brain)
        try f.write("Projects/task/AGENTS.md", "## Commits\nLong lines.\n")
        let head = try await f.git("rev-parse", "HEAD", in: f.brainRoot)
        await #expect(throws: InstructionMove.Failure.self) { try await InstructionMove.commit(plan, brain: brain, env: f.env) }
        #expect(try await f.git("rev-parse", "HEAD", in: f.brainRoot) == head)
    }

    @Test func toProjectsAppendsToTheFileTheReadersReadThenTheGlobalFileLosesIt() throws {
        try move.harnesses()
        try f.write(".claude/CLAUDE.md", "## Commits\nShort lines.\n\n## Mine\nx\n")
        try f.write("Projects/one/CLAUDE.md", "## A\r\na\r\n")
        try FileManager.default.createDirectory(at: f.home.appending(path: "Projects/two"), withIntermediateDirectories: true)
        try f.write("Projects/three/AGENTS.md", "## Commits\nShort lines.\n")
        // Claude Code reads CLAUDE.md here, not AGENTS.md (a CLAUDE.md exists).
        try f.write("Projects/four/AGENTS.md", "## B\nb\n")
        try f.write("Projects/four/CLAUDE.md", "## C\nc\n")
        let global = f.home.appending(path: ".claude/CLAUDE.md")
        let projects = ["one", "two", "three", "four"].map { f.home.appending(path: "Projects/\($0)") }
        let plan = try InstructionMove.toProjects(try section("Commits", in: global), from: global, level: .global, projects: projects,
                                                  rendered: [], env: f.env)
        #expect(plan.writes.map { $0.file.deletingLastPathComponent().lastPathComponent + "/" + $0.file.lastPathComponent }
                == ["one/CLAUDE.md", "two/CLAUDE.md", "four/CLAUDE.md"])
        #expect(plan.writes.map(\.created) == [false, true, false])
        #expect(plan.notes.contains { $0.contains("three/AGENTS.md has the section already") })
        try InstructionMove.apply(plan, env: f.env)
        #expect(f.read("Projects/one/CLAUDE.md", in: f.home) == "## A\r\na\r\n\r\n## Commits\r\nShort lines.\r\n")
        #expect(f.read("Projects/two/CLAUDE.md", in: f.home) == "## Commits\nShort lines.\n")
        #expect(f.read("Projects/four/AGENTS.md", in: f.home) == "## B\nb\n")
        #expect(f.read(".claude/CLAUDE.md", in: f.home) == "## Mine\nx\n")
    }

    @Test func projectsSharingAFileThroughLinksWriteItOnce() throws {
        try move.harnesses()
        try f.write(".claude/CLAUDE.md", "## Commits\nShort lines.\n")
        try f.write("shared/CLAUDE.md", "## S\ns\n")
        for name in ["one", "two"] {
            try FileManager.default.createDirectory(at: f.home.appending(path: "Projects/\(name)"), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: f.home.appending(path: "Projects/\(name)/CLAUDE.md").path,
                                                       withDestinationPath: f.home.appending(path: "shared/CLAUDE.md").path)
        }
        let global = f.home.appending(path: ".claude/CLAUDE.md")
        let plan = try InstructionMove.toProjects(try section("Commits", in: global), from: global, level: .global,
                                                  projects: ["one", "two"].map { f.home.appending(path: "Projects/\($0)") }, rendered: [], env: f.env)
        #expect(plan.writes.count == 1)
        try InstructionMove.apply(plan, env: f.env)
        #expect(f.read("shared/CLAUDE.md", in: f.home) == "## S\ns\n\n## Commits\nShort lines.\n")
    }

    @Test func aRenderedProjectIsNoTargetAndAChangedFileWritesNothing() throws {
        try move.harnesses()
        try f.write(".claude/CLAUDE.md", "## Commits\nShort lines.\n")
        try f.write("Projects/one/AGENTS.md", "# Rendered\n")
        let one = f.home.appending(path: "Projects/one")
        let global = f.home.appending(path: ".claude/CLAUDE.md")
        let target = InstructionMove.target(one, source: global, rendered: [InstructionEdit.realPath(one.appending(path: "AGENTS.md"))], env: f.env)
        #expect(target.file == nil && target.reason?.contains("Import to Brain") == true)

        let plan = try InstructionMove.toProjects(try section("Commits", in: global), from: global, level: .global, projects: [one],
                                                  rendered: [], env: f.env)
        try f.write(".claude/CLAUDE.md", "## Commits\nShort lines.\n\n## New\nn\n")
        #expect(throws: InstructionMove.Failure.self) { try InstructionMove.apply(plan, env: f.env) }
        #expect(f.read("Projects/one/AGENTS.md", in: f.home) == "# Rendered\n")
    }

    @Test func aNewFileIsOneEveryReaderWouldRead() throws {
        try move.harnesses()
        // OpenCode installed too: it reads ~/.claude/CLAUDE.md as its global fallback.
        try FileManager.default.createDirectory(at: f.home.appending(path: ".config/opencode"), withIntermediateDirectories: true)
        try f.write(".claude/CLAUDE.md", "## Commits\nShort lines.\n")
        let empty = f.home.appending(path: "Projects/empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let target = InstructionMove.target(empty, source: f.home.appending(path: ".claude/CLAUDE.md"), rendered: [], env: f.env)
        #expect(target.file?.lastPathComponent == "CLAUDE.md", "\(target.reason ?? "")")
        #expect(InstructionMove.wouldRead("CLAUDE.md", .codex, InstructionView(harness: .codex, project: empty, entries: [])) == false)
    }
}
