import Foundation
import Testing
@testable import AKitCore

/// Importing global skills into a brain, all inside a temporary fake home.
struct BrainImportTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-import-\(UUID().uuidString)")
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
    var source: URL { BrainImport.defaultSource(home: home) }

    func write(_ path: String, _ text: String = "") throws {
        let url = home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func skill(_ path: String, _ name: String, body: String = "") throws {
        try write("\(path)/\(name)/SKILL.md", "---\nname: \(name)\ndescription: d\n---\n\(body)")
    }

    func git(_ args: String...) async throws -> String {
        let result = try #require(await ProcessRunner.run(URL(filePath: "/usr/bin/git"), arguments: args,
                                                           directory: brainRoot, environment: env.variables, timeout: 10))
        #expect(result.succeeded, "\(result.output)")
        return result.output
    }

    /// A brain with `same` (identical copy), `other` (different copy) and a core layer listing `same`.
    func setUp() async throws -> BrainImport.Plan {
        try await BrainSetup.create(at: brainRoot, env: env)
        try skill(".agents/skills", "fresh")
        try write(".agents/skills/fresh/references/notes.md", "notes")
        try skill(".agents/skills", "same")
        try skill(".akit/registry/skills", "same")
        try skill(".agents/skills", "other", body: "mine")
        try skill(".akit/registry/skills", "other", body: "brain")
        try skill(".agents/skills/synced/bucket", "cloud")
        try write(".agents/skills/not-a-skill/README.md")
        try write(".agents/.skill-lock.json", #"{"version":3,"skills":{"fresh":{"source":"someone/skills"}}}"#)
        try write(".akit/registry/layers/core/layer.yaml", "name: core\n# the home folder\nskills:\n    - name: same\n      mode: auto\n\nfiles: []\n")
        _ = try await git("commit", "-qam", "Set up")
        _ = try await git("add", "-A")
        _ = try await git("commit", "-qm", "Add skills")
        return BrainImport.plan(from: source, into: brainRoot, env: env)
    }

    @Test func planSortsSkillsByWhatWouldHappen() async throws {
        let plan = try await setUp()
        let byName = Dictionary(uniqueKeysWithValues: plan.candidates.map { ($0.name, $0) })
        #expect(plan.candidates.map(\.name) == ["fresh", "other", "same"])
        #expect(byName["fresh"]?.state == .new)
        #expect(byName["fresh"]?.source == "someone/skills")
        #expect(byName["other"]?.state == .different)
        #expect(byName["same"]?.state == .same)
        #expect(byName["same"]?.isDone == true)
    }

    @Test func applyCopiesListsAndCommitsOnlyItsOwnPaths() async throws {
        let plan = try await setUp()
        try write(".akit/registry/machines/work.yaml", "harnesses: [pi]\n")
        _ = try await git("add", "machines/work.yaml")

        let copied = try await BrainImport.apply(plan, importing: ["fresh", "other", "same"], env: env)
        #expect(copied == ["fresh"])

        let brain = try #require(Brain.load(from: brainRoot))
        #expect(brain.problems.isEmpty, "\(brain.problems)")
        let core = try #require(brain.layers.first { $0.name == "core" })
        #expect(core.skills.map(\.name) == ["same", "fresh"])
        #expect(core.skills.map(\.mode) == [.auto, .manual])
        #expect(fm.contentsEqual(atPath: home.appending(path: ".agents/skills/fresh/references/notes.md").path,
                                 andPath: brainRoot.appending(path: "skills/fresh/references/notes.md").path))
        // The different brain copy and the originals are untouched.
        #expect(try String(contentsOf: brainRoot.appending(path: "skills/other/SKILL.md"), encoding: .utf8).hasSuffix("brain"))
        #expect(fm.fileExists(atPath: home.appending(path: ".agents/skills/fresh/SKILL.md").path))

        #expect(try await git("log", "-1", "--format=%s") == "Import 2 skills into the core layer\n")
        #expect(try await git("show", "--name-only", "--format=", "HEAD").split(separator: "\n").sorted()
                == ["layers/core/layer.yaml", "skills/fresh/SKILL.md", "skills/fresh/references/notes.md"])
        #expect(try await git("status", "--porcelain") == "A  machines/work.yaml\n")
    }

    @Test func refusesWhenCoreChangedAfterThePreview() async throws {
        let plan = try await setUp()
        try write(".akit/registry/layers/core/layer.yaml", "skills: []\n")
        await #expect(throws: BrainImport.Failure.self) {
            try await BrainImport.apply(plan, importing: ["fresh"], env: env)
        }
        #expect(!fm.fileExists(atPath: brainRoot.appending(path: "skills/fresh").path))
    }

    @Test func leavesOutGitDataSecretsAndOutsideLinks() async throws {
        _ = try await setUp()
        try write(".agents/skills/fresh/.env", "TOKEN=x")
        try write(".agents/skills/fresh/keys/server.pem", "key")
        try write(".agents/skills/fresh/.git/HEAD", "ref: refs/heads/main")
        try write(".aws/credentials", "secret")
        try write(".agents/skills/fresh/.gitignore", "*.log")
        try fm.createSymbolicLink(at: home.appending(path: ".agents/skills/fresh/creds"),
                                  withDestinationURL: home.appending(path: ".aws/credentials"))
        try fm.createSymbolicLink(atPath: home.appending(path: ".agents/skills/fresh/notes-link.md").path,
                                  withDestinationPath: "references/notes.md")
        let plan = BrainImport.plan(from: source, into: brainRoot, env: env)
        let fresh = try #require(plan.candidates.first { $0.name == "fresh" })
        #expect(fresh.skipped == [".env (may hold secrets)", ".git (git data)", "creds (link outside the skill)",
                                  "keys/server.pem (may hold secrets)"])

        try await BrainImport.apply(plan, importing: ["fresh"], env: env)
        let copied = BrainImport.copyable(brainRoot.appending(path: "skills/fresh")).files.keys.sorted()
        #expect(copied == [".gitignore", "SKILL.md", "notes-link.md", "references/notes.md"])
        let tree = try await git("ls-tree", "-r", "--format=%(objectmode) %(path)", "HEAD", "skills/fresh")
        #expect(!tree.contains("160000"))
        #expect(tree.contains("100644 skills/fresh/SKILL.md"))
        // The originals are untouched.
        #expect(fm.fileExists(atPath: home.appending(path: ".agents/skills/fresh/.env").path))
    }

    @Test func refusesUncommittedChangesInItsPaths() async throws {
        let plan = try await setUp()
        try write(".akit/registry/skills/fresh/draft.md", "half done")
        await #expect(throws: BrainImport.Failure.self) {
            try await BrainImport.apply(plan, importing: ["fresh"], env: env)
        }
        #expect(!fm.fileExists(atPath: brainRoot.appending(path: "skills/fresh/SKILL.md").path))
    }

    @Test func coreListingComesFromTheFileNotTheScan() async throws {
        _ = try await setUp()
        try write(".akit/registry/layers/core/layer.yaml", "skills:\n  - name: fresh\n")
        let plan = BrainImport.plan(from: source, into: brainRoot, env: env)
        #expect(plan.candidates.first { $0.name == "fresh" }?.inCore == true)
        #expect(try BrainImport.coreAfter(plan, importing: ["fresh"]) == plan.coreBefore)
        #expect(throws: BrainImport.Failure.self) { try BrainImport.addSkills(["fresh"], mode: .manual, to: plan.coreBefore) }
    }

    @Test func addSkillsKeepsTheRestOfTheFile() throws {
        #expect(try BrainImport.addSkills(["a"], mode: .manual, to: "name: core\nskills: []\n")
                == "name: core\nskills:\n  - name: a\n    mode: manual\n")
        #expect(try BrainImport.addSkills(["a"], mode: .manual, to: "")
                == "skills:\n  - name: a\n    mode: manual\n")
        #expect(try BrainImport.addSkills(["b"], mode: .manual, to: "skills:\n- x\n# next\nfiles: []\n")
                == "skills:\n- x\n- name: b\n  mode: manual\n# next\nfiles: []\n")
        #expect(try BrainImport.addSkills(["a"], mode: .manual, to: "name: core\r\nskills: ~ # none\r\n")
                == "name: core\r\nskills:\r\n  - name: a\r\n    mode: manual\r\n")
        #expect(throws: BrainImport.Failure.self) { try BrainImport.addSkills(["a"], mode: .manual, to: "skills: [x]\n") }
        #expect(throws: BrainImport.Failure.self) { try BrainImport.addSkills(["a"], mode: .manual, to: "skills:\n  - [broken\n") }
    }
}
