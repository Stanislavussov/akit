import AKitErrorAnalysis
import AKitFoundation
import AKitLab
import AKitModel
import AKitSessions
import Foundation
import Observation

/// Everything the Error Analysis screen shows, read from `~/.akit/lab/analysis` off the
/// main thread in one go.
struct AnalysisData: Sendable {
    var modes: [Mode] = []
    var pool: [SessionNotes] = []
    /// Accepted model notes per mode (after merges), and the ones no mode fits.
    var seenByMode: [String: [NoteRef]] = [:]
    var unmatched: [NoteRef] = []
    var checks: [String: CheckResults] = [:]
    var exemplars: [String: [Exemplar]] = [:]
    var book = LabelBook()
    var unclear: [UnclearNotes.Entry] = []
    var queue = ReviewQueue.build(modes: [], pool: [], checks: [], book: LabelBook())
    var accepted = 0
    var reviewed = 0
    var reservations: [BootstrapReservations.Entry] = []
    var labels: [String: Bootstrap.Label] = [:]
    var pairings: [String: Bootstrap.Pairing] = [:]
    var metrics: [Bootstrap.Metrics] = []
    /// Finished labels since the list of modes last changed (the stop rule).
    var sinceLastChange = 0
    var testSessions: Set<String> = []
    /// Error analysis batches, newest first.
    var batches: [Batch] = []
    /// Modes with a judge, and who judges.
    var judges: [String: LabAgent] = [:]
    /// Each judge's verdicts (`checks/<mode>@judge.json`), by mode id.
    var judgeResults: [String: CheckResults] = [:]
    var validation: [String: [ValidationResult]] = [:]
    var splits: [String: ValidationStore.Split] = [:]
    /// How far each mode's check can be trusted.
    var trust: [String: CheckTrust] = [:]
    var fixes: [String: FixDraft] = [:]
    /// Controlled eval tasks, oldest first.
    var controlTasks: [ControlTask] = []

    var current: [Mode] { modes.filter(\.isCurrent) }

    func mode(_ id: String) -> Mode? { modes.first { $0.id == id } }

    func notes(of sessionKey: String) -> SessionNotes? { pool.first { $0.sessionKey == sessionKey } }

    /// A pool note by reference, with its session.
    func note(_ ref: NoteRef) -> (session: SessionNotes, note: Note)? {
        guard let session = notes(of: ref.sessionKey), let note = session.notes.first(where: { $0.id == ref.noteID }) else { return nil }
        return (session, note)
    }

    /// A note of the pool or of the user's bootstrap labels.
    func anyNote(_ ref: NoteRef) -> Note? {
        note(ref)?.note ?? labels[ref.sessionKey]?.notes.first { $0.id == ref.noteID }
    }

    var labeledCount: Int { reservations.filter { $0.labeledAt != nil }.count }

    /// The unmatched notes clustering would send.
    func unmatchedItems() -> [Clustering.Item] { Clustering.unmatchedItems(pool, modes: modes) }

    static func load(env: HarnessEnvironment) async throws -> AnalysisData {
        var data = AnalysisData()
        let store = ModeStore(env: env)
        data.modes = try await store.list()
        data.pool = NotesStore(env: env).all().sorted { $0.createdAt > $1.createdAt }
        let seen = Matching.seen(data.pool, modes: data.modes)
        data.seenByMode = seen.byMode
        data.unmatched = seen.unmatched
        let checkStore = CheckStore(env: env)
        for mode in data.modes {
            if let results = checkStore.load(mode.id) { data.checks[mode.id] = results }
            let exemplars = (try? store.exemplars(of: mode.id)) ?? []
            if !exemplars.isEmpty { data.exemplars[mode.id] = exemplars }
        }
        data.book = LabelBookStore(env: env).load()
        data.unclear = UnclearNotes(env: env).all()
        data.queue = ReviewQueue.build(modes: data.modes, pool: data.pool, checks: Array(data.checks.values), book: data.book,
                                       spotCheck: BatchStore(env: env).latest()?.spotCheck ?? [])
        (data.accepted, data.reviewed) = Matching.acceptance(data.pool)
        data.reservations = BootstrapReservations(env: env).all().sorted { $0.reservedAt < $1.reservedAt }
        let labels = Bootstrap.LabelStore(env: env).all()
        data.labels = Dictionary(labels.map { ($0.sessionKey, $0) }, uniquingKeysWith: { first, _ in first })
        let pairings = Bootstrap.PairingStore(env: env).all()
        data.pairings = Dictionary(pairings.map { ($0.sessionKey, $0) }, uniquingKeysWith: { first, _ in first })
        // Phases read transcripts: only the sessions metrics count.
        let confirmed = Set(pairings.filter(\.isConfirmed).map(\.sessionKey))
        let counted = labels.filter { confirmed.contains($0.sessionKey) }
        data.metrics = Bootstrap.metrics(labels: labels, notes: data.pool, pairings: pairings, phases: Bootstrap.phases(of: counted))
        data.sinceLastChange = Bootstrap.sessionsSinceLastModeChange(labels, lastChange: try await store.lastTaxonomyChange())
        let validation = ValidationStore(env: env)
        data.testSessions = validation.testSessions()
        data.batches = BatchStore(env: env).all()
        data.judges = validation.judges()
        for id in data.judges.keys {
            if let results = checkStore.load(Judges.resultsID(id)) { data.judgeResults[id] = results }
        }
        data.validation = validation.results()
        data.splits = validation.splits()
        data.trust = Validation.trustMap(modes: data.modes, env: env)
        data.fixes = Dictionary(FixStore(env: env).all().map { ($0.modeID, $0) }, uniquingKeysWith: { first, _ in first })
        data.controlTasks = ControlTasks.list(env: env)
        return data
    }
}

/// The Error Analysis screen's state and actions. Files are read and written off the main
/// thread; every action reloads.
@MainActor
@Observable
final class AnalysisModel {
    private(set) var data = AnalysisData()
    private(set) var loaded = false
    /// The last action's outcome, shown in a bar at the top.
    var message: String?
    var error: String?
    /// What runs now ("Checking 120 of 900 sessions…").
    var progress: String?
    /// A model call waiting for the user's go (its sheet).
    var send: AnalysisSend?
    /// Reports: the batch shown and the one compared with it.
    var reportBatch: String? = DebugSnapshot.options?.tab == "reports" ? DebugSnapshot.options?.select : nil
    var compareBatch: String? = DebugSnapshot.options?.tab == "reports" ? DebugSnapshot.options?.query : nil
    /// The last rebuild: all notes clustered from scratch, shown and never saved.
    var rebuild: [Clustering.Candidate]?
    /// The last pool judge run per mode: sessions where the judge found the mode and no note did.
    var judgeMissed: [String: [String]] = [:]

    var env: HarnessEnvironment { .current }

    func reload() async {
        let env = env
        do {
            data = try await Task.detached { try await AnalysisData.load(env: env) }.value
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    /// Runs `work` off the main thread, then reloads. Returns its message; throws its error.
    @discardableResult
    func run(_ work: @escaping @Sendable (HarnessEnvironment) async throws -> String?) async throws -> String? {
        let env = env
        defer { Task { await reload() } }
        let result = try await Task.detached { try await work(env) }.value
        if let result { message = result }
        return result
    }

    /// `run` for buttons: the error goes to the bar.
    func act(_ work: @escaping @Sendable (HarnessEnvironment) async throws -> String?) {
        error = nil
        message = nil
        Task {
            do { try await run(work) } catch { self.error = error.localizedDescription }
        }
    }

    /// Runs a mode's code check over every indexed session, locally, with a progress line.
    /// Does nothing while another check runs.
    func runCheck(_ mode: Mode) {
        guard let check = CodeChecks.check(for: mode.id) else { return }
        runChecks([check], versions: [mode.id: mode.version]) { results in
            let rate = results.first?.rate()
            return "Checked \(rate?.total ?? 0) sessions: the mode shows in \(rate?.positive ?? 0)."
        }
    }

    /// `akit analysis check`: the code checks of every current mode, in one pass over the index.
    func runAllChecks() {
        let versions = Dictionary(data.current.map { ($0.id, $0.version) }, uniquingKeysWith: { first, _ in first })
        let checks = CodeChecks.all.filter { versions[$0.modeID] != nil }
        guard !checks.isEmpty else { return }
        runChecks(checks, versions: versions) { results in
            let total = results.first?.rate().total ?? 0
            let shown = results.filter { $0.rate().positive > 0 }.count
            return "Ran \(results.count) code checks over \(total) sessions: \(shown) of the modes show in at least one session."
        }
    }

    private func runChecks(_ checks: [CodeCheck], versions: [String: Int], summary: @escaping @Sendable ([CheckResults]) -> String) {
        guard progress == nil else { return }
        error = nil
        progress = "Checking indexed sessions…"
        Task {
            defer { progress = nil }
            do {
                try await run { env in
                    let results = try CheckRunner.run(checks, modeVersions: versions, env: env) { done, total in
                        guard done % 25 == 0 else { return }
                        Task { @MainActor in self.progress = "Checking \(done) of \(total) sessions…" }
                    }
                    guard let rate = results.first?.rate(), rate.total > 0 else {
                        return "No indexed sessions to check. Import them with akit sessions import (or akit insights install for an hourly import)."
                    }
                    return summary(results)
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Confirms a candidate or an inactive seed, then runs its code check over every indexed
    /// session at once. False when confirming failed (the error is in the bar).
    @discardableResult
    func confirm(_ mode: Mode) async -> Bool {
        let id = mode.id
        error = nil
        message = nil
        do {
            try await run { env in "\(try await ModeStore(env: env).confirm(id).name) is active." }
        } catch {
            self.error = error.localizedDescription
            return false
        }
        runCheck(mode)
        return true
    }

    /// Where analysis model calls keep their work files.
    nonisolated static func workFolder(_ env: HarnessEnvironment) -> URL {
        AnalysisPaths(env: env).folder.appending(path: "work", directoryHint: .isDirectory)
    }
}

/// A session of a bootstrap reservation or a label as the readers want it.
extension BootstrapReservations.Entry {
    var summary: SessionSummary {
        NotesPipeline.Target(harness: SessionKey.harness(of: sessionKey), file: URL(filePath: transcript)).summary
    }
}

struct AnalysisFailure: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

extension AnalysisData {
    /// How far a mode's code check (not its judge) can be trusted, from its test runs.
    func codeCheckTrust(_ mode: Mode) -> CheckTrust.Level {
        Validation.trust(modeID: mode.id, modeVersion: mode.version, checker: Validation.checker(judge: nil, modeID: mode.id),
                         results: validation[mode.id] ?? []).level
    }

    /// The code check's results when they were made for the mode's current version.
    func currentCheck(_ mode: Mode) -> CheckResults? {
        guard let results = checks[mode.id], results.modeVersion == mode.version, results.rate().total > 0 else { return nil }
        return results
    }
}

/// "3 of 40 (95% 2–20%)" for a check's rate.
enum AnalysisText {
    /// What a code check's rate means now: exact, validated, provisional or not validated.
    static func checkTrust(_ check: CodeCheck, trust: CheckTrust.Level, seen: Int, judged: Bool) -> String {
        if check.kind == .mechanical {
            return "Mechanical: the check is the definition, exact by construction, so its rate is the mode's frequency."
        }
        let text = switch trust {
        case .validated: "Heuristic — validated on the test set: reports show its rate corrected for its errors."
        case .provisional: "Heuristic — provisional (20+ test labels per class): its rate is shown beside \"seen in \(seen) notes\", never as the frequency."
        case .none, .exact: "Heuristic — not validated: until it is, the mode's frequency is \"seen in \(seen) notes\", not this rate."
        }
        return judged ? text + " The mode has a judge: reports go by the judge's validation, not this one." : text
    }

    /// "mechanical", "heuristic — validated", … for a table cell.
    static func checkKind(_ check: CodeCheck, trust: CheckTrust.Level) -> String {
        guard check.kind == .heuristic else { return "mechanical" }
        return switch trust {
        case .validated: "heuristic — validated"
        case .provisional: "heuristic — provisional"
        case .none, .exact: "heuristic — not validated"
        }
    }

    static func rate(_ results: CheckResults) -> String? {
        let rate = results.rate()
        guard rate.total > 0 else { return nil }
        return String(format: "%d of %d (95%% %.0f–%.0f%%)", rate.positive, rate.total, rate.interval.low * 100, rate.interval.high * 100)
    }

    static func percent(_ value: Double?) -> String {
        value.map { String(format: "%.0f%%", $0 * 100) } ?? "—"
    }

    /// "≈ $0.12" or why there is no estimate.
    static func cost(characters: Int, agent: LabAgent, records: [SendRecord]) -> String {
        guard let cost = SendLog.estimate(characters: characters, harness: agent.harness, model: agent.model, records: records) else {
            return "no estimate yet (no recorded calls of this model)"
        }
        return cost < 0.01 ? "≈ under $0.01" : String(format: "≈ $%.2f", cost)
    }

    /// "about 800 characters", "about 12K characters".
    static func size(_ characters: Int) -> String {
        characters < 1000 ? "about \(characters) characters" : "about \(characters / 1000)K characters"
    }

    /// "1 note", "3 notes".
    static func notes(_ count: Int) -> String { "\(count) \(count == 1 ? "note" : "notes")" }
}
