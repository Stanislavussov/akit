import Foundation
import Testing
import AKitFoundation
@testable import AKitLab

/// Runs, the queue and the worker, with a fake `claude` in a temporary home. Serialized:
/// cancelling is process-wide in the worker.
@Suite(.serialized)
struct LabRunTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-labrun-\(UUID().uuidString)")
        try fm.createDirectory(at: home.appending(path: "bin"), withIntermediateDirectories: true)
        Cancellation.reset()
    }

    var env: HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home, variables: ["HOME": home.path],
                           executableSearchPaths: [home.appending(path: "bin"), URL(filePath: "/usr/bin"), URL(filePath: "/bin")])
    }

    func write(_ path: String, _ text: String, executable: Bool = false) throws {
        let url = home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if executable { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
    }

    func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    /// Stream-json on stdout, a transcript under ~/.claude/projects, a review in its folder.
    /// FAKE_SLEEP in the run's folder name makes it wait (for cancelling).
    func fakeClaude() throws {
        try write("bin/claude", #"""
            #!/bin/sh
            printf '%s\n' "$@" > "$AKIT_LAB_DIR/args.txt"
            id=""; prev=""
            for a in "$@"; do [ "$prev" = "--session-id" ] && id="$a"; prev="$a"; done
            mkdir -p "$HOME/.claude/projects/-fake"
            t="$HOME/.claude/projects/-fake/$id.jsonl"
            echo '{"type":"user","cwd":"/fake","timestamp":"2026-09-30T10:00:00Z","message":{"role":"user","content":"Review"}}' > "$t"
            echo '{"type":"assistant","timestamp":"2026-09-30T10:00:05Z","message":{"id":"m1","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"transcript.md"}}],"usage":{"input_tokens":10,"cache_creation_input_tokens":90,"cache_read_input_tokens":900,"output_tokens":20}}}' >> "$t"
            echo '{"type":"system","subtype":"init","model":"claude-opus-5-5","session_id":"'"$id"'"}'
            echo '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"transcript.md"}}]}}'
            if [ -f "$AKIT_LAB_DIR/sleep" ]; then sleep 30; fi
            echo '{"findings":[{"title":"Re-read the same file","detail":"Line 40"}]}' > review.json
            echo 'Short summary' > summary.md
            echo '{"type":"assistant","message":{"content":[{"type":"text","text":"Wrote the review."}]}}'
            echo '{"type":"result","num_turns":2,"duration_ms":5000}'
            """#, executable: true)
    }

    /// A recorded session to review.
    func reviewedSession() throws -> URL {
        try write(".claude/projects/-work-app/abc.jsonl", """
            {"type":"user","cwd":"\(home.path)","timestamp":"2026-09-29T10:00:00Z","message":{"role":"user","content":"Fix it"}}
            {"type":"assistant","timestamp":"2026-09-29T10:00:03Z","message":{"id":"r1","model":"claude-opus-5-5","content":[{"type":"text","text":"Done"}],"usage":{"input_tokens":5,"cache_creation_input_tokens":5,"cache_read_input_tokens":100,"output_tokens":3}}}

            """)
        return home.appending(path: ".claude/projects/-work-app/abc.jsonl")
    }

    @Test func reviewRunEndToEnd() async throws {
        try fakeClaude()
        let session = try reviewedSession()
        let run = try await LabRuns.newReview(transcript: session, title: "Fix it", environment: .background,
                                              akit: URL(filePath: "/usr/bin/true"), env: env)
        #expect(run.status == .queued && run.spec.folder == home.path && run.spec.title == "Review: Fix it")

        let output = Output()
        let code = await LabWorker.run(id: run.id, env: env, startNext: false, handleSignals: false, out: output.add)
        let done = try #require(LabStore.load(run.id, env: env))
        #expect(code == 0, "\(output.lines)")
        #expect(done.status == .finished && done.state?.pid == getpid())
        #expect(done.result?.review == .ok)
        #expect(done.result?.metrics?.calls == 1 && done.result?.metrics?.freshTokens == 120)
        #expect(done.review?.findings.first?.title == "Re-read the same file")
        #expect(done.summary == "Short summary\n")
        #expect(read(run.folder.appending(path: "transcript.md")).contains("Fix it"))
        #expect(LabStore.read(SessionMetrics.self, from: run.folder.appending(path: "analysis.json"))?.calls == 1)
        #expect(read(run.folder.appending(path: "agent.jsonl")).contains("\"type\":\"result\""))
        let args = read(run.folder.appending(path: "args.txt")).split(separator: "\n").map(String.init)
        #expect(args.contains("--permission-prompts") && args.contains("none") && args.contains(run.spec.sessionID))
        #expect(args.contains("Bash(git push:*)"))
        #expect(output.lines.contains("▸ Read transcript.md"))
        #expect(output.lines.contains("Agent finished · 2 turns · 5 sec"))
        #expect(output.lines.contains("Review: ok"))

        // A finished run can't start again.
        #expect(await LabWorker.run(id: run.id, env: env, startNext: false, handleSignals: false, out: { _ in }) == 2)
    }

    @Test func missingReviewIsReportedNotHidden() async throws {
        try write("bin/claude", "#!/bin/sh\necho '{\"type\":\"result\",\"num_turns\":1}'\n", executable: true)
        let run = try await LabRuns.newReview(transcript: try reviewedSession(), title: nil, environment: .background,
                                              akit: URL(filePath: "/usr/bin/true"), env: env)
        let code = await LabWorker.run(id: run.id, env: env, startNext: false, handleSignals: false, out: { _ in })
        let done = try #require(LabStore.load(run.id, env: env))
        #expect(code == 0 && done.status == .finished)
        #expect(done.result?.review == .missing && done.result?.metrics == nil)
    }

    @Test func cancellingStopsTheAgent() async throws {
        try fakeClaude()
        let run = try await LabRuns.newReview(transcript: try reviewedSession(), title: nil, environment: .background,
                                              akit: URL(filePath: "/usr/bin/true"), env: env)
        try write(".akit/lab/\(run.id)/sleep", "")
        let env = env
        let worker = Task { await LabWorker.run(id: run.id, env: env, startNext: false, handleSignals: false, out: { _ in }) }
        // Wait for the agent phase, then cancel as SIGTERM would.
        for _ in 0..<100 where LabStore.load(run.id, env: env)?.state?.phase != .agent {
            try await Task.sleep(for: .milliseconds(100))
        }
        try await Task.sleep(for: .milliseconds(300))
        let started = Date.now
        Cancellation.cancel()
        let code = await worker.value
        Cancellation.reset()
        #expect(code == 1)
        #expect(Date.now.timeIntervalSince(started) < 10)
        let done = try #require(LabStore.load(run.id, env: env))
        #expect(done.status == .cancelled && done.result == nil)
    }

    @Test func queueStartsOneRunAtATime() async throws {
        // The "akit" the tab would run: records its arguments and exits.
        try write("bin/fake-akit", "#!/bin/sh\necho \"$@\" >> \"$HOME/launched.txt\"\n", executable: true)
        let akit = home.appending(path: "bin/fake-akit")
        let first = try await LabRuns.newReview(transcript: try reviewedSession(), title: "one", environment: .background, akit: akit, env: env)
        try await Task.sleep(for: .milliseconds(1100)) // ids and creation times sort by second
        let second = try await LabRuns.newReview(transcript: try reviewedSession(), title: "two", environment: .background, akit: akit, env: env)

        let started = try await LabQueue.startNext(env: env)
        #expect(started?.id == first.id && started?.launch?.pid != nil)
        // Launched but not yet running: the queue waits for it.
        #expect(try await LabQueue.startNext(env: env) == nil)
        for _ in 0..<50 where read(home.appending(path: "launched.txt")).isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        #expect(read(home.appending(path: "launched.txt")) == "lab run \(first.id)\n")

        // A worker that died without a word shows as an error and frees the queue.
        try LabStore.save(RunState(status: .running, phase: .agent, pid: 999_999), of: first.id, env: env)
        #expect(LabStore.load(first.id, env: env)?.status == .error)
        #expect(LabStore.load(first.id, env: env)?.message?.contains("tab was closed") == true)
        #expect(try await LabQueue.startNext(env: env)?.id == second.id)
        #expect(LabStore.list(env: env).map(\.id) == [second.id, first.id])
    }

    @Test func orcaAppFromItsCommand() throws {
        // Like /usr/local/bin/orca → /Applications/Orca.app/Contents/Resources/bin/orca.
        try write("Apps/Orca.app/Contents/Resources/bin/orca", "#!/bin/sh\n", executable: true)
        try fm.createSymbolicLink(at: home.appending(path: "bin/orca"), withDestinationURL: home.appending(path: "Apps/Orca.app/Contents/Resources/bin/orca"))
        let app = Launcher.app(for: .orca, env: env)
        #expect(app?.resolvingSymlinksInPath().path == home.appending(path: "Apps/Orca.app").resolvingSymlinksInPath().path)
        #expect(Launcher.app(for: .herdr, env: env) == nil && Launcher.app(for: .background, env: env) == nil)
    }

    @Test func reusedPidIsNotTheWorker() {
        let me = getpid()
        let start = LabStore.processStart(me)
        #expect(start != nil)
        #expect(LabStore.isAlive(RunState(status: .running, pid: me, pidStart: start)))
        // Same pid, another start time: another process now has the worker's pid.
        #expect(!LabStore.isAlive(RunState(status: .running, pid: me, pidStart: (start ?? 0) - 100)))
        #expect(!LabStore.isAlive(RunState(status: .running, pid: 1)))
    }

    @Test func reviewShowsAtMostThreeImprovements() async throws {
        let run = try await LabRuns.newReview(transcript: try reviewedSession(), title: nil, environment: .background,
                                              akit: URL(filePath: "/usr/bin/true"), env: env)
        let findings = (1...5).map { #"{"title":"Change \#($0)","detail":"Why"}"# }.joined(separator: ",")
        try Data(#"{"findings":[\#(findings)]}"#.utf8).write(to: run.folder.appending(path: "review.json"))
        let loaded = try #require(LabStore.load(run.id, env: env))
        #expect(loaded.review?.findings.map(\.title) == ["Change 1", "Change 2", "Change 3"])
    }

    @Test func reviewInPi() async throws {
        try write("bin/pi", #"""
            #!/bin/sh
            printf '%s\n' "$@" > "$AKIT_LAB_DIR/args.txt"
            echo 'Warning: No project session found with id x; creating a new session with that id.' >&2
            echo '{"type":"session","version":3,"id":"s1","cwd":"/x"}'
            echo '{"type":"message_end","message":{"role":"assistant","content":[{"type":"toolCall","id":"c1","name":"read","arguments":{"path":"transcript.md"}}],"stopReason":"toolUse"}}'
            echo '{"type":"message_end","message":{"role":"toolResult","toolName":"read","content":[{"type":"text","text":"no such file"}],"isError":true}}'
            echo '{"findings":[]}' > review.json
            echo 'One paragraph.' > summary.md
            echo '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"Done."}],"stopReason":"stop"}}'
            echo '{"type":"agent_settled"}'
            """#, executable: true)
        let agent = LabAgent(harness: .pi, model: "zai/glm-5", effort: "low")
        let run = try await LabRuns.newReview(transcript: try reviewedSession(), title: nil, agent: agent, environment: .background,
                                              akit: URL(filePath: "/usr/bin/true"), env: env)
        let output = Output()
        let code = await LabWorker.run(id: run.id, env: env, startNext: false, handleSignals: false, out: output.add)
        let done = try #require(LabStore.load(run.id, env: env))
        #expect(code == 0 && done.status == .finished && done.result?.review == .ok, "\(output.lines)")
        #expect(done.spec.agent == agent && done.review?.findings.isEmpty == true && done.summary == "One paragraph.\n")
        #expect(done.result?.agentError == nil)
        let args = read(run.folder.appending(path: "args.txt")).split(separator: "\n").map(String.init)
        #expect(args.starts(with: ["-p"]) && args.contains(run.spec.sessionID) && !args.contains("--permission-prompts"))
        #expect(args.suffix(6) == ["--model", "zai/glm-5", "--thinking", "low", "--tools", "read,write,grep,find,ls"])
        #expect(output.lines.contains("▸ read transcript.md") && output.lines.contains("  ✗ no such file"))
        #expect(output.lines.contains("Agent finished") && !output.lines.contains { $0.hasPrefix("Warning:") })
    }

    @Test func piDefaultsAndModels() throws {
        #expect(LabRuns.defaultAgent(.pi, env: env) == LabAgent(harness: .pi, model: "", effort: "medium"))
        #expect(!LabAgent(harness: .pi, model: "", effort: "medium").flags.contains("--model"))
        try write(".pi/agent/settings.json", #"{"defaultProvider":"zai","defaultModel":"glm-5","defaultThinkingLevel":"high"}"#)
        #expect(LabRuns.defaultAgent(.pi, env: env) == LabAgent(harness: .pi, model: "zai/glm-5", effort: "high"))
        #expect(LabRuns.piModels(["provider  model  context", "zai       glm-5  200K", "", "provider  model  context",
                                  "zai       glm-5  200K", "zai       glm-6  1M"]) == ["zai/glm-5", "zai/glm-6"])
    }

    @Test func piErrorsAreShown() {
        var failed = false
        let error: [String: Any] = ["type": "message_end", "message": ["role": "assistant", "content": [Any](),
                                                                      "stopReason": "error", "errorMessage": "403: no subscription"]]
        #expect(StreamPrinter.readablePi(error, failed: &failed) == ["  ✗ 403: no subscription"] && failed)
        #expect(StreamPrinter.readablePi(["type": "agent_settled"], failed: &failed) == ["Agent stopped with an error"])
        let printer = StreamPrinter(harness: .pi, out: { _ in })
        printer.print(#"{"type":"message_end","message":{"role":"assistant","content":[],"stopReason":"error","errorMessage":"403: no subscription"}}"#)
        #expect(printer.error == "403: no subscription")
        printer.print(#"{"type":"message_end","message":{"role":"assistant","content":[],"stopReason":"stop"}}"#)
        #expect(printer.error == nil)
    }

    @Test func cancelAndRemoveQueuedRun() async throws {
        let run = try await LabRuns.newReview(transcript: try reviewedSession(), title: nil, environment: .background,
                                              akit: URL(filePath: "/usr/bin/true"), env: env)
        try await LabStore.cancel(run, env: env)
        let cancelled = try #require(LabStore.load(run.id, env: env))
        #expect(cancelled.status == .cancelled)
        await #expect(throws: LabStore.Failure.self) { try await LabStore.cancel(cancelled, env: env) }
        var trashed: URL?
        try LabStore.remove(cancelled) { trashed = $0; return nil }
        #expect(trashed == run.folder)
    }

    @Test func setupsPinModelAndEffort() {
        let lean = LabSetup(name: .lean, model: "sonnet", effort: "max")
        let spec = RunSpec(id: "x", kind: .replay, title: "t", folder: "/", environment: .background, akit: "/a", setup: lean)
        let args = AgentRun.arguments(prompt: "Do it", spec: spec)
        #expect(args.starts(with: ["-p", "Do it"]))
        #expect(args.suffix(6) == ["--setting-sources", "project", "--model", "sonnet", "--effort", "max"])
        let full = AgentRun.arguments(prompt: "Do it", spec: RunSpec(id: "x", kind: .replay, title: "t", folder: "/", environment: .background,
                                                                     akit: "/a", setup: LabSetup(name: .full, model: "opus", effort: "high")))
        #expect(!full.contains("--setting-sources") && full.suffix(4) == ["--model", "opus", "--effort", "high"])
        let env = AgentRun.environment(HarnessEnvironment(homeDirectory: home, variables: ["CLAUDECODE": "1", "KEEP": "x"]), runFolder: home)
        #expect(env["CLAUDECODE"] == nil && env["KEEP"] == "x" && env["AKIT_LAB_DIR"] == home.path)
    }

    @Test func streamPrinterLines() {
        #expect(StreamPrinter.readable(["type": "user", "message": ["content": [
            ["type": "tool_result", "is_error": true, "content": "boom\nmore"]]]]) == ["  ✗ boom"])
        #expect(StreamPrinter.readable(["type": "assistant", "message": ["content": [
            ["type": "tool_use", "name": "Bash", "input": ["command": "swift test\n--x"]]]]]) == ["▸ Bash swift test"])
        #expect(Launcher.command(for: RunSpec(id: "x", kind: .review, title: "t", folder: "/", environment: .orca,
                                              akit: "/Users/me/My Tools/akit")) == "'/Users/me/My Tools/akit' lab run x")
    }
}

final class Output: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var lines: [String] { lock.withLock { stored } }
    var add: @Sendable (String) -> Void { { line in self.lock.withLock { self.stored.append(line) } } }
}
