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

    @Test func toGlobalRendersTheCoreBlockBeforeTheProjectLosesTheSection() async throws {
        try move.harnesses()
        let brain = try await f.setUpBrain()
        try f.write("Projects/task/AGENTS.md", "## Commits\nShort lines.\n\n## Style\nTabs.\n")
        let file = f.project.appending(path: "AGENTS.md")
        let plan = try InstructionMove.toGlobal(try section("Commits", in: file), from: file, level: .project, brain: brain, rendered: [], env: f.env)
        #expect(plan.core.layer == "core" && plan.removal.file == file)

        var held: [String] = []
        try await InstructionMove.apply(plan, brain: brain, context: move.context(), trash: f.trash, hold: { id, work in
            held.append(id)
            return try await work()
        })
        #expect(held == [move.homeID])
        let claude = try #require(f.read(".claude/CLAUDE.md", in: f.home))
        #expect(claude.contains(InstructionText.akitStart) && claude.contains("## Commits\nShort lines."))
        #expect(f.read("AGENTS.md") == "## Style\nTabs.\n")
        #expect(try await f.git("log", "-1", "--format=%s", in: f.brainRoot) .contains("core"))
        // Only the blocks changed in the home folder: no skills were rendered there.
        #expect(!FileManager.default.fileExists(atPath: f.home.appending(path: ".agents/skills/tdd").path))
    }

    @Test func toGlobalStopsBeforeTheCommitWhenTheFileChanged() async throws {
        try move.harnesses()
        let brain = try await f.setUpBrain()
        try f.write("Projects/task/AGENTS.md", "## Commits\nShort lines.\n")
        let file = f.project.appending(path: "AGENTS.md")
        let plan = try InstructionMove.toGlobal(try section("Commits", in: file), from: file, level: .project, brain: brain, rendered: [], env: f.env)
        try f.write("Projects/task/AGENTS.md", "## Commits\nLong lines.\n")
        let head = try await f.git("rev-parse", "HEAD", in: f.brainRoot)
        await #expect(throws: InstructionMove.Failure.self) { try await InstructionMove.apply(plan, brain: brain, context: move.context()) }
        #expect(try await f.git("rev-parse", "HEAD", in: f.brainRoot) == head)
    }

    @Test func toProjectsAppendsToEachOwnFileThenTheGlobalFileLosesIt() throws {
        try f.write(".claude/CLAUDE.md", "## Commits\nShort lines.\n\n## Mine\nx\n")
        try f.write("Projects/one/CLAUDE.md", "## A\r\na\r\n")
        try FileManager.default.createDirectory(at: f.home.appending(path: "Projects/two"), withIntermediateDirectories: true)
        try f.write("Projects/three/AGENTS.md", "## Commits\nShort lines.\n")
        let global = f.home.appending(path: ".claude/CLAUDE.md")
        let projects = ["one", "two", "three"].map { f.home.appending(path: "Projects/\($0)") }
        let plan = try InstructionMove.toProjects(try section("Commits", in: global), from: global, level: .global, projects: projects,
                                                  rendered: [], env: f.env)
        #expect(plan.writes.map(\.file.lastPathComponent) == ["CLAUDE.md", "AGENTS.md"] && plan.writes.map(\.created) == [false, true])
        #expect(plan.notes.contains { $0.contains("three/AGENTS.md has the section already") })
        try InstructionMove.apply(plan, env: f.env)
        #expect(f.read("Projects/one/CLAUDE.md", in: f.home) == "## A\r\na\r\n\r\n## Commits\r\nShort lines.\r\n")
        #expect(f.read("Projects/two/AGENTS.md", in: f.home) == "## Commits\nShort lines.\n")
        #expect(f.read("Projects/three/AGENTS.md", in: f.home) == "## Commits\nShort lines.\n")
        #expect(f.read(".claude/CLAUDE.md", in: f.home) == "## Mine\nx\n")
    }

    @Test func aRenderedProjectIsNoTargetAndAChangedFileWritesNothing() throws {
        try f.write(".claude/CLAUDE.md", "## Commits\nShort lines.\n")
        try f.write("Projects/one/AGENTS.md", "# Rendered\n")
        let one = f.home.appending(path: "Projects/one")
        let target = InstructionMove.target(one, rendered: [InstructionEdit.realPath(one.appending(path: "AGENTS.md"))])
        #expect(target.file == nil && target.reason?.contains("Import to Brain") == true)

        let global = f.home.appending(path: ".claude/CLAUDE.md")
        let plan = try InstructionMove.toProjects(try section("Commits", in: global), from: global, level: .global, projects: [one],
                                                  rendered: [], env: f.env)
        try f.write(".claude/CLAUDE.md", "## Commits\nShort lines.\n\n## New\nn\n")
        #expect(throws: InstructionMove.Failure.self) { try InstructionMove.apply(plan, env: f.env) }
        #expect(f.read("Projects/one/AGENTS.md", in: f.home) == "# Rendered\n")
    }
}
