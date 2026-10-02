import AKitErrorAnalysis
import AKitFoundation
import AKitLab
import Foundation

/// `akit analysis report|judge|validate|validation|tough …`: what a batch found, and how far
/// each mode's check can be trusted.
extension AKitCLI {
    static let analysisReportUsage = """

        Reports and checks:
          akit analysis report [BATCH] [--compare BATCH] [--json]
                                          A batch's report (the latest without BATCH): frequencies from
                                          checks only (weighted and plain, by outcome, corrected for
                                          validated checks, 95% intervals), "seen in k notes" for the
                                          rest, coverage, notes recall, verifier rejection, route
                                          acceptance, saturation, and the transition matrix or funnel
          akit analysis judge enable MODE [--harness …] [--model …] [--effort …]
          akit analysis judge disable MODE
          akit analysis judge run MODE [--yes]
                                          Run a mode's judge over the note pool's sessions: where it
                                          finds the mode, and the cases the notes missed
          akit analysis validate MODE dev|test [--yes]
                                          TPR and TNR of the mode's judge (or heuristic code check) on
                                          its labels; test runs once per mode version and check
          akit analysis validation [MODE] [--json]
          akit analysis tough MODE SESSION present|absent
                                          Decide a check's tough call (it becomes a label)

        Fixes (failure and efficiency modes; you apply them, AKit never does):
          akit analysis fix draft MODE --layer claude-md|agents-md|skill|hook|tool-description|environment
                              --text TEXT|@FILE --expect TEXT --helped TEXT [--skill NAME] [--exemplar SESSION#NOTE]… [--reset]
                                          Write the fix down before any run: the text, what should change
                                          in transcripts and the "helped" criterion
          akit analysis fix applied MODE [--at YYYY-MM-DD] [--reset]
                                          Mark it applied: T, the anchor of before/after
          akit analysis fix show MODE [--json]
                                          The draft, and the mode's check before and after T: failure
                                          rates with 95% intervals, P(after < before), Fisher's p, the
                                          verdict (15+ sessions a side), the smallest detectable effect,
                                          flags, regressions of other modes and the matrix difference
          akit analysis fix status MODE confirmed|didnt-help|rejected [--reason TEXT]
          A draft whose layer is a file (CLAUDE.md, AGENTS.md, a skill) can be tried on control
          tasks: akit analysis control run TASK --fix MODE
        """

    static func analysisReports(_ command: String, _ args: inout Arguments, options: AnalysisOptions, env: HarnessEnvironment, cwd: URL,
                                out: (String) -> Void) async throws -> Int32? {
        let modeStore = ModeStore(env: env)
        func mode(_ id: String?) async throws -> Mode {
            guard let id else { throw Failure(message: "Which mode? akit analysis modes lists them.") }
            guard let mode = try await modeStore.mode(id) else { throw Failure(message: "No mode \(id).") }
            return mode
        }
        do {
            switch command {
            case "report":
                let id = args.positional()
                let compare = args.value("--compare")
                try args.finish()
                let batches = BatchStore(env: env)
                guard let batch = id.flatMap(batches.load) ?? (id == nil ? batches.latest() : nil) else {
                    throw Failure(message: id == nil ? "No batches yet: akit lab new analysis." : "No batch \(id ?? "").")
                }
                let report = try await buildReport(batch, env: env)
                var other: BatchReport?
                if let compare {
                    guard let second = batches.load(compare) else { throw Failure(message: "No batch \(compare).") }
                    other = try await buildReport(second, env: env)
                }
                if options.json { out(try labJSON(other.map { [report, $0] } ?? [report])); return 0 }
                out(reportText(report))
                if let other {
                    out("\nCompared with \(other.batchID) (N \(report.matrix.sessions) vs \(other.matrix.sessions)):")
                    for (key, difference) in TransitionMatrix.difference(before: other.matrix, after: report.matrix).sorted(by: { $0.key < $1.key }) {
                        let mark = difference.dimmed ? " (too few)" : difference.withinNoise ? " (within noise)" : ""
                        out(String(format: "  %@: %d → %d (%+.0f%%)%@", key.replacingOccurrences(of: "|", with: " → "), difference.before,
                                   difference.after, difference.change * 100, mark))
                    }
                }
            case "judge":
                let action = args.positional()
                let target = try await mode(args.positional())
                try args.finish()
                let store = ValidationStore(env: env)
                switch action {
                case "enable":
                    let agent = try options.agent(env: env)
                    let seen = Matching.seen(NotesStore(env: env).all(), modes: try await modeStore.list()).byMode.mapValues(\.count)
                    guard Judges.eligible(try await modeStore.list(), seen: seen).contains(where: { $0.id == target.id }) else {
                        throw Failure(message: "Only a mode in the top 3 by notes with a fix drafted or applied gets a judge; "
                                          + "\(target.name) isn't one. Other modes get a code check or stay \"seen in k notes\".")
                    }
                    try store.setJudge(agent, for: target.id)
                    out("\(target.name) is judged by \(agent.label). Validate it: akit analysis validate \(target.id) dev.")
                case "disable":
                    try store.setJudge(nil, for: target.id)
                    out("No judge for \(target.name).")
                case "run":
                    guard let judge = store.judges()[target.id] else { throw Failure(message: "\(target.name) has no judge: akit analysis judge enable \(target.id).") }
                    let pool = NotesStore(env: env).all()
                    guard try confirmCost(characters: pool.count * 60_000, agent: judge, what: "Judging \(pool.count) sessions for \(target.name)",
                                          options: options, env: env, out: out) else { return 0 }
                    let gate = try await SendGate.open(agent: judge, env: env)
                    let results = try await Judges.run(mode: target, sessions: pool.map { ($0.sessionKey, $0.transcript) }, agent: judge, gate: gate,
                                                       runID: nil, workFolder: analysisWork(env), env: env, out: { LinePrinter.shared.print($0) })
                    let missed = Judges.missedByNotes(results, modeID: target.id, pool: pool, modes: try await modeStore.list())
                    let rate = results.rate()
                    out("Present in \(rate.positive) of \(rate.total) sessions; the notes missed \(missed.count) of them\(missed.isEmpty ? "" : ": " + missed.prefix(10).joined(separator: ", ")).")
                default:
                    throw Failure(message: "akit analysis judge enable|disable|run MODE.")
                }
            case "validate":
                let target = try await mode(args.positional())
                guard let set = args.positional().flatMap(Validation.LabelSet.init(rawValue:)) else { throw Failure(message: "dev or test?") }
                try args.finish()
                let judge = ValidationStore(env: env).judges()[target.id]
                var gate: SendGate?
                if let judge {
                    guard try confirmCost(characters: 60_000 * 20, agent: judge, what: "Judging the \(set.rawValue) labels of \(target.name)",
                                          options: options, env: env, out: out) else { return 0 }
                    gate = try await SendGate.open(agent: judge, env: env)
                }
                let result = try await Validation.run(mode: target, set: set, modes: try await modeStore.list(), gate: gate,
                                                      workFolder: analysisWork(env), env: env, out: { LinePrinter.shared.print($0) })
                out(validationLine(result))
                let trust = Validation.trust(modeID: target.id, modeVersion: target.version, checker: result.checker,
                                             results: ValidationStore(env: env).results()[target.id] ?? [])
                out("\(target.name): \(trust.level.rawValue).")
            case "validation":
                let id = args.positional()
                try args.finish()
                let results = ValidationStore(env: env).results().filter { id == nil || $0.key == id }
                if options.json { out(try labJSON(results)); return 0 }
                if results.isEmpty { out("No validation runs yet.") }
                for (_, runs) in results.sorted(by: { $0.key < $1.key }) { for result in runs { out(validationLine(result)) } }
                let modes = try await modeStore.list()
                for (modeID, trust) in Validation.trustMap(modes: modes, env: env).sorted(by: { $0.key < $1.key })
                where trust.level != .none && (id == nil || id == modeID) {
                    out("\(modeID): \(trust.level.rawValue)")
                }
            case "fix":
                return try await fixCommand(&args, options: options, env: env, cwd: cwd, out: out)
            case "tough":
                let target = try await mode(args.positional())
                guard let session = args.positional(), let verdict = args.positional(), ["present", "absent"].contains(verdict) else {
                    throw Failure(message: "akit analysis tough MODE SESSION present|absent.")
                }
                try args.finish()
                _ = try LabelBookStore(env: env).update { $0.toughCalls["\(target.id)|\(session)"] = verdict == "present" }
                out("Noted: \(target.name) is \(verdict) in \(session).")
            default:
                return nil
            }
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure(message: error.localizedDescription)
        }
        return 0
    }

    private static func fixCommand(_ args: inout Arguments, options: AnalysisOptions, env: HarnessEnvironment, cwd: URL,
                                   out: (String) -> Void) async throws -> Int32 {
        let store = ModeStore(env: env)
        let action = args.positional()
        guard let id = args.positional(), let mode = try await store.mode(id) else { throw Failure(message: "Which mode? akit analysis modes.") }
        guard mode.kind.takesFixes else { throw Failure(message: "\(mode.name) is a success mode: it takes no fix.") }
        let fixes = FixStore(env: env)
        switch action {
        case "draft":
            guard let layer = args.value("--layer").flatMap(FixDraft.Layer.init(rawValue:)) else {
                throw Failure(message: "--layer is \(FixDraft.Layer.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            guard var text = args.value("--text"), let expect = args.value("--expect"), let helped = args.value("--helped") else {
                throw Failure(message: "Give --text, --expect (the change you expect in transcripts) and --helped (the criterion), before any run.")
            }
            let skill = args.value("--skill")
            let reset = args.flag("--reset")
            // The draft and its "helped" criterion are fixed before the run: once applied, a new
            // draft would move T and let the criterion follow the results.
            if let status = mode.fix, ![Mode.FixStatus.open, .draft].contains(status), !reset {
                throw Failure(message: "The fix of \(mode.name) is \(status.title.lowercased()); a new draft would drop T and its criterion. Add --reset to start over.")
            }
            let exemplars = try args.values("--exemplar").map { text in
                guard let ref = NoteRef(parsing: text) else { throw Failure(message: "--exemplar is SESSION#NOTE.") }
                return ref
            }
            try args.finish()
            if text.hasPrefix("@") {
                guard let read = try? String(contentsOf: resolve(String(text.dropFirst()), cwd: cwd, env: env), encoding: .utf8) else {
                    throw Failure(message: "Can't read \(text.dropFirst()).")
                }
                text = read
            }
            guard layer != .skill || skill != nil else { throw Failure(message: "A skill fix needs --skill NAME.") }
            // The status first: a fix applied meanwhile refuses before its draft is written over.
            _ = try await store.setFix(mode.id, .draft, reset: reset)
            try fixes.save(FixDraft(modeID: mode.id, layer: layer, skillName: skill, text: text, exemplars: exemplars,
                                    expectedChange: expect, helpedCriterion: helped))
            out("Drafted a \(layer.title.lowercased()) for \(mode.name). Apply it yourself, then: akit analysis fix applied \(mode.id).")
        case "applied":
            let at = try args.value("--at").map { try day($0, "--at") } ?? .now
            let reset = args.flag("--reset")
            try args.finish()
            guard fixes.load(mode.id) != nil else { throw Failure(message: "Draft the fix first: write down what should change before T.") }
            _ = try await store.setFix(mode.id, .applied, at: at, reset: reset)
            out("\(mode.name): fix applied at \(at.formatted(date: .abbreviated, time: .shortened)).")
        case "status":
            guard let status = args.positional().flatMap(Mode.FixStatus.init(rawValue:)), [.confirmed, .didntHelp, .rejected].contains(status) else {
                throw Failure(message: "confirmed, didnt-help or rejected?")
            }
            let reason = args.value("--reason")
            try args.finish()
            _ = try await store.setFix(mode.id, status, reason: reason)
            out("\(mode.name): \(status.title).")
        case "show":
            try args.finish()
            let draft = fixes.load(mode.id)
            let evaluation = try Fixes.evaluate(mode, env: env)
            if options.json {
                struct FixJSON: Encodable { let draft: FixDraft?; let evaluation: FixEvaluation? }
                out(try labJSON(FixJSON(draft: draft, evaluation: evaluation)))
                return 0
            }
            out("\(mode.name): fix \(mode.fix?.title ?? "none")")
            if let draft {
                out("\(draft.layer.title)\(draft.skillName.map { " \($0)" } ?? ""):\n\(draft.text)")
                out("Expected change: \(draft.expectedChange)")
                out("Helped when: \(draft.helpedCriterion)")
            }
            guard let evaluation else {
                out(mode.fixAppliedAt == nil ? "Not applied yet." : "No check results for this mode: akit analysis check \(mode.id).")
                return 0
            }
            func side(_ name: String, _ side: FixEvaluation.Side) -> String {
                String(format: "%@: %d of %d sessions (95%% %.0f–%.0f%%)", name, side.failures, side.sessions, side.interval.low * 100, side.interval.high * 100)
            }
            out(side("Before T", evaluation.before))
            out(side("After T", evaluation.after))
            out(String(format: "P(after < before) %.3f · P(after > before) %.3f · Fisher p %.3f · %@", evaluation.probabilityLower,
                       evaluation.probabilityHigher, evaluation.fisherP, evaluation.verdict.rawValue))
            if let mde = evaluation.minimumDetectable {
                out(String(format: "With these numbers only a drop to about %.0f%% or lower would show.", mde * 100))
            }
            for flag in evaluation.flags { out("! \(flag)") }
            if let applied = mode.fixAppliedAt {
                let rose = try Fixes.regressions(modes: try await store.list(), since: applied, env: env).filter { $0 != mode.id }
                if !rose.isEmpty { out("Higher failure rate after T: \(rose.joined(separator: ", ")).") }
                let difference = try Fixes.matrixDifference(appliedAt: applied, pool: NotesStore(env: env).all(), env: env)
                for (key, cell) in difference.sorted(by: { $0.key < $1.key }) where !cell.dimmed && !cell.withinNoise {
                    out(String(format: "Matrix %@: %+.0f%%", key.replacingOccurrences(of: "|", with: " → "), cell.change * 100))
                }
            }
        default:
            throw Failure(message: "akit analysis fix draft|applied|status|show MODE.")
        }
        return 0
    }

    static func buildReport(_ batch: Batch, env: HarnessEnvironment) async throws -> BatchReport {
        let modes = try await ModeStore(env: env).list()
        let pool = NotesStore(env: env).all()
        let labels = Bootstrap.LabelStore(env: env).all()
        let metrics = Bootstrap.metrics(labels: labels, notes: pool, pairings: Bootstrap.PairingStore(env: env).all(),
                                        phases: Bootstrap.phases(of: labels))
        return Reports.build(batch, modes: modes, pool: pool, checks: modes.compactMap { Validation.verdicts(modeID: $0.id, env: env) },
                             trust: Validation.trustMap(modes: modes, env: env), bootstrap: metrics, acceptance: Matching.acceptance(pool),
                             allBatches: BatchStore(env: env).all(), phases: Reports.phases(of: batch))
    }

    static func validationLine(_ result: ValidationResult) -> String {
        func pct(_ value: Double?) -> String { value.map { String(format: "%.0f%%", $0 * 100) } ?? "—" }
        return "\(result.modeID) v\(result.modeVersion) \(result.set.rawValue): TPR \(pct(result.tpr)) (low \(pct(result.tprLow)), "
            + "\(result.labels.onPositives.count) positives), TNR \(pct(result.tnr)) (low \(pct(result.tnrLow)), \(result.labels.onNegatives.count) negatives)"
            + (result.toughLeftOut > 0 ? ", \(result.toughLeftOut) tough calls left out (decide them: akit analysis queue)" : "") + (result.unchecked > 0 ? ", \(result.unchecked) unchecked" : "")
    }

    static func reportText(_ report: BatchReport) -> String {
        func pct(_ value: Double?) -> String { value.map { String(format: "%.0f%%", $0 * 100) } ?? "—" }
        var lines = ["Batch \(report.batchID): \(report.coverage[0]) of \(report.coverage[1]) sessions"
                     + (report.coverage[0] < report.coverage[1] ? " (coverage \(report.coverage[0])/\(report.coverage[1]))" : "")]
        lines.append("Notes \(report.notesVersion ?? "?"): bootstrap recall \(pct(report.notesRecall)), verifier rejected \(pct(report.verifierRejection)), "
                     + "routes accepted \(report.routeAcceptance[0]) of \(report.routeAcceptance[1])")
        lines.append("")
        for mode in report.modes {
            if mode.hasFrequency {
                let value = mode.belowDetectionThreshold ? "below detection threshold" : pct(mode.corrected ?? mode.weighted)
                let interval = mode.interval.map { " [\(pct($0.low))–\(pct($0.high))]" } ?? ""
                lines.append("\(mode.name): \(value)\(interval) · plain \(pct(mode.unweighted)) · goal reached \(pct(mode.achieved)), not \(pct(mode.notAchieved))"
                             + (mode.notWorthFixing ? " · as frequent when it went well: maybe not worth fixing" : ""))
            } else {
                lines.append("\(mode.name): seen in \(mode.seenInNotes) notes"
                             + (mode.trust == .provisional ? " · provisional check \(mode.positive)/\(mode.checked)" : ""))
            }
        }
        lines.append("")
        lines.append("Saturation: \(pct(report.unmatchedShare)) of notes matched no mode; new modes \(report.newModes.isEmpty ? "none" : report.newModes.joined(separator: ", "))")
        for (project, saturation) in report.projects.sorted(by: { $0.key < $1.key }) {
            lines.append("  \(project): \(saturation.sessions) sessions, unmatched \(pct(saturation.unmatchedShare)), \(saturation.newModes) new modes")
        }
        if let rebuild = report.rebuild { lines.append(rebuild) }
        lines.append("")
        if !report.matrix.unlocated.isEmpty {
            lines.append("\(report.matrix.unlocated.count) sessions with failures but no decisive step are left out of the matrix.")
        }
        if let hidden = report.matrixHidden {
            lines.append(hidden)
        } else if report.showFunnel {
            lines.append("Deviations per phase (fewer than 50 sessions; a funnel instead of the matrix):")
            for phase in Phase.allCases.map(\.rawValue) + [TransitionMatrix.noFailures] {
                lines.append("  \(phase): \(report.matrix.funnel[phase] ?? 0)")
            }
        } else {
            let columns = Phase.allCases.map(\.rawValue) + [TransitionMatrix.noFailures]
            lines.append("Transition matrix (row: phase before, column: phase of the decisive step; N \(report.matrix.sessions)):")
            lines.append("            " + columns.map { $0.prefix(10).padding(toLength: 11, withPad: " ", startingAt: 0) }.joined())
            for row in Phase.allCases {
                lines.append(row.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0)
                             + columns.map { String(report.matrix.count(row, $0)).padding(toLength: 11, withPad: " ", startingAt: 0) }.joined())
            }
        }
        return lines.joined(separator: "\n")
    }
}
