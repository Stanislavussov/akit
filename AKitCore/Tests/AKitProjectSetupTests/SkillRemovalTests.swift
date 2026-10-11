import Foundation
import Testing
import AKitBrain
import AKitFoundation
import AKitHarnesses
import AKitSkills
@testable import AKitProjectSetup

/// Remove Everywhere: every place a harness loads a skill from, and the action for each. A fake
/// home with Claude Code and Pi, a brain, a git project with a linked worktree; the Trash is the
/// fixture's folder.
struct SkillRemovalTests {
    let move: SkillMoveTests
    var f: GitProjectFixture { move.f }
    let fm = FileManager.default

    init() throws { move = try SkillMoveTests() }

    var other: URL { f.home.appending(path: "Projects/other") }
    var kept: URL { f.home.appending(path: "Projects/kept") }

    func context(_ projects: [String: URL]) -> SkillMove.Context {
        let installed = SkillScanner.scan(installations: HarnessCatalog.detectAll(in: f.env), projects: Array(projects.values), in: f.env)
        return SkillMove.Context(env: f.env, store: f.store, homeID: move.homeID, installed: installed, targets: ["claude", "pi"],
                                 projectFolders: projects)
    }

    func exists(_ path: String, in folder: URL? = nil) -> Bool {
        var info = stat()
        return lstat((folder ?? f.home).appending(path: path).path, &info) == 0
    }

    /// A Claude Code plugin `tools` (enabled) whose skill folder is also named deploy.
    func plugin() throws {
        let base = f.home.appending(path: ".claude/plugins/cache/tools")
        try f.write(".claude/plugins/cache/tools/skills/deploy/SKILL.md", "---\nname: deploy\ndescription: The plugin's deploy\n---\n")
        try f.write(".claude/plugins/cache/tools/skills/lint/SKILL.md", "---\nname: lint\ndescription: Lint\n---\n")
        try f.write(".claude/plugins/installed_plugins.json",
                    #"{"plugins": {"tools@market": [{"scope": "user", "installPath": "\#(base.path)", "version": "1.0"}]}}"#)
        try f.write(".claude/settings.json", "{\n  \"enabledPlugins\": {\n    \"tools@market\": true\n  }\n}\n")
    }

    @Test func aSkillLeavesEveryPlaceAHarnessLoadsItFrom() async throws {
        try move.harnesses()
        let brain = try await move.renderedInCore()
        // The project gets deploy from its answers too, local only, so its worktree has a link.
        try await f.initRepo()
        try await f.git("worktree", "add", "-q", "-b", "x", move.tree.path)
        try await f.apply(ProjectAnswers(targets: ["claude", "pi"], skills: [.init(name: "deploy", mode: .auto)], localOnly: true), brain: brain)
        #expect(exists(".agents/skills/deploy", in: move.tree))
        // Own copies: Pi's global folder, another project's .claude/skills; one tracked by git; one by header name only.
        try f.write(".pi/agent/skills/deploy/SKILL.md", move.skill)
        try f.write("Projects/other/.claude/skills/deploy/SKILL.md", move.skill)
        try fm.createDirectory(at: kept, withIntermediateDirectories: true)
        try f.write("Projects/kept/.agents/skills/deploy/SKILL.md", move.skill)
        try await f.git("init", "-q", "-b", "main", in: kept)
        try await f.git("add", "-A", in: kept)
        try await f.git("commit", "-qm", "Ours", in: kept)
        try f.write(".agents/skills/ship-it/SKILL.md", move.skill)
        try plugin()
        let settings = f.read(".claude/settings.json", in: f.home)

        let current = try #require(Brain.load(from: f.brainRoot))
        let plan = SkillRemoval.plan(name: "deploy", brain: current,
                                     context: context([f.id: f.project, "local/other": other, "local/kept": kept]))
        #expect(plan.canApply, "\(plan.blockers)")
        func place(_ id: String) -> SkillRemoval.Place? { plan.places.first { $0.id == id } }
        func copy(_ path: String) -> SkillRemoval.Place? {
            plan.places.first { $0.skill.map { ($0.isSingleFile ? $0.realFile : $0.realFolder).standardizedFileURL.path }
                == f.home.appending(path: path).resolvingSymlinksInPath().standardizedFileURL.path }
        }
        let core = try #require(place("layer:core"))
        #expect(core.selected && core.before?.contains("name: deploy") == true && core.after?.contains("deploy") == false)
        #expect(place("answers:\(f.id)")?.selected == true)
        #expect(copy(".pi/agent/skills/deploy")?.action == .trash && copy(".pi/agent/skills/deploy")?.selected == true)
        #expect(copy("Projects/other/.claude/skills/deploy")?.action == .trash && copy("Projects/other/.claude/skills/deploy")?.selected == true)
        #expect(copy(".agents/skills/deploy")?.action == .rendered && copy(".agents/skills/deploy")?.selected == true)
        #expect(copy("Projects/task/.agents/skills/deploy")?.action == .rendered && copy("Projects/task/.agents/skills/deploy")?.selected == true)
        let tracked = try #require(copy("Projects/kept/.agents/skills/deploy"))
        #expect(!tracked.selected && tracked.reason?.hasPrefix("Tracked in git in ~/Projects/kept;") == true, "\(tracked.reason ?? "")")
        let header = try #require(copy(".agents/skills/ship-it"))
        #expect(header.byHeader && !header.selected && header.canSelect)
        let fromPlugin = try #require(plan.places.first { $0.plugin == "tools" })
        #expect(!fromPlugin.canSelect && fromPlugin.reason?.hasPrefix("Comes with the plugin tools (1 other skill)") == true)
        #expect(place("library")?.selected == false)
        #expect(plan.summary.hasPrefix("After this, deploy still loads in: ") && plan.summary.contains("Projects/kept/.agents/skills/deploy"))
        #expect(plan.summary.contains("tools") && !plan.summary.contains("ship-it"))

        let outcome = try await SkillRemoval.apply(plan, brain: current, env: f.env, trash: f.trash)
        #expect(outcome.done.contains("out of layer core (committed)"), "\(outcome.done)")

        // The core layer's entry is committed out; the brain keeps skills/deploy.
        #expect(!move.coreSkills().contains("deploy"))
        #expect(try await f.git("log", "--format=%s", in: f.brainRoot).contains("Remove skill deploy from layer core"))
        #expect(fm.fileExists(atPath: f.brainRoot.appending(path: "skills/deploy/SKILL.md").path))
        #expect(ProjectRecords.savedAnswers(id: f.id, in: f.store)?.skills.isEmpty == true)
        // Every copy a harness loaded is gone; the worktree's link too, and git sees nothing in either checkout.
        for path in [".agents/skills/deploy", ".pi/agent/skills/deploy", "Projects/other/.claude/skills/deploy", "Projects/task/.agents/skills/deploy"] {
            #expect(!exists(path), "\(path)")
        }
        #expect(!exists(".agents/skills/deploy", in: move.tree))
        #expect(try await f.git("status", "--porcelain", "--untracked-files=all").isEmpty)
        #expect(try await f.git("status", "--porcelain", "--untracked-files=all", in: move.tree).isEmpty)
        #expect(try await f.git("status", "--porcelain", in: f.brainRoot).isEmpty)
        // Left alone: the tracked copy, the other folder, the plugin (nothing written without Disable Plugin…).
        #expect(exists("Projects/kept/.agents/skills/deploy/SKILL.md") && exists(".agents/skills/ship-it/SKILL.md"))
        #expect(f.read(".claude/settings.json", in: f.home) == settings)
        #expect(move.trashed().count >= 4)
    }

    @Test func disablePluginIsItsOwnStepAndNamesWhatElseGoes() throws {
        try move.harnesses()
        try plugin()
        let installed = SkillScanner.scan(installations: HarnessCatalog.detectAll(in: f.env), in: f.env)
        let plan = try PluginSwitch.plan(plugin: "tools", installed: installed, in: f.env)
        #expect(plan.keys == ["tools@market"] && plan.skills == ["deploy", "lint"])
        #expect(plan.change.diff.contains { if case .added(let text) = $0 { text.contains("false") } else { false } })
        try PluginSwitch.apply(plan, home: f.home)
        #expect(f.read(".claude/settings.json", in: f.home)?.contains("\"tools@market\": false") == true)
        #expect(throws: PluginSwitch.Failure.self) { try PluginSwitch.plan(plugin: "tools", installed: installed, in: f.env) }
    }

    @Test func withoutABrainOwnCopiesGoAndAChangedCopyStopsEverything() async throws {
        try move.harnesses()
        try f.write(".agents/skills/solo/SKILL.md", "---\nname: solo\ndescription: Solo\n---\n")
        try f.write(".pi/agent/skills/solo/SKILL.md", "---\nname: solo\ndescription: Solo\n---\n")
        let plan = SkillRemoval.plan(name: "solo", brain: nil, context: context([:]))
        #expect(plan.canApply && plan.places.filter(\.selected).count == 2 && plan.summary == "After this, solo loads in: nowhere.")
        try f.write(".pi/agent/skills/solo/notes.md", "written after the preview\n")
        await #expect(throws: SkillRemoval.Failure.self) {
            try await SkillRemoval.apply(plan, brain: nil, env: f.env, trash: f.trash)
        }
        #expect(exists(".agents/skills/solo") && exists(".pi/agent/skills/solo"))
        let again = SkillRemoval.plan(name: "solo", brain: nil, context: context([:]))
        try await SkillRemoval.apply(again, brain: nil, env: f.env, trash: f.trash)
        #expect(!exists(".agents/skills/solo") && !exists(".pi/agent/skills/solo") && move.trashed().count == 2)
    }

    @Test func aRenderedCopyEditedByHandBlocksWithShowEdits() async throws {
        try move.harnesses()
        _ = try await move.renderedInCore()
        try f.write(".agents/skills/deploy/SKILL.md", move.skill + "my notes\n")
        let plan = SkillRemoval.plan(name: "deploy", brain: try #require(Brain.load(from: f.brainRoot)), context: context([:]))
        #expect(!plan.canApply && plan.blockers.first?.hasPrefix("~/.agents/skills/deploy/SKILL.md was edited by hand") == true)
        #expect(plan.edits.first?.copyText?.hasSuffix("my notes\n") == true)
        // Unticking core leaves the copy, and the plan says where it still loads.
        let kept = SkillRemoval.plan(name: "deploy", brain: try #require(Brain.load(from: f.brainRoot)), context: context([:]),
                                     leaving: ["layer:core", "library"])
        #expect(kept.blockers.isEmpty && !kept.canApply && kept.summary.contains("its brain entry stays"))
    }
}
