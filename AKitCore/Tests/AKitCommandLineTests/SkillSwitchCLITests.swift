import AKitCommandLine
import AKitFoundation
import Foundation
import Testing

/// `akit skills state` and `akit skills set` in a temporary fake home.
struct SkillSwitchCLITests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-switch-cli-\(UUID().uuidString)")
        try fm.createDirectory(at: home.appending(path: ".pi/agent"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appending(path: ".agents/skills/tdd"), withIntermediateDirectories: true)
        try Data("---\nname: tdd\ndescription: Tests first\n---\n".utf8).write(to: home.appending(path: ".agents/skills/tdd/SKILL.md"))
        try fm.createDirectory(at: home.appending(path: ".claude"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: home.appending(path: ".claude/skills"), withDestinationURL: home.appending(path: ".agents/skills"))
        try Data("{\n  \"model\": \"opus\"\n}\n".utf8).write(to: home.appending(path: ".claude/settings.json"))
    }

    func akit(_ arguments: String...) async -> (code: Int32, out: String, err: String) {
        var out: [String] = []
        var err: [String] = []
        let code = await AKitCLI.run(arguments, env: HarnessEnvironment(homeDirectory: home), cwd: home,
                                     projectsRoot: home.appending(path: "Projects"),
                                     out: { out.append($0) }, err: { err.append($0) })
        return (code, out.joined(separator: "\n"), err.joined(separator: "\n"))
    }

    func settings() throws -> String { try String(contentsOf: home.appending(path: ".claude/settings.json"), encoding: .utf8) }

    @Test func setShowsTheChangeThenWritesWithYes() async throws {
        let preview = await akit("skills", "set", "tdd", "--harness", "claude", "--state", "manual")
        #expect(preview.code == 0)
        #expect(preview.out.contains("tdd in Claude: On → Manual. Changes ~/.claude/settings.json:"))
        #expect(preview.out.contains(#"+     "tdd": "user-invocable-only""#))
        #expect(preview.out.contains("Run again with --yes"))
        #expect(try settings() == "{\n  \"model\": \"opus\"\n}\n")

        let done = await akit("skills", "set", "tdd", "--harness", "claude", "--state", "manual", "--yes")
        #expect(done.code == 0)
        #expect(done.out.contains("A backup is in ~/.akit/backups/"))
        #expect(try settings() == "{\n  \"model\": \"opus\",\n  \"skillOverrides\": {\n    \"tdd\": \"user-invocable-only\"\n  }\n}\n")

        let pi = await akit("skills", "set", "tdd", "--harness", "pi", "--state", "off", "--yes")
        #expect(pi.code == 0)
        let state = await akit("skills", "state", "tdd")
        #expect(state.out.contains("Claude: Manual, Pi: Off"))

        let again = await akit("skills", "set", "tdd", "--harness", "pi", "--state", "off")
        #expect(again.out.contains("already Off"))
    }

    @Test func aSkillMdNameResolvesToTheFolderClaudeUses() async throws {
        try fm.createDirectory(at: home.appending(path: ".agents/skills/deploy-staging"), withIntermediateDirectories: true)
        try Data("---\nname: deploy\ndescription: Deploys\n---\n".utf8).write(to: home.appending(path: ".agents/skills/deploy-staging/SKILL.md"))
        let byName = await akit("skills", "set", "deploy", "--harness", "claude", "--state", "off", "--yes")
        #expect(byName.code == 0)
        #expect(byName.out.contains("Claude knows the skill as deploy-staging (its folder)"))
        #expect(try settings().contains(#""deploy-staging": "off""#))
        let state = await akit("skills", "state", "deploy-staging")
        #expect(state.out.contains("Claude: Off (as deploy-staging)"))
        let byFolder = await akit("skills", "set", "deploy-staging", "--harness", "claude", "--state", "on", "--yes")
        #expect(byFolder.code == 0)
        #expect(try settings() == "{\n  \"model\": \"opus\"\n}\n")
    }

    @Test func refusesStatesAHarnessDoesntHaveAndUnknownSkills() async {
        #expect(await akit("skills", "set", "tdd", "--harness", "pi", "--state", "name-only").err.contains("offers On, Off"))
        #expect(await akit("skills", "set", "nope", "--harness", "claude", "--state", "off").err.contains("No skill named nope"))
        #expect(await akit("skills", "set", "tdd", "--harness", "codex", "--state", "off").err.contains("--harness is claude or pi"))
        #expect(await akit("skills", "set", "tdd", "--harness", "claude", "--state", "maybe").err.contains("--state is on"))
        #expect(await akit("skills", "state", "--yes").code != 0)
    }
}
