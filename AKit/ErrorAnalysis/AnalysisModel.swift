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
        data.sinceLastChange = Bootstrap.sessionsSinceLastModeChange(labels, lastChange: try await store.history(limit: 1).first?.date)
        data.testSessions = ValidationStore(env: env).testSessions()
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
    func runCheck(_ mode: Mode) {
        guard let check = CodeChecks.check(for: mode.id) else { return }
        error = nil
        progress = "Checking indexed sessions…"
        let id = mode.id, version = mode.version
        Task {
            defer { progress = nil }
            do {
                try await run { env in
                    let results = try CheckRunner.run([check], modeVersions: [id: version], env: env) { done, total in
                        guard done % 25 == 0 else { return }
                        Task { @MainActor in self.progress = "Checking \(done) of \(total) sessions…" }
                    }
                    guard let rate = results.first?.rate(), rate.total > 0 else {
                        return "No indexed sessions to check. Import them on the Sessions screen or with akit sessions import."
                    }
                    return "Checked \(rate.total) sessions: the mode shows in \(rate.positive)."
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Where analysis model calls keep their work files.
    nonisolated static func workFolder(_ env: HarnessEnvironment) -> URL {
        AnalysisPaths(env: env).folder.appending(path: "work", directoryHint: .isDirectory)
    }
}

/// A session of a bootstrap reservation or a label as the readers want it.
extension BootstrapReservations.Entry {
    var summary: SessionSummary {
        NotesPipeline.Target(harness: sessionKey.hasPrefix("pi:") ? .pi : .claudeCode, file: URL(filePath: transcript)).summary
    }
}

struct AnalysisFailure: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// "3 of 40 (95% 2–20%)" for a check's rate.
enum AnalysisText {
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
        SendLog.estimate(characters: characters, harness: agent.harness, model: agent.model, records: records)
            .map { String(format: "≈ $%.2f", $0) } ?? "no estimate yet (no recorded calls of this model)"
    }
}
