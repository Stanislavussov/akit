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
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        try f.write("Projects/other/.claude/settings.json", #"{"enabledPlugins": {"tools@market": true}}"#)
        let plan = try PluginSwitch.plan(plugin: "tools", installed: installed, servers: ["tools-db"], projects: [other, f.project], in: f.env)
        #expect(plan.keys == ["tools@market"] && plan.skills == ["deploy", "lint"] && plan.servers == ["tools-db"])
        #expect(plan.keptOnIn == ["~/Projects/other"])
        #expect(plan.summary.contains("\"tools@market\": true → false") && plan.summary.contains("MCP servers that stop: tools-db.")
                && plan.summary.contains("It stays on in ~/Projects/other"), "\(plan.summary)")
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

    // MARK: - Review round

    @Test func aPerSkillLinkAndItsTargetBothGoAndALinkToADevFolderLeavesTheFolder() async throws {
        try move.harnesses(link: false)
        // skills.sh layout: ~/.claude/skills/solo is a link to ~/.agents/skills/solo, which Pi loads itself.
        try f.write(".agents/skills/solo/SKILL.md", "---\nname: solo\ndescription: Solo\n---\n")
        try fm.createDirectory(at: f.home.appending(path: ".claude/skills"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: f.home.appending(path: ".claude/skills/solo").path,
                                  withDestinationPath: f.home.appending(path: ".agents/skills/solo").path)
        let plan = SkillRemoval.plan(name: "solo", brain: nil, context: context([:]))
        let link = try #require(plan.places.first { $0.isLink })
        #expect(link.selected && link.title.hasPrefix("~/.claude/skills/solo → ") && link.harnesses == [.claudeCode], "\(plan.places.map(\.title))")
        let real = try #require(plan.places.first { $0.id.hasPrefix("copy:") })
        #expect(real.selected && real.title == "~/.agents/skills/solo" && real.harnesses.contains(.pi) && !real.isLink)
        #expect(plan.summary == "After this, solo loads in: nowhere.")
        try await SkillRemoval.apply(plan, brain: nil, env: f.env, trash: f.trash)
        #expect(!exists(".claude/skills/solo") && !exists(".agents/skills/solo") && move.trashed().count == 2)

        // A link into a development folder no harness loads from: only the link goes.
        try f.write("dev/tool/SKILL.md", "---\nname: tool\ndescription: Tool\n---\n")
        try fm.createSymbolicLink(atPath: f.home.appending(path: ".claude/skills/tool").path, withDestinationPath: f.home.appending(path: "dev/tool").path)
        let dev = SkillRemoval.plan(name: "tool", brain: nil, context: context([:]))
        #expect(dev.places.map(\.isLink) == [true] && dev.notes.contains { $0.hasPrefix("~/dev/tool stays: the links to it go") })
        try await SkillRemoval.apply(dev, brain: nil, env: f.env, trash: f.trash)
        #expect(!exists(".claude/skills/tool") && exists("dev/tool/SKILL.md"))
    }

    @Test func aGlobalCopyAHomeRepositoryTracksStays() async throws {
        try move.harnesses()
        try f.write(".agents/skills/kept/SKILL.md", "---\nname: kept\ndescription: Kept\n---\n")
        try f.write(".agents/skills/loose/SKILL.md", "---\nname: loose\ndescription: Loose\n---\n")
        // A dotfiles repository in the home folder tracks one of them.
        try await f.git("init", "-q", "-b", "main", in: f.home)
        try await f.git("add", ".agents/skills/kept/SKILL.md", in: f.home)
        try await f.git("commit", "-qm", "Dotfiles", in: f.home)
        let kept = SkillRemoval.plan(name: "kept", brain: nil, context: context([:]))
        #expect(!kept.canApply && kept.places.allSatisfy { !$0.selected })
        #expect(kept.places.first?.reason?.hasPrefix("Tracked in git in ~;") == true, "\(kept.places.map { $0.reason ?? "" })")
        let loose = SkillRemoval.plan(name: "loose", brain: nil, context: context([:]))
        #expect(loose.canApply && loose.places.first?.selected == true)
    }

    @Test func onAWorkMacTheBrainsCopyOfALocalRecordIsNeverRewritten() async throws {
        try move.harnesses()
        _ = try await f.setUpBrain()
        try f.write(".akit/registry/skills/deploy/SKILL.md", move.skill)
        let answers = ProjectAnswers(layers: ["task"], targets: ["pi"], skills: [.init(name: "deploy", mode: .auto)])
        try ProjectRecords.save(.init(brainCommit: nil, brainDirty: false, files: [:]), answers: answers, id: "github.com/me/both", in: f.store)
        try await f.git("add", "-A", in: f.brainRoot)
        try await f.git("commit", "-qm", "Both", in: f.brainRoot)
        let brainFile = f.brainRoot.appending(path: "projects/github.com/me/both/answers.json")
        let before = try Data(contentsOf: brainFile)
        try MachineProfile(kind: .work, name: "work").save(home: f.home)
        let work = ProjectStore.local(home: f.home, readingBrain: f.brainRoot)
        try ProjectRecords.save(.init(brainCommit: nil, brainDirty: false, files: [:]), answers: answers, id: "github.com/me/both", in: work)
        try await f.git("config", "user.name", "pseudo-mac", in: f.brainRoot)
        try await f.git("config", "user.email", "pseudo@example.invalid", in: f.brainRoot)

        let brain = try #require(Brain.load(from: f.brainRoot))
        var ctx = context([:])
        ctx.store = work
        let plan = SkillRemoval.plan(name: "deploy", brain: brain, context: ctx, leaving: [])
        let library = try #require(plan.places.first { $0.action == .library })
        #expect(!library.selected && library.reason?.contains("this work Mac keeps its own copy of them") == true, "\(library.reason ?? "")")
        #expect(plan.notes.contains { $0.hasPrefix("Projects set up on a work Mac keep their records on that Mac") })
        try await SkillRemoval.apply(plan, brain: brain, env: f.env, trash: f.trash)
        #expect(try Data(contentsOf: brainFile) == before, "the brain's copy stays as it was")
        #expect(ProjectRecords.savedAnswers(id: "github.com/me/both", in: work)?.skills.isEmpty == true)
    }

    @Test func aWorkMacsLayerCommitUsesTheBrainsIdentityWithoutHooksOrSigning() async throws {
        try move.harnesses()
        _ = try await move.renderedInCore()
        try MachineProfile(kind: .work, name: "work").save(home: f.home)
        try await f.git("config", "user.name", "pseudo-mac", in: f.brainRoot)
        try await f.git("config", "user.email", "pseudo@example.invalid", in: f.brainRoot)
        // A hook that would refuse, and a global signing setting: neither may run.
        try f.write(".akit/registry/.git/hooks/pre-commit", "#!/bin/sh\nexit 1\n")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.brainRoot.appending(path: ".git/hooks/pre-commit").path)
        try await f.git("config", "commit.gpgsign", "true", in: f.brainRoot)
        let brain = try #require(Brain.load(from: f.brainRoot))
        var ctx = context([:])
        ctx.store = ProjectStore.local(home: f.home, readingBrain: f.brainRoot)
        try ProjectRecords.save(try #require(ProjectRecords.savedLock(id: move.homeID, in: f.store)),
                                answers: ProjectAnswers(layers: ["core"], targets: ["claude", "pi"]), id: move.homeID, in: ctx.store)
        let plan = SkillRemoval.plan(name: "deploy", brain: brain, context: ctx)
        #expect(plan.canApply, "\(plan.blockers)")
        try await SkillRemoval.apply(plan, brain: brain, env: f.env, trash: f.trash)
        // The environment's GIT_AUTHOR_* and GIT_COMMITTER_* ("Test") are dropped: the brain's own identity both times.
        #expect(try await f.git("log", "-1", "--format=%an <%ae>|%cn <%ce>|%G?|%s", in: f.brainRoot)
                == "pseudo-mac <pseudo@example.invalid>|pseudo-mac <pseudo@example.invalid>|N|Remove skill deploy from layer core\n")
    }

    // MARK: - Verifier follow-ups

    @Test func aHarnessWithTheHomeFolderAsItsSkillFolderMakesNothingThereRemovable() throws {
        try move.harnesses()
        try fm.createDirectory(at: f.home.appending(path: ".notes-agent"), withIntermediateDirectories: true)
        try f.write("Documents/notes/SKILL.md", "---\nname: notes\ndescription: My notes\n---\n")
        let custom = CustomHarness(id: "notes-agent", name: "Notes Agent", configRoot: "~/.notes-agent", skillFolders: ["~"])
        let adapters = HarnessCatalog.allAdapters(custom: [custom])
        let roots = SkillScanner.rootFolders(projects: [], adapters: adapters, in: f.env).map(\.path)
        #expect(!roots.contains(f.home.resolvingSymlinksInPath().standardizedFileURL.path) && !roots.contains("/"), "\(roots)")
        let installed = SkillScanner.scan(installations: HarnessCatalog.detectAll(in: f.env, adapters: adapters), adapters: adapters, in: f.env)
        #expect(installed.contains { $0.name == "notes" }, "the custom harness does load it")
        let ctx = SkillMove.Context(env: f.env, store: f.store, homeID: move.homeID, installed: installed, targets: ["claude", "pi"])
        let plan = SkillRemoval.plan(name: "notes", brain: nil, context: ctx)
        let place = try #require(plan.places.first)
        #expect(!place.selected && !place.canSelect && place.reason?.hasPrefix("Not directly in a skill folder AKit removes from") == true,
                "\(plan.places.map { ($0.title, $0.reason ?? "") })")
        #expect(!plan.canApply)
    }

    @Test func aTrackedLinkStaysAsADanglingLinkWhileItsUntrackedFolderGoes() async throws {
        try move.harnesses(link: false)
        try f.write(".agents/skills/solo/SKILL.md", "---\nname: solo\ndescription: Solo\n---\n")
        try fm.createDirectory(at: f.home.appending(path: ".claude/skills"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: f.home.appending(path: ".claude/skills/solo").path, withDestinationPath: "../../.agents/skills/solo")
        // A dotfiles repository tracks the link, not the folder.
        try await f.git("init", "-q", "-b", "main", in: f.home)
        try await f.git("add", ".claude/skills/solo", in: f.home)
        try await f.git("commit", "-qm", "Dotfiles", in: f.home)
        let plan = SkillRemoval.plan(name: "solo", brain: nil, context: context([:]))
        let link = try #require(plan.places.first { $0.isLink })
        #expect(!link.selected && link.reason?.hasPrefix("Tracked in git in ~;") == true)
        #expect(plan.places.first { $0.id.hasPrefix("copy:") }?.selected == true)
        #expect(plan.summary == "After this, solo loads in: nowhere.", "a dangling link loads nothing")
        #expect(plan.notes.contains("~/.claude/skills/solo stays as a link to a removed folder; remove it in its repository."), "\(plan.notes)")
        try await SkillRemoval.apply(plan, brain: nil, env: f.env, trash: f.trash)
        #expect(!exists(".agents/skills/solo") && exists(".claude/skills/solo"))
    }

    @Test func theSkillsShLockIsForgottenOnlyWhenTheRealFolderGoes() async throws {
        try move.harnesses(link: false)
        try fm.createDirectory(at: f.home.appending(path: ".claude/skills"), withIntermediateDirectories: true)
        // The temporary home is under /var, a link to /private/var: the lock holds the resolved path.
        try f.write(".agents/skills/solo/SKILL.md", "---\nname: solo\ndescription: Solo\n---\n")
        try f.write("dev/tool/SKILL.md", "---\nname: tool\ndescription: Tool\n---\n")
        try fm.createSymbolicLink(atPath: f.home.appending(path: ".claude/skills/tool").path, withDestinationPath: f.home.appending(path: "dev/tool").path)
        let solo = f.home.appending(path: ".agents/skills/solo").resolvingSymlinksInPath().path
        let tool = f.home.appending(path: "dev/tool").resolvingSymlinksInPath().path
        #expect(f.home.path.hasPrefix("/var/") == false || solo.hasPrefix("/private/var/") || solo.hasPrefix("/var/"))
        var lock = InstalledSkillLock()
        for path in [solo, tool] {
            lock.entries.append(.init(path: path, source: "me/skills", skillId: "x", pathInRepo: "skills/x", modified: false, installedAt: "2026-10-11T00:00:00Z"))
        }
        try InstalledSkillLock.save(lock, in: f.env)

        // Only a link goes: its folder's entry stays.
        try await SkillRemoval.apply(SkillRemoval.plan(name: "tool", brain: nil, context: context([:])), brain: nil, env: f.env, trash: f.trash)
        #expect(try InstalledSkillLock.load(in: f.env).entries.map(\.path) == [solo, tool])
        // The real folder goes: its entry goes too.
        try await SkillRemoval.apply(SkillRemoval.plan(name: "solo", brain: nil, context: context([:])), brain: nil, env: f.env, trash: f.trash)
        #expect(try InstalledSkillLock.load(in: f.env).entries.map(\.path) == [tool])
    }

    @Test func anItemGoneBeforeItsTurnIsANoteNotADoneLine() async throws {
        try move.harnesses()
        try f.write(".agents/skills/solo/SKILL.md", "---\nname: solo\ndescription: Solo\n---\n")
        try f.write(".pi/agent/skills/solo/SKILL.md", "---\nname: solo\ndescription: Solo\n---\n")
        let plan = SkillRemoval.plan(name: "solo", brain: nil, context: context([:]))
        #expect(plan.places.filter(\.selected).count == 2)
        let paths = [".agents/skills/solo", ".pi/agent/skills/solo"].map { f.home.appending(path: $0) }
        var first = true
        // The first move also takes the other copy away (another tool, a sync): it is gone at its turn.
        let outcome = try await SkillRemoval.apply(plan, brain: nil, env: f.env) { url in
            let moved = try f.trash(url)
            if first {
                first = false
                for other in paths where fm.fileExists(atPath: other.path) { try fm.removeItem(at: other) }
            }
            return moved
        }
        #expect(outcome.done.count == 1, "\(outcome.done)")
        #expect(outcome.notes.contains { $0.hasSuffix(" was already gone.") }, "\(outcome.notes)")
    }

    @Test func aPersonalMacCommitsAsBeforeWithItsHooks() async throws {
        try move.harnesses()
        _ = try await move.renderedInCore()
        try f.write(".akit/registry/.git/hooks/pre-commit", "#!/bin/sh\ntouch hook-ran\n")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.brainRoot.appending(path: ".git/hooks/pre-commit").path)
        let plan = SkillRemoval.plan(name: "deploy", brain: try #require(Brain.load(from: f.brainRoot)), context: context([:]))
        try await SkillRemoval.apply(plan, brain: try #require(Brain.load(from: f.brainRoot)), env: f.env, trash: f.trash)
        #expect(fm.fileExists(atPath: f.brainRoot.appending(path: "hook-ran").path), "the hook ran")
        #expect(try await f.git("log", "-1", "--format=%an <%ae>|%s", "--", "layers", in: f.brainRoot)
                == "Test <test@example.com>|Remove skill deploy from layer core\n")
    }
}
