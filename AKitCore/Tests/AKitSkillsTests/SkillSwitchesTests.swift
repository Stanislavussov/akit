import Foundation
import Testing
import AKitFoundation
import AKitModel
@testable import AKitHarnesses
@testable import AKitSkills

/// Skill switches in a temporary fake home: Claude Code's `skillOverrides` and Pi's `skills`
/// entries. Never touches the real settings.
struct SkillSwitchesTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-switches-\(UUID().uuidString)")
        try fm.createDirectory(at: home.appending(path: ".claude"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appending(path: ".pi/agent"), withIntermediateDirectories: true)
    }

    var env: HarnessEnvironment { HarnessEnvironment(homeDirectory: home) }
    var claudeSettings: URL { home.appending(path: ".claude/settings.json") }
    var piSettings: URL { home.appending(path: ".pi/agent/settings.json") }

    func write(_ path: String, _ text: String) throws {
        let url = home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    func skill(_ name: String, extra: String = "") -> String {
        "---\nname: \(name)\ndescription: Does \(name)\n\(extra)---\n\n# \(name)\n"
    }

    /// A shared skill both harnesses see, as on this Mac: `~/.claude/skills` links to `~/.agents/skills`.
    func shared(_ name: String, extra: String = "") throws -> Skill {
        try write(".agents/skills/\(name)/SKILL.md", skill(name, extra: extra))
        if !fm.fileExists(atPath: home.appending(path: ".claude/skills").path) {
            try fm.createSymbolicLink(at: home.appending(path: ".claude/skills"), withDestinationURL: home.appending(path: ".agents/skills"))
        }
        return try #require(scan().first { $0.name == name })
    }

    func scan(extraProjects: [URL] = []) -> [Skill] {
        SkillScanner.scan(installations: HarnessCatalog.detectAll(in: env), extraProjects: extraProjects, in: env)
    }

    func state(_ skill: Skill, _ harness: HarnessID) -> SkillSwitchState? {
        SkillSwitches.states(of: [skill], in: env)[skill.id]?[harness]
    }

    // MARK: - Reading

    @Test func readsClaudeOverridesAndPiEntries() throws {
        let tdd = try shared("tdd")
        #expect(tdd.visibleTo == [.claudeCode, .pi])
        #expect(tdd.places[.pi]?.relativePath == "skills/tdd/SKILL.md")
        #expect(state(tdd, .claudeCode) == .on)
        #expect(state(tdd, .pi) == .on)

        try write(".claude/settings.json", #"{"skillOverrides": {"tdd": "user-invocable-only", "other": "off"}}"#)
        try write(".pi/agent/settings.json", #"{"skills": ["-skills/tdd/SKILL.md"]}"#)
        #expect(state(tdd, .claudeCode) == .manual)
        #expect(state(tdd, .pi) == .off)

        // Pi's own rules: `!` by glob (here the folder name), `+` back on, `-` wins over `+`.
        for (entries, expected) in [(#"["!tdd"]"#, SkillSwitchState.off), (#"["!t*"]"#, .off), (#"["!*/tdd"]"#, .off),
                                    (#"["!tdd", "+skills/tdd/SKILL.md"]"#, .on), (#"["!tdd", "+./skills/tdd"]"#, .on),
                                    (#"["+skills/tdd", "-skills/tdd"]"#, .off), (#"["!other", "-skills/td"]"#, .on),
                                    (#"["extra/folder", "*.md"]"#, .on)] {
            try write(".pi/agent/settings.json", "{\"skills\": \(entries)}")
            #expect(state(tdd, .pi) == expected, "\(entries)")
        }
    }

    @Test func modelInvocationOffMeansManualAtMostInClaude() throws {
        let quiet = try shared("quiet", extra: "disable-model-invocation: true\n")
        #expect(quiet.disablesModelInvocation)
        #expect(state(quiet, .claudeCode) == .manual)
        #expect(SkillSwitches.options(for: quiet, harness: .claudeCode, in: env)?.states == [.manual, .off])
        try write(".claude/settings.json", #"{"skillOverrides": {"quiet": "off"}}"#)
        #expect(state(quiet, .claudeCode) == .off)
        #expect(throws: SkillSwitches.Failure.self) { try SkillSwitches.plan(quiet, harness: .claudeCode, to: .nameOnly, in: env) }
    }

    @Test func pluginAndPackageSkillsHaveNoSwitch() throws {
        let tdd = try shared("tdd")
        #expect(SkillSwitches.options(for: tdd, harness: .pi, in: env)?.states == [.on, .off])
        let plugin = Skill(name: "p", description: "", file: home.appending(path: "p/SKILL.md"), realFile: home.appending(path: "p/SKILL.md"),
                           isSingleFile: false, scope: .plugin(name: "x"), visibleTo: [.claudeCode], isReadOnly: true,
                           origin: nil, warnings: [], root: home)
        let options = try #require(SkillSwitches.options(for: plugin, harness: .claudeCode, in: env))
        #expect(options.states.isEmpty)
        #expect(options.unavailable?.contains("plugin") == true)
        #expect(SkillSwitches.states(of: [plugin], in: env).isEmpty)
        #expect(throws: SkillSwitches.Failure.self) { try SkillSwitches.plan(plugin, harness: .claudeCode, to: .off, in: env) }
    }

    // MARK: - Claude Code

    @Test func claudeChangeTouchesOnlyItsEntry() throws {
        let tdd = try shared("tdd")
        let original = """
            {
              "env": {
                "API_TOKEN": "sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789"
              },
              "permissions": {"allow": ["Bash(ls)"]},
              "model": "opus"
            }

            """
        try write(".claude/settings.json", original)
        let plan = try SkillSwitches.plan(tdd, harness: .claudeCode, to: .nameOnly, in: env)
        #expect(plan.from == .on && plan.to == .nameOnly)
        // The preview never shows the secret.
        let shown = plan.diff.map { "\($0)" }.joined(separator: "\n")
        #expect(!shown.contains("sk-ant"))
        #expect(plan.diff.contains(.added(#"    "tdd": "name-only""#)))

        let backup = try #require(try SkillSwitches.apply(plan, home: home))
        #expect(try text(backup) == original)
        #expect(backup.path.contains("/.akit/backups/"))
        let written = try text(claudeSettings)
        #expect(written == original.replacingOccurrences(of: "  \"model\": \"opus\"\n",
                                                         with: "  \"model\": \"opus\",\n  \"skillOverrides\": {\n    \"tdd\": \"name-only\"\n  }\n"))
        #expect(state(tdd, .claudeCode) == .nameOnly)

        // Back on: the entry goes, and the empty list with it; the file is as before.
        let back = try SkillSwitches.plan(tdd, harness: .claudeCode, to: .on, in: env)
        try SkillSwitches.apply(back, home: home)
        #expect(try text(claudeSettings) == original)
    }

    @Test func claudeKeepsOtherOverrides() throws {
        let tdd = try shared("tdd")
        try write(".claude/settings.json", "{\n  \"skillOverrides\": {\n    \"review\": \"off\",\n    \"tdd\": \"off\"\n  }\n}\n")
        try SkillSwitches.apply(try SkillSwitches.plan(tdd, harness: .claudeCode, to: .on, in: env), home: home)
        #expect(try text(claudeSettings) == "{\n  \"skillOverrides\": {\n    \"review\": \"off\"\n  }\n}\n")
    }

    @Test func createsAMissingSettingsFileWithoutABackup() throws {
        let tdd = try shared("tdd")
        let plan = try SkillSwitches.plan(tdd, harness: .claudeCode, to: .off, in: env)
        #expect(plan.notes.contains { $0.hasPrefix("Creates") })
        #expect(try SkillSwitches.apply(plan, home: home) == nil)
        #expect(try text(claudeSettings) == "{\n  \"skillOverrides\": {\n    \"tdd\": \"off\"\n  }\n}\n")
    }

    @Test func refusesWhenTheFileChangedSinceThePreview() throws {
        let tdd = try shared("tdd")
        try write(".claude/settings.json", "{\"model\": \"opus\"}\n")
        let plan = try SkillSwitches.plan(tdd, harness: .claudeCode, to: .off, in: env)
        // Claude Code rewrites its settings meanwhile.
        try write(".claude/settings.json", "{\"model\": \"sonnet\"}\n")
        #expect(throws: SkillSwitches.Failure.self) { try SkillSwitches.apply(plan, home: home) }
        #expect(try text(claudeSettings) == "{\"model\": \"sonnet\"}\n")
        #expect(!fm.fileExists(atPath: home.appending(path: ".akit/backups").path))
    }

    @Test func refusesAnInvalidFile() throws {
        let tdd = try shared("tdd")
        try write(".claude/settings.json", "{\"model\": \"opus\", // comment\n}")
        #expect(throws: SkillSwitches.Failure.self) { try SkillSwitches.plan(tdd, harness: .claudeCode, to: .off, in: env) }
    }

    @Test func writesThroughALinkAndKeepsPermissions() throws {
        let tdd = try shared("tdd")
        try write("dotfiles/claude-settings.json", "{}\n")
        let real = home.appending(path: "dotfiles/claude-settings.json")
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: real.path)
        try fm.createSymbolicLink(at: claudeSettings, withDestinationURL: real)
        try SkillSwitches.apply(try SkillSwitches.plan(tdd, harness: .claudeCode, to: .off, in: env), home: home)
        #expect(try fm.destinationOfSymbolicLink(atPath: claudeSettings.path) == real.path)
        #expect(try text(real).contains(#""tdd": "off""#))
        #expect((try fm.attributesOfItem(atPath: real.path)[.posixPermissions] as? Int) == 0o600)
    }

    // MARK: - Pi

    @Test func piAddsAndRemovesOnlyItsEntry() throws {
        let tdd = try shared("tdd")
        let original = "{\n  \"defaultModel\": \"x\",\n  \"skills\": [\n    \"!legacy\",\n    \"~/more-skills\"\n  ],\n  \"packages\": []\n}\n"
        try write(".pi/agent/settings.json", original)
        let plan = try SkillSwitches.plan(tdd, harness: .pi, to: .off, in: env)
        try SkillSwitches.apply(plan, home: home)
        #expect(try text(piSettings) == original.replacingOccurrences(of: "    \"~/more-skills\"\n",
                                                                        with: "    \"~/more-skills\",\n    \"-skills/tdd/SKILL.md\"\n"))
        #expect(state(tdd, .pi) == .off)

        try SkillSwitches.apply(try SkillSwitches.plan(tdd, harness: .pi, to: .on, in: env), home: home)
        #expect(try text(piSettings) == original)
    }

    @Test func piTurnsOnAgainstAGlobWithAPlusEntry() throws {
        let tdd = try shared("tdd")
        try write(".pi/agent/settings.json", "{\"skills\": [\"!t*\"]}\n")
        #expect(state(tdd, .pi) == .off)
        try SkillSwitches.apply(try SkillSwitches.plan(tdd, harness: .pi, to: .on, in: env), home: home)
        #expect(try text(piSettings) == "{\"skills\": [\"!t*\", \"+skills/tdd/SKILL.md\"]}\n")
        #expect(state(tdd, .pi) == .on)
        // Off again: the + entry goes; the glob alone turns it off.
        try SkillSwitches.apply(try SkillSwitches.plan(tdd, harness: .pi, to: .off, in: env), home: home)
        #expect(try text(piSettings) == "{\"skills\": [\"!t*\"]}\n")
    }

    @Test func piWithoutAListGetsOneAndLosesItAgain() throws {
        let tdd = try shared("tdd")
        try write(".pi/agent/settings.json", "{\n  \"theme\": \"dark\"\n}\n")
        try SkillSwitches.apply(try SkillSwitches.plan(tdd, harness: .pi, to: .off, in: env), home: home)
        #expect(try text(piSettings) == "{\n  \"theme\": \"dark\",\n  \"skills\": [\n    \"-skills/tdd/SKILL.md\"\n  ]\n}\n")
        try SkillSwitches.apply(try SkillSwitches.plan(tdd, harness: .pi, to: .on, in: env), home: home)
        #expect(try text(piSettings) == "{\n  \"theme\": \"dark\"\n}\n")
    }

    @Test func piProjectSkillsUseTheProjectsSettings() throws {
        let project = home.appending(path: "Projects/app")
        try fm.createDirectory(at: project.appending(path: ".git"), withIntermediateDirectories: true)
        try write("Projects/app/.agents/skills/lint/SKILL.md", skill("lint"))
        let lint = try #require(scan(extraProjects: [project]).first { $0.name == "lint" })
        #expect(lint.scope == .project(project))
        let options = try #require(SkillSwitches.options(for: lint, harness: .pi, in: env))
        #expect(options.file.path == project.appending(path: ".pi/settings.json").path)
        // The global list doesn't reach a project's own skills.
        try write(".pi/agent/settings.json", "{\"skills\": [\"-skills/lint/SKILL.md\"]}\n")
        #expect(state(lint, .pi) == .on)
        try SkillSwitches.apply(try SkillSwitches.plan(lint, harness: .pi, to: .off, in: env), home: home)
        #expect(try text(project.appending(path: ".pi/settings.json")) == "{\n  \"skills\": [\n    \"-skills/lint/SKILL.md\"\n  ]\n}\n")
        #expect(state(lint, .pi) == .off)
    }

    @Test func noChangeWritesNothing() throws {
        let tdd = try shared("tdd")
        try write(".pi/agent/settings.json", "{\"skills\": [\"-skills/tdd/SKILL.md\"]}")
        let plan = try SkillSwitches.plan(tdd, harness: .pi, to: .off, in: env)
        #expect(plan.changesNothing)
        #expect(try SkillSwitches.apply(plan, home: home) == nil)
        #expect(!fm.fileExists(atPath: home.appending(path: ".akit/backups").path))
    }

    @Test func globSubset() {
        #expect(Glob.matches("*.md", "a.md"))
        #expect(!Glob.matches("*.md", "dir/a.md"))
        #expect(Glob.matches("**/a.md", "x/y/a.md"))
        #expect(Glob.matches("**/a.md", "a.md"))
        #expect(!Glob.matches("*", ".hidden"))
        #expect(!Glob.matches("**/a", ".git/a"))
        #expect(Glob.matches("skills/{tdd,lint}", "skills/lint"))
        #expect(Glob.matches("t?d", "tdd"))
        #expect(Glob.matches("[a-c]x", "bx") && !Glob.matches("[!a-c]x", "bx"))
        #expect(!Glob.matches("#tdd", "#tdd"))
        #expect(Glob.matches("/Users/*/skills", "/Users/me/skills"))
    }
}
