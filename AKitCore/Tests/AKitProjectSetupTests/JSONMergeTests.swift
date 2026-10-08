import Foundation
import Testing
import AKitBrain
import AKitFoundation
import AKitRender
@testable import AKitProjectSetup

/// Merging the layers' keys into a project's `.mcp.json` and `.claude/settings.json`, inside a
/// temporary fake home.
struct JSONMergeTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-json-\(UUID().uuidString)")
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
    var store: ProjectStore { .brain(brainRoot) }
    let id = "local/task"

    func write(_ path: String, _ text: String = "") throws {
        let url = home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func read(_ path: String) -> String? { try? String(contentsOf: project.appending(path: path), encoding: .utf8) }
    func tree(_ path: String) throws -> JSONValue { try JSONValue.parse(try Data(contentsOf: project.appending(path: path))) }

    func trash(_ url: URL) throws -> URL? {
        let target = home.appending(path: "Trash/\(UUID().uuidString)-\(url.lastPathComponent)")
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: url, to: target)
        return target
    }

    /// Layer `mcp`: server `one` always, server `two` while field `two` is on; layer `settings`:
    /// a key in `.claude/settings.json`.
    func setUpBrain() async throws -> Brain {
        try await BrainSetup.create(at: brainRoot, env: env)
        try write(".akit/registry/layers/mcp/layer.yaml", """
            fields:
              - id: two
                type: bool
                default: true
            files:
              - template: one.json
                to: .mcp.json
              - template: two.json
                to: .mcp.json
                when: two
            """)
        try write(".akit/registry/layers/mcp/templates/one.json",
                  #"{"mcpServers": {"one": {"command": "one-server", "env": {"ONE_TOKEN": "${ONE_TOKEN}"}}}}"#)
        try write(".akit/registry/layers/mcp/templates/two.json",
                  #"{"mcpServers": {"two": {"command": "two-server", "args": ["--fast"]}}}"#)
        try write(".akit/registry/layers/settings/layer.yaml", "files:\n  - template: s.json\n    to: .claude/settings.json\n")
        try write(".akit/registry/layers/settings/templates/s.json", #"{"permissions": {"defaultMode": "plan"}}"#)
        return try #require(Brain.load(from: brainRoot))
    }

    func plan(_ layers: [String], two: Bool = true, brain: Brain, forHome: Bool = false) -> ProjectSetup.Plan {
        ProjectSetup.plan(project: forHome ? home : project, id: forHome ? "home/mac" : id,
                          answers: ProjectAnswers(layers: layers, values: ["two": .bool(two)], targets: ["claude"]),
                          brain: brain, store: store, forHome: forHome)
    }

    func change(_ plan: ProjectSetup.Plan, _ path: String = ".mcp.json") -> ProjectSetup.Change? { plan.changes.first { $0.path == path } }

    @Test func aNewFileGetsBothLayersKeysAndTheLockRecordsThem() async throws {
        let brain = try await setUpBrain()
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        let first = plan(["mcp", "settings"], brain: brain)
        #expect(first.canApply, "\(first.render.errors) \(first.blockers)")
        #expect(change(first)?.kind == .create)
        #expect(change(first)?.mergesJSON == true)
        #expect(change(first, ".claude/settings.json")?.kind == .create)

        _ = try await ProjectSetup.apply(first, brain: brain, home: home, env: env, trash: trash)
        #expect(read(".mcp.json") == """
            {
              "mcpServers": {
                "one": {
                  "command": "one-server",
                  "env": {
                    "ONE_TOKEN": "${ONE_TOKEN}"
                  }
                },
                "two": {
                  "args": [
                    "--fast"
                  ],
                  "command": "two-server"
                }
              }
            }

            """)
        #expect(try tree(".claude/settings.json") == .object(["permissions": .object(["defaultMode": .string("plan")])]))

        let lock = try #require(ProjectRecords.savedLock(id: id, in: store))
        // Merged files are not whole files AKit owns: they live in their own key.
        #expect(lock.files[".mcp.json"] == nil && lock.templates?[".mcp.json"] == nil)
        let record = try #require(lock.json?[".mcp.json"])
        #expect(record.created)
        #expect(record.layers == ["mcp"])
        #expect(record.keys.keys.sorted() == ["/mcpServers/one/command", "/mcpServers/one/env/ONE_TOKEN",
                                              "/mcpServers/two/args", "/mcpServers/two/command"])
        #expect(record.keys["/mcpServers/two/command"] == JSONMerge.hash(.string("two-server")))

        // Nothing changed: the file is not touched.
        let again = plan(["mcp", "settings"], brain: brain)
        #expect(change(again)?.kind == .same)
        #expect(again.render.warnings.isEmpty, "\(again.render.warnings)")
    }

    @Test func theProjectsFileKeepsItsKeysAndADifferingLeafIsItsOwn() async throws {
        let brain = try await setUpBrain()
        try write("Projects/task/.mcp.json", """
            {
                "mcpServers": {
                    "mine": {"command": "my-server"},
                    "two": {"command": "my-two"}
                }
            }
            """)
        let plan = plan(["mcp"], brain: brain)
        #expect(plan.canApply, "\(plan.blockers)")
        let merged = try #require(change(plan))
        #expect(merged.kind == .update)
        #expect(!merged.replacesUnmanaged && !merged.editedSinceRender)
        #expect(plan.render.warnings.contains(".mcp.json: the project sets mcpServers.two.command itself; AKit leaves it."))
        #expect(plan.render.warnings.contains { $0.hasPrefix(".mcp.json is rewritten with sorted keys") })

        let outcome = try await ProjectSetup.apply(plan, brain: brain, home: home, env: env, trash: trash)
        #expect(outcome.backup != nil)
        let result = try tree(".mcp.json")
        #expect(result.value(at: ["mcpServers", "mine", "command"]) == .string("my-server"))
        #expect(result.value(at: ["mcpServers", "two", "command"]) == .string("my-two"))
        #expect(result.value(at: ["mcpServers", "two", "args"]) == .array([.string("--fast")]))
        #expect(result.value(at: ["mcpServers", "one", "command"]) == .string("one-server"))

        let record = try #require(ProjectRecords.savedLock(id: id, in: store)?.json?[".mcp.json"])
        #expect(!record.created)
        #expect(!record.keys.keys.contains("/mcpServers/two/command"))
        #expect(record.keys.keys.contains("/mcpServers/two/args"))
    }

    @Test func aDroppedLeafGoesUnlessTheProjectChangedIt() async throws {
        let brain = try await setUpBrain()
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        _ = try await ProjectSetup.apply(plan(["mcp"], brain: brain), brain: brain, home: home, env: env, trash: trash)
        // The project edits one of AKit's leaves.
        var edited = try tree(".mcp.json")
        edited.set(.string("my-two"), at: ["mcpServers", "two", "command"])
        try write("Projects/task/.mcp.json", edited.pretty)

        let dropped = plan(["mcp"], two: false, brain: brain)
        #expect(change(dropped)?.kind == .update)
        _ = try await ProjectSetup.apply(dropped, brain: brain, home: home, env: env, trash: trash)
        let result = try tree(".mcp.json")
        #expect(result.value(at: ["mcpServers", "two"]) == .object(["command": .string("my-two")]))
        #expect(result.value(at: ["mcpServers", "one", "command"]) == .string("one-server"))
        let record = try #require(ProjectRecords.savedLock(id: id, in: store)?.json?[".mcp.json"])
        #expect(record.keys.keys.sorted() == ["/mcpServers/one/command", "/mcpServers/one/env/ONE_TOKEN"])
    }

    @Test func aFileAKitCreatedGoesToTheTrashOnceEmpty() async throws {
        let brain = try await setUpBrain()
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        _ = try await ProjectSetup.apply(plan(["settings"], brain: brain), brain: brain, home: home, env: env, trash: trash)
        #expect(read(".claude/settings.json") != nil)

        let none = plan([], brain: brain)
        #expect(change(none, ".claude/settings.json")?.kind == .remove)
        let outcome = try await ProjectSetup.apply(none, brain: brain, home: home, env: env, trash: trash)
        #expect(outcome.removed == [".claude/settings.json"])
        #expect(!fm.fileExists(atPath: project.appending(path: ".claude").path))
        #expect(ProjectRecords.savedLock(id: id, in: store)?.json == nil)
    }

    @Test func aFileThatIsNotJSONBlocksApply() async throws {
        let brain = try await setUpBrain()
        try write("Projects/task/.mcp.json", "{ \"mcpServers\": ")
        let plan = plan(["mcp"], brain: brain)
        #expect(!plan.canApply)
        #expect(plan.blockers.contains { $0.hasPrefix(".mcp.json is not valid JSON (") && $0.hasSuffix("AKit won't overwrite it; fix the file first.") })
        await #expect(throws: ProjectSetup.Failure.self) {
            try await ProjectSetup.apply(plan, brain: brain, home: home, env: env, trash: trash)
        }
        #expect(read(".mcp.json") == "{ \"mcpServers\": ")
    }

    @Test func thePreviewMasksEnvAndHeadersButTheFileKeepsThem() async throws {
        let brain = try await setUpBrain()
        try write("Projects/task/.mcp.json",
                  #"{"mcpServers": {"api": {"command": "api", "env": {"API_KEY": "sk-live-123"}, "headers": {"X-Token": "tok-456", "X-Ref": "${REF}"}}}}"#)
        let plan = plan(["mcp"], brain: brain)
        let merged = try #require(change(plan))
        for text in [merged.oldText, merged.newText] {
            let text = try #require(text)
            #expect(!text.contains("sk-live-123") && !text.contains("tok-456"))
            #expect(text.contains("\"API_KEY\": \"••••\"") && text.contains("\"X-Token\": \"••••\""))
            #expect(text.contains("${REF}"))
        }
        #expect(merged.newText?.contains("${ONE_TOKEN}") == true)

        _ = try await ProjectSetup.apply(plan, brain: brain, home: home, env: env, trash: trash)
        let result = try tree(".mcp.json")
        #expect(result.value(at: ["mcpServers", "api", "env", "API_KEY"]) == .string("sk-live-123"))
        #expect(result.value(at: ["mcpServers", "api", "headers", "X-Token"]) == .string("tok-456"))
    }

    @Test func forgettingTakesAKitsKeysOutAndKeepsTheProjects() async throws {
        let brain = try await setUpBrain()
        try write("Projects/task/.mcp.json", #"{"mcpServers": {"mine": {"command": "my-server"}}}"#)
        _ = try await ProjectSetup.apply(plan(["mcp"], brain: brain), brain: brain, home: home, env: env, trash: trash)
        let preview = try #require(ProjectForget.preview(id: id, folder: project, forHome: false, brain: brain, store: store))
        #expect(preview.keysTakenOut == [".mcp.json"])
        #expect(preview.removals.isEmpty)
        try await ProjectForget.run(preview, keepFiles: false, brain: brain, home: home, env: env, trash: trash)
        #expect(try tree(".mcp.json") == .object(["mcpServers": .object(["mine": .object(["command": .string("my-server")])])]))
    }

    @Test func theHomeFolderSkipsJSONWithAWarning() async throws {
        let brain = try await setUpBrain()
        let plan = plan(["settings"], brain: brain, forHome: true)
        #expect(plan.canApply)
        #expect(plan.changes.isEmpty)
        #expect(plan.render.warnings == [".claude/settings.json (settings): JSON files are not rendered into the home folder yet; skipped."])
    }

    @Test func locksOfEitherVersionStillRead() throws {
        // A lock written before merged JSON files existed.
        let old = #"{"brainCommit":"abc","brainDirty":false,"files":{"AGENTS.md":{"layers":["base"],"sha256":"00"}}}"#
        let decoded = try JSONDecoder().decode(ProjectRecords.Lock.self, from: Data(old.utf8))
        #expect(decoded.json == nil && decoded.files["AGENTS.md"]?.sha256 == "00")

        // An older AKit decodes a new lock: the json key is extra and ignored.
        struct OlderLock: Decodable {
            struct Entry: Decodable { var sha256: String?; var link: String?; var layers: [String] }
            var brainCommit: String?
            var brainDirty: Bool
            var files: [String: Entry]
            var templates: [String: String]?
        }
        let new = ProjectRecords.Lock(brainCommit: "abc", brainDirty: false, files: [:],
                                      json: [".mcp.json": .init(keys: ["/a": "00"], created: true, layers: ["mcp"])])
        let older = try JSONDecoder().decode(OlderLock.self, from: try JSONEncoder().encode(new))
        #expect(older.files.isEmpty && older.brainCommit == "abc")
        #expect(try JSONDecoder().decode(ProjectRecords.Lock.self, from: try JSONEncoder().encode(new)) == new)
    }
}
