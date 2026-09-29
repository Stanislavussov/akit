import Foundation
import Testing
import AKitFoundation
@testable import AKitBrain

/// Creating a layer from the New Layer form, in a temporary brain.
struct LayerWriterTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-layer-\(UUID().uuidString)")
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

    func brain() async throws -> Brain {
        if !fm.fileExists(atPath: root.path) {
            try await BrainSetup.create(at: root, env: env)
            let skill = root.appending(path: "skills/tdd/SKILL.md")
            try fm.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("---\nname: tdd\n---\n".utf8).write(to: skill)
        }
        return try #require(Brain.load(from: root))
    }

    @Test func createsALayerThatReadsBackAndIsCommitted() async throws {
        let draft = LayerWriter.Draft(name: "take-home", description: "Take-home: fast #1", requires: ["core"],
                                      skills: [("tdd", .manual)], agentsSection: "## Take-home for {{company}}\n")
        try await LayerWriter.create(draft, in: try await brain(), env: env)

        let brain = try await brain()
        #expect(brain.problems.isEmpty, "\(brain.problems)")
        let layer = try #require(brain.layers.first { $0.name == "take-home" })
        #expect(layer.description == "Take-home: fast #1")
        #expect(layer.requires == ["core"])
        #expect(layer.skills.map(\.name) == ["tdd"] && layer.skills.first?.mode == .manual)
        #expect(layer.files.map(\.to) == ["AGENTS.md"])
        #expect(try String(contentsOf: layer.templates.appending(path: "AGENTS.md"), encoding: .utf8) == "## Take-home for {{company}}\n")

        let log = try #require(await ProcessRunner.run(URL(filePath: "/usr/bin/git"), arguments: ["log", "-1", "--format=%s"],
                                                        directory: root, environment: env.variables, timeout: 10))
        #expect(log.output == "Add layer take-home\n")
    }

    @Test func minimalLayerHasNoFiles() async throws {
        try await LayerWriter.create(LayerWriter.Draft(name: "empty"), in: try await brain(), env: env)
        let layer = try #require(try await brain().layers.first { $0.name == "empty" })
        #expect(layer.files.isEmpty && layer.skills.isEmpty)
        #expect(!fm.fileExists(atPath: layer.templates.path))
    }

    @Test func namesAreChecked() async throws {
        let brain = try await brain()
        #expect(LayerWriter.nameProblem("", in: brain) != nil)
        #expect(LayerWriter.nameProblem("Take Home", in: brain) != nil)
        #expect(LayerWriter.nameProblem("../x", in: brain) != nil)
        #expect(LayerWriter.nameProblem("core", in: brain) == "A layer named core already exists.")
        #expect(LayerWriter.nameProblem("node-api2", in: brain) == nil)
        await #expect(throws: LayerWriter.Failure.self) {
            try await LayerWriter.create(LayerWriter.Draft(name: "core"), in: brain, env: env)
        }
    }
}
