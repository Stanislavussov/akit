import Foundation
import Testing
import AKitBrain
import AKitFoundation
import AKitHarnesses
import AKitSkills
@testable import AKitProjectSetup

/// Move to Global: a project's skill into the core layer and the home folder, then out of the
/// projects. A fake home with Claude Code and Pi, a brain, a git project with a linked worktree;
/// the Trash is the fixture's folder.
struct SkillMoveToGlobalTests {
    let move: SkillMoveTests
    var f: GitProjectFixture { move.f }
    let fm = FileManager.default

    init() throws { move = try SkillMoveTests() }

    func context(_ projects: [String: URL], store: ProjectStore? = nil) -> SkillMove.Context {
        let installed = SkillScanner.scan(installations: HarnessCatalog.detectAll(in: f.env), projects: Array(projects.values), in: f.env)
        return SkillMove.Context(env: f.env, store: store ?? f.store, homeID: move.homeID, installed: installed, targets: ["claude", "pi"],
                                 projectFolders: projects)
    }

    func exists(_ path: String, in folder: URL? = nil) -> Bool {
        var info = stat()
        return lstat((folder ?? f.home).appending(path: path).path, &info) == 0
    }

    /// deploy in the brain's library (no layer), committed.
    func brainWithDeploy() async throws -> Brain {
        _ = try await f.setUpBrain()
        try f.write(".akit/registry/skills/deploy/SKILL.md", move.skill)
        try await f.git("add", "-A", in: f.brainRoot)
        try await f.git("commit", "-qm", "Add deploy", in: f.brainRoot)
        return try #require(Brain.load(from: f.brainRoot))
    }

    @Test func aProjectsAnswersSkillBecomesGlobalAndLeavesTheProjectAndItsWorktree() async throws {
        try move.harnesses()
        let brain = try await brainWithDeploy()
        try await f.initRepo()
        try await f.git("worktree", "add", "-q", "-b", "x", move.tree.path)
        try await f.apply(ProjectAnswers(targets: ["claude", "pi"], skills: [.init(name: "deploy", mode: .manual)], localOnly: true), brain: brain)
        #expect(exists(".agents/skills/deploy", in: move.tree))

        #expect(SkillMove.projectsListing("deploy", brain: brain, store: f.store) == [f.id])
        let plan = SkillMove.planToGlobal(name: "deploy", from: nil, mode: nil, brain: brain, context: context([f.id: f.project]))
        #expect(plan.canApply, "\(plan.blockers) \(plan.parts.map(\.state))")
        #expect(plan.mode == .manual && plan.brainImport == nil, "the mode comes from the project's answers")
        let edit = try #require(plan.coreEdit)
        #expect(!edit.before.contains("deploy") && edit.after.contains("name: deploy") && edit.after.contains("mode: manual"))
        #expect(plan.homePaths.contains(".agents/skills/deploy/SKILL.md") && !plan.homePaths.contains(".agents/skills/akit/SKILL.md"))
        let part = try #require(plan.parts.first)
        #expect(part.state == .answers && part.paths == [".agents/skills/deploy/SKILL.md"] && part.worktrees.map(\.lastPathComponent) == ["task-x"])

        var held: [String] = []
        let outcome = try await SkillMove.applyToGlobal(plan, brain: brain, env: f.env, trash: f.trash) { id, work in
            held.append(id)
            // The skill is in the home folder before any project loses it.
            if id == f.id { #expect(exists(".agents/skills/deploy/SKILL.md")) }
            return try await work()
        }
        #expect(held == [move.homeID, f.id] && outcome.coreChanged && !outcome.imported)

        // Core lists it (committed), the home folder has it; the project, its worktree and its answers don't.
        #expect(move.coreSkills().contains("deploy"))
        #expect(try await f.git("log", "--format=%s", in: f.brainRoot).contains("Add deploy to layer core"))
        #expect(f.read(".agents/skills/deploy/SKILL.md", in: f.home)?.contains("disable-model-invocation: true") == true)
        #expect(!exists(".agents/skills/deploy", in: f.project) && !exists(".agents/skills/deploy", in: move.tree))
        #expect(ProjectRecords.savedAnswers(id: f.id, in: f.store)?.skills.isEmpty == true)
        #expect(try await f.git("status", "--porcelain", "--untracked-files=all").isEmpty)
        #expect(try await f.git("status", "--porcelain", "--untracked-files=all", in: move.tree).isEmpty)
        #expect(move.trashed().count == 1)
    }

    @Test func aProjectsOwnCopyIsImportedFirstAndTrashedLast() async throws {
        try move.harnesses()
        _ = try await f.setUpBrain()
        try await f.initRepo()
        try f.write("Projects/task/.agents/skills/deploy/SKILL.md", move.skill)
        try f.write("Projects/task/.agents/skills/deploy/run.sh", "echo\n")
        let brain = try #require(Brain.load(from: f.brainRoot))
        // Not listed in any answers: the project is named.
        let none = SkillMove.planToGlobal(name: "deploy", from: nil, mode: nil, brain: brain, context: context([f.id: f.project]))
        #expect(!none.canApply && none.blockers.first?.hasPrefix("No project's answers list deploy") == true)

        let plan = SkillMove.planToGlobal(name: "deploy", from: [f.id], mode: .auto, brain: brain, context: context([f.id: f.project]))
        #expect(plan.canApply && plan.brainImport != nil && plan.parts.first?.state == .ownCopy, "\(plan.blockers) \(plan.parts.map(\.state))")
        let outcome = try await SkillMove.applyToGlobal(plan, brain: brain, env: f.env, trash: f.trash)
        #expect(outcome.imported && outcome.coreChanged && outcome.trashed == ["~/Projects/task/.agents/skills/deploy"])
        #expect(f.read(".akit/registry/skills/deploy/run.sh", in: f.home) == "echo\n")
        #expect(f.read(".agents/skills/deploy/run.sh", in: f.home) == "echo\n")
        #expect(!exists(".agents/skills/deploy", in: f.project))
        #expect(try await f.git("log", "-3", "--format=%s", in: f.brainRoot).contains("Import skill deploy"))
    }

    @Test func aTrackedOrDifferingOwnCopyBlocks() async throws {
        try move.harnesses()
        let brain = try await brainWithDeploy()
        try await f.initRepo([".agents/skills/deploy/SKILL.md": move.skill])
        let tracked = SkillMove.planToGlobal(name: "deploy", from: [f.id], mode: nil, brain: brain, context: context([f.id: f.project]))
        guard case .blocked(let reason)? = tracked.parts.first?.state else { Issue.record("\(tracked.parts.map(\.state))"); return }
        #expect(reason.contains("Tracked in git in ~/Projects/task"), "\(reason)")

        try await f.git("rm", "-rq", "--cached", ".agents")
        try await f.git("commit", "-qm", "Untrack")
        try f.write("Projects/task/.agents/skills/deploy/SKILL.md", move.skill + "ours\n")
        let differs = SkillMove.planToGlobal(name: "deploy", from: [f.id], mode: nil, brain: brain, context: context([f.id: f.project]))
        #expect(!differs.canApply && differs.blockers.contains { $0.hasPrefix("~/Projects/task/.agents/skills/deploy differs from the brain's deploy.") })
        #expect(differs.edits.first?.copyText?.hasSuffix("ours\n") == true)
    }

    @Test func aFailedProjectStepSaysWhereTheSkillIs() async throws {
        try move.harnesses()
        let brain = try await brainWithDeploy()
        try await f.initRepo()
        try await f.apply(ProjectAnswers(targets: ["claude", "pi"], skills: [.init(name: "deploy", mode: .auto)], localOnly: true), brain: brain)
        let plan = SkillMove.planToGlobal(name: "deploy", from: nil, mode: nil, brain: brain, context: context([f.id: f.project]))
        do {
            try await SkillMove.applyToGlobal(plan, brain: brain, env: f.env, trash: { _ in throw CocoaError(.fileWriteNoPermission) })
            Issue.record("the move went on")
        } catch {
            #expect(error.message.hasPrefix("deploy is in the core layer and the home folder, but taking it out of local/task stopped:"), "\(error.message)")
            #expect(error.outcome.coreChanged && error.outcome.home != nil && error.outcome.projects.isEmpty)
        }
        #expect(exists(".agents/skills/deploy/SKILL.md") && exists(".agents/skills/deploy", in: f.project))
    }

    @Test func onAWorkMacAPersonalProjectsBrainAnswersLoseOnlyThatEntry() async throws {
        try move.harnesses()
        let brain = try await brainWithDeploy()
        try MachineProfile(kind: .work, name: "work").save(home: f.home)
        let work = ProjectStore.local(home: f.home, readingBrain: f.brainRoot)
        try await f.git("config", "user.name", "pseudo-mac", in: f.brainRoot)
        try await f.git("config", "user.email", "pseudo@example.invalid", in: f.brainRoot)
        let personal = ProjectAnswers(layers: ["task"], targets: ["pi"], skills: [.init(name: "tdd", mode: .manual), .init(name: "deploy", mode: .auto)])
        try ProjectRecords.save(.init(brainCommit: nil, brainDirty: false, files: [:]), answers: personal, id: "github.com/me/old", in: f.store)
        try await f.git("add", "-A", in: f.brainRoot)
        try await f.git("commit", "-qm", "Old", in: f.brainRoot)

        let plan = SkillMove.planToGlobal(name: "deploy", from: nil, mode: nil, brain: brain, context: context([:], store: work))
        #expect(plan.canApply && plan.parts.first?.state == .answersOnly && plan.parts.first?.workBrainAnswers == true,
                "\(plan.blockers) \(plan.parts.map(\.state))")
        let outcome = try await SkillMove.applyToGlobal(plan, brain: brain, env: f.env, trash: f.trash)
        #expect(outcome.answersSaved == ["github.com/me/old"])
        #expect(ProjectRecords.savedAnswers(id: "github.com/me/old", in: f.store)?.skills == [.init(name: "tdd", mode: .manual)])
        #expect(try await f.git("log", "-1", "--format=%an|%s", "--", "projects/github.com/me/old/answers.json", in: f.brainRoot)
                == "pseudo-mac|Remove skill deploy from github.com/me/old's answers\n")
        #expect(!fm.fileExists(atPath: work.folder(id: "github.com/me/old").path), "nothing in ~/.akit/local for it")
    }

    @Test func aClaudeSkillsFolderOfItsOwnBlocksTakingAProjectCopyClaudeLoads() async throws {
        try move.harnesses(link: false)
        try fm.createDirectory(at: f.home.appending(path: ".claude/skills/mine"), withIntermediateDirectories: true)
        try f.write(".claude/skills/mine/SKILL.md", "---\nname: mine\ndescription: Mine\n---\n")
        let brain = try await brainWithDeploy()
        try await f.initRepo()
        try await f.apply(ProjectAnswers(targets: ["claude", "pi"], skills: [.init(name: "deploy", mode: .auto)], localOnly: true), brain: brain)
        let plan = SkillMove.planToGlobal(name: "deploy", from: nil, mode: nil, brain: brain, context: context([f.id: f.project]))
        #expect(!plan.canApply)
        #expect(plan.blockers.contains { $0.hasPrefix("~/.claude/skills is a folder of its own, so Claude Code wouldn't see deploy from the home folder, and the move takes it out of local/task") },
                "\(plan.blockers)")
    }
}
