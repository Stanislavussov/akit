import AKitFoundation
import AKitLab
import Foundation

/// `akit lab …`: measuring agent sessions (docs/design/lab.md).
extension AKitCLI {
    public static let labUsage = """
        akit lab — measure agent sessions (Claude Code); files in ~/.akit/lab

          akit lab analyze SESSION [--json]
                                          Calls, fresh tokens, context rent, tool errors, re-reads,
                                          rejected calls, interrupts, commits (and whether they reached
                                          the main branch) of one session. SESSION: a transcript path
                                          or a Claude Code session id

        Runs (one at a time; each opens a tab that runs `akit lab run ID`):
          akit lab new review SESSION [--env orca|herdr|background] [--no-start]
                                          An agent reads the session (masked) and AKit's numbers and
                                          writes a review. Opens where the session ran; --env overrides
          akit lab list [--json]          Runs, newest first, with status
          akit lab show ID [--json]       One run: state, metrics, test results, review
          akit lab start                  Start the next queued run, if none is running
          akit lab cancel ID              Stop a running run (its tab stays), or drop a queued one
          akit lab remove ID              Move a run's folder to the Trash
          akit lab run ID                 Do the run here (what the tab runs)
        """

    /// `akit` itself, for the tab command: `<akit> lab run ID`.
    static var ownExecutable: URL {
        Bundle.main.executableURL?.resolvingSymlinksInPath() ?? URL(filePath: CommandLine.arguments[0])
    }

    static func lab(_ arguments: [String], env: HarnessEnvironment, cwd: URL,
                    out: (String) -> Void, err: (String) -> Void, trash: (URL) throws -> URL?) async throws -> Int32 {
        var args = Arguments(arguments)
        if args.flag("--help") || args.flag("-h") || args.isEmpty {
            out(labUsage)
            return 0
        }
        let json = args.flag("--json")
        let noStart = args.flag("--no-start")
        let environmentText = args.value("--env")
        let command = args.positional()
        switch command {
        case "analyze":
            guard let session = args.positional() else { throw Failure(message: "Which session? akit lab analyze SESSION.") }
            try args.finish()
            let file = try transcript(session, cwd: cwd, env: env)
            let metrics: SessionMetrics
            do {
                metrics = try await LabAnalysis.analyze(file: file, env: env)
            } catch {
                throw Failure(message: "Couldn't read \(file.path): \(error.localizedDescription)")
            }
            out(json ? try labJSON(metrics) : ([file.path] + MetricsText.lines(metrics)).joined(separator: "\n"))
            return 0
        case "new":
            let kind = args.positional()
            guard kind == "review" else { throw Failure(message: "akit lab new review SESSION.") }
            guard let session = args.positional() else { throw Failure(message: "Which session? akit lab new review SESSION.") }
            try args.finish()
            let environment = try labEnvironment(environmentText, env: env)
            let file = try transcript(session, cwd: cwd, env: env)
            let run = try await LabRuns.newReview(transcript: file, title: nil, environment: environment, akit: ownExecutable, env: env)
            out("Queued \(run.id): \(run.spec.title) (\(run.spec.environment.title), \(run.spec.folder)).")
            if !noStart { try await startNext(env: env, out: out) }
            return 0
        case "list":
            try args.finish()
            let runs = LabStore.list(env: env)
            if json {
                out(try labJSON(runs.map(RunJSON.init)))
            } else {
                out(runs.isEmpty ? "No Lab runs." : runs.map(listLine).joined(separator: "\n"))
            }
            return 0
        case "show":
            let run = try labRun(args.positional(), env: env)
            try args.finish()
            out(json ? try labJSON(RunJSON(run)) : showText(run))
            return 0
        case "start":
            try args.finish()
            try await startNext(env: env, out: out)
            return 0
        case "cancel":
            let run = try labRun(args.positional(), env: env)
            try args.finish()
            let wasRunning = run.status == .running
            do {
                try LabStore.cancel(run, env: env)
            } catch {
                throw Failure(message: error.localizedDescription)
            }
            out(wasRunning ? "Asked \(run.id) to stop; its tab shows when it has." : "Dropped \(run.id) from the queue.")
            return 0
        case "remove":
            let run = try labRun(args.positional(), env: env)
            try args.finish()
            do {
                try LabStore.remove(run, trash: trash)
            } catch {
                throw Failure(message: error.localizedDescription)
            }
            out("Moved \(run.folder.path) to the Trash.")
            return 0
        case "run":
            guard let id = args.positional() else { throw Failure(message: "Which run? akit lab run ID.") }
            try args.finish()
            // The worker prints from background threads, straight to the terminal that hosts it.
            return await LabWorker.run(id: id, env: env, out: { LinePrinter.shared.print($0) })
        default:
            throw Failure(message: "Unknown “akit lab \(command ?? "")”. Run akit lab --help.")
        }
    }

    private static func startNext(env: HarnessEnvironment, out: (String) -> Void) async throws {
        do {
            if let run = try await LabQueue.startNext(env: env) {
                out("Started \(run.id) in \(run.spec.environment.title).")
            } else if LabStore.list(env: env).contains(where: { $0.status == .running }) {
                out("Another run is running; this one starts after it.")
            } else {
                out("Nothing queued.")
            }
        } catch {
            throw Failure(message: "The run didn't start: \(error.localizedDescription)")
        }
    }

    private static func labEnvironment(_ text: String?, env: HarnessEnvironment) throws -> LabEnvironment? {
        guard let text else { return nil }
        guard let environment = LabEnvironment(rawValue: text) else {
            throw Failure(message: "--env is orca, herdr or background.")
        }
        guard Launcher.available(env: env).contains(environment) else { throw Failure(message: "\(environment.title) is not installed.") }
        return environment
    }

    private static func labRun(_ id: String?, env: HarnessEnvironment) throws -> LabRun {
        guard let id else { throw Failure(message: "Which run? Give its id (akit lab list).") }
        guard let run = LabStore.load(id, env: env) else { throw Failure(message: "No Lab run \(id).") }
        return run
    }

    private static func listLine(_ run: LabRun) -> String {
        var line = "\(run.id)  \(run.status.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0))  \(run.spec.title)"
        if let metrics = run.result?.metrics { line += "  · \(metrics.calls) calls, \(MetricsText.short(metrics.freshTokens)) fresh" }
        if let tests = run.result?.tests { line += "  · tests \(tests.status.rawValue)" }
        return line
    }

    private static func showText(_ run: LabRun) -> String {
        var lines = ["\(run.spec.title)", "Run      \(run.id) · \(run.spec.kind.rawValue) · \(run.status.rawValue)"
                     + (run.state?.phase.map { " (\($0.title))" } ?? ""),
                     "Opens in \(run.spec.environment.title) · \(run.spec.folder)",
                     "Folder   \(run.folder.path)"]
        if let message = run.message { lines.append("Message  \(message)") }
        if let result = run.result {
            if let metrics = result.metrics { lines += [""] + MetricsText.lines(metrics) }
            lines += LabWorker.resultLines(result)
        }
        if let summary = run.summary { lines += ["", summary.trimmingCharacters(in: .whitespacesAndNewlines)] }
        if let review = run.review, !review.findings.isEmpty {
            lines.append("")
            for (index, finding) in review.findings.enumerated() {
                lines.append("\(index + 1). \(finding.title)")
                lines.append("   \(finding.detail)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// A transcript path, or a Claude Code session id.
    private static func transcript(_ argument: String, cwd: URL, env: HarnessEnvironment) throws -> URL {
        if argument.hasSuffix(".jsonl") || argument.contains("/") {
            let file = resolve(argument, cwd: cwd, env: env)
            guard FileManager.default.fileExists(atPath: file.path) else { throw Failure(message: "No file at \(file.path).") }
            return file
        }
        guard let file = LabPaths.transcript(sessionID: argument, env: env) else {
            throw Failure(message: "No Claude Code session \(argument) in \(LabPaths.claudeRoot(env: env).path)/projects.")
        }
        return file
    }

    static func labJSON<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    /// A run as `--json` prints it.
    struct RunJSON: Encodable {
        let id: String
        let status: RunState.Status
        let message: String?
        let spec: RunSpec
        let state: RunState?
        let launch: LaunchInfo?
        let result: RunResult?
        let review: Review?

        init(_ run: LabRun) {
            id = run.id
            status = run.status
            message = run.message
            spec = run.spec
            state = run.state
            launch = run.launch
            result = run.result
            review = run.review
        }
    }
}

/// Standard output for the worker, which prints from background threads.
private final class LinePrinter: @unchecked Sendable {
    static let shared = LinePrinter()
    private let lock = NSLock()

    func print(_ line: String) {
        lock.withLock {
            Swift.print(line)
            fflush(stdout)
        }
    }
}
