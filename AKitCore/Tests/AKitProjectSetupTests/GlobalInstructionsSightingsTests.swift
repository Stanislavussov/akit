import Foundation
import Testing
import AKitFoundation
import AKitHarnesses
import AKitModel
@testable import AKitSessions
@testable import AKitProjectSetup

/// Global Instructions → Loaded in Sessions: the files recorded sessions loaded, against the
/// global files AKit looks at. A fake home with one Claude Code and one Pi session.
struct GlobalInstructionsSightingsTests {
    let move: SkillMoveTests
    var f: GitProjectFixture { move.f }

    init() throws { move = try SkillMoveTests() }

    func json(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    /// Pi read its global file from `~/work-pi` (a PI_CODING_AGENT_DIR the app doesn't see),
    /// Claude Code its usual one; both read the project's file.
    func sessions() throws {
        try move.harnesses()
        try f.write(".claude/CLAUDE.md", "## Claude\n")
        try f.write("work-pi/AGENTS.md", "## Work rules\nBe brief.\n")
        try f.write("Projects/task/AGENTS.md", "## Task\n")
        let home = f.home.path, project = f.project.path
        let context = """
            <project_context>
            Project-specific instructions and guidelines:

            <project_instructions path="\(home)/work-pi/AGENTS.md">
            ## Work rules
            </project_instructions>

            <project_instructions path="\(project)/AGENTS.md">
            ## Task
            </project_instructions>
            </project_context>
            """
        let pi = try [
            json(["type": "session", "version": 3, "id": "p1", "timestamp": "2026-10-30T10:00:00.000Z", "cwd": project]),
            json(["type": "message", "id": "m1", "timestamp": "2026-10-30T10:00:01.000Z",
                  "message": ["role": "system", "sections": ["project_context": context, "cwd": project]]]),
        ].joined(separator: "\n") + "\n"
        try f.write(".pi/agent/sessions/--x--/2026-10-30T10-00-00-000Z_p1.jsonl", pi)
        let claude = try [
            json(["type": "user", "cwd": project, "sessionId": "c1", "timestamp": "2026-10-30T10:00:00.000Z",
                  "message": ["role": "user", "content": "hi"]]),
            json(["type": "attachment", "cwd": project, "sessionId": "c1", "timestamp": "2026-10-30T10:00:00.000Z",
                  "attachment": ["type": "instructions", "files": [
                      ["path": "\(home)/.claude/CLAUDE.md", "type": "User", "content": "## Claude\n"],
                      ["path": "\(home)/.claude/projects/x/memory/MEMORY.md", "type": "AutoMem", "content": "- note\n"],
                      ["path": "\(project)/AGENTS.md", "type": "Project", "content": "## Task\n"],
                  ]]]),
        ].joined(separator: "\n") + "\n"
        try f.write(".claude/projects/-x/c1.jsonl", claude)
    }

    @Test func sessionsShowEachLoadedFileAndAGlobalFileAKitDoesNotLookAt() throws {
        try sessions()
        let seen = GlobalInstructions.sightings(env: f.env)
        let global = seen.report.global.map { URL(filePath: $0.path).lastPathComponent + ":" + $0.harnesses.map(\.rawValue).joined() }
        #expect(Set(global) == ["CLAUDE.md:\(HarnessID.claudeCode.rawValue)", "AGENTS.md:\(HarnessID.pi.rawValue)"])
        // Claude's auto memory isn't an instruction file.
        #expect(!seen.report.sightings.contains { $0.path.hasSuffix("MEMORY.md") })
        let projects = seen.report.byProject
        #expect(projects.count == 1 && projects.first?.files.first?.sessions == 2)
        #expect(projects.first?.files.first?.file.harnesses.count == 2)

        let claude = try #require(seen.report.global.first { $0.harnesses == [.claudeCode] })
        let pi = try #require(seen.report.global.first { $0.harnesses == [.pi] })
        #expect(seen.isKnown(claude) && !seen.isKnown(pi))
        #expect(seen.notes.contains { $0.contains("Pi loaded ~/work-pi/AGENTS.md") && $0.contains("PI_CODING_AGENT_DIR") })
    }

    @Test func aPiFolderOnlyTheShellSetsIsWhereTheSessionsAreRead() throws {
        try sessions()
        let file = ".pi/agent/sessions/--x--/2026-10-30T10-00-00-000Z_p1.jsonl"
        let text = try #require(f.read(file, in: f.home))
        try FileManager.default.removeItem(at: f.home.appending(path: file))
        try f.write("work-pi/sessions/--x--/2026-10-30T10-00-00-000Z_p1.jsonl", text)
        #expect(GlobalInstructions.sightings(env: f.env).notes.contains { $0.contains("no Pi sessions") })
        let seen = GlobalInstructions.sightings(env: f.env, shell: ["PI_CODING_AGENT_DIR": f.home.path + "/work-pi"])
        #expect(seen.report.read[.pi] == 1)
        #expect(seen.notes.first?.contains("Your shell sets PI_CODING_AGENT_DIR") == true)
        let pi = try #require(seen.report.global.first { $0.harnesses == [.pi] })
        #expect(!seen.isKnown(pi))
    }

    @Test func oldSessionsAndGoneFoldersAreLeftOut() throws {
        try sessions()
        let later = Date.now.addingTimeInterval(40 * 86_400)
        let installations = HarnessCatalog.detectAll(in: f.env)
        let all = SessionScanner.scan(installations: installations, in: f.env)
        #expect(InstructionSightings.scan(all, days: 30, now: later).sightings.isEmpty)
        try FileManager.default.removeItem(at: f.project)
        #expect(InstructionSightings.scan(all, days: 30).sightings.isEmpty)
    }

    @Test func useAsCoreTextTakesOnlyTheUsersOwnSections() throws {
        try f.write("x/AGENTS.md", "<!-- OMC:START -->\n## Setup\n<!-- OMC:END -->\n\n## Mine\nShort.\n")
        #expect(GlobalInstructions.ownText(of: f.home.appending(path: "x/AGENTS.md")) == "## Mine\nShort.")
        #expect(GlobalInstructions.ownText(of: f.home.appending(path: "missing.md")) == nil)
    }

    @Test func aPiFileAboveTheSessionFolderIsAProjectFile() {
        let cwd = URL(filePath: "/u/me/Projects/app")
        #expect(InstructionSightings.isAbove("/u/me/Projects/app/AGENTS.md", cwd: cwd))
        #expect(InstructionSightings.isAbove("/u/me/AGENTS.md", cwd: cwd))
        #expect(!InstructionSightings.isAbove("/u/me/.pi/agent/AGENTS.md", cwd: cwd))
        #expect(!InstructionSightings.isAbove("/u/me/Projects/application/AGENTS.md", cwd: URL(filePath: "/u/me/Projects/app")))
    }
}
