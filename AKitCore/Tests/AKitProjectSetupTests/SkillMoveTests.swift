import Foundation
import Testing
import AKitBrain
import AKitFoundation
import AKitHarnesses
import AKitSkills
@testable import AKitProjectSetup

/// Move to Project: a global skill into projects through the brain, then out of core and the
/// home folder. A fake home with Claude Code and Pi folders, a brain, a git project with a
/// linked worktree; the Trash is the fixture's folder.
struct SkillMoveTests {
    let f: GitProjectFixture
    let fm = FileManager.default
    let homeID = "home/test"

    init() throws { f = try GitProjectFixture("skill-move") }

    var tree: URL { f.home.appending(path: "trees/task-x") }
    var other: URL { f.home.appending(path: "Projects/other") }
    let skill = "---\nname: deploy\ndescription: Deploys the app\n---\n\n# Deploy\n"

    func context(projectFolders: [String: URL] = [:]) -> SkillMove.Context {
        let installed = SkillScanner.scan(installations: HarnessCatalog.detectAll(in: f.env), in: f.env)
        return SkillMove.Context(env: f.env, store: f.store, homeID: homeID, installed: installed, targets: ["claude", "pi"],
                                 projectFolders: projectFolders)
    }

    func plan(_ targets: [SkillMove.Target], mode: LayerSkill.Mode = .auto, keepGlobal: Bool = false, brain: Brain,
              projectFolders: [String: URL] = [:]) -> SkillMove.Plan {
        SkillMove.plan(name: "deploy", targets: targets, mode: mode, keepGlobal: keepGlobal, brain: brain,
                       context: context(projectFolders: projectFolders))
    }

    var target: SkillMove.Target { .init(id: f.id, folder: f.project) }

    /// Claude Code and Pi are "installed": their folders exist; Claude reads the shared folder through a link.
    func harnesses() throws {
        try fm.createDirectory(at: f.home.appending(path: ".pi/agent"), withIntermediateDirectories: true)
        try fm.createDirectory(at: f.home.appending(path: ".agents/skills"), withIntermediateDirectories: true)
        try fm.createDirectory(at: f.home.appending(path: ".claude"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: f.home.appending(path: ".claude/skills").path, withDestinationPath: "../.agents/skills")
    }

    /// `deploy` in the brain and in core, rendered into the home folder.
    func renderedInCore() async throws -> Brain {
        _ = try await f.setUpBrain()
        try f.write(".akit/registry/skills/deploy/SKILL.md", skill)
        let core = try #require(f.read(".akit/registry/layers/core/layer.yaml", in: f.home))
        try f.write(".akit/registry/layers/core/layer.yaml", core + "  - name: deploy\n    mode: manual\n")
        try await f.git("add", "-A", in: f.brainRoot)
        try await f.git("commit", "-qm", "Add deploy", in: f.brainRoot)
        let brain = try #require(Brain.load(from: f.brainRoot))
        #expect(brain.layers.first { $0.name == "core" }?.skills.contains { $0.name == "deploy" } == true, "\(core)")
        let home = ProjectSetup.plan(project: f.home, id: homeID, answers: ProjectAnswers(layers: ["core"], targets: ["claude", "pi"]),
                                     brain: brain, store: f.store, forHome: true, env: f.env)
        #expect(home.canApply, "\(home.blockers) \(home.render.errors)")
        _ = try await ProjectSetup.apply(home, brain: brain, home: f.home, env: f.env, trash: f.trash)
        #expect(f.read(".agents/skills/deploy/SKILL.md", in: f.home)?.contains("disable-model-invocation: true") == true)
        return brain
    }

    func coreSkills() -> [String] {
        Brain.load(from: f.brainRoot)?.layers.first { $0.name == "core" }?.skills.map(\.name) ?? []
    }

    func trashed() -> [String] {
        ((try? fm.contentsOfDirectory(atPath: f.home.appending(path: "Trash").path)) ?? []).sorted()
    }

    @Test func aPlainGlobalFolderMovesIntoALocalOnlyProjectAndItsWorktree() async throws {
        let brain = try await f.setUpBrain()
        try harnesses()
        try f.write(".agents/skills/deploy/SKILL.md", skill)
        try f.write(".agents/skills/deploy/scripts/run.sh", "echo deploy\n")
        try f.write(".pi/agent/skills/deploy/SKILL.md", skill + "pi copy\n")
        try await f.initRepo()
        try await f.git("worktree", "add", "-q", "-b", "x", tree.path)

        let plan = plan([target], brain: brain)
        #expect(plan.canApply, "\(plan.blockers) \(plan.parts.map(\.state))")
        #expect(plan.brainImport != nil && plan.coreEdit == nil && plan.home == nil && !plan.sourceRendered)
        #expect(plan.trashSource.map { $0.lastPathComponent } == ["deploy"])
        #expect(plan.extraCopies.map { SkillMove.shown($0.folder, home: f.home) } == ["~/.pi/agent/skills/deploy"])
        let part = try #require(plan.parts.first)
        #expect(part.state == .add && part.isNew && part.localOnly && part.savedLocalOnly == nil)
        #expect(part.worktrees.map(\.lastPathComponent) == ["task-x"])
        #expect(part.paths == [".agents/skills/deploy/SKILL.md", ".agents/skills/deploy/scripts/run.sh", ".claude/skills"])
        #expect(plan.notes.contains { $0.hasPrefix("Other Macs: ") })

        var held: [String] = []
        let outcome = try await SkillMove.apply(plan, brain: brain, env: f.env, trash: f.trash) { id, work in
            held.append(id)
            return try await work()
        }
        #expect(held == [f.id])
        #expect(outcome.imported && !outcome.coreChanged && outcome.home == nil)
        #expect(outcome.trashed == ["~/.agents/skills/deploy", "~/.pi/agent/skills/deploy"])

        // The brain's library has it (no layer), the project's answers list it.
        #expect(f.read(".akit/registry/skills/deploy/scripts/run.sh", in: f.home) == "echo deploy\n")
        #expect(try await f.git("log", "-3", "--format=%s", in: f.brainRoot).hasPrefix("Render task\nImport skill deploy\n"))
        let answers = try #require(ProjectRecords.savedAnswers(id: f.id, in: f.store))
        #expect(answers.skills == [.init(name: "deploy", mode: .auto)] && answers.localOnly == true && answers.layers.isEmpty)

        // In the project and, through a link, in its worktree; git sees nothing in either.
        #expect(f.read(".agents/skills/deploy/SKILL.md") == skill)
        let link = try fm.destinationOfSymbolicLink(atPath: tree.appending(path: ".agents/skills/deploy").path)
        #expect(link == ProjectWorktrees.realPath(f.project.path) + "/.agents/skills/deploy")
        #expect(f.read(".agents/skills/deploy/SKILL.md", in: tree) == skill)
        #expect(try await f.git("status", "--porcelain", "--untracked-files=all").isEmpty)
        #expect(try await f.git("status", "--porcelain", "--untracked-files=all", in: tree).isEmpty)

        // The global copies are in the Trash.
        #expect(!fm.fileExists(atPath: f.home.appending(path: ".agents/skills/deploy").path))
        #expect(!fm.fileExists(atPath: f.home.appending(path: ".pi/agent/skills/deploy").path))
        #expect(trashed().count == 2)

        // A worktree made later gets the link with the next sync, like every AKit file.
        let later = f.home.appending(path: "trees/task-y")
        try await f.git("worktree", "add", "-q", "-b", "y", later.path)
        #expect(ProjectWorktrees.sync(f.project, env: f.env).created.contains { $0.hasSuffix("/trees/task-y/.agents/skills/deploy") })
        #expect(f.read(".agents/skills/deploy/SKILL.md", in: later) == skill)
    }

    @Test func aCoreSkillLeavesCoreAndTheHomeFolderAfterTheProjectHasIt() async throws {
        try harnesses()
        let brain = try await renderedInCore()
        try await f.initRepo()

        let plan = plan([target], mode: .manual, brain: brain)
        #expect(plan.canApply, "\(plan.blockers) \(plan.parts.map(\.state))")
        #expect(plan.brainImport == nil && plan.sourceRendered && plan.trashSource.isEmpty && plan.extraCopies.isEmpty)
        let edit = try #require(plan.coreEdit)
        #expect(edit.before.contains("name: deploy") && !edit.after.contains("deploy"))
        #expect(plan.homePaths == [".agents/skills/deploy/SKILL.md"])
        #expect(!plan.homeExcluded.contains(".agents/skills/deploy/SKILL.md"))
        #expect(SkillMove.currentMode("deploy", brain: brain, installed: context().installed) == .manual)

        let outcome = try await SkillMove.apply(plan, brain: brain, env: f.env, trash: f.trash)
        #expect(!outcome.imported && outcome.coreChanged && outcome.home?.removed == [".agents/skills/deploy/SKILL.md"])
        #expect(coreSkills() == ["akit"])
        #expect(try await f.git("log", "-1", "--format=%s", in: f.brainRoot).hasPrefix("Render the core layer into home/test"))
        #expect(try await f.git("log", "-3", "--format=%s", in: f.brainRoot).contains("Remove skill deploy from layer core"))
        #expect(!fm.fileExists(atPath: f.home.appending(path: ".agents/skills/deploy").path))
        #expect(fm.fileExists(atPath: f.home.appending(path: ".agents/skills/akit/SKILL.md").path), "other core skills stay")
        #expect(f.read(".agents/skills/deploy/SKILL.md")?.contains("disable-model-invocation: true") == true)
        // The home record no longer lists the skill's files; another render changes nothing for it.
        let lock = try #require(ProjectRecords.savedLock(id: homeID, in: f.store))
        #expect(!lock.files.keys.contains { $0.hasPrefix(".agents/skills/deploy/") })
    }

    @Test func aHomeCopyEditedByHandStopsTheMove() async throws {
        try harnesses()
        let brain = try await renderedInCore()
        try await f.initRepo()
        try f.write(".agents/skills/deploy/SKILL.md", skill + "my notes\n")

        let plan = plan([target], brain: brain)
        #expect(!plan.canApply)
        #expect(plan.blockers.contains { $0.hasPrefix("~/.agents/skills/deploy/ was edited by hand since AKit wrote it") })
        let edit = try #require(plan.edits.first)
        #expect(edit.path == "~/.agents/skills/deploy/SKILL.md" && edit.brainText == skill && edit.copyText?.hasSuffix("my notes\n") == true)
        await #expect(throws: SkillMove.Failure.self) {
            try await SkillMove.apply(plan, brain: brain, env: f.env, trash: f.trash)
        }
        #expect(coreSkills().contains("deploy"))
    }

    @Test func aFailureInTheSecondProjectLeavesCoreAndHomeAsTheyWere() async throws {
        try harnesses()
        let brain = try await renderedInCore()
        try await f.initRepo()
        try fm.createDirectory(at: other, withIntermediateDirectories: true)

        let plan = plan([target, .init(id: "local/other", folder: other)], brain: brain)
        #expect(plan.canApply, "\(plan.blockers) \(plan.parts.map(\.state))")
        // The second project changes after the preview: its Apply stops.
        try f.write("Projects/other/.agents/skills/deploy/SKILL.md", "mine\n")
        do {
            try await SkillMove.apply(plan, brain: brain, env: f.env, trash: f.trash)
            Issue.record("the move went on")
        } catch {
            #expect(error.message.hasPrefix("Moving stopped at local/other: "))
            #expect(error.outcome.projects.map(\.id) == [f.id] && !error.outcome.coreChanged && error.outcome.home == nil)
        }
        #expect(coreSkills().contains("deploy"))
        #expect(fm.fileExists(atPath: f.home.appending(path: ".agents/skills/deploy/SKILL.md").path))
        #expect(f.read(".agents/skills/deploy/SKILL.md") != nil, "the first project has it")
    }

    @Test func aProjectsOwnCopyBlocksUntilKeptAndKeepingWritesNothing() async throws {
        try harnesses()
        let brain = try await renderedInCore()
        try await f.initRepo([".agents/skills/deploy/SKILL.md": "---\nname: deploy\ndescription: Ours\n---\n"])

        let blocked = plan([target], brain: brain)
        #expect(!blocked.canApply)
        let part = try #require(blocked.parts.first)
        guard case .blocked(let reason) = part.state else { Issue.record("not blocked: \(part.state)"); return }
        #expect(reason.contains("has its own deploy in .agents/skills (in git)") && part.ownTracked && part.ownFolder != nil)

        let kept = plan([.init(id: f.id, folder: f.project, keepOwn: true)], brain: brain)
        #expect(kept.canApply && kept.parts.first?.state == .keepOwn && kept.adding.isEmpty)
        let outcome = try await SkillMove.apply(kept, brain: brain, env: f.env, trash: f.trash)
        #expect(outcome.projects.isEmpty && outcome.coreChanged)
        #expect(f.read(".agents/skills/deploy/SKILL.md")?.contains("Ours") == true)
        #expect(ProjectRecords.savedAnswers(id: f.id, in: f.store) == nil)
        #expect(!coreSkills().contains("deploy"))
    }

    @Test func keepGlobalOnlyCopiesIntoTheProjects() async throws {
        try harnesses()
        let brain = try await renderedInCore()
        try await f.initRepo()
        let plan = plan([.init(id: f.id, folder: f.project, localOnly: false)], keepGlobal: true, brain: brain)
        #expect(plan.canApply && plan.coreEdit == nil && plan.home == nil && plan.trashSource.isEmpty)
        #expect(!plan.notes.contains { $0.hasPrefix("Other Macs: ") })
        try await SkillMove.apply(plan, brain: brain, env: f.env, trash: f.trash)
        #expect(coreSkills().contains("deploy"))
        #expect(fm.fileExists(atPath: f.home.appending(path: ".agents/skills/deploy/SKILL.md").path))
        #expect(f.read(".agents/skills/deploy/SKILL.md") != nil)
        #expect(ProjectRecords.savedAnswers(id: f.id, in: f.store)?.localOnly == false)
        #expect(try await f.git("status", "--porcelain", "--untracked-files=all").contains(".agents/"))
    }

    @Test func savedChoicesWinAndOtherPendingChangesWait() async throws {
        let brain = try await f.setUpBrain()
        try harnesses()
        try f.write(".agents/skills/deploy/SKILL.md", skill)
        try await f.initRepo()
        try await f.apply(f.answers(localOnly: false), brain: brain)
        // The layer changed since: its new text is a pending change Move leaves alone.
        try f.write(".akit/registry/layers/task/templates/agents.md", "# Task, revised\n")
        let changed = try #require(Brain.load(from: f.brainRoot))

        let plan = plan([target], brain: changed)
        let part = try #require(plan.parts.first)
        #expect(!part.isNew && !part.localOnly && part.savedLocalOnly == false)
        #expect(part.excluded.contains("AGENTS.md") && !part.paths.contains("AGENTS.md"))
        try await SkillMove.apply(plan, brain: changed, env: f.env, trash: f.trash)
        #expect(f.read("AGENTS.md") == "# Task\n")
        let answers = try #require(ProjectRecords.savedAnswers(id: f.id, in: f.store))
        #expect(answers.layers == ["task"] && answers.skills.map(\.name) == ["deploy"])
        // The next Set Up still offers the layer's new text.
        let after = try #require(Brain.load(from: f.brainRoot))
        #expect(f.plan(answers, brain: after).changes.contains { $0.path == "AGENTS.md" && $0.kind == .update })
    }

    @Test func readOnlySkillsAreRefusedAndMentionsWarn() async throws {
        let brain = try await f.setUpBrain()
        try harnesses()
        try f.write(".claude/skills/synced/bucket/cloud/SKILL.md", "---\nname: cloud\ndescription: From claude.ai\n---\n")
        let refused = SkillMove.plan(name: "cloud", targets: [target], mode: .auto, brain: brain, context: context())
        #expect(refused.blockers.contains { $0.hasPrefix("cloud is a claude.ai skill (synced by Claude), so AKit can't move it.") })

        try f.write(".agents/skills/deploy/SKILL.md", skill)
        try f.write(".akit/registry/layers/core/templates/agents.md", "Use the deploy skill to ship.\n")
        try f.write(".akit/registry/skills/review/SKILL.md", "---\nname: review\ndescription: Review\n---\nThen run /deploy.\n")
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        try f.write("Projects/other/AGENTS.md", "Ship with deploy.\n")
        let warned = plan([target], brain: try #require(Brain.load(from: f.brainRoot)), projectFolders: [f.id: f.project, "local/other": other])
        #expect(warned.warnings.contains { $0.hasPrefix("Strong: the core layer's templates mention deploy.") })
        #expect(warned.warnings.contains { $0.hasPrefix("The brain's skill review mentions deploy;") })
        #expect(warned.warnings.contains("AGENTS.md of local/other mentions deploy, but local/other won't have it."))

        #expect(SkillMove.mentions("deploy", in: "run deploy now") && SkillMove.mentions("deploy", in: "/deploy."))
        #expect(!SkillMove.mentions("deploy", in: "deploy-staging and redeploy") && !SkillMove.mentions("deploy", in: ""))
    }

    @Test func aProjectNotOnThisMacIsSkipped() async throws {
        let brain = try await f.setUpBrain()
        try harnesses()
        try f.write(".agents/skills/deploy/SKILL.md", skill)
        let plan = plan([.init(id: "github.com/me/away", folder: nil)], brain: brain)
        #expect(plan.parts.first?.state == .skipped("not on this Mac; set it up on a Mac that has it"))
        #expect(!plan.canApply, "nothing to move into")
        #expect(plan.warnings.contains("github.com/me/away: not on this Mac; set it up on a Mac that has it"))
    }
}
