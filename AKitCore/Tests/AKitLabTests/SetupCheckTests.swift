import Foundation
import Testing
import AKitFoundation
@testable import AKitLab

/// The setup check of a layer cell: nothing of the layer where the setup must not have it (the
/// clone, its parent folders, `~/.claude`), everything the setup must have where Claude Code
/// reads it, and the skills the transcript listed. Folders only: no git, no agent.
struct SetupCheckTests {
    let home: URL
    let clone: URL
    let fm = FileManager.default

    init() throws {
        let root = fm.temporaryDirectory.appending(path: "akit-setupcheck-\(UUID().uuidString)")
        home = root.appending(path: "home", directoryHint: .isDirectory)
        clone = root.appending(path: "clone", directoryHint: .isDirectory)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try write("CLAUDE.md", "# Rules\n- BASE-RULE\n")
        try write("value.txt", "1\n")
    }

    func write(_ path: String, _ text: String, in folder: URL? = nil) throws {
        let url = (folder ?? clone).appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func skill(_ name: String, manual: Bool = false, in folder: URL? = nil, at parent: String = ".agents/skills") throws {
        try write("\(parent)/\(name)/SKILL.md", "---\nname: \(name)\ndescription: x\n\(manual ? "disable-model-invocation: true\n" : "")---\nUse it.\n",
                  in: folder)
    }

    func link() throws {
        try fm.createDirectory(at: clone.appending(path: ".claude"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: clone.appending(path: ".claude/skills").path, withDestinationPath: "../.agents/skills")
    }

    let section = SetupCheck.Text(label: "the swiftui layer's AGENTS.md text", text: "- LAYER-MARKER: check with make snapshot", path: "AGENTS.md")

    /// "without swiftui": none of the layer's skill, section or file.
    var baseline: SetupCheck {
        SetupCheck(absentSkills: ["swiftui-expert"], absentTexts: [section],
                   absentFiles: [SetupCheck.File(path: ".swiftlint.yml", sha256: Checksum.sha256(Data("rules: []\n".utf8)))])
    }

    /// "layer swiftui": its skills with their modes and its section where Claude Code reads it;
    /// `old` is turned off.
    var layer: SetupCheck {
        SetupCheck(skills: [.init(name: "swiftui-expert", manual: false), .init(name: "swiftui-review", manual: true)],
                   absentSkills: ["old"], texts: [section])
    }

    func problems(_ check: SetupCheck, own: (findings: Set<SetupCheck.Finding>, skills: Set<String>)? = nil,
                  writes: [ControlOverlay.Write] = []) -> [String] {
        check.problems(clone: clone, home: home, writes: writes, projectContent: own ?? ([], []))
    }

    @Test func aCleanBaselinePasses() throws {
        try fm.createDirectory(at: clone.appending(path: ".claude"), withIntermediateDirectories: true)
        try write("docs/notes.md", "Some notes.\n")
        let own = baseline.projectContent(in: clone, home: home)
        #expect(own.findings.isEmpty && own.skills.isEmpty)
        #expect(problems(baseline, own: own) == [])
        // The project's own skill of the same name is the project's: both setups have it (the overlap warning names it).
        try skill("swiftui-expert")
        let tracked = baseline.projectContent(in: clone, home: home)
        #expect(tracked.skills == ["swiftui-expert"] && problems(baseline, own: tracked) == [])
    }

    @Test func aLayerSkillPlantedInTheBaselineFails() throws {
        let own = baseline.projectContent(in: clone, home: home)
        try skill("swiftui-expert")
        try link()
        let found = problems(baseline, own: own)
        #expect(found.contains(".agents/skills/swiftui-expert holds the skill swiftui-expert, which this setup must not have"), "\(found)")
        #expect(found.contains(".claude/skills/swiftui-expert holds the skill swiftui-expert, which this setup must not have"), "\(found)")
        // In a nested folder, and under another folder name whose SKILL.md names it.
        try fm.removeItem(at: clone.appending(path: ".agents"))
        try fm.removeItem(at: clone.appending(path: ".claude/skills"))
        try write("App/.claude/skills/renamed/SKILL.md", "---\nname: swiftui-expert\n---\n")
        #expect(problems(baseline, own: own) == ["App/.claude/skills/renamed holds the skill swiftui-expert, which this setup must not have"])
        try fm.removeItem(at: clone.appending(path: "App"))
        // Outside the clone: the home folder's skills, which every cell reads. Synced claude.ai
        // skills are named `anthropic-skills:<name>` there, so they never carry the layer's name.
        try skill("swiftui-expert", in: home, at: ".claude/skills/synced/account")
        #expect(problems(baseline, own: own) == [])
        try skill("swiftui-expert", in: home, at: ".claude/skills")
        let path = home.appending(path: ".claude/skills/swiftui-expert").path
        let outside = problems(baseline, own: own)
        #expect(outside == ["\(path) holds the skill swiftui-expert, which this setup must not have (move \(path) elsewhere while the eval runs)"],
                "\(outside)")
        #expect(baseline.outsideProblems(of: clone, home: home) == outside)
        // A command of that name is the same name to Claude Code: in the home folder and in the clone.
        try fm.removeItem(at: home.appending(path: ".claude"))
        try write(".claude/commands/swiftui-expert.md", "Do it.\n", in: home)
        try write(".claude/commands/git/swiftui-expert.md", "Do it.\n")
        #expect(problems(baseline, own: own) == [
            "\(home.appending(path: ".claude/commands/swiftui-expert.md").path) holds the command swiftui-expert, which this setup must not have "
                + "(move \(home.appending(path: ".claude/commands/swiftui-expert.md").path) elsewhere while the eval runs)",
        ])
        #expect(SetupCheck(absentSkills: ["git:swiftui-expert"]).problems(clone: clone, home: home, writes: [], projectContent: ([], []))
                    == [".claude/commands/git/swiftui-expert.md holds the command git:swiftui-expert, which this setup must not have"])
        try fm.removeItem(at: clone.appending(path: ".claude/commands"))
        // A file of the layer, byte for byte.
        try fm.removeItem(at: home.appending(path: ".claude"))
        try write(".swiftlint.yml", "rules: []\n")
        #expect(problems(baseline, own: own) == [".swiftlint.yml holds the file .swiftlint.yml of another setup, which this setup must not have"])
    }

    @Test func aLayerSectionPlantedInTheBaselineFails() throws {
        let own = baseline.projectContent(in: clone, home: home)
        try write("CLAUDE.md", "# Rules\n- BASE-RULE\n\n- LAYER-MARKER: check with make snapshot\n")
        #expect(problems(baseline, own: own) == ["CLAUDE.md holds the swiftui layer's AGENTS.md text, which this setup must not have"])
        // Through an import, and in an AGENTS.md nobody imports: the clone must not hold it at all.
        try write("CLAUDE.md", "# Rules\n@docs/rules.md\n")
        try write("docs/rules.md", "- LAYER-MARKER: check with make snapshot\n")
        try write("AGENTS.md", "- LAYER-MARKER: check with make snapshot\n")
        #expect(problems(baseline, own: own) == ["AGENTS.md holds the swiftui layer's AGENTS.md text, which this setup must not have",
                                                 "docs/rules.md holds the swiftui layer's AGENTS.md text, which this setup must not have"])
        // In the home folder's CLAUDE.md or its rules.
        try write("CLAUDE.md", "# Rules\n")
        try fm.removeItem(at: clone.appending(path: "AGENTS.md"))
        try write(".claude/rules/swift.md", "- LAYER-MARKER: check with make snapshot\n", in: home)
        let rules = home.appending(path: ".claude/rules/swift.md").path
        #expect(problems(baseline, own: own) == ["\(rules) holds the swiftui layer's AGENTS.md text, which this setup must not have "
                                                 + "(take that text out of it while the eval runs)"])
        // An imported file over 1 MB is not read (a log someone imported).
        try fm.removeItem(at: home.appending(path: ".claude"))
        try write("CLAUDE.md", "# Rules\n@big.log\n")
        try write("big.log", String(repeating: "x", count: SetupCheck.largestFile) + "- LAYER-MARKER: check with make snapshot\n")
        #expect(problems(baseline, own: own) == [])
    }

    /// The project's own commit already holds the layer's text: allowed (both setups have it),
    /// and shown by `projectContent` so the cell can say so.
    @Test func theProjectsOwnCopyOfTheLayerIsShown() throws {
        try write("CLAUDE.md", "# Rules\n- LAYER-MARKER: check with make snapshot\n")
        let own = baseline.projectContent(in: clone, home: home)
        #expect(own.findings == [SetupCheck.Finding(what: "the swiftui layer's AGENTS.md text", path: "CLAUDE.md")])
        #expect(problems(baseline, own: own) == [])
    }

    @Test func aSkillTheLayerTurnsOffMustBeAbsentInTheLayerCell() throws {
        let own = layer.projectContent(in: clone, home: home)
        try skill("swiftui-expert")
        try skill("swiftui-review", manual: true)
        try link()
        try write("CLAUDE.md", "# Rules\n\n- LAYER-MARKER: check with make snapshot\n")
        #expect(problems(layer, own: own) == [])
        try skill("old")
        #expect(problems(layer, own: own) == [".agents/skills/old holds the skill old, which this setup must not have",
                                              ".claude/skills/old holds the skill old, which this setup must not have"])
    }

    @Test func aLayerCellMissingWhatItMustHaveFails() throws {
        let own = layer.projectContent(in: clone, home: home)
        try skill("swiftui-review")  // manual, but without the header
        try link()
        let found = problems(layer, own: own)
        #expect(found == ["the skill swiftui-expert is missing (.claude/skills/swiftui-expert/SKILL.md)",
                          ".claude/skills/swiftui-review/SKILL.md lacks disable-model-invocation: true, but swiftui-review is a manual skill",
                          "the swiftui layer's AGENTS.md text is in no file Claude Code reads (CLAUDE.md, .claude/CLAUDE.md, CLAUDE.local.md and "
                            + "their imports)"], "\(found)")
        // The section in AGENTS.md is read once CLAUDE.md imports it; an overlay write that isn't there fails.
        try skill("swiftui-expert")
        try skill("swiftui-review", manual: true)
        try write("CLAUDE.md", "@AGENTS.md\n")
        try write("AGENTS.md", "- LAYER-MARKER: check with make snapshot\n")
        #expect(problems(layer, own: own) == [])
        let missing = ControlOverlay.Write(path: ".agents/skills/swiftui-expert/refs.json", action: .create, data: Data("{}".utf8), kind: .skillFile)
        #expect(problems(layer, own: own, writes: [missing]) == [".agents/skills/swiftui-expert/refs.json doesn't hold the file the overlay wrote"])
    }

    /// The stream's `system/init` names the skills Claude Code loaded (names, or objects with one).
    @Test func theStreamNamesTheLoadedSkills() {
        let printer = StreamPrinter(out: { _ in })
        #expect(printer.skills == nil)
        printer.print(#"{"type":"system","subtype":"init","claude_code_version":"2.1.290","skills":["tdd",{"name":"review"}]}"#)
        #expect(printer.skills == ["tdd", "review"] && printer.version == "2.1.290")
    }

    /// Two sources: the stream's init (`loaded`: every skill, manual ones too, no commands) and the
    /// transcript's `skill_listing` (`listed`: what the model saw, no manual skills, commands too).
    @Test func theSkillsAfterTheAgent() throws {
        #expect(baseline.afterRun(listed: nil, loaded: nil).status == .notChecked)
        #expect(baseline.afterRun(listed: ["tdd"]).status == .passed)
        #expect(baseline.afterRun(listed: nil, loaded: ["tdd"]).detail == "before the agent, and the skills Claude Code loaded")
        let leaked = baseline.afterRun(listed: ["tdd", "swiftui-expert"])
        #expect(leaked.status == .failed && leaked.detail == "Claude Code loaded swiftui-expert, which this setup must not have")
        #expect(leaked.line == "setup check failed: Claude Code loaded swiftui-expert, which this setup must not have")
        // A manual skill of the layer leaks only into the init's list: still caught.
        #expect(SetupCheck(absentSkills: ["swiftui-review"]).afterRun(listed: ["tdd"], loaded: ["tdd", "swiftui-review"]).status == .failed)
        // The project's own skill of that name may show in any setup.
        #expect(baseline.afterRun(listed: ["swiftui-expert"], projectSkills: ["swiftui-expert"]).status == .passed)
        // The layer cell: every skill loaded, the auto ones listed, the manual one not listed.
        let both: Set<String> = ["swiftui-expert", "swiftui-review"]
        #expect(layer.afterRun(listed: ["swiftui-expert"], loaded: both).status == .passed)
        #expect(layer.afterRun(listed: ["swiftui-expert"], loaded: ["swiftui-expert"]).detail == "Claude Code didn't load swiftui-review")
        #expect(layer.afterRun(listed: ["swiftui-review"], loaded: both).detail
                == "Claude Code didn't list swiftui-expert to the model; Claude Code listed the manual swiftui-review to the model")
        #expect(layer.afterRun(listed: ["swiftui-expert", "old"], loaded: both).status == .failed)
        // Only the listing: the manual skill can't be checked for being loaded.
        #expect(layer.afterRun(listed: ["swiftui-expert"]).status == .passed)

        // Read from the transcript's skill_listing attachments; a subagent's don't count.
        let transcript = home.appending(path: "t.jsonl")
        func line(_ object: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) }
        try (try [
            line(["type": "user", "message": ["role": "user", "content": "Go"]]),
            line(["type": "attachment", "attachment": ["type": "skill_listing", "isInitial": true, "names": ["tdd", "swiftui-expert"],
                                                       "content": "- tdd: tests\n- swiftui-expert: SwiftUI"]]),
            line(["type": "attachment", "attachment": ["type": "skill_listing", "content": "- lint: style"]]),
            line(["type": "attachment", "isSidechain": true, "attachment": ["type": "skill_listing", "names": ["old"]]]),
        ].joined(separator: "\n") + "\n").write(to: transcript, atomically: true, encoding: .utf8)
        #expect(SetupCheck.listedSkills(in: transcript) == ["tdd", "swiftui-expert", "lint"])
        try (try line(["type": "user", "message": ["role": "user", "content": "Go"]]) + "\n").write(to: transcript, atomically: true, encoding: .utf8)
        #expect(SetupCheck.listedSkills(in: transcript) == nil)
    }
}
