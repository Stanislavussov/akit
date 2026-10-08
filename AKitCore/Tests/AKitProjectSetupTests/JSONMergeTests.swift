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

    @Test func aValueTheProjectSetIsNeverClaimedEvenWhenTheLayersAgree() async throws {
        let brain = try await setUpBrain()
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        _ = try await ProjectSetup.apply(plan(["mcp"], brain: brain), brain: brain, home: home, env: env, trash: trash)
        // The project changes AKit's value, then the layers bring the same new value.
        var edited = try tree(".mcp.json")
        edited.set(.string("new-two"), at: ["mcpServers", "two", "command"])
        try write("Projects/task/.mcp.json", edited.pretty)
        try write(".akit/registry/layers/mcp/templates/two.json", #"{"mcpServers": {"two": {"command": "new-two", "args": ["--fast"]}}}"#)
        let agreeing = try #require(Brain.load(from: brainRoot))
        _ = try await ProjectSetup.apply(plan(["mcp"], brain: agreeing), brain: agreeing, home: home, env: env, trash: trash)
        #expect(ProjectRecords.savedLock(id: id, in: store)?.json?[".mcp.json"]?.keys["/mcpServers/two/command"] == nil)
        // Dropping the layer's server later leaves the project's value.
        _ = try await ProjectSetup.apply(plan(["mcp"], two: false, brain: agreeing), brain: agreeing, home: home, env: env, trash: trash)
        #expect(try tree(".mcp.json").value(at: ["mcpServers", "two"]) == .object(["command": .string("new-two")]))
    }

    @Test func aFileAnOlderAKitWroteWholeBecomesMerged() async throws {
        let brain = try await setUpBrain()
        // An older AKit wrote .mcp.json whole and recorded it in `files`.
        let whole = #"{"mcpServers": {"old": {"command": "old-server"}, "one": {"command": "one-server"}}}"#
        try write("Projects/task/.mcp.json", whole)
        try ProjectRecords.save(ProjectRecords.Lock(brainCommit: nil, brainDirty: false,
                                                    files: [".mcp.json": .init(sha256: Checksum.sha256(Data(whole.utf8)), link: nil, layers: ["mcp"])]),
                                answers: nil, id: id, in: store)
        let migrated = plan(["mcp"], two: false, brain: brain)
        #expect(migrated.render.warnings.filter { $0.contains("itself") }.isEmpty, "\(migrated.render.warnings)")
        _ = try await ProjectSetup.apply(migrated, brain: brain, home: home, env: env, trash: trash)
        let result = try tree(".mcp.json")
        // Untouched since the old render: every key was AKit's, so the one no layer brings goes.
        #expect(result.value(at: ["mcpServers", "old"]) == nil)
        #expect(result.value(at: ["mcpServers", "one", "command"]) == .string("one-server"))
        let lock = try #require(ProjectRecords.savedLock(id: id, in: store))
        #expect(lock.files[".mcp.json"] == nil)
        #expect(lock.json?[".mcp.json"]?.created == true)
        #expect(lock.json?[".mcp.json"]?.keys["/mcpServers/one/command"] != nil)
    }

    @Test func theHomeFolderNeverTrashesAJSONFileAnOlderAKitWrote() async throws {
        let brain = try await setUpBrain()
        try write(".claude/settings.json", #"{"permissions": {"defaultMode": "plan"}}"#)
        let data = try Data(contentsOf: home.appending(path: ".claude/settings.json"))
        try ProjectRecords.save(ProjectRecords.Lock(brainCommit: nil, brainDirty: false,
                                                    files: [".claude/settings.json": .init(sha256: Checksum.sha256(data), link: nil, layers: ["settings"])]),
                                answers: nil, id: "home/mac", in: store)
        for layers in [["settings"], []] {
            let plan = plan(layers, brain: brain, forHome: true)
            #expect(plan.changes.isEmpty)
            _ = try await ProjectSetup.apply(plan, brain: brain, home: home, env: env, trash: trash)
            #expect(fm.fileExists(atPath: home.appending(path: ".claude/settings.json").path))
            #expect(ProjectRecords.savedLock(id: "home/mac", in: store)?.files[".claude/settings.json"] != nil)
        }
    }

    @Test func aDroppedWholeFileOfAnOlderAKitIsShownMaskedAndSecretFilesAreNeverRead() async throws {
        let brain = try await setUpBrain()
        let whole = #"{"mcpServers": {"api": {"env": {"API_KEY": "sk-live-123"}}}}"#
        try write("Projects/task/.mcp.json", whole)
        try write("Projects/task/.claude/settings.local.json", #"{"env": {"TOKEN": "tok-456"}}"#)
        try write("Projects/task/tsconfig.json", "// comment\n{\"compilerOptions\": {\"strict\": true},}\n")
        let hash = { (path: String) in Checksum.sha256(try Data(contentsOf: project.appending(path: path))) }
        try ProjectRecords.save(ProjectRecords.Lock(brainCommit: nil, brainDirty: false, files: [
            ".mcp.json": .init(sha256: try hash(".mcp.json"), link: nil, layers: ["old"]),
            ".claude/settings.local.json": .init(sha256: try hash(".claude/settings.local.json"), link: nil, layers: ["old"]),
            "tsconfig.json": .init(sha256: try hash("tsconfig.json"), link: nil, layers: ["old"]),
        ]), answers: nil, id: id, in: store)

        let plan = plan([], brain: brain)
        let removed = try #require(change(plan))
        #expect(removed.kind == .remove)
        #expect(removed.oldText?.contains("sk-live-123") == false)
        #expect(removed.oldText?.contains("\"API_KEY\": \"••••\"") == true)
        // JSONC is read without its comments, for showing only.
        #expect(change(plan, "tsconfig.json")?.oldText?.contains("\"strict\": true") == true)
        // settings.local.json: no change, no text, a warning, and its entry stays.
        #expect(change(plan, ".claude/settings.local.json") == nil)
        #expect(plan.render.warnings.contains { $0.hasPrefix(".claude/settings.local.json was written by an earlier render") })
        _ = try await ProjectSetup.apply(plan, brain: brain, home: home, env: env, trash: trash)
        #expect(fm.fileExists(atPath: project.appending(path: ".claude/settings.local.json").path))
        #expect(ProjectRecords.savedLock(id: id, in: store)?.files[".claude/settings.local.json"] != nil)
    }

    @Test func anInterruptedApplyNeverLeavesAFileBothWholeAndMerged() async throws {
        let brain = try await setUpBrain()
        let whole = #"{"mcpServers": {"one": {"command": "one-server"}}}"#
        try write("Projects/task/.mcp.json", whole)
        try write("Projects/task/old.md", "old")
        try ProjectRecords.save(ProjectRecords.Lock(brainCommit: nil, brainDirty: false, files: [
            ".mcp.json": .init(sha256: Checksum.sha256(Data(whole.utf8)), link: nil, layers: ["mcp"]),
            "old.md": .init(sha256: Checksum.sha256(Data("old".utf8)), link: nil, layers: ["gone"]),
        ]), answers: nil, id: id, in: store)
        let plan = plan(["mcp"], brain: brain)
        #expect(change(plan)?.kind == .update && change(plan, "old.md")?.kind == .remove)
        // .mcp.json is written first, then trashing old.md fails.
        await #expect(throws: ProjectSetup.Failure.self) {
            try await ProjectSetup.apply(plan, brain: brain, home: home, env: env, trash: { _ in throw CocoaError(.fileWriteNoPermission) })
        }
        let raw = try JSONDecoder().decode(ProjectRecords.Lock.self, from: try Data(contentsOf: store.folder(id: id).appending(path: "lock.json")))
        #expect(raw.json?[".mcp.json"] != nil)
        #expect(raw.files[".mcp.json"] == nil)
        #expect(raw.files["old.md"] != nil)

        // A lock that has both anyway (written by hand, or by an older build) reads as merged.
        var both = raw
        both.files[".mcp.json"] = .init(sha256: "00", link: nil, layers: ["mcp"])
        try ProjectRecords.save(both, answers: nil, id: id, in: store)
        #expect(ProjectRecords.savedLock(id: id, in: store)?.files[".mcp.json"] == nil)
    }

    @Test func whatTheProjectDeletedStaysDeleted() async throws {
        let brain = try await setUpBrain()
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        _ = try await ProjectSetup.apply(plan(["mcp"], brain: brain), brain: brain, home: home, env: env, trash: trash)
        // The project deletes one of AKit's leaves.
        var edited = try tree(".mcp.json")
        edited.remove(at: ["mcpServers", "two", "args"])
        try write("Projects/task/.mcp.json", edited.pretty)
        let next = plan(["mcp"], brain: brain)
        #expect(change(next)?.kind == .same)
        #expect(next.render.warnings.contains(".mcp.json: the project removed mcpServers.two.args; AKit leaves it out."))
        _ = try await ProjectSetup.apply(next, brain: brain, home: home, env: env, trash: trash)
        #expect(try tree(".mcp.json").value(at: ["mcpServers", "two", "args"]) == nil)
        #expect(ProjectRecords.savedLock(id: id, in: store)?.json?[".mcp.json"]?.keys["/mcpServers/two/args"] == nil)
        #expect(ProjectRecords.savedLock(id: id, in: store)?.json?[".mcp.json"]?.declined == ["/mcpServers/two/args"])
        // And the plan after that: still out.
        let third = plan(["mcp"], brain: brain)
        #expect(change(third)?.kind == .same)
        _ = try await ProjectSetup.apply(third, brain: brain, home: home, env: env, trash: trash)
        #expect(try tree(".mcp.json").value(at: ["mcpServers", "two", "args"]) == nil)
        // Once the layers stop bringing it, it is forgotten.
        _ = try await ProjectSetup.apply(plan(["mcp"], two: false, brain: brain), brain: brain, home: home, env: env, trash: trash)
        #expect(ProjectRecords.savedLock(id: id, in: store)?.json?[".mcp.json"]?.declined == nil)
        _ = try await ProjectSetup.apply(plan(["mcp"], brain: brain), brain: brain, home: home, env: env, trash: trash)
        #expect(try tree(".mcp.json").value(at: ["mcpServers", "two", "args"]) == .array([.string("--fast")]))

        // The project deletes the whole file: not created again, only offered.
        try fm.removeItem(at: project.appending(path: ".mcp.json"))
        let gone = plan(["mcp"], brain: brain)
        #expect(change(gone)?.kind == .own)
        #expect(gone.render.warnings.contains { $0.hasPrefix(".mcp.json: the project deleted it, so AKit doesn't create it again.") })
        _ = try await ProjectSetup.apply(gone, brain: brain, home: home, env: env, trash: trash)
        #expect(read(".mcp.json") == nil)
        #expect(ProjectRecords.savedLock(id: id, in: store)?.json?[".mcp.json"] != nil)
        // Taken on purpose.
        let offered = plan(["mcp"], brain: brain)
        _ = try await ProjectSetup.apply(offered, accepting: [".mcp.json"], brain: brain, home: home, env: env, trash: trash)
        #expect(try tree(".mcp.json").value(at: ["mcpServers", "one", "command"]) == .string("one-server"))
    }

    @Test func whenTheProjectDeletesEveryKeyOfAKitsNoneComesBack() async throws {
        let brain = try await setUpBrain()
        try write("Projects/task/.mcp.json", #"{"mine": true}"#)
        _ = try await ProjectSetup.apply(plan(["mcp"], brain: brain), brain: brain, home: home, env: env, trash: trash)
        try write("Projects/task/.mcp.json", #"{"mine": true}"#)
        for _ in 0..<3 {
            let again = plan(["mcp"], brain: brain)
            #expect(change(again)?.kind == .same)
            _ = try await ProjectSetup.apply(again, brain: brain, home: home, env: env, trash: trash)
            #expect(try tree(".mcp.json") == .object(["mine": .bool(true)]))
        }
        let record = try #require(ProjectRecords.savedLock(id: id, in: store)?.json?[".mcp.json"])
        #expect(record.keys.isEmpty && record.declined?.count == 4)
    }

    @Test func anInterruptedApplyKeepsTheDeclinedKeysOfATrashedFile() async throws {
        let brain = try await setUpBrain()
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        _ = try await ProjectSetup.apply(plan(["mcp"], brain: brain), brain: brain, home: home, env: env, trash: trash)
        // The project takes out every key of AKit's; the file AKit created is left as {}.
        try write("Projects/task/.mcp.json", "{}")
        var lock = try #require(ProjectRecords.savedLock(id: id, in: store))
        try write("Projects/task/old.md", "old")
        lock.files["old.md"] = .init(sha256: Checksum.sha256(Data("old".utf8)), link: nil, layers: ["gone"])
        try ProjectRecords.save(lock, answers: nil, id: id, in: store)
        let next = plan(["mcp"], brain: brain)
        #expect(change(next)?.kind == .remove && change(next, "old.md")?.kind == .remove)
        // .mcp.json goes to the Trash, then trashing old.md fails.
        await #expect(throws: ProjectSetup.Failure.self) {
            try await ProjectSetup.apply(next, brain: brain, home: home, env: env, trash: { url in
                if url.lastPathComponent == "old.md" { throw CocoaError(.fileWriteNoPermission) }
                return try trash(url)
            })
        }
        try #require(read(".mcp.json") == nil, "the test needs .mcp.json trashed before old.md")
        #expect(ProjectRecords.savedLock(id: id, in: store)?.json?[".mcp.json"]?.declined?.count == 4)
        #expect(change(plan(["mcp"], brain: brain))?.kind == .own)
    }

    @Test func anEarlyRecordWithoutContainersTreatsEveryObjectOfAFileAKitCreatedAsItsOwn() async throws {
        let brain = try await setUpBrain()
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        _ = try await ProjectSetup.apply(plan(["mcp"], brain: brain), brain: brain, home: home, env: env, trash: trash)
        var lock = try #require(ProjectRecords.savedLock(id: id, in: store))
        lock.json?[".mcp.json"]?.containers = nil
        try ProjectRecords.save(lock, answers: nil, id: id, in: store)
        let none = plan([], brain: brain)
        #expect(change(none)?.kind == .remove)
    }

    @Test func lockPathsAreReadInOneSpelling() async throws {
        let brain = try await setUpBrain()
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        let first = plan(["mcp"], brain: brain)
        _ = try await ProjectSetup.apply(first, brain: brain, home: home, env: env, trash: trash)
        var lock = try #require(ProjectRecords.savedLock(id: id, in: store))
        lock.files["./AGENTS.md"] = .init(sha256: "00", link: nil, layers: ["old"])
        lock.templates = ["./AGENTS.md": "00"]
        lock.json = lock.json.map { Dictionary(uniqueKeysWithValues: $0.map { ("./" + $0.key, $0.value) }) }
        try ProjectRecords.save(lock, answers: nil, id: id, in: store)
        let read = try #require(ProjectRecords.savedLock(id: id, in: store))
        #expect(read.files["AGENTS.md"] != nil && read.files["./AGENTS.md"] == nil)
        #expect(read.templates?["AGENTS.md"] == "00")
        #expect(read.json?[".mcp.json"] != nil)
        #expect(change(plan(["mcp"], brain: brain))?.kind == .same)
    }

    @Test func wholeOpenCodeFilesShowNoEnvironmentValues() async throws {
        let brain = try await setUpBrain()
        try write(".akit/registry/layers/oc/layer.yaml", "files:\n  - template: oc.json\n    to: opencode.json\n")
        try write(".akit/registry/layers/oc/templates/oc.json", #"{"mcp": {"x": {"type": "local", "environment": {"KEY": "{env:KEY}"}}}}"#)
        try write("Projects/task/opencode.json", #"{"mcp": {"x": {"type": "local", "Environment": {"KEY": "oc-secret-789"}}}}"#)
        let refreshed = try #require(Brain.load(from: brainRoot))
        let plan = plan(["oc"], brain: refreshed)
        let whole = try #require(change(plan, "opencode.json"))
        #expect(!whole.mergesJSON)
        #expect(whole.oldText?.contains("oc-secret-789") == false)
        #expect(whole.oldText?.contains("\"KEY\": \"••••\"") == true)
    }

    @Test func onlyObjectsAKitCreatedAreCleanedUp() async throws {
        let brain = try await setUpBrain()
        try write("Projects/task/.mcp.json", #"{"mcpServers": {}}"#)
        _ = try await ProjectSetup.apply(plan(["mcp"], brain: brain), brain: brain, home: home, env: env, trash: trash)
        let record = try #require(ProjectRecords.savedLock(id: id, in: store)?.json?[".mcp.json"])
        #expect(record.containers?.sorted() == ["/mcpServers/one", "/mcpServers/one/env", "/mcpServers/two"])
        // Server two goes with its object; the project's own mcpServers stays even when empty.
        _ = try await ProjectSetup.apply(plan(["mcp"], two: false, brain: brain), brain: brain, home: home, env: env, trash: trash)
        #expect(try tree(".mcp.json").value(at: ["mcpServers", "two"]) == nil)
        _ = try await ProjectSetup.apply(plan([], brain: brain), brain: brain, home: home, env: env, trash: trash)
        #expect(try tree(".mcp.json") == .object(["mcpServers": .object([:])]))
    }

    @Test func anEditAfterThePreviewStopsApply() async throws {
        let brain = try await setUpBrain()
        try write("Projects/task/.mcp.json", #"{"mcpServers": {}}"#)
        let plan = plan(["mcp"], brain: brain)
        try write("Projects/task/.mcp.json", #"{"mcpServers": {"mine": {"command": "x"}}}"#)
        await #expect(throws: ProjectSetup.Failure.self) {
            try await ProjectSetup.apply(plan, brain: brain, home: home, env: env, trash: trash)
        }
        #expect(read(".mcp.json") == #"{"mcpServers": {"mine": {"command": "x"}}}"#)
    }

    @Test func theProjectsNumbersSurviveAMergeAsWritten() async throws {
        let brain = try await setUpBrain()
        try write("Projects/task/.mcp.json", #"{"n": -0, "e": 1E+2, "big": 123456789012345678901234567890, "f": 0.10, "g": -1.5e-300}"#)
        let outcome = try await ProjectSetup.apply(plan(["mcp"], brain: brain), brain: brain, home: home, env: env, trash: trash)
        let text = try #require(read(".mcp.json"))
        for number in [#""n": -0"#, #""e": 1E+2,"#, #""big": 123456789012345678901234567890,"#, #""f": 0.10,"#, #""g": -1.5e-300,"#] {
            #expect(text.contains(number), "\(number)")
        }
        // Backups hold the project's file, secrets included: only the user may read them.
        let backup = try #require(outcome.backup)
        for folder in [backup, backup.deletingLastPathComponent()] {
            #expect((try fm.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int) == 0o700)
        }
    }

    @Test func forgettingWarnsWhenAKitsKeysStayInAFileItCantRead() async throws {
        let brain = try await setUpBrain()
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        _ = try await ProjectSetup.apply(plan(["mcp"], brain: brain), brain: brain, home: home, env: env, trash: trash)
        try write("Projects/task/.mcp.json", "{ broken")
        let preview = try #require(ProjectForget.preview(id: id, folder: project, forHome: false, brain: brain, store: store))
        #expect(preview.keysLeft == [".mcp.json"])
        #expect(preview.keysTakenOut.isEmpty)
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
