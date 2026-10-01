import Foundation
import Testing
import AKitFoundation
import AKitLab
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
        try LabSettings(piAccounts: [PiAccount(provider: "fake", account: "me", org: "Me")]).save(env: env)
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

        // The baseline's cell is done; the weakened one is flagged, so it runs again.
        let again = try await ControlRuns.newControlRuns(tasks: [task], setups: [baseline, variant("- WEAKEN-TESTS")], repeats: 2,
                                                         environment: .background, keep: true, akit: URL(filePath: "/usr/bin/true"), env: env)
        #expect(again.skipped == 1 && again.runs.count == 3)
        #expect(again.runs.map { $0.spec.repeatIndex ?? 0 } == [1, 2, 2])
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
}

/// Worker output, collected from background threads.
final class Output: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [String] = []
    func add(_ line: String) { lock.withLock { collected.append(line) } }
    var lines: [String] { lock.withLock { collected } }
}
