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

    func context(projectFolders: [String: URL] = [:], store: ProjectStore? = nil) -> SkillMove.Context {
        let installed = SkillScanner.scan(installations: HarnessCatalog.detectAll(in: f.env), in: f.env)
        return SkillMove.Context(env: f.env, store: store ?? f.store, homeID: homeID, installed: installed, targets: ["claude", "pi"],
                                 projectFolders: projectFolders)
    }

    func plan(_ targets: [SkillMove.Target], mode: LayerSkill.Mode = .auto, keepGlobal: Bool = false, brain: Brain,
              projectFolders: [String: URL] = [:]) -> SkillMove.Plan {
        SkillMove.plan(name: "deploy", targets: targets, mode: mode, keepGlobal: keepGlobal, brain: brain,
                       context: context(projectFolders: projectFolders))
    }

    var target: SkillMove.Target { .init(id: f.id, folder: f.project) }

    /// Claude Code and Pi are "installed": their folders exist; Claude reads the shared folder through a link.
    /// `link: false`: the home render makes the `.claude/skills` link, so it is AKit's.
    func harnesses(link: Bool = true) throws {
        try fm.createDirectory(at: f.home.appending(path: ".pi/agent"), withIntermediateDirectories: true)
        try fm.createDirectory(at: f.home.appending(path: ".agents/skills"), withIntermediateDirectories: true)
        try fm.createDirectory(at: f.home.appending(path: ".claude"), withIntermediateDirectories: true)
        if link { try fm.createSymbolicLink(atPath: f.home.appending(path: ".claude/skills").path, withDestinationPath: "../.agents/skills") }
    }

    /// `deploy` in the brain and in core, rendered into the home folder. `only`: core lists nothing else.
    func renderedInCore(only: Bool = false) async throws -> Brain {
        _ = try await f.setUpBrain()
        try f.write(".akit/registry/skills/deploy/SKILL.md", skill)
        let core = try #require(f.read(".akit/registry/layers/core/layer.yaml", in: f.home))
        try f.write(".akit/registry/layers/core/layer.yaml", only ? "name: core\nskills:\n  - name: deploy\n    mode: manual\n"
                    : core + "  - name: deploy\n    mode: manual\n")
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
        try f.write(".pi/agent/skills/deploy/SKILL.md", skill)
        try f.write(".pi/agent/skills/deploy/scripts/run.sh", "echo deploy\n")
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

    @Test func aProjectNotOnThisMacGetsOnlyItsAnswersAndOneWithoutARecordBlocks() async throws {
        let brain = try await f.setUpBrain()
        try harnesses()
        try f.write(".agents/skills/deploy/SKILL.md", skill)
        try await f.initRepo()
        let unknown = plan([target, .init(id: "github.com/me/away", folder: nil)], brain: brain)
        guard case .blocked(let reason)? = unknown.parts.last?.state else { Issue.record("\(unknown.parts.map(\.state))"); return }
        #expect(reason.hasPrefix("is not on this Mac and AKit has no record of it.") && !unknown.canApply)

        // A record in the brain: only its answers get the skill, committed, next to a project here.
        try ProjectRecords.save(.init(brainCommit: nil, brainDirty: false, files: [:]), answers: ProjectAnswers(layers: ["task"], targets: ["pi"]),
                                id: "github.com/me/away", in: f.store)
        try await f.git("add", "-A", in: f.brainRoot)
        try await f.git("commit", "-qm", "Away", in: f.brainRoot)
        let mixed = plan([target, .init(id: "github.com/me/away", folder: nil)], brain: brain)
        #expect(mixed.canApply && mixed.answersOnly.map(\.id) == ["github.com/me/away"] && mixed.adding.map(\.id) == [f.id])
        #expect(mixed.notes.contains { $0.hasPrefix("github.com/me/away is not on this Mac: its answers get deploy") })
        let outcome = try await SkillMove.apply(mixed, brain: brain, env: f.env, trash: f.trash)
        #expect(outcome.answersSaved == ["github.com/me/away"] && outcome.projects.map(\.id) == [f.id])
        let away = try #require(ProjectRecords.savedAnswers(id: "github.com/me/away", in: f.store))
        #expect(away.layers == ["task"] && away.skills == [.init(name: "deploy", mode: .auto)])
        #expect(try await f.git("log", "--format=%s", in: f.brainRoot).contains("Add skill deploy to github.com/me/away's answers"))
        #expect(try await f.git("status", "--porcelain", "--", "projects", in: f.brainRoot).isEmpty)
    }

    @Test func anExtraCopyThatDiffersStopsTheMoveAndOneByHeaderNameStays() async throws {
        let brain = try await f.setUpBrain()
        try harnesses()
        try await f.initRepo()
        try f.write(".agents/skills/deploy/SKILL.md", skill)
        try f.write(".pi/agent/skills/deploy/SKILL.md", skill + "my Pi notes\n")
        try f.write(".pi/agent/skills/deploy/extra.md", "only here\n")
        // Another folder whose header says deploy: a different skill.
        try f.write(".pi/agent/skills/ship-it/SKILL.md", skill)
        let blocked = plan([target], brain: brain)
        #expect(!blocked.canApply && blocked.blockers.contains { $0.hasPrefix("~/.pi/agent/skills/deploy differs from the brain's deploy.") })
        #expect(blocked.edits.map(\.path) == ["~/.pi/agent/skills/deploy/SKILL.md", "~/.pi/agent/skills/deploy/extra.md"])
        #expect(blocked.edits.last?.brainText == nil && blocked.edits.last?.copyText == "only here\n")
        #expect(blocked.warnings.contains("~/.pi/agent/skills/ship-it also says deploy in its header, but it is a different folder; it stays where it is."))
        #expect(blocked.extraCopies.isEmpty)

        // The same files: it goes to the Trash; the other folder never does.
        try fm.removeItem(at: f.home.appending(path: ".pi/agent/skills/deploy"))
        try f.write(".pi/agent/skills/deploy/SKILL.md", skill)
        let plan = plan([target], brain: brain)
        #expect(plan.canApply && plan.extraCopies.count == 1, "\(plan.blockers)")
        try await SkillMove.apply(plan, brain: brain, env: f.env, trash: f.trash)
        #expect(!fm.fileExists(atPath: f.home.appending(path: ".pi/agent/skills/deploy").path))
        #expect(fm.fileExists(atPath: f.home.appending(path: ".pi/agent/skills/ship-it/SKILL.md").path))
    }

    @Test func aCopyEditedAfterThePreviewIsNotTrashed() async throws {
        let brain = try await f.setUpBrain()
        try harnesses()
        try await f.initRepo()
        try f.write(".agents/skills/deploy/SKILL.md", skill)
        try f.write(".agents/skills/deploy/notes.md", "v1\n")
        let plan = plan([target], brain: brain)
        #expect(plan.canApply)
        try f.write(".agents/skills/deploy/notes.md", "v2, written after the preview\n")
        do {
            try await SkillMove.apply(plan, brain: brain, env: f.env, trash: f.trash)
            Issue.record("the move went on")
        } catch {
            #expect(error.message.contains("changed since the preview") && !error.outcome.imported && error.outcome.projects.isEmpty)
        }
        #expect(f.read(".agents/skills/deploy/notes.md", in: f.home) == "v2, written after the preview\n")
        #expect(!fm.fileExists(atPath: f.brainRoot.appending(path: "skills/deploy").path) && trashed().isEmpty)
    }

    @Test func theClaudeLinkReplacesAnEmptyFolderAndALinkElsewhereBlocks() async throws {
        let brain = try await f.setUpBrain()
        try harnesses()
        try await f.initRepo()
        try f.write(".agents/skills/deploy/SKILL.md", skill)
        try fm.createDirectory(at: f.project.appending(path: ".claude/skills"), withIntermediateDirectories: true)
        let plan = plan([target], brain: brain)
        #expect(plan.canApply && plan.parts.first?.paths.contains(".claude/skills") == true, "\(plan.parts.map(\.state))")
        try await SkillMove.apply(plan, brain: brain, env: f.env, trash: f.trash)
        #expect(try fm.destinationOfSymbolicLink(atPath: f.project.appending(path: ".claude/skills").path) == "../.agents/skills")

        // A link of the user's elsewhere: Claude Code wouldn't see the skill.
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        try fm.createDirectory(at: other.appending(path: ".claude"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: other.appending(path: ".claude/skills").path, withDestinationPath: "/nowhere/skills")
        let elsewhere = SkillMove.plan(name: "deploy", targets: [.init(id: "local/other", folder: other)], mode: .auto, keepGlobal: true,
                                       brain: try #require(Brain.load(from: f.brainRoot)), context: context())
        guard case .blocked(let reason)? = elsewhere.parts.first?.state else { Issue.record("\(elsewhere.parts.map(\.state))"); return }
        #expect(reason.hasPrefix(".claude/skills links to /nowhere/skills, so Claude Code wouldn't see deploy there."))
    }

    @Test func aPendingSuggestionIsOfferedAgainAfterTheMove() async throws {
        let brain = try await f.setUpBrain()
        try harnesses()
        try f.write(".agents/skills/deploy/SKILL.md", skill)
        try await f.initRepo()
        try await f.apply(f.answers(localOnly: false), brain: brain)
        let before = try #require(ProjectRecords.savedLock(id: f.id, in: f.store))
        try f.write("Projects/task/AGENTS.md", "# Task\nOur own rules\n")
        try f.write(".akit/registry/layers/task/templates/agents.md", "# Task, revised\n")
        let changed = try #require(Brain.load(from: f.brainRoot))
        #expect(f.plan(f.answers(localOnly: false), brain: changed).changes.first { $0.path == "AGENTS.md" }?.kind == .suggest)

        try await SkillMove.apply(plan([target], brain: changed), brain: changed, env: f.env, trash: f.trash)
        let after = try #require(Brain.load(from: f.brainRoot))
        let answers = try #require(ProjectRecords.savedAnswers(id: f.id, in: f.store))
        #expect(f.plan(answers, brain: after).changes.first { $0.path == "AGENTS.md" }?.kind == .suggest)
        // Not fully up to date: the lock keeps the brain commit of the last full render.
        #expect(ProjectRecords.savedLock(id: f.id, in: f.store)?.brainCommit == before.brainCommit)
    }

    @Test func aSourceLinkedFromADevFolderImportsOnlyThatSkill() async throws {
        let brain = try await f.setUpBrain()
        try harnesses()
        try await f.initRepo()
        try f.write("dev/deploy/SKILL.md", skill)
        try f.write("dev/deploy/run.sh", "echo\n")
        try f.write("dev/sideproject/SKILL.md", "---\nname: sideproject\ndescription: Not this\n---\n")
        try fm.createSymbolicLink(atPath: f.home.appending(path: ".agents/skills/deploy").path, withDestinationPath: f.home.appending(path: "dev/deploy").path)
        let plan = plan([target], brain: brain)
        #expect(plan.canApply && plan.brainImport?.candidates.map(\.name) == ["deploy"], "\(plan.blockers)")
        try await SkillMove.apply(plan, brain: brain, env: f.env, trash: f.trash)
        #expect(!fm.fileExists(atPath: f.brainRoot.appending(path: "skills/sideproject").path))
        #expect(fm.fileExists(atPath: f.home.appending(path: "dev/deploy/SKILL.md").path), "only the link goes")
        #expect((try? fm.destinationOfSymbolicLink(atPath: f.home.appending(path: ".agents/skills/deploy").path)) == nil)

        // The brain's copy differs from the dev folder: every differing file is shown.
        try f.write("dev/deploy/run.sh", "echo changed\n")
        try f.write("dev/deploy/new.md", "new\n")
        try fm.createSymbolicLink(atPath: f.home.appending(path: ".agents/skills/deploy").path, withDestinationPath: f.home.appending(path: "dev/deploy").path)
        let differs = SkillMove.plan(name: "deploy", targets: [target], mode: .auto, brain: try #require(Brain.load(from: f.brainRoot)), context: context())
        #expect(!differs.canApply && differs.edits.map { $0.path.components(separatedBy: "/").last ?? "" } == ["new.md", "run.sh"])
    }

    @Test func aHomeApplyFailureAfterTheCoreCommitSaysWhereTheSkillIs() async throws {
        try harnesses()
        let brain = try await renderedInCore()
        try await f.initRepo()
        let plan = plan([target], brain: brain)
        #expect(plan.canApply)
        // The Trash refuses the home copy: its Apply stops, after core.
        do {
            try await SkillMove.apply(plan, brain: brain, env: f.env, trash: { _ in throw CocoaError(.fileWriteNoPermission) })
            Issue.record("the move went on")
        } catch {
            #expect(error.message.hasPrefix("deploy is in the projects and out of the core layer, but the home folder's copy stayed in ~/.agents/skills/deploy:"))
            #expect(error.message.hasSuffix("Brain → core → Update Home Folder… (akit apply --home) takes it out."))
            #expect(error.outcome.coreChanged && error.outcome.projects.map(\.id) == [f.id])
        }
        #expect(!coreSkills().contains("deploy") && fm.fileExists(atPath: f.home.appending(path: ".agents/skills/deploy/SKILL.md").path))
    }

    @Test func aHomeCopyEditedAfterThePreviewStopsBeforeAnything() async throws {
        try harnesses()
        let brain = try await renderedInCore()
        try await f.initRepo()
        let plan = plan([target], brain: brain)
        try f.write(".agents/skills/deploy/SKILL.md", skill + "late edit\n")
        do {
            try await SkillMove.apply(plan, brain: brain, env: f.env, trash: f.trash)
            Issue.record("the move went on")
        } catch {
            #expect(error.message == "~/.agents/skills/deploy/SKILL.md changed since the preview. Look at the preview again.")
            #expect(error.outcome.projects.isEmpty && !error.outcome.coreChanged && !error.outcome.imported)
        }
        #expect(coreSkills().contains("deploy") && f.read(".agents/skills/deploy/SKILL.md") == nil)
    }

    @Test func aDeferredHomeApplyKeepsTheLastFullRendersRecord() async throws {
        try harnesses()
        _ = try await renderedInCore()
        try await f.initRepo()
        // Core gains a skill after the home render: a pending change the move leaves for later.
        try f.write(".akit/registry/skills/later/SKILL.md", "---\nname: later\ndescription: Later\n---\n")
        let core = try #require(f.read(".akit/registry/layers/core/layer.yaml", in: f.home))
        try f.write(".akit/registry/layers/core/layer.yaml", core + "  - later\n")
        try await f.git("add", "-A", in: f.brainRoot)
        try await f.git("commit", "-qm", "Add later", in: f.brainRoot)
        var lock = try #require(ProjectRecords.savedLock(id: homeID, in: f.store))
        lock.brainCommit = "abc1234"
        lock.brainDirty = true
        lock.piAgentDir = "/remembered/pi"
        try ProjectRecords.save(lock, answers: nil, id: homeID, in: f.store)
        let brain = try #require(Brain.load(from: f.brainRoot))
        let plan = plan([target], brain: brain)
        #expect(plan.homeExcluded.contains(".agents/skills/later/SKILL.md"))
        try await SkillMove.apply(plan, brain: brain, env: f.env, trash: f.trash)
        let after = try #require(ProjectRecords.savedLock(id: homeID, in: f.store))
        #expect(after.brainCommit == "abc1234" && after.brainDirty && after.piAgentDir == "/remembered/pi")
        #expect(!after.files.keys.contains { $0.hasPrefix(".agents/skills/deploy/") } && after.files[".agents/skills/later/SKILL.md"] == nil)
    }

    @Test func onAWorkMacAProjectOnAnotherMacIsBlocked() async throws {
        let brain = try await f.setUpBrain()
        try harnesses()
        try f.write(".agents/skills/deploy/SKILL.md", skill)
        try await f.initRepo()
        let work = ProjectStore.local(home: f.home, readingBrain: f.brainRoot)
        // A record in the local store, and one only in the brain (read as a fallback).
        try ProjectRecords.save(.init(brainCommit: nil, brainDirty: false, files: [:]), answers: ProjectAnswers(targets: ["pi"]), id: "github.com/me/local", in: work)
        try ProjectRecords.save(.init(brainCommit: nil, brainDirty: false, files: [:]), answers: ProjectAnswers(targets: ["pi"]), id: "github.com/me/old", in: f.store)
        let plan = SkillMove.plan(name: "deploy", targets: [target, .init(id: "github.com/me/local", folder: nil), .init(id: "github.com/me/old", folder: nil)],
                                  mode: .auto, brain: brain, context: context(store: work))
        #expect(!plan.canApply && plan.answersOnly.isEmpty)
        for part in plan.parts.dropFirst() {
            #expect(part.state == .blocked("is not on this Mac, and on a work Mac a project's answers live on the Mac that set it up; move it there, or keep the skill global."))
        }
    }

    @Test func copiesTheTrashCantCheckOrWouldTakeHistoryAlongBlock() async throws {
        let brain = try await f.setUpBrain()
        try harnesses()
        try await f.initRepo()
        try f.write(".agents/skills/deploy/SKILL.md", skill)
        // A clone: its git history isn't copied into the brain and would go to the Trash.
        try f.write(".agents/skills/deploy/.git/HEAD", "ref: refs/heads/main\n")
        let clone = plan([target], brain: brain)
        #expect(!clone.canApply && clone.blockers.contains("~/.agents/skills/deploy has its own git history; move or remove it by hand, then move again."))
        #expect(clone.warnings.contains { $0.hasPrefix("Not in the brain's copy, and in the Trash with ~/.agents/skills/deploy: .git (git data)") })
        try fm.removeItem(at: f.home.appending(path: ".agents/skills/deploy/.git"))

        // A part AKit can't read.
        let locked = f.home.appending(path: ".agents/skills/deploy/private")
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        try f.write(".agents/skills/deploy/private/notes.md", "x\n")
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let unreadable = plan([target], brain: brain)
        #expect(unreadable.blockers.contains { $0.hasPrefix("~/.agents/skills/deploy has parts AKit can't read") }, "\(unreadable.blockers)")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        try fm.removeItem(at: locked)

        // Too many files to check again.
        let many = f.home.appending(path: ".agents/skills/deploy/many")
        try fm.createDirectory(at: many, withIntermediateDirectories: true)
        for index in 0..<10_001 { _ = fm.createFile(atPath: many.appending(path: "\(index)").path, contents: nil) }
        let large = plan([target], brain: brain)
        #expect(large.blockers.contains { $0.hasPrefix("~/.agents/skills/deploy holds more than 10,000 files") })
        #expect(SkillMove.treeDigest(many, limit: 10_001) != SkillMove.digestTooLarge && SkillMove.treeDigest(many, limit: 10) == SkillMove.digestTooLarge)
    }

    @Test func aLinkOnlyExtraCopyLosesOnlyTheLink() async throws {
        let brain = try await f.setUpBrain()
        try harnesses()
        try await f.initRepo()
        try f.write(".agents/skills/deploy/SKILL.md", skill)
        try f.write("dev/deploy-pi/SKILL.md", skill + "different, but only linked\n")
        try fm.createDirectory(at: f.home.appending(path: ".pi/agent/skills"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: f.home.appending(path: ".pi/agent/skills/deploy").path,
                                  withDestinationPath: f.home.appending(path: "dev/deploy-pi").path)
        let plan = plan([target], brain: brain)
        #expect(plan.canApply && plan.extraCopies.count == 1, "\(plan.blockers)")
        try await SkillMove.apply(plan, brain: brain, env: f.env, trash: f.trash)
        #expect((try? fm.destinationOfSymbolicLink(atPath: f.home.appending(path: ".pi/agent/skills/deploy").path)) == nil)
        #expect(f.read("dev/deploy-pi/SKILL.md", in: f.home)?.hasSuffix("only linked\n") == true)
    }

    @Test func aFailedImportCommitSaysTheCopyMayBeUncommitted() async throws {
        let brain = try await f.setUpBrain()
        try harnesses()
        try await f.initRepo()
        try f.write(".agents/skills/deploy/SKILL.md", skill)
        try f.write(".akit/registry/.git/hooks/pre-commit", "#!/bin/sh\nexit 1\n")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.brainRoot.appending(path: ".git/hooks/pre-commit").path)
        do {
            try await SkillMove.apply(plan([target], brain: brain), brain: brain, env: f.env, trash: f.trash)
            Issue.record("the move went on")
        } catch {
            #expect(error.message.contains("skills/deploy may be in the brain, uncommitted: commit or remove it, then move again."))
            #expect(error.outcome.projects.isEmpty && !error.outcome.coreChanged)
        }
        #expect(f.read(".agents/skills/deploy/SKILL.md") == nil && fm.fileExists(atPath: f.home.appending(path: ".agents/skills/deploy").path))
    }

    @Test func takingCoresLastSkillOutKeepsTheClaudeLinkWhileOtherSkillsAreThere() async throws {
        try harnesses(link: false)
        let brain = try await renderedInCore(only: true)
        try await f.initRepo()
        #expect(ProjectRecords.savedLock(id: homeID, in: f.store)?.files[".claude/skills"]?.link == "../.agents/skills")
        try f.write(".agents/skills/mine/SKILL.md", "---\nname: mine\ndescription: Mine\n---\n")
        try await SkillMove.apply(plan([target], brain: brain), brain: brain, env: f.env, trash: f.trash)
        #expect(coreSkills().isEmpty)
        // A later Update Home Folder keeps the link: ~/.agents/skills still has a skill.
        let later = ProjectSetup.plan(project: f.home, id: homeID, answers: ProjectAnswers(layers: ["core"], targets: ["claude", "pi"]),
                                      brain: try #require(Brain.load(from: f.brainRoot)), store: f.store, forHome: true, env: f.env)
        #expect(later.changes.first { $0.path == ".claude/skills" }?.kind == .same, "\(later.changes.map { ($0.path, $0.kind) })")
        try fm.removeItem(at: f.home.appending(path: ".agents/skills/mine"))
        let empty = ProjectSetup.plan(project: f.home, id: homeID, answers: ProjectAnswers(layers: ["core"], targets: ["claude", "pi"]),
                                      brain: try #require(Brain.load(from: f.brainRoot)), store: f.store, forHome: true, env: f.env)
        #expect(empty.changes.first { $0.path == ".claude/skills" }?.kind == .remove)
    }

    @Test func keepOwnChecksTheOwnCopyAgainAndWarnsWhenItIsNotInGit() async throws {
        try harnesses()
        let brain = try await renderedInCore()
        try await f.initRepo()
        try f.write("Projects/task/.agents/skills/deploy/SKILL.md", "---\nname: deploy\ndescription: Ours\n---\n")
        let kept = plan([.init(id: f.id, folder: f.project, keepOwn: true)], brain: brain)
        #expect(kept.canApply && kept.parts.first?.ownTracked == false)
        #expect(kept.warnings.contains { $0.hasPrefix("local/task's own deploy is not in git: its git worktrees won't have deploy") })
        try fm.removeItem(at: f.project.appending(path: ".agents/skills/deploy"))
        do {
            try await SkillMove.apply(kept, brain: brain, env: f.env, trash: f.trash)
            Issue.record("the move went on")
        } catch {
            #expect(error.message == "local/task's own deploy is gone since the preview. Look at the preview again.")
        }
        #expect(coreSkills().contains("deploy"))
    }
}
