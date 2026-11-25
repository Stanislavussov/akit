import Foundation
import Testing
import AKitBrain
import AKitFoundation
import AKitSkills
@testable import AKitProjectSetup

/// A Pi-only project gets no skill copies; its modes go into `~/.akit/local/skill-modes.json`,
/// and the home folder brings its skills (skill-modes.md, step 6). All in a temporary fake home.
struct PiOnlySkillsTests {
    let home: URL
    let fm = FileManager.default
    let id = "example.com/team/app"

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-pi-only-\(UUID().uuidString)")
        try fm.createDirectory(at: project.appending(path: ".git"), withIntermediateDirectories: true)
        try Data("[remote \"origin\"]\n\turl = git@example.com:team/app.git\n".utf8).write(to: project.appending(path: ".git/config"))
    }

    var env: HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home, variables: [
            "HOME": home.path, "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
            "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
        ], executableSearchPaths: [URL(filePath: "/usr/bin")])
    }

    var brainRoot: URL { Brain.defaultRoot(home: home) }
    var project: URL { home.appending(path: "Projects/app") }
    var store: ProjectStore { .brain(brainRoot) }
    var homeID: String { ProjectRecords.homeID(hostName: "test-mac") }

    func write(_ path: String, _ text: String, in base: URL? = nil) throws {
        let url = (base ?? home).appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func trash(_ url: URL) throws -> URL? {
        let target = home.appending(path: "Trash/\(UUID().uuidString)-\(url.lastPathComponent)")
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: url, to: target)
        return target
    }

    func skill(_ name: String) -> String { "---\nname: \(name)\ndescription: Does \(name)\n---\n\n# \(name)\n" }

    /// core: tdd auto, lint manual. coding: tdd manual, lint auto, explain auto, ship off. review: in no layer.
    func setUpBrain() async throws -> Brain {
        try await BrainSetup.create(at: brainRoot, env: env)
        for name in ["tdd", "lint", "explain", "ship", "review"] { try write(".akit/registry/skills/\(name)/SKILL.md", skill(name)) }
        let core = brainRoot.appending(path: "layers/core/layer.yaml")
        let text = try String(contentsOf: core, encoding: .utf8)
        try Data((text + "\n").replacingOccurrences(of: "skills:\n", with: "skills:\n  - name: tdd\n    mode: auto\n  - name: lint\n    mode: manual\n").utf8)
            .write(to: core)
        try write(".akit/registry/layers/coding/layer.yaml", """
            skills:
              - name: tdd
                mode: manual
              - name: lint
                mode: auto
              - name: explain
                mode: auto
              - name: ship
                mode: off
            files:
              - template: agents.md
                to: AGENTS.md
            """)
        try write(".akit/registry/layers/coding/templates/agents.md", "# Coding\n")
        return try #require(Brain.load(from: brainRoot))
    }

    func plan(_ answers: ProjectAnswers, brain: Brain) -> ProjectSetup.Plan {
        ProjectSetup.plan(project: project, id: id, answers: answers, brain: brain, store: store, projectsRoot: home.appending(path: "Projects"), env: env)
    }

    func apply(_ plan: ProjectSetup.Plan, brain: Brain) async throws -> ProjectSetup.Outcome {
        try await ProjectSetup.apply(plan, brain: brain, home: home, env: env, trash: trash)
    }

    func entries() -> [String: SkillMode] { SkillModes.read(SkillModes.file(home: home), home: home).entries(for: id) }

    @Test func aPiOnlyProjectGetsNoSkillFilesAndTheModesThatDiffer() async throws {
        let brain = try await setUpBrain()
        let answers = ProjectAnswers(layers: ["coding"], targets: ["pi"], skills: [.init(name: "review", mode: .auto)])
        let first = plan(answers, brain: brain)
        #expect(first.canApply)
        #expect(!first.changes.contains { $0.path.hasPrefix(".agents/skills/") || $0.path == ".claude/skills" })
        #expect(first.changes.contains { $0.path == "AGENTS.md" && $0.kind == .create })
        #expect(first.notes.contains { $0.hasPrefix("Pi only: the skills") })
        #expect(first.skillModes?.summary == "\(id): explain auto, lint auto, review auto, ship off, tdd manual")
        _ = try await apply(first, brain: brain)
        #expect(!fm.fileExists(atPath: project.appending(path: ".agents").path))
        // home: tdd auto (core) → project manual; lint manual (core) → auto; explain, review: manual at home → auto; ship off.
        #expect(entries() == ["tdd": .manual, "lint": .auto, "explain": .auto, "review": .auto, "ship": .off])
        #expect(ProjectRecords.savedLock(id: id, in: store)?.skillModes?.count == 5)

        // A second Apply has nothing to do.
        let again = plan(answers, brain: brain)
        #expect(again.skillModes == nil)
        #expect(again.changes.allSatisfy { $0.kind == .same })
    }

    @Test func theUsersOwnEntryWinsAndAKitsLeavesWhenTheLayerDoes() async throws {
        let brain = try await setUpBrain()
        try SkillModes.apply(try SkillModes.plan(set: .manual, name: "explain", project: id, home: home), home: home)
        let answers = ProjectAnswers(layers: ["coding"], targets: ["pi"])
        let first = plan(answers, brain: brain)
        #expect(first.notes.contains { $0.hasPrefix("explain: the layers make it Auto here, but your entry") })
        _ = try await apply(first, brain: brain)
        #expect(entries()["explain"] == .manual)
        // The layer goes: AKit's entries come out, the user's stays.
        let none = plan(ProjectAnswers(layers: [], targets: ["pi"]), brain: brain)
        _ = try await apply(none, brain: brain)
        #expect(entries() == ["explain": .manual])
    }

    @Test func earlierCopiesGoToTheTrashAndAnEditedOneStays() async throws {
        let brain = try await setUpBrain()
        let both = ProjectAnswers(layers: ["coding"], targets: ["claude", "pi"])
        _ = try await apply(plan(both, brain: brain), brain: brain)
        #expect(fm.fileExists(atPath: project.appending(path: ".agents/skills/lint/SKILL.md").path))
        try write(".agents/skills/explain/SKILL.md", "my own notes\n", in: project)
        let piOnly = plan(ProjectAnswers(layers: ["coding"], targets: ["pi"]), brain: brain)
        #expect(piOnly.changes.first { $0.path == ".agents/skills/lint/SKILL.md" }?.kind == .remove)
        #expect(piOnly.changes.first { $0.path == ".claude/skills" }?.kind == .remove)
        #expect(piOnly.changes.first { $0.path == ".agents/skills/explain/SKILL.md" }?.kind == .keepEdited)
        #expect(piOnly.notes.contains { $0.hasPrefix("Skill copies an earlier Apply wrote go to the Trash") })
        _ = try await apply(piOnly, brain: brain)
        #expect(!fm.fileExists(atPath: project.appending(path: ".agents/skills/lint").path))
        #expect(try String(contentsOf: project.appending(path: ".agents/skills/explain/SKILL.md"), encoding: .utf8) == "my own notes\n")
    }

    @Test func aProjectWithAnotherTargetKeepsItsCopiesAndNoEntries() async throws {
        let brain = try await setUpBrain()
        let both = plan(ProjectAnswers(layers: ["coding"], targets: ["claude", "pi"]), brain: brain)
        #expect(both.changes.contains { $0.path == ".agents/skills/lint/SKILL.md" && $0.kind == .create })
        #expect(both.changes.contains { $0.path == ".claude/skills" })
        #expect(!both.piOnlySkills && both.skillModes == nil)
        _ = try await apply(both, brain: brain)
        #expect(!fm.fileExists(atPath: SkillModes.file(home: home).path))
    }

    @Test func theHomeFolderBringsTheSkillsPiOnlyProjectsUseAsManual() async throws {
        let brain = try await setUpBrain()
        let answers = ProjectAnswers(layers: ["coding"], targets: ["pi"], skills: [.init(name: "review", mode: .auto)])
        _ = try await apply(plan(answers, brain: brain), brain: brain)
        let reloaded = try #require(Brain.load(from: brainRoot))
        let homePlan = ProjectSetup.plan(project: home, id: homeID, answers: ProjectAnswers(layers: ["core"], targets: ["pi"]), brain: reloaded,
                                         store: store, forHome: true, env: env)
        func homeText(_ name: String) -> String? {
            homePlan.render.outputs.first { $0.path == ".agents/skills/\(name)/SKILL.md" }.flatMap { output in
                if case .data(let data) = output.content { String(decoding: data, as: UTF8.self) } else { nil }
            }
        }
        #expect(homeText("explain")?.contains("disable-model-invocation: true") == true)
        #expect(homeText("review")?.contains("disable-model-invocation: true") == true)
        #expect(homeText("tdd")?.contains("disable-model-invocation") == false)  // core's Auto stays
        #expect(homeText("ship") == nil)  // off in the project: not needed
        #expect(homePlan.render.skills.first { $0.name == "explain" }?.source == ProjectBundle.brainSource)
        // No Pi-only project: the home folder gets only core's skills.
        let plain = try await setUpBrainElsewhere()
        let homeOnly = ProjectSetup.plan(project: home, id: homeID, answers: ProjectAnswers(layers: ["core"], targets: ["pi"]), brain: plain,
                                         store: .brain(plain.root), forHome: true, env: env)
        #expect(!homeOnly.render.outputs.contains { $0.path.hasPrefix(".agents/skills/explain/") })
    }

    /// A second brain with the same layers and no projects.
    func setUpBrainElsewhere() async throws -> Brain {
        let root = home.appending(path: "other-brain")
        try await BrainSetup.create(at: root, env: env)
        try write("other-brain/skills/explain/SKILL.md", skill("explain"))
        return try #require(Brain.load(from: root))
    }

    @Test func forgetTakesTheProjectsEntriesOut() async throws {
        let brain = try await setUpBrain()
        _ = try await apply(plan(ProjectAnswers(layers: ["coding"], targets: ["pi"]), brain: brain), brain: brain)
        try SkillModes.apply(try SkillModes.plan(set: .off, name: "mine", project: id, home: home), home: home)
        try SkillModes.apply(try SkillModes.plan(set: .auto, name: "x", project: "other/project", home: home), home: home)
        let reloaded = try #require(Brain.load(from: brainRoot))
        let preview = try #require(ProjectForget.preview(id: id, folder: project, forHome: false, brain: reloaded, store: store,
                                                         projectsRoot: home.appending(path: "Projects"), env: env))
        #expect(preview.skillModes?.summary.contains("taken out") == true)
        try await ProjectForget.run(preview, keepFiles: false, brain: reloaded, home: home, env: env, trash: trash)
        let left = SkillModes.read(SkillModes.file(home: home), home: home).projects
        #expect(left == ["other/project": ["x": .auto]])
    }
}
