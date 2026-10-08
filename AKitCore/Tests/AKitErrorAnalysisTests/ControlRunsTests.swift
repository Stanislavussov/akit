import Foundation
import Testing
import AKitFoundation
@testable import AKitLab
import AKitSessions
@testable import AKitErrorAnalysis

/// Control cells end to end: fake `claude` and `pi` in a temporary home, a temporary
/// repository as the user's. Serialized: the worker's cancellation state is process-wide.
@Suite(.serialized)
struct ControlRunsTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-controlruns-\(UUID().uuidString)")
        try fm.createDirectory(at: home.appending(path: "bin"), withIntermediateDirectories: true)
        Cancellation.reset()
    }

    var env: HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home, variables: [
            "HOME": home.path, "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "T", "GIT_AUTHOR_EMAIL": "t@example.com",
            "GIT_COMMITTER_NAME": "T", "GIT_COMMITTER_EMAIL": "t@example.com",
        ], executableSearchPaths: [home.appending(path: "bin"), URL(filePath: "/usr/bin"), URL(filePath: "/bin")])
    }

    func write(_ path: String, _ text: String, in folder: URL? = nil, executable: Bool = false) throws {
        let url = (folder ?? home).appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if executable { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
    }

    func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    @discardableResult
    func git(_ args: String..., in folder: URL) async -> String? {
        let result = await ProcessRunner.run(URL(filePath: "/usr/bin/git"), arguments: ["-C", folder.path] + args,
                                             environment: env.gitVariables, timeout: 60)
        return result?.succeeded == true ? result?.output.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    /// value.txt holds 1; the oracle wants 2. Two tests guard it.
    func repository() async throws -> (repo: URL, base: String) {
        let repo = home.appending(path: "repo")
        try write("value.txt", "1\n", in: repo)
        try write("CLAUDE.md", "# Rules\n", in: repo)
        try write("Tests/ValueTests.swift", "@Test func one() {}\n@Test func two() {}\n", in: repo)
        await git("init", "-q", "-b", "master", in: repo)
        await git("add", "-A", in: repo)
        await git("commit", "-q", "-m", "Start", in: repo)
        return (repo, try #require(await git("rev-parse", "HEAD", in: repo)))
    }

    /// Writes a transcript and acts on CLAUDE.md in the clone: USE-THE-FIX makes value.txt 2,
    /// WEAKEN-TESTS also drops a test, REPEAT runs the same failing build three times, PEEK
    /// looks into the session history.
    func fakeClaude() throws {
        try write("bin/claude", #"""
            #!/bin/sh
            if [ "$1 $2" = "auth status" ]; then
              echo '{"loggedIn":true,"apiProvider":"firstParty","email":"me@example.com","orgName":"Me"}'; exit 0
            fi
            id=""; prev=""
            for a in "$@"; do [ "$prev" = "--session-id" ] && id="$a"; prev="$a"; done
            printf '%s\n' "$@" > "$HOME/args-$id.txt"
            mkdir -p "$HOME/.claude/projects/-fake"
            t="$HOME/.claude/projects/-fake/$id.jsonl"
            echo '{"type":"user","cwd":"/fake","timestamp":"2026-10-01T10:00:00Z","message":{"role":"user","content":"Make value 2"}}' > "$t"
            call() {
              echo '{"type":"assistant","timestamp":"2026-10-01T10:00:01Z","message":{"id":"m'"$2"'","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"t'"$2"'","name":"Bash","input":{"command":"'"$1"'"}}],"usage":{"input_tokens":10,"output_tokens":5}}}' >> "$t"
              echo '{"type":"user","timestamp":"2026-10-01T10:00:02Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t'"$2"'","content":"same output"}]}}' >> "$t"
            }
            if grep -q USE-THE-FIX CLAUDE.md; then echo 2 > value.txt; call "echo 2 > value.txt" 1; fi
            if grep -q WEAKEN-TESTS CLAUDE.md; then echo 2 > value.txt; echo '@Test func one() {}' > Tests/ValueTests.swift; fi
            if grep -q REPEAT CLAUDE.md; then call "swift build" 2; call "swift build" 3; call "swift build" 4; fi
            if grep -q PEEK CLAUDE.md; then call "ls ~/.claude/projects" 5; fi
            if grep -q FIX-ADD CLAUDE.md; then
              printf 'public func add(_ a: Int, _ b: Int) -> Int { a + b }\n' > Pkg/Sources/Lib/Lib.swift
              printf 'struct Extra {}\n' >> Pkg/Tests/LibTests/LibTests.swift
              call "swift build" 6
            fi
            if grep -q LOOK-UP-COMMIT CLAUDE.md; then
              sha=$(sed -n 's/.*LOOK-UP-COMMIT //p' CLAUDE.md); call "git show $sha" 7; rm Pkg/Package.swift
            fi
            echo '{"type":"assistant","timestamp":"2026-10-01T10:00:09Z","message":{"id":"m9","model":"claude-opus-5-5","content":[{"type":"text","text":"Finished."}],"usage":{"input_tokens":10,"output_tokens":5}}}' >> "$t"
            echo '{"type":"system","subtype":"init","model":"claude-opus-5-5","session_id":"'"$id"'"}'
            echo '{"type":"result","num_turns":2,"duration_ms":1000,"usage":{"input_tokens":20,"output_tokens":10},"total_cost_usd":0.05}'
            """#, executable: true)
    }

    func task(_ repo: URL, _ base: String, oracle: ControlTask.Oracle) -> ControlTask {
        ControlTask(id: "make-value-2-abcd", title: "Make value 2", repo: repo.path, base: base, prompt: "Make value 2",
                    source: .session(key: SessionKey(harness: "claude", nativeID: "exemplar-1")), oracle: oracle)
    }

    let claude = LabAgent(harness: .claudeCode, model: "opus", effort: "high")
    var baseline: ControlSetup { ControlSetup(name: "baseline", agent: claude) }
    func variant(_ text: String) -> ControlSetup { ControlSetup(name: "variant", agent: claude, patch: ControlPatch(file: "CLAUDE.md", text: text)) }

    /// Queues and runs every cell; `keep` so the clones stay in the run folders, not the Trash.
    func runAll(_ task: ControlTask, _ setups: [ControlSetup], repeats: Int = 1) async throws -> [LabRun] {
        try ControlTasks.save(task, env: env)
        let queued = try await ControlRuns.newControlRuns(tasks: [task], setups: setups, repeats: repeats, environment: .background,
                                                         keep: true, akit: URL(filePath: "/usr/bin/true"), env: env).runs
        var done: [LabRun] = []
        for run in queued {
            let output = Output()
            let code = await LabWorker.run(id: run.id, env: env, startNext: false, handleSignals: false, execute: AnalysisRuns.execute,
                                           out: output.add)
            #expect(code == 0, "\(output.lines)")
            done.append(try #require(LabStore.load(run.id, env: env)))
        }
        return done
    }

    @Test func testsOracleJudgesEachSetupInItsOwnClone() async throws {
        try fakeClaude()
        let (repo, base) = try await repository()
        let task = task(repo, base, oracle: .tests(command: #"test "$(cat value.txt)" = 2"#))
        let runs = try await runAll(task, [baseline, variant("- USE-THE-FIX")])

        let (plain, fixed) = (runs[0], runs[1])
        #expect(plain.spec.kind == .control && plain.spec.controlTask == task.id && plain.spec.title == "Control Make value 2 · baseline · 1/1")
        #expect(plain.result?.control?.passed == false && plain.result?.control?.oracle == "tests failed (exit 1)")
        #expect(fixed.result?.control?.passed == true && fixed.result?.control?.oracle == "tests passed (exit 0)")
        #expect(fixed.result?.control?.flagged == false && fixed.result?.metrics?.calls == 2)
        // The patch reached the variant's clone only; the user's repository is untouched.
        #expect(read(fixed.folder.appending(path: "work/CLAUDE.md")).contains("USE-THE-FIX"))
        #expect(!read(plain.folder.appending(path: "work/CLAUDE.md")).contains("USE-THE-FIX"))
        #expect(read(repo.appending(path: "CLAUDE.md")) == "# Rules\n" && read(repo.appending(path: "value.txt")) == "1\n")
        #expect(await git("status", "--porcelain", in: repo) == "")
        // Claude Code runs like a replay, with the replay's safety flags.
        let args = read(home.appending(path: "args-\(fixed.spec.sessionID).txt")).split(separator: "\n").map(String.init)
        #expect(args.contains("--permission-prompts") && args.contains("Bash(git push:*)") && args.contains("auto"))
        #expect(args.contains("opus") && args.contains("high") && !args.contains("--tools"))
        let sends = SendLog.records(env: env)
        #expect(sends.map(\.purpose) == ["control", "control"] && sends[0].session == "claude:exemplar-1" && sends[0].usage.cost == 0.05)
        #expect(sends[0].runID == plain.id)
    }

    @Test func guardFlagsWeakenedTestsAndLeaks() async throws {
        try fakeClaude()
        let (repo, base) = try await repository()
        let task = task(repo, base, oracle: .tests(command: #"test "$(cat value.txt)" = 2"#))
        let runs = try await runAll(task, [variant("- WEAKEN-TESTS"), variant("- USE-THE-FIX PEEK")])

        let weakened = try #require(runs[0].result?.control)
        #expect(weakened.passed && weakened.testsDropped && weakened.changedTestFiles == ["Tests/ValueTests.swift"] && weakened.flagged)
        let peeked = try #require(runs[1].result?.control)
        #expect(peeked.passed && peeked.leaks == ["the session history"] && peeked.flagged && runs[1].result?.leaked == true)
    }

    @Test func assertionOracleReadsTheCellsTranscript() async throws {
        try fakeClaude()
        let (repo, base) = try await repository()
        let task = task(repo, base, oracle: .assertion(modeID: "repeated-steps"))
        let runs = try await runAll(task, [baseline, variant("- REPEAT")])
        #expect(runs[0].result?.control?.passed == true && runs[0].result?.control?.oracle == "repeated-steps: not present")
        let repeated = try #require(runs[1].result?.control)
        #expect(!repeated.passed && repeated.oracle.hasPrefix("repeated-steps: present") && !repeated.checkSteps.isEmpty)
        // No test command: no check.log.
        #expect(!fm.fileExists(atPath: runs[0].folder.appending(path: "check.log").path))
    }

    @Test func piCellReadsItsStreamThroughTheSharedParser() async throws {
        try write("bin/pi", #"""
            #!/bin/sh
            if [ "$1 $2" = "auth check" ]; then echo '{"provider":"fake","status":"ready"}'; exit 0; fi
            printf '%s\n' "$@" > "$HOME/pi-args.txt"
            echo 'Warning: No project session found with id x, creating it'
            echo '{"type":"message_end","message":{"role":"user","content":[{"type":"text","text":"Make value 2"}]}}'
            echo 2 > value.txt
            echo '{"type":"message_end","message":{"role":"assistant","model":"m","provider":"fake","stopReason":"toolUse","content":[{"type":"toolCall","id":"c1","name":"write","arguments":{"path":"value.txt","content":"2"}}],"usage":{"input":10,"output":5,"cacheRead":0,"cacheWrite":0,"cost":{"total":0.01}}}}'
            echo '{"type":"message_end","message":{"role":"toolResult","toolCallId":"c1","toolName":"write","content":[{"type":"text","text":"ok"}],"isError":false}}'
            echo '{"type":"message_end","message":{"role":"assistant","model":"m","provider":"fake","stopReason":"stop","content":[{"type":"text","text":"Done"}],"usage":{"input":10,"output":5,"cacheRead":0,"cacheWrite":0,"cost":{"total":0.01}}}}'
            echo '{"type":"agent_settled"}'
            """#, executable: true)
        // The task comes from a Claude Code session: sending its turn to Pi needs the allowed list.
        try LabSettings(allowedDestinations: [SendDestination(harness: .pi, provider: "fake", account: "me", org: "Me")],
                        piAccounts: [PiAccount(provider: "fake", account: "me", org: "Me")]).save(env: env)
        let (repo, base) = try await repository()
        let pi = LabAgent(harness: .pi, model: "fake/m", effort: "low")
        let task = task(repo, base, oracle: .tests(command: #"test "$(cat value.txt)" = 2"#))
        let runs = try await runAll(task, [ControlSetup(name: "pi", agent: pi)])
        #expect(runs[0].result?.control?.passed == true && runs[0].result?.metrics == nil)
        let args = read(home.appending(path: "pi-args.txt")).split(separator: "\n").map(String.init)
        #expect(args.contains("--offline") && args.contains("read,write,edit,bash,grep,find,ls") && args.contains("--thinking"))
        #expect(args.contains(runs[0].spec.sessionID))
        let send = try #require(SendLog.records(env: env).first)
        #expect(send.purpose == "control" && send.provider == "fake" && send.usage.cost == 0.02)
        // The cell's stream reads like a session: the write call and its result.
        let transcript = PiSessions.transcript(ofStream: read(runs[0].folder.appending(path: "agent.jsonl")).split(separator: "\n").map(String.init))
        #expect(transcript.items.map(\.kind) == [.user, .toolCall(name: "write"), .toolResult(name: "write", isError: false), .assistant])
    }

    @Test func readOnlySetupMustFail() async throws {
        try fakeClaude()
        let (repo, base) = try await repository()
        let task = task(repo, base, oracle: .tests(command: #"test "$(cat value.txt)" = 2"#))
        // A real read-only agent couldn't write; the fake ignores the flag, so only the flags are checked.
        let runs = try await runAll(task, [ControlSetup(name: "read-only", agent: claude, readOnly: true)])
        let args = read(home.appending(path: "args-\(runs[0].spec.sessionID).txt")).split(separator: "\n").map(String.init)
        #expect(args.contains("--tools") && args.contains("Read,Grep,Glob") && runs[0].result?.control?.passed == false)
    }

    @Test func cellKeysSkipFinishedAndQueuedCells() async throws {
        try fakeClaude()
        let (repo, base) = try await repository()
        let task = task(repo, base, oracle: .tests(command: #"test "$(cat value.txt)" = 2"#))
        _ = try await runAll(task, [baseline, variant("- WEAKEN-TESTS")])

        // Both first cells are done: the weakened one is flagged and counts as a failure, so it
        // isn't run again.
        let again = try await ControlRuns.newControlRuns(tasks: [task], setups: [baseline, variant("- WEAKEN-TESTS")], repeats: 2,
                                                         environment: .background, keep: true, akit: URL(filePath: "/usr/bin/true"), env: env)
        #expect(again.skipped == 2 && again.runs.count == 2)
        #expect(again.runs.map { $0.spec.repeatIndex ?? 0 } == [2, 2])
        // Queued cells aren't queued twice.
        let twice = try await ControlRuns.newControlRuns(tasks: [task], setups: [baseline, variant("- WEAKEN-TESTS")], repeats: 2,
                                                         environment: .background, keep: true, akit: URL(filePath: "/usr/bin/true"), env: env)
        #expect(twice.skipped == 4 && twice.runs.isEmpty)

        // The key: task + setup (not its name) + base + repeat.
        var renamed = baseline
        renamed.name = "plain"
        #expect(ControlRuns.cellKey(task: task, setup: renamed, repeatIndex: 1) == ControlRuns.cellKey(task: task, setup: baseline, repeatIndex: 1))
        #expect(ControlRuns.cellKey(task: task, setup: baseline, repeatIndex: 2) != ControlRuns.cellKey(task: task, setup: baseline, repeatIndex: 1))
        var otherBase = task
        otherBase.base = String(repeating: "b", count: 40)
        #expect(ControlRuns.cellKey(task: otherBase, setup: baseline, repeatIndex: 1) != ControlRuns.cellKey(task: task, setup: baseline, repeatIndex: 1))
        #expect(ControlRuns.cellKey(task: task, setup: variant("a"), repeatIndex: 1) != ControlRuns.cellKey(task: task, setup: variant("b"), repeatIndex: 1))
    }

    /// Keys of plain, patch and read-only setups as master computed them before layer evals:
    /// a change here would queue every finished cell again.
    @Test func cellKeysOfSetupsWithoutALayerAreUnchanged() {
        let task = ControlTask(id: "make-value-2-abcd", title: "Make value 2", repo: "/work/repo", base: String(repeating: "a", count: 40),
                               prompt: "Make value 2", source: .reproduction, oracle: .tests(command: "swift test"),
                               createdAt: Date(timeIntervalSince1970: 0))
        #expect(ControlRuns.cellKey(task: task, setup: baseline, repeatIndex: 1) == "8f09f13e3d60d9a30ddf0a0a1e9b3510dd5a656a9db2fb05acb2835d8e30d295.8a5eca1b2c4a83e9dc0a89a2b12344d078d1858e1542f432ff15fcc0aff78b37")
        #expect(ControlRuns.cellKey(task: task, setup: variant("- Run the tests"), repeatIndex: 2) == "8f09f13e3d60d9a30ddf0a0a1e9b3510dd5a656a9db2fb05acb2835d8e30d295.d7158f3c5892cf974091d701032b3ea8d68b8e9627e303dc6713bbc661bb71c1")
        #expect(ControlRuns.cellKey(task: task, setup: ControlSetup(name: "read-only", agent: claude, readOnly: true), repeatIndex: 3)
                == "8f09f13e3d60d9a30ddf0a0a1e9b3510dd5a656a9db2fb05acb2835d8e30d295.05113429b2225c6b601458dfbccde35a6ac4d99f238caf30a59d879203ecbcfb")
    }

    @Test func layerCellKeysDifferByRoleOverlayAndEvalNotBrainCommit() {
        let task = task(URL(filePath: "/work/repo"), "abc", oracle: .tests(command: "true"))
        let layer = LayerVariant(layer: "swiftui", role: .layer, overlayHash: "h1", evalID: "swiftui-20261012-0930-ab12", brainCommit: "c1")
        func key(_ change: (inout LayerVariant) -> Void) -> String {
            var variant = layer
            change(&variant)
            return ControlRuns.cellKey(task: task, setup: ControlSetup(name: "layer swiftui", agent: claude, layer: variant), repeatIndex: 1)
        }
        let original = key { _ in }
        #expect(original != ControlRuns.cellKey(task: task, setup: baseline, repeatIndex: 1))
        #expect(key { $0.role = .requiredOnly } != original)
        #expect(key { $0.overlayHash = "h2" } != original && key { $0.overlayHash = nil } != original)
        #expect(key { $0.evalID = "swiftui-20261013-0930-cd34" } != original)
        #expect(key { $0.layer = "other" } != original)
        #expect(key { $0.brainCommit = "c2" } == original)
    }

    /// The whole slice with a fake `claude`: a layer eval prepared from a temporary brain, its
    /// folder written, cells queued (sanity after the first repeat) and run. The fake passes
    /// only when the clone's CLAUDE.md carries the layer's marker.
    @Test func layerEvalEndToEnd() async throws {
        let fixture = LayerFixture(home: home)
        try fixture.fakeClaude()
        // The fake, not a real Claude Code, is what runs.
        #expect(env.findExecutable("claude")?.path == home.appending(path: "bin/claude").path)
        try await fixture.makeBrain()
        let base = try await fixture.makeRepo()
        let brainHead = await fixture.git("rev-parse", "HEAD", in: fixture.brain)
        let task = ControlTask(id: "make-value-2-abcd", title: "Make value 2", repo: fixture.repo.path, base: base, prompt: "Make value 2",
                               source: .reproduction, oracle: .tests(command: #"test "$(cat value.txt)" = 2"#))
        try ControlTasks.save(task, env: env)
        let prepared = try await LayerSetups.prepare(layer: "swiftui", tasks: [task], answers: [:], agent: claude, sanity: true,
                                                     homeSkills: [], brain: fixture.brain, store: .local(home: home),
                                                     projectsRoot: home, env: env)
        try LayerEvalStore.create(prepared, repeats: 2, env: env)
        let sanity = try #require(prepared.sanitySetup)
        let queued = try await ControlRuns.newControlRuns(tasks: prepared.runnable, setups: prepared.setups, repeats: 2,
                                                         sanity: (sanity, prepared.sanityTasks, 1), environment: .background,
                                                         keep: true, akit: URL(filePath: "/usr/bin/true"), env: env).runs
        // Sanity cells right after the first repeat, so a broken oracle shows early.
        #expect(queued.map { $0.spec.controlSetup?.label ?? "" } == [
            "without swiftui@\(prepared.brainCommit.prefix(7)) · Claude Code · opus · high",
            "layer swiftui@\(prepared.brainCommit.prefix(7)) · Claude Code · opus · high",
            "read-only · without swiftui@\(prepared.brainCommit.prefix(7)) · Claude Code · opus · high",
            "without swiftui@\(prepared.brainCommit.prefix(7)) · Claude Code · opus · high",
            "layer swiftui@\(prepared.brainCommit.prefix(7)) · Claude Code · opus · high",
        ])
        var done: [LabRun] = []
        for run in queued {
            let output = Output()
            let code = await LabWorker.run(id: run.id, env: env, startNext: false, handleSignals: false, execute: AnalysisRuns.execute,
                                           out: output.add)
            #expect(code == 0, "\(output.lines)")
            done.append(try #require(LabStore.load(run.id, env: env)))
        }
        #expect(FileManager.default.fileExists(atPath: home.appending(path: "fake-claude-ran").path))

        let (without, layered) = (done[0], done[1])
        #expect(without.result?.control?.passed == false && layered.result?.control?.passed == true)
        #expect(done[2].result?.control?.passed == false)
        // The layer's section went into the clone's own CLAUDE.md; the baseline got base's only.
        #expect(read(layered.folder.appending(path: "work/CLAUDE.md")).contains("LAYER-MARKER: check with make snapshot"))
        #expect(read(without.folder.appending(path: "work/CLAUDE.md")) == "# Rules\n\n- BASE-RULE\n")
        #expect(read(layered.folder.appending(path: "work/.claude/skills/swiftui-expert/SKILL.md")).contains("Use repo."))
        // Every layer cell records its overlay notes and Claude Code version.
        for run in done {
            #expect(run.result?.control?.overlay?.first?.contains("project's own CLAUDE.md") == true)
            #expect(run.result?.control?.harnessVersion == "2.1.290")
        }
        // The agent saw a clean checkout; the user's repository and the brain are untouched.
        for run in done { #expect(read(home.appending(path: "status-\(run.spec.sessionID).txt")) == "") }
        #expect(read(fixture.repo.appending(path: "CLAUDE.md")) == "# Rules\n" && read(fixture.repo.appending(path: "value.txt")) == "1\n")
        #expect(await git("status", "--porcelain", in: fixture.repo) == "")
        #expect(await fixture.git("rev-parse", "HEAD", in: fixture.brain) == brainHead)
        #expect(await fixture.git("status", "--porcelain", in: fixture.brain) == "")

        // One pair: the layer against its eval's required layers; the read-only row stays apart.
        let comparison = ControlComparison.compare(ControlComparison.Cell.of(done))
        #expect(comparison.rows.count == 3 && comparison.paired.count == 1)
        #expect(comparison.paired[0].variant == prepared.setups[1] && comparison.paired[0].baseline == prepared.setups[0])
        #expect(comparison.paired[0].verdict == .noConclusion && comparison.paired[0].harnessVersions == ["2.1.290"])

        // Queuing the same eval again skips every cell.
        let again = try await ControlRuns.newControlRuns(tasks: prepared.runnable, setups: prepared.setups, repeats: 2,
                                                        sanity: (sanity, prepared.sanityTasks, 1), environment: .background,
                                                        keep: true, akit: URL(filePath: "/usr/bin/true"), env: env)
        #expect(again.runs.isEmpty && again.skipped == 5)
    }

    @Test func layerCellRunByAnOlderAkitIsNotDone() async throws {
        let (repo, base) = try await repository()
        let task = task(repo, base, oracle: .tests(command: "true"))
        let layer = ControlSetup(name: "layer swiftui", agent: claude,
                                 layer: LayerVariant(layer: "swiftui", role: .layer, overlayHash: "h", evalID: "e", brainCommit: "c"))
        let first = try #require(try await ControlRuns.newControlRuns(tasks: [task], setups: [layer, baseline], repeats: 1,
                                                                     environment: .background, keep: false,
                                                                     akit: URL(filePath: "/usr/bin/true"), env: env).runs)
        // Both finished; the layer cell without overlay notes, as an akit that ignored the layer leaves it.
        for run in first {
            try LabStore.save(RunState(status: .finished), of: run.id, env: env)
            let key = ControlRuns.cellKey(task: task, setup: try #require(run.spec.controlSetup), repeatIndex: 1)
            try LabStore.save(RunResult(control: ControlOutcome(key: key, passed: true, oracle: "x")), of: run.id, env: env)
        }
        let again = try await ControlRuns.newControlRuns(tasks: [task], setups: [layer, baseline], repeats: 1, environment: .background,
                                                        keep: false, akit: URL(filePath: "/usr/bin/true"), env: env)
        #expect(again.skipped == 1 && again.runs.map { $0.spec.controlSetup } == [layer])

        // One setup makes one difference: a patch and a layer together are refused.
        var both = layer
        both.patch = ControlPatch(file: "CLAUDE.md", text: "x")
        await #expect(throws: (any Error).self) {
            _ = try await ControlRuns.newControlRuns(tasks: [task], setups: [both], repeats: 1, environment: .background, keep: false,
                                                     akit: URL(filePath: "/usr/bin/true"), env: env)
        }
    }

    /// A Swift package whose second commit fixes `add` and adds a test for it.
    func packageRepository() async throws -> (repo: URL, fix: String) {
        let repo = home.appending(path: "pkg-repo")
        try write("CLAUDE.md", "# Rules\n", in: repo)
        try write("Pkg/Package.swift", """
            // swift-tools-version: 6.0
            import PackageDescription
            let package = Package(name: "Pkg", targets: [.target(name: "Lib"), .testTarget(name: "LibTests", dependencies: ["Lib"])])

            """, in: repo)
        try write("Pkg/Sources/Lib/Lib.swift", "public func add(_ a: Int, _ b: Int) -> Int { a - b }\n", in: repo)
        try write("Pkg/Tests/LibTests/LibTests.swift", "import Testing\n@testable import Lib\nstruct LibTests {\n    @Test func zero() { #expect(add(0, 0) == 0) }\n}\n",
                  in: repo)
        await git("init", "-q", "-b", "master", in: repo)
        await git("add", "-A", in: repo)
        await git("commit", "-q", "-m", "Start", in: repo)
        try write("Pkg/Sources/Lib/Lib.swift", "public func add(_ a: Int, _ b: Int) -> Int { a + b }\n", in: repo)
        try write("Pkg/Tests/LibTests/LibTests.swift", """
            import Testing
            @testable import Lib
            struct LibTests {
                @Test func zero() { #expect(add(0, 0) == 0) }
                @Test func adds() { #expect(add(2, 2) == 4) }
            }

            """, in: repo)
        await git("commit", "-q", "-am", "Fix add\n\nIt subtracted.", in: repo)
        return (repo, try #require(await git("rev-parse", "HEAD", in: repo)))
    }

    /// A task from a commit, judged by the commit's own tests after the agent (real builds of a
    /// tiny package, a few seconds each; the agent is the fake).
    @Test func commitTaskIsJudgedByItsHiddenTests() async throws {
        try fakeClaude()
        #expect(env.findExecutable("claude")?.path == home.appending(path: "bin/claude").path)
        let (repo, fix) = try await packageRepository()
        let task = try await ControlTasks.fromCommit(String(fix.prefix(7)), repo: repo, env: env)
        #expect(task.source == .commit(sha: fix) && task.oracle == .hiddenTests(commit: fix) && task.oracle.label == "hidden tests of \(fix.prefix(7))")
        #expect(task.reference == fix && task.referenceGreen == true && task.title == "Fix add" && task.prompt.hasPrefix("Fix add\n\nIt subtracted."))
        #expect(task.base == (await git("rev-parse", "HEAD~1", in: repo)))
        #expect(ReplayTasks.cached(fix, env: env)?.failToPass.map(\.id) == ["LibTests/adds"])

        let runs = try await runAll(task, [baseline, variant("- FIX-ADD"), variant("- LOOK-UP-COMMIT \(fix.prefix(7))")])
        let plain = try #require(runs[0].result?.control)
        #expect(!plain.passed && plain.oracle == "hidden tests: 0/1 fail-to-pass, 1/1 pass-to-pass" && !plain.flagged)
        #expect(runs[0].result?.tests?.failed == ["LibTests/adds"])
        // The fix passes; adding to a test file the hidden tests replace isn't weakening them.
        let fixed = try #require(runs[1].result?.control)
        #expect(fixed.passed && fixed.oracle == "hidden tests: 1/1 fail-to-pass, 1/1 pass-to-pass" && !fixed.flagged, "\(fixed)")
        #expect(runs[1].result?.tests?.status == .passed)
        #expect(read(runs[1].folder.appending(path: "work/Pkg/Tests/LibTests/LibTests.swift")).contains("adds"))
        // Looking up the commit is a leak: the cell is flagged.
        let peeked = try #require(runs[2].result?.control)
        #expect(!peeked.passed && peeked.leaks == ["the commit \(fix.prefix(7))"] && peeked.flagged)
        #expect(peeked.oracle.contains("don't build"))
        // The user's repository is untouched.
        #expect(await git("status", "--porcelain", in: repo) == "")
        #expect(await git("rev-parse", "HEAD", in: repo) == fix)

        // The same commit again gives the same task.
        try ControlTasks.save(task, env: env)
        #expect(try await ControlTasks.fromCommit(fix, repo: repo, env: env).id == task.id)
    }

    @Test func labAloneCantRunACell() async throws {
        let (repo, base) = try await repository()
        let task = task(repo, base, oracle: .tests(command: "true"))
        try ControlTasks.save(task, env: env)
        let run = try #require(try await ControlRuns.newControlRuns(tasks: [task], setups: [baseline], repeats: 1, environment: .background,
                                                                   keep: true, akit: URL(filePath: "/usr/bin/true"), env: env).runs.first)
        let code = await LabWorker.run(id: run.id, env: env, startNext: false, handleSignals: false, out: { _ in })
        let done = try #require(LabStore.load(run.id, env: env))
        #expect(code == 1 && done.status == .error && done.message?.contains("can't do a control run") == true)
    }

    @Test func leaksNameTheExemplarAndTheRepository() {
        let task = task(URL(filePath: "/work/repo"), "abc", oracle: .tests(command: "true"))
        func transcript(_ calls: [(String, String)]) -> SessionTranscript {
            SessionTranscript(items: calls.enumerated().map { TranscriptItem(id: $0.offset, kind: .toolCall(name: $0.element.0), text: $0.element.1, timestamp: nil) })
        }
        #expect(ControlRuns.leaks(in: transcript([("Bash", #"{"command":"swift test"}"#)]), task: task).isEmpty)
        #expect(ControlRuns.leaks(in: transcript([("Bash", #"{"command":"grep -r exemplar-1 ~"}"#)]), task: task) == ["the exemplar session claude:exemplar-1"])
        #expect(ControlRuns.leaks(in: transcript([("read", #"{"path":"/Users/me/.pi/agent/sessions/x.jsonl"}"#)]), task: task) == ["the session history"])
        #expect(ControlRuns.leaks(in: transcript([("Bash", #"{"command":"git -C /work/repo log"}"#)]), task: task) == ["the real repository"])
    }

    @Test func aRedReferenceBlocksQueuingCells() async throws {
        let (repo, base) = try await repository()
        var red = task(repo, base, oracle: .tests(command: "false"))
        red.referenceGreen = false
        try ControlTasks.save(red, env: env)
        await #expect(throws: (any Error).self) {
            _ = try await ControlRuns.newControlRuns(tasks: [red], setups: [ControlSetup(name: "baseline", agent: LabAgent(harness: .claudeCode, model: "opus", effort: "low"))],
                                                     repeats: 1, environment: .background, keep: true, akit: URL(filePath: "/usr/bin/true"), env: env)
        }
        #expect(LabStore.list(env: env).isEmpty)
    }
}

/// Worker output, collected from background threads.
final class Output: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [String] = []
    func add(_ line: String) { lock.withLock { collected.append(line) } }
    var lines: [String] { lock.withLock { collected } }

}
