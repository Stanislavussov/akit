import AKitErrorAnalysis
import AKitFoundation
import AKitInsights
import AKitLab
import Foundation

/// `akit analysis …`: failure modes across many sessions (docs/design/error-analysis.md).
extension AKitCLI {
    public static let analysisUsage = """
        akit analysis — failure modes across many sessions; files in ~/.akit/lab/analysis

          akit analysis notes [SESSION] [--json]
                                          A reviewed session's outcome, notes (accepted and rejected
                                          by the verifier), deviation steps and advice. Without
                                          SESSION: every reviewed session. Review one with
                                          akit lab new review SESSION
          akit analysis signals [--json]  Compute cheap signals (interrupts, pushbacks, tool errors,
                                          repeated calls, "done" with no check) for every indexed
                                          session; local, no model call. Run akit sessions import first
          akit analysis check [MODE…] [--json]
                                          Run code checks over every indexed session (all of them
                                          without MODE): the share of sessions where each mode shows,
                                          with a 95% interval. Local, nothing is sent
        """ + analysisModesUsage + analysisReportUsage + "\n\n" + analysisControlUsage

    static func analysis(_ arguments: [String], env: HarnessEnvironment, cwd: URL,
                         out: (String) -> Void, err: (String) -> Void, trash: (URL) throws -> URL? = Trash.move) async throws -> Int32 {
        var args = Arguments(arguments)
        if args.flag("--help") || args.flag("-h") || args.isEmpty {
            out(analysisUsage)
            return 0
        }
        let json = args.flag("--json")
        let options = AnalysisOptions(json: json, yes: args.flag("--yes"), harness: args.value("--harness"), model: args.value("--model"),
                                      effort: args.value("--effort"))
        let command = args.positional()
        if let command, let code = try await analysisModes(command, &args, options: options, env: env, cwd: cwd, out: out) {
            return code
        }
        if let command, let code = try await analysisReports(command, &args, options: options, env: env, cwd: cwd, out: out) {
            return code
        }
        switch command {
        case "notes":
            let session = args.positional()
            try args.finish()
            try options.refuseModelFlags("notes")
            let store = NotesStore(env: env)
            guard let session else {
                let all = store.all().sorted { $0.createdAt > $1.createdAt }
                if json { out(try labJSON(all)); return 0 }
                out(all.isEmpty ? "No reviewed sessions." : all.map { notes in
                    "\(notes.sessionKey)  \(notes.outcome.title.padding(toLength: 12, withPad: " ", startingAt: 0))  "
                        + "\(notes.accepted.count) notes  \(notes.title ?? "")"
                }.joined(separator: "\n"))
                return 0
            }
            guard let notes = store.load(try sessionKey(session, cwd: cwd, env: env)) else {
                throw Failure(message: "No notes for \(session). Review it first: akit lab new review \(session).")
            }
            out(json ? try labJSON(notes) : notesText(notes))
            return 0
        case "signals":
            try args.finish()
            try options.refuseModelFlags("signals")
            let result = try SignalScanner.refresh(env: env)
            guard result.total > 0 else { throw Failure(message: "The session index is empty. Run akit sessions import first.") }
            guard let database = try AnalysisIndex.open(env: env) else { return 0 }
            let signals = try AnalysisIndex.signals(database).mapValues(\.signals)
            if json { out(try labJSON(signals)); return 0 }
            let raised = signals.values.filter(\.raised).count
            out("Computed \(result.computed) of \(result.total) sessions. \(raised) raise a signal:")
            for (name, count) in [("interrupted", signals.values.filter { $0.interrupts > 0 }.count),
                                  ("pushback", signals.values.filter { $0.pushbacks > 0 }.count),
                                  ("tool errors", signals.values.filter { $0.toolErrors > 0 }.count),
                                  ("repeated calls", signals.values.filter { $0.repeatedCalls > 0 }.count),
                                  ("done with no check", signals.values.filter(\.unverifiedDone).count)] {
                out("  \(name.padding(toLength: 20, withPad: " ", startingAt: 0)) \(count)")
            }
            return 0
        case "check":
            var ids: [String] = []
            while let id = args.positional() { ids.append(id) }
            try args.finish()
            try options.refuseModelFlags("check")
            let checks = try ids.isEmpty ? CodeChecks.all : ids.map { id in
                guard let check = CodeChecks.check(for: id) else {
                    throw Failure(message: "No code check for \(id). Code checks: \(CodeChecks.all.map(\.modeID).joined(separator: ", ")).")
                }
                return check
            }
            // With the modes' versions, as the import and batches run them: a run without
            // them would make the next of those start the results over.
            let modes = FileManager.default.fileExists(atPath: AnalysisPaths(env: env).modesFile.path) ? try await ModeStore(env: env).list() : []
            let versions = Dictionary(modes.filter(\.isCurrent).map { ($0.id, $0.version) }, uniquingKeysWith: { first, _ in first })
            let results = try CheckRunner.run(checks, modeVersions: versions, env: env)
            if json { out(try labJSON(results)); return 0 }
            for (check, result) in zip(checks, results) {
                let rate = result.rate()
                let share = rate.total == 0 ? "no sessions" : String(format: "%d of %d (%.1f%%, 95%% %.1f–%.1f%%)", rate.positive, rate.total,
                                                                       100 * Double(rate.positive) / Double(rate.total),
                                                                       100 * rate.interval.low, 100 * rate.interval.high)
                out("\(check.modeID) [\(check.kind.rawValue)]: \(share)")
                if check.kind == .heuristic { out("  not validated: reports show this mode as \"seen in k notes\"") }
            }
            return 0
        case "control":
            return try await analysisControl(&args, options: options, env: env, cwd: cwd, out: out, trash: trash)
        case let other:
            throw Failure(message: "Unknown “akit analysis \(other ?? "")”. Run akit analysis --help.")
        }
    }

    /// A session key (`claude:<id>`), a transcript path, or a Claude Code session id.
    static func sessionKey(_ text: String, cwd: URL, env: HarnessEnvironment) throws -> String {
        if SessionKey(parsing: text) != nil { return text }
        let path = resolve(text, cwd: cwd, env: env)
        // A Pi session log: its key comes from the file's header.
        if path.pathExtension == "jsonl", FileManager.default.fileExists(atPath: path.path),
           let key = SessionKey.of(NotesPipeline.Target(harness: LabPaths.harness(ofTranscript: path), file: path).summary) {
            return key.description
        }
        let file = try transcript(text, cwd: cwd, env: env)
        return SessionKey.of(NotesPipeline.Target(harness: .claudeCode, file: file).summary)?.description
            ?? "claude:" + file.deletingPathExtension().lastPathComponent
    }

    static func notesText(_ notes: SessionNotes) -> String {
        var lines = ["\(notes.title ?? notes.sessionKey)", "Session  \(notes.sessionKey)", "Outcome  \(notes.outcome.title)",
                     "Notes by \(notes.notesConfig.harness ?? "?") · \(notes.notesConfig.model ?? "?")"]
        if let conclusion = notes.conclusion { lines.append("Conclusion: \(conclusion)") }
        if !notes.requirements.isEmpty {
            lines.append("Requirements:")
            lines += notes.requirements.map { "  - \($0)" }
        }
        if let step = notes.deviation.decisiveStep { lines.append("Decided about step #\(step)") }
        if let step = notes.deviation.observedStep { lines.append("Visible about step #\(step)") }
        lines.append("")
        lines.append(notes.paragraph)
        for note in notes.notes {
            let mark = note.isAccepted ? "✓" : "✗"
            lines.append("\(mark) #\(note.step) [\(note.phase?.rawValue ?? "?")] \(note.severity?.rawValue ?? "") \(note.description)")
            lines.append("    “\(note.quote)”")
            if let verdict = note.verdict, !verdict.accepted { lines.append("    rejected: \(verdict.reason)") }
        }
        for (index, advice) in notes.advice.enumerated() { lines.append("\(index + 1). \(advice.title) (\(advice.noteIDs.joined(separator: ", ")))") }
        return lines.joined(separator: "\n")
    }
}

extension AKitCLI.AnalysisOptions {
    /// A command that sends nothing refuses `--harness`, `--model`, `--effort` and `--yes`
    /// rather than ignoring them, so nobody thinks they took effect.
    func refuseModelFlags(_ command: String) throws {
        let given = [("--harness", harness != nil), ("--model", model != nil), ("--effort", effort != nil), ("--yes", yes)]
            .filter(\.1).map(\.0)
        guard given.isEmpty else {
            throw AKitCLI.Failure(message: "akit analysis \(command) sends nothing to a model; leave out \(given.joined(separator: ", ")).")
        }
    }
}
