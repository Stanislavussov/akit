import Foundation
import Testing
import AKitFoundation
@testable import AKitSkills

/// Port to Pi: the deterministic pass and the check, on a made-up skill shaped like OMC's
/// deep-interview, in a temporary fake home.
struct SkillPortTests {
    let home: URL
    let fm = FileManager.default

    /// A small made-up skill in the shape of an OMC interview skill: Claude-only frontmatter,
    /// a subagent call, a question tool, state tools, a handoff and a score gate.
    static let interview = """
        ---
        name: interview
        description: Ask questions until the ambiguity score is below 0.2
        argument-hint: "<idea>"
        allowed-tools:
          - Read
          - AskUserQuestion
        model: opus
        ---

        # Interview

        [MAGIC KEYWORD: interview]

        ## Phase 1: Ask

        Use AskUserQuestion with 4 options. Keep the plan in .omc/state/interview.json via state_write.
        Read the spec with the Read tool, then run Grep tool on src. Call Read("spec.md") first.

        ## Phase 2: Gate

        Stop when ambiguity is at most 0.2 or after 12 rounds.
        Agent(subagent_type="oh-my-claudecode:critic", model="opus", prompt="review")
        Then hand off to /oh-my-claudecode:ralplan and see references/rubric.md.
        Skills live in ~/.claude/skills and .claude/skills.
        """

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-port-\(UUID().uuidString)")
        try write(".claude/skills/interview/SKILL.md", Self.interview)
        try write(".claude/skills/interview/references/rubric.md", "Score 0.2 means clear. Write it to .omc/notes.md.\n")
        try write(".claude/skills/interview/scripts/run.sh", "#!/bin/sh\ncat .omc/state/x.json\n")
        try write(".claude/plugins/cache/omc/oh-my-claudecode/4.1.0/agents/critic.md", "---\nname: critic\n---\nYou are Critic. Find flaws.\n")
    }

    var env: HarnessEnvironment { HarnessEnvironment(homeDirectory: home) }
    var source: URL { home.appending(path: ".claude/skills/interview") }

    func write(_ path: String, _ text: String) throws {
        let url = home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test func frontmatterKeepsOnlyPiFields() {
        let result = SkillPort.portFrontmatter(Self.interview)
        #expect(result.dropped == ["argument-hint", "allowed-tools", "model"])
        let header = result.text.components(separatedBy: "\n").prefix(4).joined(separator: "\n")
        #expect(header == "---\nname: interview\ndescription: Ask questions until the ambiguity score is below 0.2\n---")
        // Nothing to drop: the text stays byte for byte.
        #expect(SkillPort.portFrontmatter("---\nname: a\ndescription: b\n---\nBody").text == "---\nname: a\ndescription: b\n---\nBody")
        #expect(SkillPort.portFrontmatter("No header").text == "No header")
    }

    @Test func replacesCommandsPathsAndToolNames() {
        let text = SkillPort.transform(Self.interview, path: "SKILL.md").text
        #expect(text.contains("/skill:ralplan"))
        #expect(text.contains("~/.pi/agent/skills and .pi/skills."))
        #expect(text.contains(".pi/state/interview.json"))
        #expect(text.contains("with the `read` tool"))
        #expect(text.contains("run `grep` command via the `bash` tool on src"))
        #expect(text.contains("Call read(\"spec.md\")"))
        // URLs and ports are not commands.
        #expect(SkillPort.transform("See https://example.com:8080/x", path: "a.md").text == "See https://example.com:8080/x")
        // Tool names stay in scripts; paths change everywhere.
        #expect(SkillPort.transform("Read( .omc/x", path: "run.sh").text == "Read( .pi/state/x")
        // A second run changes nothing.
        #expect(SkillPort.transform(text, path: "SKILL.md").text == text)
    }

    @Test func portCopiesRolePromptsAndKeepsFiles() throws {
        let draft = try SkillPort.port(folder: source, env: env)
        #expect(draft.name == "interview")
        #expect(draft.roles == ["critic"])
        #expect(draft.texts["references/critic.md"]?.contains("You are Critic") == true)
        #expect(draft.texts["scripts/run.sh"] == "#!/bin/sh\ncat .pi/state/x.json\n")
        #expect(draft.texts["references/rubric.md"]?.contains(".pi/state/notes.md") == true)
        #expect(draft.changes.contains { $0.hasPrefix("Frontmatter: dropped argument-hint, allowed-tools, model") })
        #expect(draft.changes.contains("Copied role prompts into references/: critic.md"))
    }

    @Test func roleFromThePluginTheSkillIsIn() throws {
        try write("plugins/omc/skills/x/SKILL.md", "---\nname: x\ndescription: d\n---\nUse the planner.\n")
        try write("plugins/omc/agents/planner.md", "Own planner\n")
        let folder = home.appending(path: "plugins/omc/skills/x")
        #expect(SkillPort.roleFile("planner", near: folder, env: env)?.lastPathComponent == "planner.md")
        #expect(try SkillPort.port(folder: folder, env: env).texts["references/planner.md"] == "Own planner\n")
        #expect(SkillPort.roleFile("nobody", near: folder, env: env) == nil)
    }

    @Test func lintFindsEachLeftover() {
        let lines = [
            "Agent(x)", "subagent_type", "AskUserQuestion", "TodoWrite", "TaskCreate", "mcp__x", "Skill(\"a\")",
            "state_read", "notepad_write", "model = opus", "/oh-my-claudecode:x", "~/.claude/CLAUDE.md", ".omc/x", "[MAGIC KEYWORD: x]",
        ]
        let hits = SkillPortCheck.lint(["SKILL.md": lines.joined(separator: "\n")])
        #expect(hits.map(\.rule) == SkillPortCheck.rules.map(\.id))
        #expect(hits.map(\.line) == Array(1...lines.count))
        #expect(SkillPortCheck.lint(["a.md": "read the file, ask the user, model it"]).isEmpty)
    }

    @Test func draftCheckWarnsAboutLeftoversOnly() throws {
        let draft = try SkillPort.port(folder: source, env: env)
        let report = SkillPortCheck.check(draft)
        #expect(report.problems.isEmpty)
        #expect(report.verdict == .warnings)
        let rules = Set(report.hits.map(\.rule))
        #expect(rules.isSuperset(of: ["AskUserQuestion", "Agent(", "subagent_type", "state_write/state_read", "[MAGIC KEYWORD", "model="]))
        #expect(!rules.contains(".omc/") && !rules.contains("/oh-my-claudecode:"))
        #expect(report.missingNumbers.isEmpty && report.missingHeadings.isEmpty)
    }

    @Test func structureNeedsNameDescriptionAndFiles() {
        func problems(_ skill: String, folder: String = "good", paths: Set<String> = ["SKILL.md"]) -> [String] {
            SkillPortCheck.structure(folderName: folder, texts: ["SKILL.md": skill], paths: paths)
        }
        #expect(problems("---\nname: good\ndescription: d\n---\n").isEmpty)
        #expect(problems("No header").first?.contains("no frontmatter") == true)
        #expect(problems("---\nname: good\n---\n").contains { $0.contains("no description") })
        #expect(problems("---\nname: Bad_Name\ndescription: d\n---\n", folder: "Bad_Name").contains { $0.contains("a-z, 0-9") })
        #expect(problems("---\nname: other\ndescription: d\n---\n").contains { $0.contains("not the folder's name") })
        let long = String(repeating: "x", count: 1025)
        #expect(problems("---\nname: good\ndescription: \(long)\n---\n").contains { $0.contains("1025 characters") })
        let missing = problems("---\nname: good\ndescription: d\n---\nSee references/a.md, scripts/run.sh and references/<role>.md.",
                               paths: ["SKILL.md", "scripts/run.sh"])
        #expect(missing == ["SKILL.md names references/a.md, which is not in the port."])
    }

    @Test func meaningReportsLostNumbersAndHeadings() {
        let original = ["SKILL.md": "---\nname: a\nmodel: 4\n---\n# A\n## Gate\nAt most 0.2, 12 rounds, 80%.\n```\n# not a heading\n```\n",
                        "references/r.md": "## R\nKeep 3."]
        let ported = ["SKILL.md": "---\nname: a\n---\n# A\nAt most 0.3, 12 rounds.\n", "references/r.md": "Keep 3."]
        let result = SkillPortCheck.meaning(original: original, ported: ported)
        // The header's numbers don't count: dropped fields are not the skill's meaning.
        #expect(result.numbers == ["0.2", "80%"])
        #expect(result.headings == ["## Gate", "## R (references/r.md)"])
    }

    @Test func checkOnlyReadsAFolder() throws {
        try write("pi/good/SKILL.md", "---\nname: good\ndescription: d\n---\nRead the file.\n")
        #expect(try SkillPortCheck.check(folder: home.appending(path: "pi/good")).verdict == .pass)
        try write("pi/bad/SKILL.md", "---\nname: good\n---\nAskUserQuestion\n")
        let report = try SkillPortCheck.check(folder: home.appending(path: "pi/bad"))
        #expect(report.verdict == .fail)
        #expect(report.hits.map(\.rule) == ["AskUserQuestion"])
    }

    @Test func installPreviewsThenTrashesTheOldFolder() throws {
        let draft = try SkillPort.port(folder: source, env: env)
        let fresh = SkillPort.plan(draft, target: .global, env: env)
        #expect(fresh.folder.path.hasSuffix(".pi/agent/skills/interview"))
        #expect(!fresh.replaces && fresh.changed.contains("SKILL.md"))
        try SkillPort.install(draft, plan: fresh, trash: { _ in Issue.record("nothing to trash"); return nil })
        #expect(try String(contentsOf: fresh.folder.appending(path: "SKILL.md"), encoding: .utf8) == draft.skillText)
        #expect(fm.fileExists(atPath: fresh.folder.appending(path: "references/critic.md").path))
        // A stale plan is refused.
        #expect(throws: SkillPort.Failure.self) { try SkillPort.install(draft, plan: fresh) }

        var changed = draft
        changed.texts["SKILL.md"] = draft.skillText + "\nMore.\n"
        let again = SkillPort.plan(changed, target: .global, env: env)
        #expect(again.replaces && again.changed == ["SKILL.md"])
        #expect(again.diff.contains(.added("More.")))
        let trashFolder = home.appending(path: "Trash")
        try SkillPort.install(changed, plan: again, trash: { url in
            try fm.createDirectory(at: trashFolder, withIntermediateDirectories: true)
            let to = trashFolder.appending(path: url.lastPathComponent)
            try fm.moveItem(at: url, to: to)
            return to
        })
        #expect(fm.fileExists(atPath: trashFolder.appending(path: "interview/SKILL.md").path))
        #expect(try String(contentsOf: again.folder.appending(path: "SKILL.md"), encoding: .utf8).hasSuffix("More.\n"))
        let project = home.appending(path: "Projects/app")
        #expect(SkillPort.folder(for: .project(project), name: "x", env: env).path == project.appending(path: ".pi/skills/x").path)
    }
}
