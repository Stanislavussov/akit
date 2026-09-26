import Foundation
import Testing
@testable import AKitCore

/// Removing layers, skills and projects from a brain in a temporary fake home.
struct BrainRemoveTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-remove-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var env: HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home, variables: [
            "HOME": home.path, "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
            "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
        ], executableSearchPaths: [URL(filePath: "/usr/bin")])
    }

    var root: URL { Brain.defaultRoot(home: home) }
    var project: URL { home.appending(path: "Projects/task") }

    func write(_ path: String, _ text: String = "") throws {
        let url = home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func trash(_ url: URL) throws -> URL? {
        let target = home.appending(path: "Trash/\(UUID().uuidString)")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try fm.moveItem(at: url, to: target.appending(path: url.lastPathComponent))
        return target
    }

    func git(_ args: String...) async throws -> String {
        let result = try #require(await ProcessRunner.run(URL(filePath: "/usr/bin/git"), arguments: args,
                                                           directory: root, environment: env.variables, timeout: 10))
        return result.output
    }

    func akit(_ arguments: String...) async -> (code: Int32, out: String, err: String) {
        var out: [String] = [], err: [String] = []
        let code = await AKitCLI.run(arguments, env: env, cwd: project, projectsRoot: home.appending(path: "Projects"),
                                     hostName: "mac", installedTargets: ["claude"],
                                     out: { out.append($0) }, err: { err.append($0) }, trash: trash)
        return (code, out.joined(separator: "\n"), err.joined(separator: "\n"))
    }

    func setUp() async throws {
        try await BrainSetup.create(at: root, env: env)
        try write(".akit/registry/skills/tdd/SKILL.md", "---\nname: tdd\n---\n")
        try write(".akit/registry/skills/old/SKILL.md", "---\nname: old\n---\n")
        try write(".akit/registry/layers/base/layer.yaml", "description: Base\n# the skills\nskills:\n  - name: tdd\n    mode: manual\n  - old\nfiles:\n  - template: a.md\n    to: AGENTS.md\n")
        try write(".akit/registry/layers/base/templates/a.md", "# Base\n")
        try write(".akit/registry/layers/task/layer.yaml", "requires: [base]\n")
        _ = try await git("add", "-A")
        _ = try await git("commit", "-qm", "Set up")
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
    }

    @Test func dropSkillKeepsTheRestOfTheLayer() throws {
        let text = "name: x\nskills:\n  - name: a\n    mode: manual\n  - b  # note\n  - mode: auto\n    name: c\nfiles: []\n"
        #expect(try BrainRemove.dropSkill("a", from: text) == "name: x\nskills:\n  - b  # note\n  - mode: auto\n    name: c\nfiles: []\n")
        #expect(try BrainRemove.dropSkill("b", from: text) == "name: x\nskills:\n  - name: a\n    mode: manual\n  - mode: auto\n    name: c\nfiles: []\n")
        #expect(try BrainRemove.dropSkill("c", from: text) == "name: x\nskills:\n  - name: a\n    mode: manual\n  - b  # note\nfiles: []\n")
        #expect(try BrainRemove.dropSkill("a", from: "skills:\n  - name: a\n") == "skills: []\n")
        #expect(throws: BrainRemove.Failure.self) { try BrainRemove.dropSkill("z", from: text) }
        #expect(throws: BrainRemove.Failure.self) { try BrainRemove.dropSkill("a", from: "skills: [a, b]\n") }
    }

    @Test func layerRemovalIsRefusedWhileRequiredAndUpdatesProjects() async throws {
        try await setUp()
        #expect(await akit("apply", "--layers", "task").code == 0)

        let refused = await akit("remove", "layer", "base", "--yes")
        #expect(refused.code == 1 && refused.out.contains("required by task"))
        let preview = await akit("remove", "layer", "task")
        #expect(preview.out.contains("dropped from the answers of: local/task") && preview.out.contains("--yes"))
        #expect(fm.fileExists(atPath: root.appending(path: "layers/task").path))

        let done = await akit("remove", "layer", "task", "--yes")
        #expect(done.code == 0, "\(done)")
        #expect(!fm.fileExists(atPath: root.appending(path: "layers/task").path))
        #expect(ProjectSetup.savedAnswers(id: "local/task", brain: root)?.layers == [])
        #expect(try await git("log", "-1", "--format=%s") == "Remove layer task\n")
        #expect(try await git("status", "--porcelain") == "")
        #expect(await akit("remove", "layer", "core", "--yes").code == 2)
    }

    @Test func skillRemovalGoesThroughTheLayerFirst() async throws {
        try await setUp()
        let refused = await akit("remove", "skill", "old", "--yes")
        #expect(refused.code == 1 && refused.out.contains("akit remove skill old --from base"))

        let preview = await akit("remove", "skill", "old", "--from", "base")
        #expect(preview.out.contains("-   - old"))
        #expect(await akit("remove", "skill", "old", "--from", "base", "--yes").code == 0)
        let layer = try #require(Brain.load(from: root)?.layers.first { $0.name == "base" })
        #expect(layer.skills.map(\.name) == ["tdd"])
        #expect(layer.description == "Base" && layer.files.count == 1)

        #expect(await akit("remove", "skill", "old", "--yes").code == 0)
        #expect(!fm.fileExists(atPath: root.appending(path: "skills/old").path))
        #expect(try await git("log", "-2", "--format=%s") == "Remove skill old\nRemove skill old from layer base\n")
    }

    @Test func projectRemovalTrashesOnlyWhatAKitWrote() async throws {
        try await setUp()
        // Already there with the same content: stays the user's.
        try write("Projects/task/.agents/skills/tdd/SKILL.md", "---\nname: tdd\ndisable-model-invocation: true\n---\n")
        #expect(await akit("apply", "--layers", "base").code == 0)
        let lock = try #require(ProjectSetup.savedLock(id: "local/task", brain: root))
        #expect(lock.files.keys.sorted() == [".agents/skills/old/SKILL.md", ".claude/skills", "AGENTS.md", "CLAUDE.md"])

        let preview = await akit("remove", "project")
        #expect(preview.out.contains("Files AKit wrote go to the Trash: .agents/skills/old/SKILL.md, .claude/skills, AGENTS.md, CLAUDE.md"))
        let done = await akit("remove", "project", "--yes")
        #expect(done.code == 0, "\(done)")
        #expect(!fm.fileExists(atPath: project.appending(path: "AGENTS.md").path))
        #expect(fm.fileExists(atPath: project.appending(path: ".agents/skills/tdd/SKILL.md").path))
        #expect(!fm.fileExists(atPath: root.appending(path: "projects/local/task").path))
        #expect(await akit("remove", "project", "--yes").code == 1)
    }
}
