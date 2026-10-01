import AKitFoundation
import AKitModel
import AKitSessions
import Foundation

/// `akit lab run <id>`: does one run in the terminal that hosts it. Writes `state.json` at
/// every phase, `result.json` at the end, then starts the next queued run.
public enum LabWorker {
    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
        public init(message: String) { self.message = message }
    }

    /// Does a run whose work lives in a module above Lab (error analysis: the one-call review
    /// and batch runs). Returns nil for a run it doesn't do.
    public typealias Execute = @Sendable (_ run: LabRun, _ env: HarnessEnvironment, _ phase: @escaping @Sendable (RunState.Phase) -> Void,
                                          _ out: @escaping @Sendable (String) -> Void) async throws -> RunResult?

    /// Returns the exit code. `startNext` and `handleSignals` are off in tests. `execute` does
    /// the runs Lab itself can't (`akit lab run` passes error analysis's).
    public static func run(id: String, env: HarnessEnvironment, startNext: Bool = true, handleSignals: Bool = true,
                           execute: Execute? = nil, out: @escaping @Sendable (String) -> Void) async -> Int32 {
        // Signals first: from here on a closed tab or Ctrl-C stops the run cleanly.
        if handleSignals { Cancellation.installSignalHandlers() }
        let started = Date.now
        let pidStart = LabStore.processStart(getpid())
        @Sendable func state(_ status: RunState.Status, _ phase: RunState.Phase? = nil, message: String? = nil) {
            try? LabStore.save(RunState(status: status, phase: phase, pid: getpid(), pidStart: pidStart, startedAt: started,
                                        message: message), of: id, env: env)
        }
        // Take the run under the queue lock, so a cancel of the queued run can't cross it.
        let taken: Result<LabRun, LabStore.Failure>
        do {
            taken = try await LabQueue.locked(env: env) {
                guard let run = LabStore.load(id, env: env) else {
                    return .failure(LabStore.Failure(message: "no Lab run \(id) in \(LabPaths(env: env).folder.path)."))
                }
                guard run.status == .queued else {
                    return .failure(LabStore.Failure(message: "run \(id) is \(run.status.rawValue); only a queued run can start."))
                }
                state(.running, .prepare)
                return .success(run)
            }
        } catch {
            taken = .failure(LabStore.Failure(message: error.localizedDescription))
        }
        let run: LabRun
        switch taken {
        case .success(let value): run = value
        case .failure(let failure):
            out("akit: \(failure.message)")
            if startNext { _ = try? await LabQueue.startNext(env: env) }
            return 2
        }
        out("Lab run \(id): \(run.spec.title)")

        let code: Int32
        do {
            let result: RunResult
            if let execute, let done = try await execute(run, env, { state(.running, $0) }, out) {
                result = done
            } else {
                switch run.spec.kind {
                case .review where (run.spec.agent?.mode ?? .agent) == .agent:
                    result = try await ReviewRun.execute(run, env: env, phase: { state(.running, $0) }, out: out)
                case .replay:
                    result = try await ReplayRun.execute(run, env: env, phase: { state(.running, $0) }, out: out)
                default:
                    throw Failure(message: "This akit can't do a \(run.spec.kind.rawValue) run; run it with the akit command.")
                }
            }
            if Cancellation.isCancelled { throw CancellationError() }
            try LabStore.save(result, of: id, env: env)
            state(.finished)
            out("")
            if let metrics = result.metrics { MetricsText.lines(metrics).forEach(out) }
            for line in resultLines(result) { out(line) }
            out("Finished. Details in AKit (Lab) or \(run.folder.path).")
            code = 0
        } catch is CancellationError {
            state(.cancelled, message: "Cancelled.")
            out("Cancelled.")
            code = 1
        } catch {
            if Cancellation.isCancelled {
                state(.cancelled, message: "Cancelled.")
                out("Cancelled.")
            } else {
                state(.error, message: error.localizedDescription)
                out("akit: \(error.localizedDescription)")
            }
            code = 1
        }
        if startNext {
            do {
                if let next = try await LabQueue.startNext(env: env) {
                    out("Started the next queued run: \(next.spec.title) (\(next.spec.environment.title)).")
                }
            } catch {
                out("akit: the next queued run didn't start: \(error.localizedDescription)")
            }
        }
        return code
    }

    public static func resultLines(_ result: RunResult) -> [String] {
        var lines: [String] = []
        if let tests = result.tests {
            lines.append("Hidden tests: \(tests.status.rawValue) · fail-to-pass \(tests.failToPass.passed)/\(tests.failToPass.total)"
                         + " · pass-to-pass \(tests.passToPass.passed)/\(tests.passToPass.total)"
                         + (tests.timeouts > 0 ? " · \(tests.timeouts) timed out" : ""))
            if let note = tests.note { lines.append("  \(note)") }
        }
        if let error = result.agentError { lines.append("The agent stopped with an error: \(error)") }
        if let review = result.review { lines.append("Review: \(review.rawValue)") }
        if let leaks = result.leaks, !leaks.isEmpty {
            lines.append("Left out of comparisons: the transcript mentions \(leaks.joined(separator: ", ")).")
        }
        return lines
    }

    /// The run's own agent session, measured; nil when Claude Code wrote no transcript (and
    /// for Pi, whose sessions AKit doesn't measure yet).
    static func ownMetrics(_ spec: RunSpec, project: URL, env: HarnessEnvironment) async -> SessionMetrics? {
        guard let file = LabPaths.transcript(sessionID: spec.sessionID, env: env) else { return nil }
        return try? await LabAnalysis.analyze(file: file, project: project, env: env)
    }
}

/// A session review. By default one model call, done by error analysis's notes pipeline
/// (`execute` of `LabWorker.run`); here only the agent mode: an agent with file tools reads
/// the whole transcript itself and writes `review.json` and `summary.md`.
public enum ReviewRun {
    static func execute(_ run: LabRun, env: HarnessEnvironment, phase: (RunState.Phase) -> Void,
                        out: @escaping @Sendable (String) -> Void) async throws -> RunResult {
        let file = try reviewedFile(run)
        let agent = run.spec.agent ?? LabRuns.defaultAgent(.claudeCode, env: env)
        // The account behind the agent is checked before anything is written for it to read.
        let gate = try await SendGate.open(agent: agent, env: env)
        try gate.check(SendOrigin.of(harness: run.spec.reviewedHarness, sessionFile: file))
        let (transcript, _) = try await prepare(run, transcript: file, env: env)
        try Data(gate.scrub(transcript).text.utf8).write(to: run.folder.appending(path: "transcript.md"))
        guard !Cancellation.isCancelled else { throw CancellationError() }

        phase(.agent)
        let language = run.spec.language ?? .english
        // The transcript may carry text written to steer an agent (fetched pages, file
        // contents): the reviewer gets only file tools, with no shell, web or MCP. Claude
        // Code's --restricted also confines them to the run folder and skips your settings;
        // acceptEdits lets it write there (auto asks, and nobody can answer). Pi's allowlist
        // covers extension tools, but its file tools reach any path.
        let tools = switch agent.harness {
        case .claudeCode: ["--tools", "Read,Write,Glob,Grep", "--restricted", "--strict-mcp-config",
                           "--permission-mode", "acceptEdits"]
        case .pi: ["--tools", "read,write,grep,find,ls"]
        }
        let outcome = try await AgentRun.run(prompt: agentPrompt + "\n\n" + language.instruction, spec: run.spec, in: run.folder,
                                             runFolder: run.folder, exposeRunFolder: true, extra: tools, env: env, out: out)
        guard !outcome.exit.cancelled else { throw CancellationError() }
        try? SendLog.append(SendRecord(purpose: "review", session: file.path, runID: run.id, destination: gate.destination,
                                       model: agent.model, inputCharacters: transcript.count, usage: outcome.usage), env: env)

        phase(.metrics)
        return RunResult(metrics: await LabWorker.ownMetrics(run.spec, project: run.folder, env: env),
                         review: status(in: run.folder), agentError: outcome.error)
    }

    /// The session a review run names, which must still exist.
    public static func reviewedFile(_ run: LabRun) throws -> URL {
        guard let path = run.spec.reviewedTranscript else { throw LabWorker.Failure(message: "The run names no session to review.") }
        guard FileManager.default.fileExists(atPath: path) else {
            throw LabWorker.Failure(message: "The session file is gone: \(path).")
        }
        return URL(filePath: path)
    }

    /// `analysis.json` (AKit's numbers, Claude Code sessions only) for you to check the review
    /// against, and the masked Markdown of the session, which the caller scrubs before an agent
    /// reads it.
    public static func prepare(_ run: LabRun, transcript file: URL, env: HarnessEnvironment) async throws -> (markdown: String, metrics: SessionMetrics?) {
        let info = JSONLines.fileInfo(file)
        let summary = SessionSummary(harness: run.spec.reviewedHarness, file: file,
                                     title: run.spec.reviewedTitle ?? file.deletingPathExtension().lastPathComponent,
                                     project: LabPaths.folder(ofTranscript: file), started: nil,
                                     modified: info.modified, size: info.size)
        let transcript = try SessionReader.transcript(of: summary)
        var metrics: SessionMetrics?
        if run.spec.reviewedHarness == .claudeCode {
            metrics = try await LabAnalysis.analyze(file: file, env: env)
            try LabStore.write(metrics, to: run.folder.appending(path: "analysis.json"))
        }
        return (SessionExport.markdown(summary, transcript), metrics)
    }

    /// Whether a readable review is there.
    public static func status(in folder: URL) -> ReviewStatus {
        guard let data = try? Data(contentsOf: folder.appending(path: "review.json")) else { return .missing }
        guard let review = try? LabStore.decoder.decode(Review.self, from: data),
              review.findings.allSatisfy({ !$0.title.isEmpty }) else { return .invalid }
        return .ok
    }

    /// Writes what the Lab screen shows: `summary.md` and `review.json` (masked).
    public static func write(summary: String, findings: [Review.Finding], to folder: URL) throws {
        try Data((SecretFilter.masked(summary) + "\n").utf8).write(to: folder.appending(path: "summary.md"))
        try LabStore.write(Review(findings: findings.prefix(Review.limit).map(\.masked)), to: folder.appending(path: "review.json"))
    }

    /// What a review says: the session in one paragraph, then generic advice that the
    /// session's own facts support.
    static let findingRules = """
        Find the barriers: where the session lost time or tokens or went wrong (wrong turns,
        work done twice, large or repeated reads, avoidable tool errors, checks that were
        skipped, instructions that were ignored, waiting on the user).

        - summary: one plain paragraph of 3 to 5 sentences, no headings or lists: what the
          session did, whether it went well, and how efficient it was (one or two numbers).
        - improvements: at most 3, the most valuable first. Each is generic advice that would
          help any future session meeting the same barrier, not a fix for this task: a rule
          for AGENTS.md or CLAUDE.md, a skill, a hook, a setting, a way to prompt or to split
          work. Its title names no feature, file, branch or tool of this project.
          - title: the generic advice, in one sentence.
          - evidence: the facts from this session that prove the barrier: cite items (#n) and
            numbers (calls, tokens, errors, minutes).
          - detail: what following the advice would improve, in one sentence (fewer calls or
            tokens, fewer tool errors, a check that isn't skipped).
          Leave out anything the facts don't show clearly or that is small: 0 or 1
          improvements are fine when the session went well.
        """

    static let agentPrompt = """
        You review one recorded agent session for AKit Lab. The current folder holds:
        - transcript.md: the whole conversation (secrets are masked),
        - analysis.json (Claude Code sessions): numbers AKit computed from the transcript and
          git: API calls, fresh tokens, context rent (baseline, reading code, own output,
          injections, other), tool errors, re-reads, rejected tool calls, interrupts,
          compactions, commits.

        Trust the numbers; don't recompute them. Read the transcript (it can be long: read it in
        parts; cite places by the heading they are under).

        """ + findingRules + """

        Write exactly two files in the current folder and change nothing else:
        - summary.md: the summary paragraph.
        - review.json: {"findings": [{"title": "…", "evidence": "…", "detail": "…"}]}, the
          improvements.
        """
}

/// A replay: the agent redoes a commit in an isolated clone of its parent, then the
/// commit's own tests judge the result.
enum ReplayRun {
    static func execute(_ run: LabRun, env: HarnessEnvironment, phase: (RunState.Phase) -> Void,
                        out: @escaping @Sendable (String) -> Void) async throws -> RunResult {
        guard let commit = run.spec.commit, let repoPath = run.spec.repo else {
            throw LabWorker.Failure(message: "The run names no commit to replay.")
        }
        let repo = URL(filePath: repoPath, directoryHint: .isDirectory)
        // The clone lives in a folder with a random name, not in the run folder: nothing in or
        // next to it (run.json, the task cache) points at the commit being replayed.
        let work = FileManager.default.temporaryDirectory
            .appending(path: "akit-replay-\(UUID().uuidString.lowercased())", directoryHint: .isDirectory)
        let logURL = run.folder.appending(path: "check.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try? FileHandle(forWritingTo: logURL)
        defer {
            try? log?.close()
            // The clone (with its build) goes to the Trash unless kept, then it moves into the
            // run folder; no branch is ever left in the real repository.
            if FileManager.default.fileExists(atPath: work.path) {
                if run.spec.keep {
                    try? FileManager.default.moveItem(at: work, to: run.folder.appending(path: "work"))
                } else {
                    _ = try? Trash.move(work)
                }
            }
        }

        let task = try await ReplayTasks.task(commit: commit, repo: repo, env: env, out: out)
        guard !Cancellation.isCancelled else { throw CancellationError() }
        out("Replaying \(task.shortCommit) “\(task.subject)” from \(String(task.base.prefix(7)))"
            + (run.spec.setup.map { " · \($0.label)" } ?? ""))
        try await IsolatedClone.make(at: work, from: URL(filePath: task.repo), commit: task.base, env: env)

        phase(.agent)
        // The agent sends the repository's code to its provider: the sending policy applies.
        let defaults = LabRuns.defaultModelAndEffort(env: env)
        let model = run.spec.setup?.model ?? defaults.model
        let gate = try await SendGate.open(agent: LabAgent(harness: .claudeCode, model: model, effort: run.spec.setup?.effort ?? defaults.effort),
                                           env: env)
        try gate.check(.code(.claudeCode))
        let agent = try await AgentRun.run(prompt: task.prompt, spec: run.spec, in: work, runFolder: run.folder, exposeRunFolder: false,
                                           env: env, out: out)
        guard !agent.exit.cancelled else { throw CancellationError() }
        try? SendLog.append(SendRecord(purpose: "replay", session: nil, runID: run.id, destination: gate.destination, model: model,
                                       inputCharacters: task.prompt.count, usage: agent.usage), env: env)

        phase(.tests)
        out("Hidden tests: \(task.failToPass.count) fail-to-pass, \(task.passToPass.count) pass-to-pass.")
        try await IsolatedClone.copyTests(task.testFiles, from: URL(filePath: task.repo), commit: task.commit, into: work, env: env)
        let package = task.package.isEmpty ? work : work.appending(path: task.package, directoryHint: .isDirectory)
        let runner = SwiftTests(package: package, folder: work, env: env, log: log, out: out)
        let outcome: TestOutcome
        if await runner.build() {
            let results = await runner.run(task.failToPass + task.passToPass)
            guard !Cancellation.isCancelled else { throw CancellationError() }
            outcome = Self.outcome(task, results)
        } else {
            guard !Cancellation.isCancelled else { throw CancellationError() }
            outcome = TestOutcome(status: .failed, failToPass: .init(passed: 0, total: task.failToPass.count),
                                  passToPass: .init(passed: 0, total: task.passToPass.count),
                                  failed: (task.failToPass + task.passToPass).map(\.id),
                                  note: "The tests don't build after the agent's changes (see check.log).")
        }

        phase(.metrics)
        let metrics = await LabWorker.ownMetrics(run.spec, project: work, env: env)
        let leaks = LabPaths.transcript(sessionID: run.spec.sessionID, env: env)
            .map { LeakCheck.leaks(in: $0, task: task, repo: repo, env: env) } ?? []
        return RunResult(metrics: metrics, tests: outcome, leaks: leaks, agentError: agent.error)
    }

    static func outcome(_ task: ReplayTask, _ results: [TestName: SwiftTests.Outcome]) -> TestOutcome {
        func count(_ tests: [TestName]) -> TestOutcome.Count {
            TestOutcome.Count(passed: tests.filter { results[$0] == .passed }.count, total: tests.count)
        }
        let all = task.failToPass + task.passToPass
        let failed = all.filter { results[$0] != .passed }
        return TestOutcome(status: failed.isEmpty ? .passed : .failed, failToPass: count(task.failToPass),
                           passToPass: count(task.passToPass), timeouts: all.filter { results[$0] == .timedOut }.count,
                           failed: failed.map(\.id))
    }
}
