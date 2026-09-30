import AKitFoundation
import AKitModel
import AKitSessions
import Foundation

/// `akit lab run <id>`: does one run in the terminal that hosts it. Writes `state.json` at
/// every phase, `result.json` at the end, then starts the next queued run.
public enum LabWorker {
    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Returns the exit code. `startNext` and `handleSignals` are off in tests.
    public static func run(id: String, env: HarnessEnvironment, startNext: Bool = true, handleSignals: Bool = true,
                           out: @escaping @Sendable (String) -> Void) async -> Int32 {
        guard let run = LabStore.load(id, env: env) else {
            out("akit: no Lab run \(id) in \(LabPaths(env: env).folder.path).")
            return 2
        }
        guard run.status == .queued else {
            out("akit: run \(id) is \(run.status.rawValue); only a queued run can start.")
            return 2
        }
        let started = Date.now
        func state(_ status: RunState.Status, _ phase: RunState.Phase? = nil, message: String? = nil) {
            try? LabStore.save(RunState(status: status, phase: phase, pid: getpid(), startedAt: started, message: message),
                               of: id, env: env)
        }
        state(.running, .prepare)
        if handleSignals { Cancellation.installSignalHandlers() }
        out("Lab run \(id): \(run.spec.title)")

        let code: Int32
        do {
            let result: RunResult
            switch run.spec.kind {
            case .review: result = try await ReviewRun.execute(run, env: env, phase: { state(.running, $0) }, out: out)
            case .replay: result = try await ReplayRun.execute(run, env: env, phase: { state(.running, $0) }, out: out)
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
        if let review = result.review { lines.append("Review: \(review.rawValue)") }
        if let leaks = result.leaks, !leaks.isEmpty {
            lines.append("Left out of comparisons: the transcript mentions \(leaks.joined(separator: ", ")).")
        }
        return lines
    }

    /// The run's own agent session, measured; nil when Claude Code wrote no transcript.
    static func ownMetrics(_ spec: RunSpec, project: URL, env: HarnessEnvironment) async -> SessionMetrics? {
        guard let file = LabPaths.transcript(sessionID: spec.sessionID, env: env) else { return nil }
        return try? await LabAnalysis.analyze(file: file, project: project, env: env)
    }
}

/// A session review: the agent reads a masked transcript and AKit's numbers and writes
/// `review.json` and `summary.md` into the run folder, where it runs.
enum ReviewRun {
    static func execute(_ run: LabRun, env: HarnessEnvironment, phase: (RunState.Phase) -> Void,
                        out: @escaping @Sendable (String) -> Void) async throws -> RunResult {
        guard let path = run.spec.reviewedTranscript else { throw LabWorker.Failure(message: "The run names no session to review.") }
        let file = URL(filePath: path)
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw LabWorker.Failure(message: "The session file is gone: \(path).")
        }
        try await prepare(run, transcript: file, env: env)
        guard !Cancellation.isCancelled else { throw CancellationError() }

        phase(.agent)
        let exit = try await AgentRun.run(prompt: prompt, spec: run.spec, in: run.folder, runFolder: run.folder, env: env, out: out)
        guard !exit.cancelled else { throw CancellationError() }

        phase(.metrics)
        return RunResult(metrics: await LabWorker.ownMetrics(run.spec, project: run.folder, env: env),
                         review: status(in: run.folder))
    }

    /// `transcript.md` (masked, as the app copies it) and `analysis.json` for the agent.
    static func prepare(_ run: LabRun, transcript file: URL, env: HarnessEnvironment) async throws {
        let info = JSONLines.fileInfo(file)
        let summary = SessionSummary(harness: .claudeCode, file: file,
                                     title: run.spec.reviewedTitle ?? file.deletingPathExtension().lastPathComponent,
                                     project: LabPaths.folder(ofTranscript: file), started: nil,
                                     modified: info.modified, size: info.size)
        let markdown = SessionExport.markdown(summary, try SessionReader.transcript(of: summary))
        try Data(markdown.utf8).write(to: run.folder.appending(path: "transcript.md"))
        let metrics = try await LabAnalysis.analyze(file: file, env: env)
        try LabStore.write(metrics, to: run.folder.appending(path: "analysis.json"))
    }

    /// Whether the agent left a readable review.
    static func status(in folder: URL) -> ReviewStatus {
        guard let data = try? Data(contentsOf: folder.appending(path: "review.json")) else { return .missing }
        guard let review = try? LabStore.decoder.decode(Review.self, from: data),
              review.findings.allSatisfy({ !$0.title.isEmpty }) else { return .invalid }
        return .ok
    }

    static let prompt = """
        You review one recorded Claude Code session for AKit Lab. The current folder holds:
        - transcript.md: the whole conversation (secrets are masked),
        - analysis.json: numbers AKit computed from the transcript and git: API calls, fresh
          tokens, context rent (baseline, reading code, own output, injections, other), tool
          errors, re-reads, rejected tool calls, interrupts, compactions, commits.

        Trust the numbers; don't recompute them. Read the transcript (it can be long: read it in
        parts) and find where the session lost time or tokens or went wrong: wrong turns, work
        done twice, large or repeated reads, avoidable tool errors, checks that were skipped,
        instructions that were ignored. For each, say what would have avoided it: a different
        prompt, a line in AGENTS.md or CLAUDE.md, a skill, a hook, a setting.

        Write exactly two files in the current folder and change nothing else:
        - review.json: {"findings": [{"title": "…", "detail": "…"}]} with at most 10 findings,
          the most costly first. Each detail says where in the transcript it happened and what
          to change.
        - summary.md: 5 to 15 lines for a person: what the session did, how efficient it was
          (use the numbers), and the two or three changes that matter most.
        """
}

/// Replay tasks (plan step 3). No command or screen creates a replay run yet.
enum ReplayRun {
    static func execute(_ run: LabRun, env: HarnessEnvironment, phase: (RunState.Phase) -> Void,
                        out: @escaping @Sendable (String) -> Void) async throws -> RunResult {
        throw LabWorker.Failure(message: "This akit can't run replay tasks yet.")
    }
}
