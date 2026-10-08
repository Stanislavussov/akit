import Foundation
import Testing
import AKitBrain
import AKitFoundation
@testable import AKitCommandLine
@testable import AKitInsights

/// The `akit` command, run in-process against a temporary fake home.
struct AKitCLITests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-cli-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var env: HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home, variables: [
            "HOME": home.path, "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
            "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
        ], executableSearchPaths: [URL(filePath: "/usr/bin")])
    }

    var project: URL { home.appending(path: "Projects/task") }

    func write(_ path: String, _ text: String = "") throws {
        let url = home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func read(_ path: String) -> String? { try? String(contentsOf: project.appending(path: path), encoding: .utf8) }

    /// Runs `akit` with these arguments from the project folder; returns (exit code, stdout, stderr).
    func akit(_ arguments: String...) async -> (code: Int32, out: String, err: String) {
        var out: [String] = [], err: [String] = []
        let code = await AKitCLI.run(arguments, env: env, cwd: project, projectsRoot: home.appending(path: "Projects"), hostName: "TestMac.local",
                                     installedTargets: ["claude"], out: { out.append($0) }, err: { err.append($0) },
                                     trash: { url in
                                         let target = home.appending(path: "Trash/\(UUID().uuidString)")
                                         try fm.createDirectory(at: target, withIntermediateDirectories: true)
                                         try fm.moveItem(at: url, to: target.appending(path: url.lastPathComponent))
                                         return target
                                     }, hardwareHash: { "test-hardware" })
        return (code, out.joined(separator: "\n"), err.joined(separator: "\n"))
    }

    func setUp() async throws {
        try await BrainSetup.create(at: Brain.defaultRoot(home: home), env: env)
        try write(".akit/registry/skills/tdd/SKILL.md", "---\nname: tdd\ndescription: Tests first\n---\n")
        try write(".akit/registry/layers/task/layer.yaml", """
            fields:
              - id: company
                required: true
              - id: stack
                type: choice
                options: [node, swift]
              - id: review
                type: bool
            skills: [tdd]
            files:
              - template: agents.md
                to: AGENTS.md
            """)
        try write(".akit/registry/layers/task/templates/agents.md", "# {{company}} in {{stack}}\n")
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
    }

    @Test func planNeverPrintsSecretsOfAJSONFileAnOlderAKitWroteWhole() async throws {
        try await setUp()
        // An older AKit wrote .mcp.json whole from a layer that is gone now.
        let whole = #"{"mcpServers": {"api": {"command": "api", "env": {"API_KEY": "sk-live-123"}}}}"#
        try write("Projects/task/.mcp.json", whole)
        try ProjectRecords.save(ProjectRecords.Lock(brainCommit: nil, brainDirty: false,
                                                    files: [".mcp.json": .init(sha256: Checksum.sha256(Data(whole.utf8)), link: nil, layers: ["old"])]),
                                answers: nil, id: "local/task", in: .brain(Brain.defaultRoot(home: home)))
        let plan = await akit("plan", "--layers", "task", "--set", "company=Acme")
        #expect(plan.code == 0, "\(plan.err)")
        #expect(plan.out.contains("REMOVE (to the Trash) .mcp.json"), "\(plan.out)")
        #expect(!plan.out.contains("sk-live-123"))
        #expect(plan.out.contains("\"API_KEY\": \"••••\""))

        // A whole opencode.json: its MCP `environment` values are masked too.
        try write(".akit/registry/layers/oc/layer.yaml", "files:\n  - template: oc.json\n    to: opencode.json\n")
        try write(".akit/registry/layers/oc/templates/oc.json", #"{"mcp": {"x": {"environment": {"KEY": "{env:KEY}"}}}}"#)
        try write("Projects/task/opencode.json", #"{"mcp": {"x": {"environment": {"KEY": "oc-secret-789"}}}}"#)
        let opencode = await akit("plan", "--layers", "oc")
        #expect(opencode.code == 0, "\(opencode.err)")
        #expect(opencode.out.contains("opencode.json"), "\(opencode.out)")
        #expect(!opencode.out.contains("oc-secret-789"))
    }

    @Test func checkAndLayers() async throws {
        try await setUp()
        let ok = await akit("check")
        #expect(ok.code == 0 && ok.out.contains("No problems."), "\(ok)")
        try write(".akit/registry/layers/bad/layer.yaml", "skills: [ghost]\n")
        let bad = await akit("check")
        #expect(bad.code == 1 && bad.out.contains("- layers/bad: Skill “ghost” is not in skills/."))

        let layers = await akit("layers", "--json")
        let json = try JSONSerialization.jsonObject(with: Data(layers.out.utf8)) as? [[String: Any]]
        #expect(json?.map { $0["name"] as? String } == ["bad", "core", "task"])
        #expect(await akit("--brain", home.appending(path: "nope").path, "check").code == 2)
    }

    @Test func planThenApplyFromFlags() async throws {
        try await setUp()
        let missing = await akit("plan", "--layers", "task")
        #expect(missing.code == 1 && missing.out.contains("ERROR: “company” (company) is required by task."))
        #expect(await akit("plan", "--layers", "task", "--set", "stack=rust").err.contains("“rust” is not an option of stack"))
        #expect(await akit("plan", "--set", "nope=1").code == 2)

        let plan = await akit("plan", ".", "--layers", "task", "--set", "company=Acme", "--set", "stack=swift")
        #expect(plan.code == 0, "\(plan)")
        #expect(plan.out.contains("NEW AGENTS.md") && plan.out.contains("+ # Acme in swift"))
        #expect(read("AGENTS.md") == nil)  // plan never writes

        let apply = await akit("apply", "--layers", "task", "--set", "company=Acme", "--set", "stack=swift", "--targets", "claude,pi")
        #expect(apply.code == 0, "\(apply)")
        #expect(read("AGENTS.md") == "# Acme in swift\n")
        #expect(read("CLAUDE.md") == "@AGENTS.md\n")

        // Saved answers are the starting point next time.
        let answers = await akit("answers")
        #expect(answers.out.contains("\"company\" : \"Acme\""))
        let again = await akit("plan", "--set", "company=Beta")
        #expect(again.out.contains("CHANGED AGENTS.md") && again.out.contains("+ # Beta in swift"))
    }

    @Test func homeGetsTheCoreLayerAndTakesOverOldCopiesOnlyWhenAsked() async throws {
        try await setUp()
        try write(".akit/registry/layers/core/layer.yaml", "name: core\nskills:\n  - name: tdd\n    mode: manual\n")
        // The old global copy (same file as the brain's) and Claude's link to the shared folder.
        try write(".agents/skills/tdd/SKILL.md", "---\nname: tdd\ndescription: Tests first\n---\n")
        try fm.createDirectory(at: home.appending(path: ".claude"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: home.appending(path: ".claude/skills").path, withDestinationPath: "../.agents/skills")

        let plan = await akit("plan", "--home")
        #expect(plan.code == 0, "\(plan)")
        #expect(plan.out.contains("CHANGED .agents/skills/tdd/SKILL.md  (AKit didn't write it"))
        #expect(!plan.out.contains("CLAUDE.md") && !plan.out.contains("AGENTS.md"))
        #expect(plan.out.contains("(brain: projects/home/testmac)"))
        #expect(await akit("plan", "--home", "--layers", "task").code == 2)

        let skipped = await akit("apply", "--home")
        #expect(skipped.out.contains("Skipped: .agents/skills/tdd/SKILL.md"))
        let taken = await akit("apply", "--home", "--include-unmanaged")
        #expect(taken.code == 0, "\(taken)")
        let skill = try String(contentsOf: home.appending(path: ".agents/skills/tdd/SKILL.md"), encoding: .utf8)
        #expect(skill.contains("disable-model-invocation: true"))
        #expect(try fm.destinationOfSymbolicLink(atPath: home.appending(path: ".claude/skills").path) == "../.agents/skills")
        #expect(taken.out.contains("Backup: "))
        #expect(ProjectRecords.savedAnswers(id: "home/testmac", in: .brain(Brain.defaultRoot(home: home)))?.layers == ["core"])
    }

    @Test func homeGetsTheCoreLayersInstructionsAsABlockInEachHarnessFile() async throws {
        try await setUp()
        try write(".akit/registry/layers/core/layer.yaml", "name: core\nfiles:\n  - template: AGENTS.md\n    to: AGENTS.md\n")
        try write(".akit/registry/layers/core/templates/AGENTS.md", "Be brief.\n")
        try write(".claude/CLAUDE.md", "# Mine\n")
        // Pi's folder comes from PI_CODING_AGENT_DIR, like Pi's own.
        var piEnv = env
        piEnv.variables["PI_CODING_AGENT_DIR"] = "~/pi-config"
        var out: [String] = []
        let code = await AKitCLI.run(["apply", "--home", "--targets", "claude,pi"], env: piEnv, cwd: project, projectsRoot: home.appending(path: "Projects"),
                                     hostName: "TestMac.local", installedTargets: ["claude"], out: { out.append($0) }, err: { out.append($0) },
                                     trash: { _ in nil }, hardwareHash: { "test-hardware" })
        #expect(code == 0, "\(out)")
        let text = out.joined(separator: "\n")
        #expect(text.contains("CHANGED .claude/CLAUDE.md  (AKit's block between the akit:core markers; the text around it stays)"), "\(text)")
        #expect(text.contains("NEW pi-config/AGENTS.md"))
        let block = "<!-- akit:core:start -->\nBe brief.\n<!-- akit:core:end -->\n"
        #expect(try String(contentsOf: home.appending(path: ".claude/CLAUDE.md"), encoding: .utf8) == "# Mine\n\n" + block)
        #expect(try String(contentsOf: home.appending(path: "pi-config/AGENTS.md"), encoding: .utf8) == block)
        #expect(!fm.fileExists(atPath: home.appending(path: "AGENTS.md").path))
        #expect(!fm.fileExists(atPath: home.appending(path: ".pi").path))
    }

    @Test func homeIDs() {
        #expect(ProjectRecords.homeID(hostName: "Example-Mac.local") == "home/example-mac")
        #expect(ProjectRecords.homeID(hostName: "") == "home/mac")
        #expect(ProjectRecords.homeID(hostName: "ACME-1234.local", machineName: "Work") == "home/work")
        #expect(ProjectRecords.homeID(hostName: "ACME-1234.local", machineName: "") == "home/acme-1234")
    }

    func brainGit(_ args: String...) async throws -> String {
        let result = try #require(await ProcessRunner.run(URL(filePath: "/usr/bin/git"), arguments: args,
                                                           directory: Brain.defaultRoot(home: home), environment: env.variables, timeout: 10))
        #expect(result.succeeded, "\(result.output)")
        return result.output
    }

    @Test func workMacKeepsProjectRecordsOutOfTheBrain() async throws {
        try await setUp()
        try write(".akit/registry/layers/core/layer.yaml", "name: core\nskills:\n  - name: tdd\n    mode: manual\n")
        _ = try await brainGit("add", "-A")
        _ = try await brainGit("commit", "-qm", "Layers")
        #expect(await akit("apply", "--home").code == 0)  // saved as a personal Mac: projects/home/testmac
        #expect(await akit("machine").out.hasPrefix("Personal Mac."))

        let switched = await akit("machine", "work")
        #expect(switched.code == 0, "\(switched)")
        #expect(switched.out.contains("Copied this Mac's home record (projects/home/testmac)"))
        #expect(switched.out.contains("The brain still has records saved before (by any Mac): home/testmac."))
        #expect(await akit("machine").out.hasPrefix("Work Mac “work”."))
        let local = ProjectStore.local(home: home)
        let commits = try await brainGit("rev-list", "--count", "HEAD")

        // The home render still knows its files (the lock was copied) and saves under the new name.
        let homeAgain = await akit("apply", "--home")
        #expect(homeAgain.code == 0 && !homeAgain.out.contains("Skipped"), "\(homeAgain)")
        #expect(homeAgain.out.contains("on this Mac only"))
        #expect(ProjectRecords.savedAnswers(id: "home/work", in: local)?.layers == ["core"])

        let applied = await akit("apply", "--layers", "task", "--set", "company=Acme", "--set", "stack=swift")
        #expect(applied.code == 0, "\(applied)")
        #expect(applied.out.contains("(saved locally: \(local.folder(id: "local/task").path))"))
        #expect(read("AGENTS.md") == "# Acme in swift\n")
        #expect(ProjectRecords.savedAnswers(id: "local/task", in: local)?.values["company"] == .text("Acme"))
        #expect(await akit("answers").out.contains("\"company\" : \"Acme\""))

        // Nothing reached the brain: no new commit, no new files.
        #expect(try await brainGit("rev-list", "--count", "HEAD") == commits)
        #expect(try await brainGit("status", "--porcelain").isEmpty)
        #expect(!fm.fileExists(atPath: Brain.defaultRoot(home: home).appending(path: "projects/local").path))

        // Removing a layer updates local answers without committing them.
        #expect(await akit("remove", "layer", "task", "--yes").code == 0)
        #expect(ProjectRecords.savedAnswers(id: "local/task", in: local)?.layers == [])
        #expect(try await brainGit("status", "--porcelain").isEmpty)

        let forgot = await akit("remove", "project", "--yes")
        #expect(forgot.code == 0, "\(forgot)")
        #expect(!fm.fileExists(atPath: local.folder(id: "local/task").path))

        let back = await akit("machine", "personal")
        #expect(back.code == 0 && back.out.hasPrefix("Personal Mac:"))
        let personal = MachineProfile.load(home: home)
        #expect(personal.kind == .personal && personal.name == nil && personal.problem == nil)
    }

    @Test func workMacFailsClosedAndKeepsEarlierRendersKnown() async throws {
        try await setUp()
        _ = try await brainGit("add", "-A")
        _ = try await brainGit("commit", "-qm", "Layers")
        // Rendered while personal: the record is in the brain.
        #expect(await akit("apply", "--layers", "task", "--set", "company=Acme", "--set", "stack=swift").code == 0)
        let commits = try await brainGit("rev-list", "--count", "HEAD")

        // A broken machine.json counts as a work Mac, with a warning.
        try write(".akit/machine.json", "{ \"kind\": \"Work\", }")
        #expect(MachineProfile.load(home: home).isWork)
        let broken = await akit("plan")
        #expect(broken.err.contains("can't be read, so this Mac counts as a work Mac"), "\(broken)")
        #expect(broken.out.contains("saved locally"))
        #expect(await akit("machine").out.contains("can't be read"))

        // Case doesn't matter; --name belongs to akit machine only.
        let switched = await akit("machine", "WORK")
        #expect(switched.code == 0, "\(switched)")
        #expect(switched.out.contains("git -C") && switched.out.contains("config user.email"))
        #expect(await akit("apply", "--name", "x").code == 2)

        // The brain's earlier record is read (answers prefilled, files known), never written.
        let changed = await akit("apply", "--set", "company=Beta")
        #expect(changed.code == 0, "\(changed)")
        #expect(changed.out.contains("CHANGED AGENTS.md") && !changed.out.contains("Skipped"), "\(changed)")
        #expect(read("AGENTS.md") == "# Beta in swift\n")
        let local = ProjectStore.local(home: home)
        #expect(fm.fileExists(atPath: local.folder(id: "local/task").appending(path: "lock.json").path))
        #expect(ProjectRecords.savedAnswers(id: "local/task", in: .brain(Brain.defaultRoot(home: home)))?.values["company"] == .text("Acme"))
        #expect(try await brainGit("rev-list", "--count", "HEAD") == commits)
        #expect(try await brainGit("status", "--porcelain").isEmpty)

        // Forgetting it clears the local record and points at the brain's one.
        let forgot = await akit("remove", "project", "--keep-files", "--yes")
        #expect(forgot.code == 0 && forgot.out.contains("The brain still has projects/local/task"), "\(forgot)")
        #expect(!fm.fileExists(atPath: local.folder(id: "local/task").path))
    }

    @Test func renamingAWorkMacMovesItsHomeRecord() async throws {
        try await setUp()
        try write(".akit/registry/layers/core/layer.yaml", "name: core\nskills:\n  - name: tdd\n    mode: manual\n")
        #expect(await akit("machine", "work").code == 0)
        #expect(await akit("apply", "--home").code == 0)
        let local = ProjectStore.local(home: home)
        #expect(fm.fileExists(atPath: local.folder(id: "home/work").path))

        let renamed = await akit("machine", "work", "--name", "Laptop")
        #expect(renamed.out.contains("Renamed this Mac's home record from home/work to home/laptop"), "\(renamed)")
        #expect(!fm.fileExists(atPath: local.folder(id: "home/work").path))
        let again = await akit("apply", "--home")
        #expect(again.code == 0 && again.out.contains("No changes."), "\(again)")
        #expect(await akit("machine").out.hasPrefix("Work Mac “Laptop”."))
    }

    @Test func applySkipsForeignFilesUnlessIncluded() async throws {
        try await setUp()
        try write("Projects/task/CLAUDE.md", "my rules\n")
        let skipped = await akit("apply", "--layers", "task", "--set", "company=A")
        #expect(skipped.code == 0 && skipped.out.contains("Skipped: CLAUDE.md"))
        #expect(read("CLAUDE.md") == "my rules\n")

        let included = await akit("apply", "--include", "CLAUDE.md")
        #expect(included.code == 0, "\(included)")
        #expect(read("CLAUDE.md") == "@AGENTS.md\n")
        #expect(included.out.contains("Backup: "))
    }

    @Test func initCreatesABrainWithTheAkitSkillInCore() async throws {
        let created = await akit("init")
        #expect(created.code == 0 && created.out.contains("akit apply --home"))
        let brain = try #require(Brain.load(from: Brain.defaultRoot(home: home)))
        #expect(brain.problems.isEmpty)
        #expect(brain.skills.map(\.name) == ["akit"])
        #expect(brain.layers.first { $0.name == "core" }?.skills.map { "\($0.name):\($0.mode)" } == ["akit:manual"])
        #expect(await akit("init").code == 2)  // not over an existing brain

        let home = await akit("apply", "--home")
        #expect(home.code == 0)
        let skill = try String(contentsOf: self.home.appending(path: ".agents/skills/akit/SKILL.md"), encoding: .utf8)
        #expect(skill.contains("disable-model-invocation: true") && skill.contains("akit sync"))
    }

    // MARK: Session insights

    @Test func sessionsImportNeedsNoBrain() async throws {
        try write(".claude/projects/-work-app/s1.jsonl", """
            {"type":"assistant","uuid":"a","timestamp":"2026-09-20T10:00:00.000Z","message":{"id":"m1","model":"claude-opus-5-5","content":[],"usage":{"input_tokens":3,"output_tokens":1}}}

            """)
        let first = await akit("sessions", "import", "--json")
        #expect(first.code == 0, "\(first)")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(first.out.utf8)) as? [String: Any])
        for key in ["sources", "newBytes", "sessions", "requests", "toolCalls", "skillCalls", "spoolLines", "skipped", "ms"] {
            #expect(json[key] != nil, "\(key)")
        }
        #expect(json["sources"] as? Int == 1 && json["requests"] as? Int == 1)
        #expect(fm.fileExists(atPath: home.appending(path: ".akit/index/index.sqlite").path))

        let again = await akit("sessions", "import")
        #expect(again.code == 0 && again.out.contains("Nothing new"))
        let quiet = await akit("sessions", "import", "--quiet")
        #expect(quiet.code == 0 && quiet.out.isEmpty)
    }

    @Test func recordSessionNeedsNoBrain() async throws {
        var out: [String] = [], err: [String] = []
        let input = Data(#"{"session_id":"r1","cwd":"/work/app"}"#.utf8)
        let code = await AKitCLI.run(["record-session", "--harness", "pi", "--bogus"], env: env, cwd: home,
                                     out: { out.append($0) }, err: { err.append($0) }, input: { input })
        #expect(code == 0 && out.isEmpty && err.isEmpty)
        let spool = InsightsPaths(home: home).spool
        let files = try fm.contentsOfDirectory(atPath: spool.path)
        let text = try String(contentsOf: spool.appending(path: try #require(files.first)), encoding: .utf8)
        #expect(files.count == 1 && text.contains(#""session_id":"r1""#) && text.contains(#""harness":"pi""#))
        #expect(!fm.fileExists(atPath: Brain.defaultRoot(home: home).path))
        // Garbage: still silent and 0.
        #expect(await AKitCLI.run(["record-session"], env: env, cwd: home, out: { out.append($0) }, err: { err.append($0) },
                                  input: { Data("nope".utf8) }) == 0)
        #expect(out.isEmpty && err.isEmpty)
    }

    @Test func secondImporterSkips() async throws {
        let held = try #require(try ImportLock.acquire(InsightsPaths(home: home).lock))
        let result = await akit("sessions", "import")
        #expect(result.code == 0 && result.out == "Import already running.")
        #expect(await akit("sessions", "import", "--quiet").out.isEmpty)
        withExtendedLifetime(held) {}
    }

    @Test func unknownInsightsFlagFails() async throws {
        let unknown = await akit("sessions", "import", "--bogus")
        #expect(unknown.code == 2 && unknown.err.contains("--bogus"))
        let project = await akit("sessions", "import", "--home")
        #expect(project.code == 2 && project.err.contains("--home doesn't go with akit sessions"))
        #expect(await akit("sessions", "--layers", "a", "import").code == 2)
        #expect(await akit("sessions", "export").code == 2)
        #expect(!fm.fileExists(atPath: home.appending(path: ".akit/index/index.sqlite").path))
    }

    /// A Claude session s1 (listing, model and user skill calls, a built-in command, a subagent run) and s2, whose
    /// version should have written a listing but didn't.
    func writeStatsSessions() throws {
        func line(_ object: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: object, options: .sortedKeys), as: UTF8.self)
        }
        func entry(_ type: String, _ uuid: String, _ time: String, session: String = "s1", _ fields: [String: Any]) -> [String: Any] {
            fields.merging(["type": type, "uuid": uuid, "sessionId": session, "version": "2.1.283",
                            "timestamp": "2026-09-20T10:00:\(time).000Z"]) { $1 }
        }
        let usage: [String: Any] = ["input_tokens": 3, "output_tokens": 1, "cache_read_input_tokens": 100, "cache_creation_input_tokens": 20]
        let s1: [[String: Any]] = [
            entry("attachment", "L1", "00", ["attachment": ["type": "skill_listing", "isInitial": true, "names": ["tdd", "lint"],
                                                            "content": "- tdd: Tests first\n- lint: Lint"]]),
            entry("user", "U1", "01", ["message": ["role": "user", "content": "<command-message>tdd</command-message>\n<command-name>/tdd</command-name>"]]),
            entry("user", "U0", "01", ["message": ["role": "user", "content": "<command-name>/model</command-name>\n<command-args>opus</command-args>"]]),
            entry("assistant", "A1", "02", ["message": ["id": "m1", "model": "claude-opus-5-5", "usage": usage, "content": [
                ["type": "tool_use", "id": "t1", "name": "Skill", "input": ["skill": "lint"]],
                ["type": "tool_use", "id": "t2", "name": "Bash", "input": ["command": "ls"]],
            ]]]),
            entry("user", "U2", "03", ["message": ["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": "t2", "content": String(repeating: "x", count: 500)],
            ]]]),
        ]
        let agent: [[String: Any]] = [
            entry("assistant", "SA1", "04", ["isSidechain": true, "message": ["id": "sm1", "model": "claude-opus-5-5", "usage": usage, "content": [
                ["type": "tool_use", "id": "st1", "name": "Skill", "input": ["skill": "tdd"]],
            ]]]),
        ]
        let s2: [[String: Any]] = [
            entry("assistant", "B1", "30", session: "s2", ["message": ["id": "n1", "model": "claude-opus-5-5", "usage": usage, "content": []]]),
        ]
        try write(".claude/projects/-work-app/s1.jsonl", try s1.map(line).joined(separator: "\n") + "\n")
        try write(".claude/projects/-work-app/s1/subagents/agent-a1.jsonl", try agent.map(line).joined(separator: "\n") + "\n")
        try write(".claude/projects/-work-app/s2.jsonl", try s2.map(line).joined(separator: "\n") + "\n")
    }

    func statsJSON(_ result: (code: Int32, out: String, err: String)) throws -> (sessions: [[String: Any]], notes: [String]) {
        let json = try #require(try JSONSerialization.jsonObject(with: Data(result.out.utf8)) as? [String: Any], "\(result)")
        return (json["sessions"] as? [[String: Any]] ?? [], json["notes"] as? [String] ?? [])
    }

    @Test func statsDebugWorksWithoutBrain() async throws {
        try writeStatsSessions()
        let plain = await akit("stats")
        #expect(plain.code == 0 && plain.out.contains("note: \(InsightsStats.piNote)"), "\(plain)")

        let all = try statsJSON(await akit("stats", "--debug", "--json"))
        #expect(all.sessions.compactMap { $0["key"] as? String } == ["claude:s2", "claude:s1"])
        // s2 has a version and requests but no listing: the parser may be out of date.
        #expect(all.notes.contains { $0.contains("claude:s2") && $0.contains("no skill listing") }, "\(all.notes)")
        #expect(!all.notes.contains { $0.contains("claude:s1") })

        let s1 = try #require(all.sessions.last)
        #expect(s1["harness"] as? String == "claude" && s1["started"] as? String == "2026-09-20T10:00:00Z")
        #expect(s1["listings"] as? Int == 2 && s1["listedChars"] as? Int == "Tests first".count + "Lint".count)
        #expect(s1["modelCalls"] as? Int == 1 && s1["userCalls"] as? Int == 1 && s1["userCommands"] as? Int == 1)
        #expect(s1["subagentCalls"] as? Int == 1 && s1["subagentRuns"] as? Int == 1)
        #expect(s1["firstRequestContext"] as? Int == 123)
        let outputs = try #require(s1["largestToolOutputs"] as? [[String: Any]])
        #expect(outputs.count == 1 && outputs[0]["name"] as? String == "Bash" && outputs[0]["bytes"] as? Int == 500)

        let text = await akit("stats", "--debug")
        #expect(text.code == 0 && text.out.contains("claude:s1") && text.out.contains("1 by the model, 1 by the user, "), "\(text)")
        #expect(text.out.contains("; 1 built-in commands (/model, /clear …)"), "\(text)")
        #expect(!fm.fileExists(atPath: home.appending(path: ".akit/registry").path))
    }

    @Test func statsFlagsBeforeSubcommandWord() async throws {
        try writeStatsSessions()
        for arguments in [["stats", "--session", "s1", "--debug", "--json"], ["--json", "stats", "--debug", "--session", "claude:s1"]] {
            var out: [String] = []
            let code = await AKitCLI.run(arguments, env: env, cwd: project, out: { out.append($0) }, err: { _ in })
            let stats = try statsJSON((code, out.joined(separator: "\n"), ""))
            #expect(code == 0 && stats.sessions.count == 1 && stats.sessions.first?["key"] as? String == "claude:s1", "\(arguments)")
        }
        let missing = await akit("stats", "--debug", "--session", "nope")
        #expect(missing.code == 2 && missing.err.contains("No session “nope”"))

        // A value flag before the subcommand word is never taken for it.
        let bindings = await akit("stats", "--days", "30", "bindings", "--json")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(bindings.out.utf8)) as? [String: Any], "\(bindings)")
        #expect(bindings.code == 0 && (json["recent"] as? [String: Any])?["days"] as? Int == 30 && json["byMethod"] != nil)
        let week = await akit("--json", "stats", "--days", "7", "bindings")
        #expect(week.code == 0 && week.out.contains(#""days" : 7"#), "\(week)")
        #expect(await akit("stats", "--days", "0").code == 2)
        #expect(await akit("stats", "--top", "x").code == 2)
        #expect(await akit("stats", "--session", "s1").code == 2, "--session goes with --debug")
    }

    @Test func statsBindingsWorksWithoutBrain() async throws {
        // Two recent sessions: one in the project folder (a plain folder under the projects root), one gone.
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        let yesterday = Date().addingTimeInterval(-86_400).formatted(.iso8601)
        for (id, cwd) in [("b1", project.path), ("b2", home.appending(path: "gone/wt").path)] {
            let line = try JSONSerialization.data(withJSONObject: [
                "type": "assistant", "uuid": "u-\(id)", "sessionId": id, "cwd": cwd, "gitBranch": "feature", "timestamp": yesterday,
                "message": ["id": "m-\(id)", "model": "claude-opus-5-5", "content": [], "usage": ["input_tokens": 1, "output_tokens": 1]],
            ] as [String: Any], options: .sortedKeys)
            try write(".claude/projects/-work-\(id)/\(id).jsonl", String(decoding: line, as: UTF8.self) + "\n")
        }
        let result = await akit("stats", "bindings", "--json")
        #expect(result.code == 0, "\(result)")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(result.out.utf8)) as? [String: Any], "\(result)")
        #expect(json["bindingSet"] as? [String] == ["exact", "high", "medium"])
        let byMethod = try #require(json["byMethod"] as? [String: Int])
        #expect(byMethod["live"] == 1 && byMethod["none"] == 1 && json["undecided"] as? Int == 0, "\(json)")
        let recent = try #require(json["recent"] as? [String: Any])
        #expect(recent["days"] as? Int == 30 && recent["sessions"] as? Int == 2 && recent["bound"] as? Int == 1)
        #expect(json["unboundFolders"] as? [String] == [home.appending(path: "gone/wt").path])
        #expect(json["byConfidence"] != nil && json["notes"] != nil)
        #expect(!fm.fileExists(atPath: Brain.defaultRoot(home: home).path))

        let text = await akit("stats", "bindings")
        #expect(text.code == 0 && text.out.contains("Last 30 days: 1 of 2 main sessions bound at exact, high, medium (50%)."), "\(text)")
        #expect(text.out.contains("by method: hook 0, live 1,") && text.out.contains(home.appending(path: "gone/wt").path))

        // Flags before the subcommand word; low counts only when asked for.
        for arguments in [["--json", "stats", "bindings"], ["stats", "--bindings", "exact,low", "--json", "bindings"]] {
            var out: [String] = []
            let code = await AKitCLI.run(arguments, env: env, cwd: project, projectsRoot: home.appending(path: "Projects"),
                                         out: { out.append($0) }, err: { _ in })
            let json = try #require(try JSONSerialization.jsonObject(with: Data(out.joined().utf8)) as? [String: Any], "\(arguments)")
            #expect(code == 0 && json["byMethod"] != nil, "\(arguments)")
        }
        let bad = await akit("stats", "--bindings", "bogus", "bindings")
        #expect(bad.code == 2 && bad.err.contains("bogus"))
        #expect(await akit("stats", "--debug", "--bindings", "low").code == 2)
        #expect(await akit("stats", "bindings", "--debug").code == 2)
        #expect(await akit("stats", "bindings", "extra").code == 2)
        #expect(await akit("stats", "nope").code == 2)
    }

    @Test func statsReadsTheIndexWhileAnImportRuns() async throws {
        let held = try #require(try ImportLock.acquire(InsightsPaths(home: home).lock))
        let stats = try statsJSON(await akit("stats", "--debug", "--json"))
        #expect(stats.sessions.isEmpty && stats.notes == ["import running; data up to no import yet"])
        withExtendedLifetime(held) {}
    }

    @Test func unknownStatsFlagFails() async throws {
        let unknown = await akit("stats", "--debug", "--bogus")
        #expect(unknown.code == 2 && unknown.err.contains("--bogus"))
        let project = await akit("stats", "--debug", "--home")
        #expect(project.code == 2 && project.err.contains("--home doesn't go with akit stats"))
        #expect(await akit("stats", "--debug", "extra").code == 2)
        #expect(await akit("stats", "--debug", "--session").code == 2)
        // A value never starts with `--`: --debug is no session id.
        let swallowed = await akit("stats", "--session", "--debug")
        #expect(swallowed.code == 2 && swallowed.err.contains("--session"), "\(swallowed)")
        #expect(!fm.fileExists(atPath: home.appending(path: ".akit/index/index.sqlite").path))
    }

    /// A recent Claude session listing an own skill, a plugin skill and a built-in one, with a model call of the own skill.
    func writeListedSkills() throws {
        let time = Date().addingTimeInterval(-3600)
        func line(_ object: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: object, options: .sortedKeys), as: UTF8.self)
        }
        func entry(_ type: String, _ uuid: String, _ seconds: Double, _ fields: [String: Any]) -> [String: Any] {
            fields.merging(["type": type, "uuid": uuid, "sessionId": "l1", "version": "2.1.283",
                            "timestamp": time.addingTimeInterval(seconds).formatted(.iso8601)]) { $1 }
        }
        let usage: [String: Any] = ["input_tokens": 3, "output_tokens": 1, "cache_read_input_tokens": 100]
        let lines: [[String: Any]] = [
            entry("attachment", "L1", 0, ["attachment": ["type": "skill_listing", "isInitial": true,
                                                         "names": ["mine", "marketing:seo-audit", "ghost"],
                                                         "content": "- mine: Own skill\n- marketing:seo-audit: Audit a site\n- ghost: Built in"]]),
            entry("assistant", "A1", 1, ["message": ["id": "m1", "model": "claude-opus-5-5", "usage": usage, "content": [
                ["type": "tool_use", "id": "t1", "name": "Skill", "input": ["skill": "mine"]],
            ]]]),
        ]
        try write(".claude/projects/-work-app/l1.jsonl", try lines.map(line).joined(separator: "\n") + "\n")
        try write(".claude/skills/mine/SKILL.md", "---\nname: mine\ndescription: Own skill\n---\n")
    }

    func statsReport(_ result: (code: Int32, out: String, err: String)) throws -> (json: [String: Any], owners: [String: [String: Any]]) {
        let json = try #require(try JSONSerialization.jsonObject(with: Data(result.out.utf8)) as? [String: Any], "\(result)")
        let skills = json["skills"] as? [[String: Any]] ?? []
        return (json, Dictionary(uniqueKeysWithValues: skills.compactMap { skill in
            (skill["name"] as? String).map { ($0, skill["owner"] as? [String: Any] ?? [:]) }
        }))
    }

    @Test func statsWithoutBrainMarksLayerOwnersUnknown() async throws {
        try writeListedSkills()
        let blind = try statsReport(await akit("stats", "--json"))
        #expect(blind.json["version"] as? Int == 1)
        #expect(blind.owners["mine"]?["kind"] as? String == "unknown", "\(blind.owners)")
        #expect(blind.owners["marketing:seo-audit"]?["kind"] as? String == "plugin"
                && blind.owners["marketing:seo-audit"]?["name"] as? String == "marketing")
        #expect(blind.owners["ghost"]?["kind"] as? String == "builtIn")
        #expect((blind.json["notes"] as? [String])?.contains(InsightsStats.noBrainNote) == true, "\(blind.json)")
        let mine = (blind.json["skills"] as? [[String: Any]])?.first { $0["name"] as? String == "mine" }
        #expect(mine?["listedSessions"] as? Int == 1 && mine?["modelCalls"] as? Int == 1 && mine?["callRate"] as? Double == 1)
        let text = await akit("stats")
        #expect(text.code == 0 && text.out.contains("unknown: 1 skill") && text.out.contains("note: \(InsightsStats.noBrainNote)"), "\(text)")
        #expect(!fm.fileExists(atPath: Brain.defaultRoot(home: home).path))

        // With a brain, an own skill it doesn't hold is hand-installed.
        try await setUp()
        let known = try statsReport(await akit("stats", "--json"))
        #expect(known.owners["mine"]?["kind"] as? String == "handInstalled"
                && known.owners["mine"]?["name"] as? String == "~/.claude/skills/mine/SKILL.md", "\(known.owners)")
        #expect((known.json["notes"] as? [String])?.contains(InsightsStats.noBrainNote) == false)
    }

    @Test func statsSubcommandWordsDontClashWithProject() async throws {
        try writeListedSkills()
        for word in ["bindings", "changes", "mark"] {
            let result = await akit("stats", "--project", word, "--json")
            let scope = try statsReport(result).json["scope"] as? [String: Any]
            #expect(result.code == 0 && scope?["project"] as? String == word, "\(word): \(result)")
        }
        // A folder gives its project id; the default and --all cover every session.
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        let here = try statsReport(await akit("stats", "--project", ".", "--json"))
        #expect((here.json["scope"] as? [String: Any])?["project"] as? String == "local/task")
        #expect((here.json["summary"] as? [String: Any])?["sessions"] as? Int == 0, "no session is bound to it")
        let all = try statsReport(await akit("stats", "--all", "--json"))
        #expect((all.json["scope"] as? [String: Any])?["project"] is NSNull && (all.json["summary"] as? [String: Any])?["sessions"] as? Int == 1)
        #expect(await akit("stats", "--project", "x", "--all").code == 2)
        #expect(await akit("stats", "bindings", "--project", "x").code == 2)
        #expect(await akit("stats", "--debug", "--all").code == 2)
        #expect(await akit("stats", "trend").code == 2)
        #expect(await akit("stats", "--project", "changes", "changes").code == 0)
    }
}
