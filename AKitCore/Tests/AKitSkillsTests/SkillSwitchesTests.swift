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
        SkillSwitches.states(of: [skill], in: env)[skill.id]?[harness]?.state
    }

    func reading(_ skill: Skill, _ harness: HarnessID) -> SkillSwitchReading? {
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
        // Back to Manual: the file already says so, so the entry goes.
        try SkillSwitches.apply(try SkillSwitches.plan(quiet, harness: .claudeCode, to: .manual, in: env), home: home)
        #expect(try text(claudeSettings) == "{}")
        #expect(state(quiet, .claudeCode) == .manual)
        #expect(SkillSwitches.defaultState(of: quiet, harness: .claudeCode) == .manual)
        #expect(SkillSwitches.defaultState(of: quiet, harness: .pi) == .on)
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
        #expect(Glob.matches("*.md", "a.md") == true)
        #expect(Glob.matches("*.md", "dir/a.md") == false)
        #expect(Glob.matches("**/a.md", "x/y/a.md") == true)
        #expect(Glob.matches("**/a.md", "a.md") == true)
        #expect(Glob.matches("*", ".hidden") == false)
        #expect(Glob.matches("**/a", ".git/a") == false)
        #expect(Glob.matches("skills/{tdd,lint}", "skills/lint") == true)
        #expect(Glob.matches("t?d", "tdd") == true)
        #expect(Glob.matches("[a-c]x", "bx") == true && Glob.matches("[!a-c]x", "bx") == false)
        #expect(Glob.matches("#tdd", "#tdd") == false)
        #expect(Glob.matches("/Users/*/skills", "/Users/me/skills") == true)
    }

    /// minimatch 10 behaviour the review listed.
    @Test func globEdgesLikeMinimatch() {
        #expect(Glob.matches("skills/**", "skills") == false)
        #expect(Glob.matches("skills/**", "skills/a/b") == true)
        #expect(Glob.matches("skills/**/x", "skills/x") == true)
        #expect(Glob.matches("a/*", "a/") == false)
        #expect(Glob.matches("skills//tdd", "skills/tdd") == true)
        #expect(Glob.matches("/x/*", "x/a") == false)
        // A brace that is no group is a literal; the scan goes on to the next one.
        #expect(Glob.matches("{x}/{a,b}", "{x}/a") == true)
        #expect(Glob.matches("{x/{a,b}", "{x/b") == true)
        // Syntax AKit doesn't read: unknown, never a guess.
        for pattern in ["@(tdd|lint)", "+(a)", "!(tdd)", "?(a)", "*(a)", "[[:alpha:]]dd", "skill{1..3}"] {
            #expect(Glob.matches(pattern, "tdd") == nil, "\(pattern)")
        }
    }

    /// Patterns that take exponential time in a naive matcher finish at once.
    @Test(.timeLimit(.minutes(1))) func hostileGlobsAreBounded() {
        let start = Date()
        #expect(Glob.matches(String(repeating: "{a,b}", count: 22), String(repeating: "a", count: 22)) == nil)
        #expect(Glob.matches(String(repeating: "*a", count: 12) + "b", String(repeating: "a", count: 40)) == false)
        #expect(Glob.matches(String(repeating: "**/", count: 30) + "x", Array(repeating: "d", count: 40).joined(separator: "/")) == false)
        #expect(Date().timeIntervalSince(start) < 15)
    }

    // MARK: - Review round

    @Test func claudeKeysByTheFolderNotTheSkillMdName() throws {
        try write(".agents/skills/deploy-staging/SKILL.md", skill("deploy"))
        try fm.createSymbolicLink(at: home.appending(path: ".claude/skills"), withDestinationURL: home.appending(path: ".agents/skills"))
        let deploy = try #require(scan().first { $0.name == "deploy" })
        #expect(SkillSwitches.claudeName(of: deploy) == "deploy-staging")
        let options = try #require(SkillSwitches.options(for: deploy, harness: .claudeCode, in: env))
        #expect(options.key == #"skillOverrides."deploy-staging""#)
        #expect(options.note?.contains("deploy-staging (its folder), not deploy") == true)
        try SkillSwitches.apply(try SkillSwitches.plan(deploy, harness: .claudeCode, to: .off, in: env), home: home)
        #expect(try text(claudeSettings) == "{\n  \"skillOverrides\": {\n    \"deploy-staging\": \"off\"\n  }\n}\n")
        // An entry under the SKILL.md name is not the skill's.
        try write(".claude/settings.json", #"{"skillOverrides": {"deploy": "off"}}"#)
        #expect(state(deploy, .claudeCode) == .on)
    }

    @Test func syncedSkillsUseTheQualifiedName() throws {
        try write(".claude/skills/synced/bucket/pdf/SKILL.md", skill("pdf"))
        let pdf = try #require(scan().first { $0.name == "pdf" })
        #expect(pdf.scope == .synced)
        #expect(SkillSwitches.claudeName(of: pdf) == "anthropic-skills:pdf")
    }

    @Test func syncedSkillsAlsoAnswerToTheirBareName() throws {
        try write(".claude/skills/synced/bucket/pdf/SKILL.md", skill("pdf"))
        let pdf = try #require(scan().first { $0.name == "pdf" })
        try write(".claude/settings.json", "{\n  \"skillOverrides\": {\n    \"pdf\": \"off\"\n  }\n}\n")
        #expect(state(pdf, .claudeCode) == .off)
        // Changing it writes the qualified name and drops the bare one, so one entry decides.
        try SkillSwitches.apply(try SkillSwitches.plan(pdf, harness: .claudeCode, to: .nameOnly, in: env), home: home)
        #expect(try text(claudeSettings) == "{\n  \"skillOverrides\": {\n    \"anthropic-skills:pdf\": \"name-only\"\n  }\n}\n")
        try SkillSwitches.apply(try SkillSwitches.plan(pdf, harness: .claudeCode, to: .on, in: env), home: home)
        #expect(try text(claudeSettings) == "{}\n")
    }

    @Test func piFileFollowsTheRootPiFoundTheSkillIn() throws {
        // ~/.agents/skills/lint is a link into a project's own skills: Pi finds it in a personal folder.
        let project = home.appending(path: "Projects/app")
        try fm.createDirectory(at: project.appending(path: ".git"), withIntermediateDirectories: true)
        try write("Projects/app/.agents/skills/lint/SKILL.md", skill("lint"))
        try fm.createDirectory(at: home.appending(path: ".agents/skills"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: home.appending(path: ".agents/skills/lint"), withDestinationURL: project.appending(path: ".agents/skills/lint"))
        let lint = try #require(scan().first { $0.name == "lint" })
        #expect(lint.places[.pi]?.scope == .global)
        #expect(SkillSwitches.settingsFile(for: lint, harness: .pi, in: env)?.path == piSettings.path)
    }

    @Test func aTextEditMustDoExactlyTheIntendedChange() throws {
        // The file has "café" precomposed; a file URL gives the folder name decomposed (as macOS
        // file names come back). The text edit (by Unicode scalars) adds a second key that Swift's tree
        // sees as the same one: the check after the edit refuses instead of writing the key twice.
        try write(".claude/settings.json", "{\"skillOverrides\": {\"caf\u{e9}\": \"off\"}}\n")
        let file = home.appending(path: ".claude/skills/caf\u{e9}/SKILL.md")
        let cafe = Skill(name: "caf\u{e9}", description: "", file: file, realFile: file, isSingleFile: false, scope: .global,
                         visibleTo: [.claudeCode], isReadOnly: false, origin: nil, warnings: [], root: home.appending(path: ".claude/skills"),
                         places: [.claudeCode: Skill.Place(file: file, base: home.appending(path: ".claude"), scope: .global)])
        #expect(SkillSwitches.claudeName(of: cafe)?.unicodeScalars.count == 5)
        #expect(throws: SkillSwitches.Failure.self) { try SkillSwitches.plan(cafe, harness: .claudeCode, to: .nameOnly, in: env) }
        #expect(throws: SettingsFile.Failure.self) {
            try SettingsFile.checked(#"{"a": 1, "b": 2}"#, expected: .object(["a": .number("1")]), file: claudeSettings, home: home)
        }
    }

    @Test func previewShowsOnlyTheChangedObject() throws {
        let tdd = try shared("tdd")
        try write(".claude/settings.json", #"{"apiKeyHelper": "print-key --secret", "statusLine": {"command": "x"}, "skillOverrides": {"a": "off"}}"#)
        let plan = try SkillSwitches.plan(tdd, harness: .claudeCode, to: .off, in: env)
        let shown = plan.diff.map { "\($0)" }.joined(separator: "\n")
        #expect(!shown.contains("apiKeyHelper") && !shown.contains("print-key") && !shown.contains("statusLine"))
        #expect(plan.diff.contains(.same(#"  "skillOverrides": {"#)))
        #expect(plan.diff.contains(.added(#"    "tdd": "off""#)))
    }

    @Test func unreadableFilesAndPatternsAreUnknown() throws {
        let tdd = try shared("tdd")
        try write(".claude/settings.json", "{ not json")
        guard case .unknown(let reason)? = reading(tdd, .claudeCode) else { Issue.record("expected unknown"); return }
        #expect(reason.contains("not valid JSON"))
        try write(".pi/agent/settings.json", #"{"skills": ["!@(tdd|x)"]}"#)
        guard case .unknown(let pattern)? = reading(tdd, .pi) else { Issue.record("expected unknown"); return }
        #expect(pattern.contains("can't read"))
        #expect(throws: SkillSwitches.Failure.self) { try SkillSwitches.plan(tdd, harness: .pi, to: .off, in: env) }
        try write(".pi/agent/settings.json", #"{"skills": "tdd"}"#)
        #expect(reading(tdd, .pi)?.state == nil)
        #expect(throws: SkillSwitches.Failure.self) { try SkillSwitches.plan(tdd, harness: .pi, to: .off, in: env) }
        try write(".claude/settings.json", #"{"skillOverrides": ["tdd"]}"#)
        #expect(reading(tdd, .claudeCode)?.state == nil)
        #expect(throws: SkillSwitches.Failure.self) { try SkillSwitches.plan(tdd, harness: .claudeCode, to: .off, in: env) }
    }

    @Test func crlfFilesGetCrlfLines() throws {
        let tdd = try shared("tdd")
        try write(".claude/settings.json", "{\r\n  \"model\": \"opus\"\r\n}\r\n")
        try SkillSwitches.apply(try SkillSwitches.plan(tdd, harness: .claudeCode, to: .off, in: env), home: home)
        #expect(try text(claudeSettings) == "{\r\n  \"model\": \"opus\",\r\n  \"skillOverrides\": {\r\n    \"tdd\": \"off\"\r\n  }\r\n}\r\n")
    }

    @Test func applyKeepsModeAndExtendedAttributes() throws {
        let tdd = try shared("tdd")
        try write(".claude/settings.json", "{}\n")
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: claudeSettings.path)
        #expect(setxattr(claudeSettings.path, "com.akit.test", "v", 1, 0, 0) == 0)
        try SkillSwitches.apply(try SkillSwitches.plan(tdd, harness: .claudeCode, to: .off, in: env), home: home)
        #expect((try fm.attributesOfItem(atPath: claudeSettings.path)[.posixPermissions] as? Int) == 0o600)
        var byte: UInt8 = 0
        #expect(getxattr(claudeSettings.path, "com.akit.test", &byte, 1, 0, 0) == 1 && byte == UInt8(ascii: "v"))
        // No temporary file is left next to it.
        #expect(try fm.contentsOfDirectory(atPath: home.appending(path: ".claude").path).filter { $0.contains("akit-") }.isEmpty)
    }
}
