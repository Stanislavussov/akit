import Foundation
import Testing
import AKitBrain
import AKitFoundation
import AKitRender
@testable import AKitProjectSetup

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

    @Test func checkReportsTheBundlesAndTheRendersErrors() async throws {
        _ = try await setUpBrain()
        try write(".akit/registry/layers/twice/layer.yaml", "files:\n  - template: s.md\n    to: .agents/skills/tdd/SKILL.md\n")
        try write(".akit/registry/layers/twice/templates/s.md", "x")
        let brain = try #require(Brain.load(from: brainRoot))
        let bundle = ProjectBundle.resolve(ProjectAnswers(layers: ["task", "twice"], targets: ["claude"]), brain: brain, projectName: "task")
        let check = ProjectSetup.check(bundle)
        #expect(!bundle.errors.isEmpty && !bundle.errors.contains { $0.contains("written twice") })
        #expect(Array(check.errors.prefix(bundle.errors.count)) == bundle.errors)
        #expect(check.errors.contains { $0.hasPrefix(".agents/skills/tdd/SKILL.md is written twice") })
        #expect(Set(check.errors).count == check.errors.count)
        #expect(check.warnings == bundle.warnings)
    }

    @Test func remoteURLsBecomeIDs() {
        #expect(ProjectRecords.normalizedRemote("git@github.com:Owner/Repo.git\n") == "github.com/owner/repo")
        #expect(ProjectRecords.normalizedRemote("https://user@github.com/owner/repo") == "github.com/owner/repo")
        #expect(ProjectRecords.normalizedRemote("ssh://git@gitlab.example.com:2222/group/sub/proj.git") == "gitlab.example.com/group/sub/proj")
        #expect(ProjectRecords.normalizedRemote("https://github.com/../../etc") == "github.com/etc")
        #expect(ProjectRecords.normalizedRemote("") == nil)
        #expect(ProjectRecords.normalizedRemote("https://me:p/ss@github.com/o/r.git") == "github.com/o/r")
        #expect(ProjectRecords.normalizedRemote("https://host/.git/x/y") == "host/x/y")
        // A query or fragment never reaches the id.
        #expect(ProjectRecords.normalizedRemote("https://github.com/o/r.git?access_token=XYZ") == "github.com/o/r")
        #expect(ProjectRecords.normalizedRemote("https://u:t@github.com/o/r#main") == "github.com/o/r")
        // A raw password with "#" or "?" goes with the user name.
        #expect(ProjectRecords.normalizedRemote("https://me:p#a?ss@github.com/o/r.git") == "github.com/o/r")
    }

    @Test func projectOutsideTheRootGetsAHashedID() async throws {
        let other = home.appending(path: "Elsewhere/app")
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        let id = await ProjectRecords.projectID(for: other, projectsRoot: home.appending(path: "Projects"), env: env)
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
        #expect(change.kind == .suggest && change.replacesUnmanaged && change.oldText == "→ NOTES.md (a link)")

        let outcome = try await ProjectSetup.apply(plan, accepting: ["CLAUDE.md"], brain: brain, home: home, env: env, trash: trash)
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
        // Edited by the project, and the layers' version changed: offered, not written.
        #expect(plan.changes.first { $0.path == "AGENTS.md" }?.kind == .suggest)

        // The Trash fails on REVIEW.md: AGENTS.md was already written and must be in the lock.
        await #expect(throws: ProjectSetup.Failure.self) {
            try await ProjectSetup.apply(plan, accepting: ["AGENTS.md"], brain: brain, home: home, env: env,
                                         trash: { _ in throw CocoaError(.fileWriteNoPermission) })
        }
        let lock = try #require(ProjectRecords.savedLock(id: "local/task", in: .brain(brainRoot)))
        #expect(lock.files["AGENTS.md"]?.sha256 == Checksum.sha256(Data("# Task for Beta\n".utf8)))
    }

    @Test func projectWithoutRemoteUsesItsPath() async throws {
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        #expect(await ProjectRecords.projectID(for: project, projectsRoot: home.appending(path: "Projects"), env: env) == "local/task")
    }

    @Test func firstRenderWritesFilesBacksUpAndSavesAnswers() async throws {
        let brain = try await setUpBrain()
        try write("Projects/task/CLAUDE.md", "# My own rules\n")

        let plan = ProjectSetup.plan(project: project, id: "local/task", answers: answers, brain: brain, store: .brain(brainRoot))
        #expect(plan.canApply, "\(plan.render.errors) \(plan.blockers)")
        let kinds = Dictionary(uniqueKeysWithValues: plan.changes.map { ($0.path, $0.kind) })
        // The project's own CLAUDE.md is only offered the layers' version.
        #expect(kinds == ["AGENTS.md": .create, "CLAUDE.md": .suggest, "REVIEW.md": .create,
                          ".agents/skills/tdd/SKILL.md": .create, ".claude/skills": .create])
        #expect(plan.changes.first { $0.path == "CLAUDE.md" }?.replacesUnmanaged == true)

        let outcome = try await ProjectSetup.apply(plan, brain: brain, home: home, env: env, trash: trash)
        #expect(read("AGENTS.md") == "# Task for Acme\n")
        #expect(read("CLAUDE.md") == "# My own rules\n")
        #expect(read(".claude/skills/tdd/SKILL.md")?.contains("disable-model-invocation: true") == true)
        #expect(outcome.backup == nil)

        #expect(ProjectRecords.savedAnswers(id: "local/task", in: .brain(brainRoot)) == answers)
        let lock = try #require(ProjectRecords.savedLock(id: "local/task", in: .brain(brainRoot)))
        #expect(lock.files.keys.sorted() == [".agents/skills/tdd/SKILL.md", ".claude/skills", "AGENTS.md", "REVIEW.md"])
        #expect(lock.templates?.keys.sorted() == ["AGENTS.md", "CLAUDE.md", "REVIEW.md"])
        #expect(lock.brainCommit?.isEmpty == false)
        #expect(!lock.brainDirty)
        #expect(try await git("log", "-1", "--format=%s") == "Render task\n")
        // Nothing from AKit in the project.
        #expect(!fm.fileExists(atPath: project.appending(path: ".akit").path))

        // Seen once: no longer pushed, but it can still be taken.
        let again = ProjectSetup.plan(project: project, id: "local/task", answers: answers, brain: brain, store: .brain(brainRoot))
        #expect(again.changes.first { $0.path == "CLAUDE.md" }?.kind == .own)
        let taken = try await ProjectSetup.apply(again, accepting: ["CLAUDE.md"], brain: brain, home: home, env: env, trash: trash)
        #expect(read("CLAUDE.md") == "@AGENTS.md\n")
        #expect(try String(contentsOf: try #require(taken.backup).appending(path: "Projects/task/CLAUDE.md"), encoding: .utf8) == "# My own rules\n")
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
        // Edited by the project, and the layers' AGENTS.md is the same as last time: left alone.
        #expect(kinds["AGENTS.md"] == .own)
        #expect(plan.changes.first { $0.path == "AGENTS.md" }?.replacesUnmanaged == false)

        let outcome = try await ProjectSetup.apply(plan, brain: brain, home: home, env: env, trash: trash)
        #expect(outcome.removed.sorted() == [".claude/skills", "CLAUDE.md", "REVIEW.md"])
        #expect(read("AGENTS.md") == "# Task for Acme\n\nMy note.\n")
        #expect(!fm.fileExists(atPath: project.appending(path: ".claude").path))
        #expect(fm.fileExists(atPath: project.appending(path: ".agents/skills/tdd/SKILL.md").path))
        // A file left alone keeps its old lock entry, so the next plan still knows AKit wrote it.
        #expect(ProjectRecords.savedLock(id: "local/task", in: .brain(brainRoot))?.files["AGENTS.md"] != nil)

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

    // MARK: - Project skills

    @Test func projectSkillsAddToAndOverrideTheLayers() async throws {
        let brain = try await setUpBrain()
        try write(".akit/registry/skills/grill/SKILL.md", "---\nname: grill\ndescription: Ask\n---\n")
        let withGrill = try #require(Brain.load(from: brainRoot))
        var picked = answers
        picked.skills = [.init(name: "grill", mode: .auto), .init(name: "tdd", mode: .auto)]
        let render = Render.render(ProjectBundle.resolve(picked, brain: withGrill, projectName: "task"))
        let skill = { (name: String) in render.outputs.first { $0.path == ".agents/skills/\(name)/SKILL.md" } }
        #expect(skill("grill")?.layers == [ProjectBundle.projectSource])
        // tdd is manual in the layer; the project makes it auto.
        #expect(skill("tdd")?.text?.contains("disable-model-invocation") == false)
        #expect(skill("tdd")?.layers == [ProjectBundle.projectSource])

        picked.skills = [.init(name: "tdd", mode: .off)]
        #expect(!Render.render(ProjectBundle.resolve(picked, brain: brain, projectName: "task")).outputs.contains { $0.path.hasPrefix(".agents/skills/tdd/") })

        // Answers saved before project skills existed still read.
        let old = try JSONDecoder().decode(ProjectAnswers.self, from: Data(#"{"layers":["task"],"values":{},"targets":["pi"]}"#.utf8))
        #expect(old == ProjectAnswers(layers: ["task"], targets: ["pi"]))
    }

    @Test func anOffForASkillNoLayerBringsIsDropped() async throws {
        let brain = try await setUpBrain()
        var picked = answers
        picked.skills = [.init(name: "tdd", mode: .off)]
        // The task layer brings tdd: the off stays.
        #expect(ProjectSetup.plan(project: project, id: "local/task", answers: picked, brain: brain, store: .brain(brainRoot)).answers.skills == picked.skills)
        // Without the layer, off turns nothing off and is not saved.
        picked.layers = []
        picked.skills.append(.init(name: "tdd2", mode: .auto))
        let plan = ProjectSetup.plan(project: project, id: "local/task", answers: picked, brain: brain, store: .brain(brainRoot))
        #expect(plan.answers.skills == [.init(name: "tdd2", mode: .auto)])
    }

    @Test func theProjectsOwnSkillsAreNeverOverwritten() async throws {
        let brain = try await setUpBrain()
        // Set up once with nothing from the brain, so AKit has a lock for the project.
        let empty = ProjectSetup.plan(project: project, id: "local/task", answers: ProjectAnswers(targets: ["claude"]), brain: brain, store: .brain(brainRoot))
        _ = try await ProjectSetup.apply(empty, brain: brain, home: home, env: env, trash: trash)
        try ProjectSkills.create("deploy", description: "Deploy: to staging", in: project)
        try write("Projects/task/.agents/skills/tdd/SKILL.md", "our tdd\n")
        #expect(ProjectSkills.nameProblem("deploy", in: project) != nil)
        #expect(ProjectSkills.list(in: project, id: "local/task", store: .brain(brainRoot)).map(\.name) == ["deploy", "tdd"])
        #expect(ProjectSkills.list(in: project, id: "local/task", store: .brain(brainRoot)).first?.description == "Deploy: to staging")

        let plan = ProjectSetup.plan(project: project, id: "local/task", answers: answers, brain: brain, store: .brain(brainRoot))
        #expect(!plan.changes.contains { $0.path.hasPrefix(".agents/skills/") })
        #expect(plan.render.warnings.contains { $0.hasPrefix("The project has its own tdd skill") })
        _ = try await ProjectSetup.apply(plan, brain: brain, home: home, env: env, trash: trash)
        #expect(read(".agents/skills/tdd/SKILL.md") == "our tdd\n")
        #expect(read(".claude/skills/deploy/SKILL.md")?.hasPrefix("---\nname: deploy\ndescription: 'Deploy: to staging'\n---\n") == true)

        try ProjectSkills.remove("deploy", in: project, id: "local/task", store: .brain(brainRoot), trash: trash)
        #expect(!fm.fileExists(atPath: project.appending(path: ".agents/skills/deploy").path))
        #expect(throws: ProjectSkills.Failure.self) {
            try ProjectSkills.remove("deploy", in: project, id: "local/task", store: .brain(brainRoot), trash: trash)
        }
    }

    @Test func withoutALockNothingIsTheProjectsOwnAndADeclinedFileComesBack() async throws {
        let brain = try await setUpBrain()
        // No lock yet (first set-up, or the project id changed): a brain skill already in
        // the project is AKit's to update, not the project's own.
        try write("Projects/task/.agents/skills/tdd/SKILL.md", "old copy\n")
        let first = ProjectSetup.plan(project: project, id: "local/task", answers: answers, brain: brain, store: .brain(brainRoot))
        #expect(first.render.warnings.isEmpty)
        #expect(first.changes.first { $0.path == ".agents/skills/tdd/SKILL.md" }.map { $0.kind == .update && $0.replacesUnmanaged } == true)

        // Declining the first REVIEW.md doesn't make it "the project's": offered again.
        _ = try await ProjectSetup.apply(first, excluding: ["REVIEW.md"], brain: brain, home: home, env: env, trash: trash)
        let second = ProjectSetup.plan(project: project, id: "local/task", answers: answers, brain: brain, store: .brain(brainRoot))
        #expect(second.changes.first { $0.path == "REVIEW.md" }?.kind == .create)

        // A folder that is exactly the brain's render is AKit's, even with a lock that lost it;
        // plain files and folders without SKILL.md are no skills at all.
        try write("Projects/task/.agents/skills/README.md", "notes")
        try fm.createDirectory(at: project.appending(path: ".agents/skills/empty"), withIntermediateDirectories: true)
        #expect(ProjectSkills.list(in: project, id: "local/task", store: .brain(brainRoot)).isEmpty)
    }

    @Test func forgettingTrashesOnlyUneditedFilesAndKeepsThemWhenAsked() async throws {
        let brain = try await setUpBrain()
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        let store = ProjectStore.brain(brainRoot)
        let plan = ProjectSetup.plan(project: project, id: "local/task", answers: answers, brain: brain, store: store)
        _ = try await ProjectSetup.apply(plan, brain: brain, home: home, env: env, trash: trash)
        try write("Projects/task/REVIEW.md", "Edited by hand\n")
        #expect(ProjectForget.preview(id: "local/other", folder: nil, forHome: false, brain: brain, store: store) == nil)

        let preview = try #require(ProjectForget.preview(id: "local/task", folder: project, forHome: false, brain: brain, store: store))
        #expect(preview.ownRecord && !preview.brainCopyLeft)
        #expect(preview.removals.contains("AGENTS.md") && !preview.removals.contains("REVIEW.md"))
        #expect(preview.kept == ["REVIEW.md"])
        try await ProjectForget.run(preview, keepFiles: false, brain: brain, home: home, env: env, trash: trash)
        #expect(read("AGENTS.md") == nil && read("REVIEW.md") == "Edited by hand\n")
        #expect(ProjectRecords.savedAnswers(id: "local/task", in: store) == nil)
        #expect(try await git("log", "-1", "--format=%s") == "Forget local/task\n")
    }

    @Test func forgettingAProjectNotOnThisMacOnlyDropsItsRecord() async throws {
        let brain = try await setUpBrain()
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        let store = ProjectStore.brain(brainRoot)
        let plan = ProjectSetup.plan(project: project, id: "local/task", answers: answers, brain: brain, store: store)
        _ = try await ProjectSetup.apply(plan, brain: brain, home: home, env: env, trash: trash)

        let preview = try #require(ProjectForget.preview(id: "local/task", folder: nil, forHome: false, brain: brain, store: store))
        #expect(preview.plan == nil && preview.removals.isEmpty)
        try await ProjectForget.run(preview, keepFiles: false, brain: brain, home: home, env: env, trash: trash)
        #expect(read("AGENTS.md") != nil)
        #expect(!fm.fileExists(atPath: brainRoot.appending(path: "projects/local/task").path))
    }

    @Test func onAWorkMacForgettingDropsOnlyTheLocalRecordAndLeavesTheBrainCopy() async throws {
        let brain = try await setUpBrain()
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        let plan = ProjectSetup.plan(project: project, id: "local/task", answers: answers, brain: brain, store: .brain(brainRoot))
        _ = try await ProjectSetup.apply(plan, brain: brain, home: home, env: env, trash: trash)
        try MachineProfile(kind: .work).save(home: home)
        let store = ProjectStore.current(brain: brainRoot, home: home)
        #expect(store.isLocal)

        // Only the brain has the record: this Mac has none of its own, but the files can go.
        let preview = try #require(ProjectForget.preview(id: "local/task", folder: project, forHome: false, brain: brain, store: store))
        #expect(!preview.ownRecord && preview.brainCopyLeft && preview.removals.contains("AGENTS.md"))
        try await ProjectForget.run(preview, keepFiles: false, brain: brain, home: home, env: env, trash: trash)
        #expect(read("AGENTS.md") == nil)
        // The lock apply saved locally is forgotten too; the brain copy stays for other Macs.
        #expect(!fm.fileExists(atPath: store.folder(id: "local/task").path))
        #expect(fm.fileExists(atPath: brainRoot.appending(path: "projects/local/task").path))
    }

    @Test func forgettingRefusesAPreviewMadeBeforeTheMacBecameAWorkMac() async throws {
        let brain = try await setUpBrain()
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        let store = ProjectStore.brain(brainRoot)
        let plan = ProjectSetup.plan(project: project, id: "local/task", answers: answers, brain: brain, store: store)
        _ = try await ProjectSetup.apply(plan, brain: brain, home: home, env: env, trash: trash)
        let preview = try #require(ProjectForget.preview(id: "local/task", folder: project, forHome: false, brain: brain, store: store))
        try MachineProfile(kind: .work).save(home: home)
        await #expect(throws: ProjectSetup.Failure.self) {
            try await ProjectForget.run(preview, keepFiles: true, brain: brain, home: home, env: env, trash: trash)
        }
        #expect(fm.fileExists(atPath: brainRoot.appending(path: "projects/local/task").path))
    }
}
