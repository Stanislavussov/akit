import AKitFoundation
import AKitInsights
import AKitLab
import AKitModel
import Foundation

/// Queuing and doing error analysis batches (`docs/design/error-analysis.md`, "Batch run").
public enum Batches {
    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Two sessions at a time; 429s back off inside each call.
    public static let parallelism = 2

    /// Samples sessions from the index and queues a Lab run for them. The sample is drawn
    /// now, so the run and its report always name the same sessions.
    public static func new(filter: Sampling.Filter, size: Int = 20, notesAgent: LabAgent, matchingAgent: LabAgent? = nil,
                           language: LabLanguage? = nil, environment: LabEnvironment?, akit: URL, seed: UInt64? = nil,
                           env: HarnessEnvironment) async throws -> LabRun {
        guard let database = try AnalysisIndex.open(env: env) else {
            throw Failure(message: "The session index is empty. Run akit sessions import first.")
        }
        try SignalScanner.refresh(env: env)
        let signals = try AnalysisIndex.signals(database).mapValues(\.signals)
        let population = Sampling.population(try AnalysisIndex.sessions(database), filter: filter,
                                             reserved: BootstrapReservations(env: env).keys())
        guard !population.isEmpty else { throw Failure(message: "No sessions match (at least \(Sampling.minimumRequests) requests each).") }
        let seed = seed ?? UInt64(Date.now.timeIntervalSince1970 * 1000)
        var generator = SeededGenerator(seed: seed)
        let picks = Sampling.sample(population, signals: signals, size: size, using: &generator)
        let title = "Error analysis: \(filter.project.map { ($0 as NSString).lastPathComponent } ?? "all projects") · \(picks.count) sessions"
        return try await queue(picks: picks, filter: filter, size: size, seed: seed, fixed: false, title: title, notesAgent: notesAgent,
                               matchingAgent: matchingAgent, language: language, environment: environment, akit: akit, env: env)
    }

    /// A batch over fixed sessions (the labeled bootstrap sessions), each with inclusion 1.
    public static func newFixed(sessions: [(key: String, file: String)], title: String, notesAgent: LabAgent, matchingAgent: LabAgent? = nil,
                                language: LabLanguage? = nil, environment: LabEnvironment?, akit: URL, env: HarnessEnvironment) async throws -> LabRun {
        let picks = sessions.map {
            Sampling.Pick(sessionKey: $0.key, file: $0.file, inclusion: 1, sampling: "fixed", stratum: "fixed", projectID: nil)
        }
        guard !picks.isEmpty else { throw Failure(message: "No sessions to review.") }
        return try await queue(picks: picks, filter: Sampling.Filter(), size: picks.count, seed: 0, fixed: true, title: title,
                               notesAgent: notesAgent, matchingAgent: matchingAgent, language: language, environment: environment,
                               akit: akit, env: env)
    }

    static func queue(picks: [Sampling.Pick], filter: Sampling.Filter, size: Int, seed: UInt64, fixed: Bool, title: String,
                      notesAgent: LabAgent, matchingAgent: LabAgent?, language: LabLanguage?, environment: LabEnvironment?, akit: URL,
                      env: HarnessEnvironment) async throws -> LabRun {
        let id = RunSpec.newID()
        let language = language ?? LabSettings.load(env: env).reportLanguage
        let batch = Batch(runID: id, filter: filter, size: size, seed: seed, fixed: fixed, notesAgent: notesAgent,
                          matchingAgent: matchingAgent ?? notesAgent, language: language, sessions: picks.map { Batch.Session(pick: $0) })
        try BatchStore(env: env).save(batch)
        return try await queueRun(batchID: id, runID: id, title: title, environment: environment, akit: akit, env: env)
    }

    static func queueRun(batchID: String, runID: String, title: String, environment: LabEnvironment?, akit: URL,
                         env: HarnessEnvironment) async throws -> LabRun {
        let folder = env.homeDirectory
        let chosen: LabEnvironment
        if let environment { chosen = environment } else { chosen = await Launcher.suggested(for: folder, env: env) }
        var spec = RunSpec(id: runID, kind: .analysis, title: title, folder: folder.path, environment: chosen, akit: akit.path)
        spec.batch = batchID
        return try LabStore.create(spec, env: env)
    }

    /// Asks a running batch to stop after its current calls.
    public static func pause(_ batchID: String, env: HarnessEnvironment) throws {
        let store = BatchStore(env: env)
        guard var batch = store.load(batchID) else { throw Failure(message: "No batch \(batchID).") }
        batch.paused = true
        try store.save(batch)
    }

    /// Continues a paused batch from where it stopped, as a new run.
    public static func resume(_ batchID: String, retryErrors: Bool = false, environment: LabEnvironment?, akit: URL,
                              env: HarnessEnvironment) async throws -> LabRun {
        let store = BatchStore(env: env)
        guard var batch = store.load(batchID) else { throw Failure(message: "No batch \(batchID).") }
        batch.paused = false
        if retryErrors {
            // The old result of a failed session stays until the retry succeeds: notes files are
            // replaced only by a successful review.
            for index in batch.sessions.indices where batch.sessions[index].status == .error {
                batch.sessions[index].status = .pending
            }
        }
        guard batch.sessions.contains(where: { $0.status != .done }) || !batch.clustered else {
            throw Failure(message: "The batch is done; nothing to resume.")
        }
        try store.save(batch)
        let title = (retryErrors ? "Error analysis (retry errors)" : "Error analysis (resumed)") + ": \(batch.sessions.count) sessions"
        return try await queueRun(batchID: batchID, runID: RunSpec.newID(), title: title, environment: environment, akit: akit, env: env)
    }
}

/// One batch run in its terminal tab.
enum BatchRunner {
    /// The batch file is read and written by both workers; changes go through here.
    actor State {
        private(set) var batch: Batch
        let store: BatchStore

        init(batch: Batch, store: BatchStore) {
            self.batch = batch
            self.store = store
        }

        /// Pause is written into the file by another process (the app, `akit analysis batch
        /// pause`): read it before every write so it is never written over.
        private func save() {
            if let saved = store.load(batch.runID), saved.paused { batch.paused = true }
            try? store.save(batch)
        }

        func update(_ key: String, _ change: (inout Batch.Session) -> Void) {
            guard let index = batch.sessions.firstIndex(where: { $0.pick.sessionKey == key }) else { return }
            change(&batch.sessions[index])
            save()
        }

        /// The next pending session, unless the user asked to pause.
        func next() -> Batch.Session? {
            if let saved = store.load(batch.runID), saved.paused { batch.paused = true }
            guard !batch.paused, let index = batch.sessions.firstIndex(where: { $0.status == .pending }) else { return nil }
            batch.sessions[index].status = .running
            save()
            return batch.sessions[index]
        }

        func finish(_ change: (inout Batch) -> Void) {
            change(&batch)
            save()
        }
    }

    static func execute(_ run: LabRun, env: HarnessEnvironment, phase: @escaping @Sendable (RunState.Phase) -> Void,
                        out: @escaping @Sendable (String) -> Void) async throws -> RunResult {
        guard let batchID = run.spec.batch, var batch = BatchStore(env: env).load(batchID) else {
            throw LabWorker.Failure(message: "The run names no batch.")
        }
        // A session left running by a run that died starts again.
        for index in batch.sessions.indices where batch.sessions[index].status == .running { batch.sessions[index].status = .pending }
        // Starting is resuming: the run clears an earlier pause.
        batch.paused = false
        try BatchStore(env: env).save(batch)
        let state = State(batch: batch, store: BatchStore(env: env))

        // Account checks once at the start; each session's own origin is checked per call.
        let notesGate = try await SendGate.open(agent: batch.notesAgent, env: env)
        let matchingGate = batch.matchingAgent == batch.notesAgent ? notesGate : try await SendGate.open(agent: batch.matchingAgent, env: env)
        let modeStore = ModeStore(env: env)
        let modes = try await modeStore.list()
        var found: [String: [Exemplar]] = [:]
        for mode in Matching.routable(modes) { found[mode.id] = try modeStore.exemplars(of: mode.id) }
        let exemplars = found
        let config = NotesPipeline.Config(notes: batch.notesAgent, language: batch.language)
        let work = run.folder.appending(path: "work", directoryHint: .isDirectory)

        phase(.agent)
        out("Batch \(batchID): \(batch.sessions.count) sessions, \(Batches.parallelism) at a time, notes by \(batch.notesAgent.label).")
        let snapshot = batch
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<Batches.parallelism {
                group.addTask {
                    while !Cancellation.isCancelled, let session = await state.next() {
                        await process(session, batch: snapshot, config: config, modes: modes, exemplars: exemplars, notesGate: notesGate,
                                      matchingGate: matchingGate, state: state, work: work, env: env, out: out)
                    }
                }
            }
        }
        guard !Cancellation.isCancelled else { throw CancellationError() }
        batch = await state.batch

        let open = batch.sessions.contains { $0.status == .pending || $0.status == .running }
        if !batch.paused, !open, !batch.clustered {
            phase(.metrics)
            await finishBatch(state: state, modeStore: modeStore, gate: matchingGate, work: work, env: env, out: out)
            batch = await state.batch
        }
        let coverage = batch.coverage
        let failed = batch.sessions.filter { $0.status == .error }.count
        out("Batch \(batchID): \(coverage.done) of \(coverage.total) sessions done\(failed > 0 ? ", \(failed) failed" : "")\(batch.paused ? ", paused" : "").")
        return RunResult(batch: BatchProgress(done: coverage.done, failed: failed, total: coverage.total, paused: batch.paused))
    }

    /// notes → verifier → matching for one session. Any failure marks the session as an error
    /// with the reason; the earlier result of a retried session stays until this one succeeds.
    static func process(_ session: Batch.Session, batch: Batch, config: NotesPipeline.Config, modes: [Mode], exemplars: [String: [Exemplar]],
                        notesGate: SendGate, matchingGate: SendGate, state: State, work: URL, env: HarnessEnvironment,
                        out: @escaping @Sendable (String) -> Void) async {
        let key = session.pick.sessionKey
        let harness: HarnessID = key.hasPrefix("pi:") ? .pi : .claudeCode
        let target = NotesPipeline.Target(harness: harness, file: URL(filePath: session.pick.file))
        do {
            guard FileManager.default.fileExists(atPath: session.pick.file) else { throw Batches.Failure(message: "The session file is gone.") }
            let notes = try await NotesPipeline.review(target, config: config, notesGate: notesGate, verifierGate: notesGate, runID: batch.runID,
                                                       workFolder: work, env: env, out: { _ in })
            await state.update(key) { $0.steps = ["notes", "verifier"] }
            _ = try await Matching.route(notes, modes: modes, exemplars: exemplars, agent: batch.matchingAgent, gate: matchingGate,
                                         origin: notes.origin, runID: batch.runID, workFolder: work, env: env)
            await state.update(key) {
                $0.steps = ["notes", "verifier", "matching"]
                $0.status = .done
                $0.message = nil
            }
            out("✓ \(key): \(notes.outcome.title.lowercased()), \(notes.accepted.count) notes")
        } catch {
            let message = error is CancellationError ? "Cancelled." : error.localizedDescription
            await state.update(key) {
                $0.status = error is CancellationError ? .pending : .error
                $0.message = message
            }
            out("✗ \(key): \(message)")
        }
    }

    /// Once all sessions are done: code checks of active modes over the batch's sessions,
    /// clustering of the unmatched notes, seed activation by batch matches, and the notes for
    /// the precision spot check.
    static func finishBatch(state: State, modeStore: ModeStore, gate: SendGate, work: URL, env: HarnessEnvironment,
                            out: @escaping @Sendable (String) -> Void) async {
        let batch = await state.batch
        let keys = Set(batch.sessions.filter { $0.status == .done }.map(\.pick.sessionKey))
        let pool = NotesStore(env: env).all().filter { keys.contains($0.sessionKey) }
        do {
            var modes = try await modeStore.list()
            let checks = modes.filter { $0.status == .active }.compactMap { mode in CodeChecks.check(for: mode.id).map { (mode, $0) } }
            if !checks.isEmpty {
                try CheckRunner.run(checks.map(\.1), modeVersions: Dictionary(uniqueKeysWithValues: checks.map { ($0.0.id, $0.0.version) }), env: env)
                out("Code checks: \(checks.map(\.0.id).joined(separator: ", ")).")
            }
            // Seeds become active after matches in two independent batches.
            let matched = Set(Matching.seen(pool, modes: modes).byMode.keys)
            for mode in modes where matched.contains(mode.id) && mode.origin.isSeed {
                let updated = try await modeStore.recordBatchMatch(mode.id, runID: batch.runID)
                if updated.status == .active, mode.status != .active { out("Seed \(mode.name) is now active (matched in two batches).") }
            }
            modes = try await modeStore.list()
            let items = Clustering.unmatchedItems(pool, modes: modes)
            var created: [Mode] = []
            if !items.isEmpty {
                let candidates = try await Clustering.cluster(items, existing: modes, rejected: try await modeStore.rejectedNames(),
                                                              agent: batch.matchingAgent, gate: gate, runID: batch.runID, workFolder: work, env: env)
                created = try await Clustering.apply(candidates, store: modeStore, env: env)
                out("Clustering: \(created.count) candidate modes from \(items.count) unmatched notes.")
            }
            var generator = SeededGenerator(seed: batch.seed &+ 1)
            let spot = ReviewQueue.pickSpotCheck(pool, using: &generator)
            await state.finish {
                $0.clustered = true
                $0.candidates = created.map(\.id)
                $0.spotCheck = spot
            }
        } catch {
            out("The end of the batch failed: \(error.localizedDescription). Resume the batch to try again.")
        }
    }
}
