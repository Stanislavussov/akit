import Foundation
import Testing
@testable import AKitCore

/// Planning and applying a render to a project, all inside a temporary fake home.
struct ProjectSetupTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-setup-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var env: HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home, variables: [
            "HOME": home.path, "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
            "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
        ], executableSearchPaths: [URL(filePath: "/usr/bin")])
    }

    var brainRoot: URL { Brain.defaultRoot(home: home) }
    var project: URL { home.appending(path: "Projects/task") }

    func write(_ path: String, _ text: String = "") throws {
        let url = home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func read(_ path: String) -> String? { try? String(contentsOf: project.appending(path: path), encoding: .utf8) }

    /// Moves "trashed" files into a folder of the fake home instead of the real Trash.
    func trash(_ url: URL) throws -> URL? {
        let target = home.appending(path: "Trash/\(UUID().uuidString)-\(url.lastPathComponent)")
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: url, to: target)
        return target
    }

    func git(_ args: String...) async throws -> String {
        let result = try #require(await ProcessRunner.run(URL(filePath: "/usr/bin/git"), arguments: args,
                                                           directory: brainRoot, environment: env.variables, timeout: 10))
        #expect(result.succeeded, "\(result.output)")
        return result.output
    }

    func setUpBrain() async throws -> Brain {
        try await BrainSetup.create(at: brainRoot, env: env)
        try write(".akit/registry/skills/tdd/SKILL.md", "---\nname: tdd\ndescription: Tests first\n---\n")
        try write(".akit/registry/layers/task/layer.yaml", """
            fields:
              - id: company
                required: true
              - id: review
                type: bool
                default: true
            skills:
              - name: tdd
                mode: manual
            files:
              - template: agents.md
                to: AGENTS.md
              - template: REVIEW.md
                when: review
            """)
        try write(".akit/registry/layers/task/templates/agents.md", "# Task for {{company}}\n")
        try write(".akit/registry/layers/task/templates/REVIEW.md", "Review {{company}}\n")
        _ = try await git("add", "-A")
        _ = try await git("commit", "-qm", "Add task layer")
        return try #require(Brain.load(from: brainRoot))
    }

    var answers: ProjectAnswers {
        ProjectAnswers(layers: ["task"], values: ["company": .text("Acme")], targets: ["claude", "pi"])
    }

    @Test func applyRefusesAPlanMadeBeforeTheMacBecameAWorkMac() async throws {
        let brain = try await setUpBrain()
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        let plan = ProjectSetup.plan(project: project, id: "local/task", answers: answers, brain: brain,
                                     store: .current(brain: brainRoot, home: home))
        #expect(!plan.store.isLocal)
        try MachineProfile(kind: .work).save(home: home)
        await #expect(throws: ProjectSetup.Failure.self) {
            try await ProjectSetup.apply(plan, brain: brain, home: home, env: env, trash: trash)
        }
        #expect(read("AGENTS.md") == nil)
        #expect(!fm.fileExists(atPath: brainRoot.appending(path: "projects/local").path))
    }

    @Test func remoteURLsBecomeIDs() {
        #expect(ProjectSetup.normalizedRemote("git@github.com:Owner/Repo.git\n") == "github.com/owner/repo")
        #expect(ProjectSetup.normalizedRemote("https://user@github.com/owner/repo") == "github.com/owner/repo")
        #expect(ProjectSetup.normalizedRemote("ssh://git@gitlab.example.com:2222/group/sub/proj.git") == "gitlab.example.com/group/sub/proj")
        #expect(ProjectSetup.normalizedRemote("https://github.com/../../etc") == "github.com/etc")
        #expect(ProjectSetup.normalizedRemote("") == nil)
        #expect(ProjectSetup.normalizedRemote("https://me:p/ss@github.com/o/r.git") == "github.com/o/r")
        #expect(ProjectSetup.normalizedRemote("https://host/.git/x/y") == "host/x/y")
    }

    @Test func projectOutsideTheRootGetsAHashedID() async throws {
        let other = home.appending(path: "Elsewhere/app")
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        let id = await ProjectSetup.projectID(for: other, projectsRoot: home.appending(path: "Projects"), env: env)
        #expect(id.hasPrefix("local/app-") && id.count == "local/app-".count + 8)
    }

    @Test func changesAfterThePreviewAreNeverOverwritten() async throws {
        let brain = try await setUpBrain()
        try fm.createDirectory(at: project, withIntermediateDirectories: true)

        // A real .claude/skills folder appears after the preview.
        let plan = ProjectSetup.plan(project: project, id: "local/task", answers: answers, brain: brain, store: .brain(brainRoot))
        try write("Projects/task/.claude/skills/mine/SKILL.md", "mine")
        await #expect(throws: ProjectSetup.Failure.self) {
            try await ProjectSetup.apply(plan, brain: brain, home: home, env: env, trash: trash)
        }
        #expect(read(".claude/skills/mine/SKILL.md") == "mine")
        try fm.removeItem(at: project.appending(path: ".claude"))

        // .agents becomes a link out of the project after the preview.
        let second = ProjectSetup.plan(project: project, id: "local/task", answers: answers, brain: brain, store: .brain(brainRoot))
        try fm.createDirectory(at: home.appending(path: "outside"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: project.appending(path: ".agents"), withDestinationURL: home.appending(path: "outside"))
        await #expect(throws: ProjectSetup.Failure.self) {
            try await ProjectSetup.apply(second, brain: brain, home: home, env: env, trash: trash)
        }
        #expect(try fm.contentsOfDirectory(atPath: home.appending(path: "outside").path).isEmpty)
    }

    @Test func aLinkedFileIsShownAndBackedUpAsALink() async throws {
        let brain = try await setUpBrain()
        try write("Projects/task/NOTES.md", "notes")
        try fm.createSymbolicLink(atPath: project.appending(path: "CLAUDE.md").path, withDestinationPath: "NOTES.md")
        let plan = ProjectSetup.plan(project: project, id: "local/task", answers: answers, brain: brain, store: .brain(brainRoot))
        let change = try #require(plan.changes.first { $0.path == "CLAUDE.md" })
        #expect(change.kind == .update && change.replacesUnmanaged && change.oldText == "→ NOTES.md (a link)")

        let outcome = try await ProjectSetup.apply(plan, brain: brain, home: home, env: env, trash: trash)
        #expect(read("CLAUDE.md") == "@AGENTS.md\n")
        #expect(read("NOTES.md") == "notes")
        let backup = try #require(outcome.backup).appending(path: "Projects/task/CLAUDE.md")
        #expect(try fm.destinationOfSymbolicLink(atPath: backup.path) == "NOTES.md")
    }

    @Test func handEditsAreFlaggedAndAFailedApplyStillRecordsWhatItWrote() async throws {
        let brain = try await setUpBrain()
        _ = try await ProjectSetup.apply(ProjectSetup.plan(project: project, id: "local/task", answers: answers, brain: brain, store: .brain(brainRoot)),
                                         brain: brain, home: home, env: env, trash: trash)
        try write("Projects/task/AGENTS.md", "hand edit")
        var next = answers
        next.values["company"] = .text("Beta")
        next.values["review"] = .bool(false)
        let plan = ProjectSetup.plan(project: project, id: "local/task", answers: next, brain: brain, store: .brain(brainRoot))
        #expect(plan.changes.first { $0.path == "AGENTS.md" }?.editedSinceRender == true)

        // The Trash fails on REVIEW.md: AGENTS.md was already written and must be in the lock.
        await #expect(throws: ProjectSetup.Failure.self) {
            try await ProjectSetup.apply(plan, brain: brain, home: home, env: env,
                                         trash: { _ in throw CocoaError(.fileWriteNoPermission) })
        }
        let lock = try #require(ProjectSetup.savedLock(id: "local/task", in: .brain(brainRoot)))
        #expect(lock.files["AGENTS.md"]?.sha256 == ProjectSetup.sha256(Data("# Task for Beta\n".utf8)))
    }

    @Test func projectWithoutRemoteUsesItsPath() async throws {
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        #expect(await ProjectSetup.projectID(for: project, projectsRoot: home.appending(path: "Projects"), env: env) == "local/task")
    }

    @Test func firstRenderWritesFilesBacksUpAndSavesAnswers() async throws {
        let brain = try await setUpBrain()
        try write("Projects/task/CLAUDE.md", "# My own rules\n")

        let plan = ProjectSetup.plan(project: project, id: "local/task", answers: answers, brain: brain, store: .brain(brainRoot))
        #expect(plan.canApply, "\(plan.render.errors) \(plan.blockers)")
        let kinds = Dictionary(uniqueKeysWithValues: plan.changes.map { ($0.path, $0.kind) })
        #expect(kinds == ["AGENTS.md": .create, "CLAUDE.md": .update, "REVIEW.md": .create,
                          ".agents/skills/tdd/SKILL.md": .create, ".claude/skills": .create])
        #expect(plan.changes.first { $0.path == "CLAUDE.md" }?.replacesUnmanaged == true)

        let outcome = try await ProjectSetup.apply(plan, brain: brain, home: home, env: env, trash: trash)
        #expect(read("AGENTS.md") == "# Task for Acme\n")
        #expect(read("CLAUDE.md") == "@AGENTS.md\n")
        #expect(read(".claude/skills/tdd/SKILL.md")?.contains("disable-model-invocation: true") == true)
        let backup = try #require(outcome.backup)
        #expect(try String(contentsOf: backup.appending(path: "Projects/task/CLAUDE.md"), encoding: .utf8) == "# My own rules\n")

        #expect(ProjectSetup.savedAnswers(id: "local/task", in: .brain(brainRoot)) == answers)
        let lock = try #require(ProjectSetup.savedLock(id: "local/task", in: .brain(brainRoot)))
        #expect(lock.files.keys.sorted() == [".agents/skills/tdd/SKILL.md", ".claude/skills", "AGENTS.md", "CLAUDE.md", "REVIEW.md"])
        #expect(lock.brainCommit?.isEmpty == false)
        #expect(!lock.brainDirty)
        #expect(try await git("log", "-1", "--format=%s") == "Render task\n")
        // Nothing from AKit in the project.
        #expect(!fm.fileExists(atPath: project.appending(path: ".akit").path))
    }

    @Test func secondRenderRemovesDroppedFilesButKeepsEditedOnes() async throws {
        let brain = try await setUpBrain()
        _ = try await ProjectSetup.apply(ProjectSetup.plan(project: project, id: "local/task", answers: answers, brain: brain, store: .brain(brainRoot)),
                                         brain: brain, home: home, env: env, trash: trash)
        try write("Projects/task/AGENTS.md", "# Task for Acme\n\nMy note.\n")

        var next = answers
        next.values["review"] = .bool(false)
        next.targets = ["pi"]
        let plan = ProjectSetup.plan(project: project, id: "local/task", answers: next, brain: brain, store: .brain(brainRoot))
        let kinds = Dictionary(uniqueKeysWithValues: plan.changes.map { ($0.path, $0.kind) })
        #expect(kinds["REVIEW.md"] == .remove)
        #expect(kinds["CLAUDE.md"] == .remove)
        #expect(kinds[".claude/skills"] == .remove)
        #expect(kinds["AGENTS.md"] == .update)
        #expect(plan.changes.first { $0.path == "AGENTS.md" }?.replacesUnmanaged == false)

        let outcome = try await ProjectSetup.apply(plan, excluding: ["AGENTS.md"], brain: brain, home: home, env: env, trash: trash)
        #expect(outcome.removed.sorted() == [".claude/skills", "CLAUDE.md", "REVIEW.md"])
        #expect(read("AGENTS.md") == "# Task for Acme\n\nMy note.\n")
        #expect(!fm.fileExists(atPath: project.appending(path: ".claude").path))
        #expect(fm.fileExists(atPath: project.appending(path: ".agents/skills/tdd/SKILL.md").path))
        // An excluded file keeps its old lock entry, so the next plan still knows AKit wrote it.
        #expect(ProjectSetup.savedLock(id: "local/task", in: .brain(brainRoot))?.files["AGENTS.md"] != nil)

        // Edited after a render and then dropped: left alone.
        try write("Projects/task/.agents/skills/tdd/SKILL.md", "mine")
        let dropped = ProjectSetup.plan(project: project, id: "local/task", answers: ProjectAnswers(layers: []), brain: brain, store: .brain(brainRoot))
        #expect(dropped.changes.first { $0.path == ".agents/skills/tdd/SKILL.md" }?.kind == .keepEdited)
    }

    @Test func blockersAndStalePreviews() async throws {
        let brain = try await setUpBrain()
        try write("Projects/task/.claude/skills/own/SKILL.md", "x")
        let blocked = ProjectSetup.plan(project: project, id: "local/task", answers: answers, brain: brain, store: .brain(brainRoot))
        #expect(!blocked.canApply)
        #expect(blocked.blockers.first?.hasPrefix(".claude/skills is a folder with 1 item (own).") == true)
        await #expect(throws: ProjectSetup.Failure.self) {
            try await ProjectSetup.apply(blocked, brain: brain, home: home, env: env, trash: trash)
        }

        try fm.removeItem(at: project.appending(path: ".claude"))
        let plan = ProjectSetup.plan(project: project, id: "local/task", answers: answers, brain: brain, store: .brain(brainRoot))
        try write("Projects/task/AGENTS.md", "written meanwhile")
        await #expect(throws: ProjectSetup.Failure.self) {
            try await ProjectSetup.apply(plan, brain: brain, home: home, env: env, trash: trash)
        }
        #expect(read("AGENTS.md") == "written meanwhile")
        #expect(!fm.fileExists(atPath: project.appending(path: "REVIEW.md").path))
    }
}
