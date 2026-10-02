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
    /// `notesAgent` nil: a reviewer of another model family than the sampled sessions', when
    /// the sending policy allows one (`defaultReviewer`); none allowed for all of them throws.
    public static func new(filter: Sampling.Filter, size: Int = 20, notesAgent: LabAgent?, matchingAgent: LabAgent? = nil,
                           language: LabLanguage? = nil, environment: LabEnvironment?, akit: URL, seed: UInt64? = nil,
                           env: HarnessEnvironment) async throws -> LabRun {
        guard let database = try AnalysisIndex.open(env: env) else {
            throw Failure(message: "The session index is empty. Run akit sessions import first.")
        }
        try SignalScanner.refresh(env: env)
        let signals = try AnalysisIndex.signals(database).mapValues(\.signals)
        let indexed = try AnalysisIndex.sessions(database)
        let population = Sampling.population(indexed, filter: filter,
                                             reserved: BootstrapReservations(env: env).keys().union(IndexedSessions.labKeys(env: env)))
        guard !population.isEmpty else { throw Failure(message: "No sessions match (at least \(Sampling.minimumRequests) requests each).") }
        let seed = seed ?? UInt64(Date.now.timeIntervalSince1970 * 1000)
        var generator = SeededGenerator(seed: seed)
        let hinted = Sampling.hintedStrata(pool: NotesStore(env: env).all(), batches: BatchStore(env: env).all(), sessions: indexed,
                                           signals: signals)
        let picks = Sampling.sample(population, signals: signals, size: size, hinted: hinted, using: &generator)
        let title = "Error analysis: \(filter.project.map { ($0 as NSString).lastPathComponent } ?? "all projects") · \(picks.count) sessions"
        let models = Dictionary(population.map { ($0.key, $0.model) }, uniquingKeysWith: { first, _ in first })
        let reviewer: LabAgent
        if let notesAgent {
            reviewer = notesAgent
        } else {
            reviewer = try await defaultReviewer(sessions: picks.map { pick in
                (models[pick.sessionKey] ?? nil, SessionNotes.origin(sessionKey: pick.sessionKey, transcript: pick.file))
            }, env: env)
        }
        return try await queue(picks: picks, filter: filter, size: size, seed: seed, fixed: false, title: title, notesAgent: reviewer,
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
        var batch = Batch(runID: id, filter: filter, size: size, seed: seed, fixed: fixed, notesAgent: notesAgent,
                          matchingAgent: matchingAgent ?? notesAgent, language: language, sessions: picks.map { Batch.Session(pick: $0) })
        // Before any model work: the estimate, and the monthly limit.
        batch.estimate = estimate(sessions: picks.count, agent: notesAgent, env: env)
        try SendLog.checkLimit(estimate: batch.estimate, settings: LabSettings.load(env: env), env: env)
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

    /// "≈" cost of reviewing `sessions` sessions with `agent`: the recorded cost of notes,
    /// verifier and matching per reviewed session with the same model so far, from each
    /// session's latest review (its last notes call and what came after it), so a re-reviewed
    /// session counts once. nil until a session was reviewed with it.
    /// The judges of active modes run on every session of a batch too: their recorded cost per
    /// call is added.
    public static func estimate(sessions: Int, agent: LabAgent, env: HarnessEnvironment) -> Double? {
        let all = SendLog.records(env: env)
        let records = all.filter {
            ["notes", "verifier", "matching"].contains($0.purpose) && $0.harness == agent.harness && $0.model == agent.model
                && $0.session != nil && $0.usage.cost != nil
        }
        let bySession = Dictionary(grouping: records, by: { $0.session ?? "" }).mapValues { records in
            let latest = records.filter { $0.purpose == "notes" }.map(\.date).max() ?? .distantPast
            return records.filter { $0.date >= latest }.compactMap(\.usage.cost).reduce(0, +)
        }
        guard !bySession.isEmpty else { return nil }
        var perSession = bySession.values.reduce(0, +) / Double(bySession.count)
        // Batches run the judges of active modes only.
        let active = Set((JSONFile.read([Mode].self, from: AnalysisPaths(env: env).modesFile) ?? [])
            .filter { $0.isCurrent && $0.status == .active }.map(\.id))
        for (modeID, judge) in ValidationStore(env: env).judges() where active.contains(modeID) {
            let costs = all.filter { $0.purpose == "judge" && $0.harness == judge.harness && $0.model == judge.model }.compactMap(\.usage.cost)
            if !costs.isEmpty { perSession += costs.reduce(0, +) / Double(costs.count) }
        }
        return perSession * Double(sessions)
    }

    /// How many sessions a batch with this filter would review: the sample is at most `size`.
    public static func sampleSize(filter: Sampling.Filter, size: Int, env: HarnessEnvironment) -> Int {
        guard let database = try? AnalysisIndex.open(env: env), let indexed = try? AnalysisIndex.sessions(database) else { return 0 }
        let population = Sampling.population(indexed, filter: filter,
                                             reserved: BootstrapReservations(env: env).keys().union(IndexedSessions.labKeys(env: env)))
        return min(size, population.count)
    }

    /// "≈ $1.20 for 20 sessions…", shown before any model work.
    public static func estimateText(sessions: Int, agent: LabAgent, env: HarnessEnvironment) -> String {
        guard let estimate = estimate(sessions: sessions, agent: agent, env: env) else {
            return "\(sessions) sessions; no estimate yet: no session was reviewed with \(agent.harness.title) · \(agent.model) before."
        }
        return String(format: "%d sessions, ≈ $%.2f at the recorded cost per reviewed session so far (judges included).", sessions, estimate)
    }

    /// The default reviewer for sampled sessions: Claude Code or Pi with your settings, a model
    /// of another family than the one that ran most of them first, and only one the sending
    /// policy allows for the origin of every session. Throws, before anything is sent, when
    /// neither is allowed for all of them.
    public static func defaultReviewer(sessions: [(model: String?, origin: SendOrigin)], env: HarnessEnvironment) async throws -> LabAgent {
        var claude = LabRuns.defaultAgent(.claudeCode, env: env)
        claude.mode = .call
        var candidates = [claude]
        if env.findExecutable("pi") != nil {
            var pi = LabRuns.defaultAgent(.pi, env: env)
            pi.mode = .call
            if !pi.model.isEmpty { candidates.append(pi) }
        }
        let families = Dictionary(grouping: sessions.compactMap(\.model).map(vendor), by: { $0 })
        if let main = families.max(by: { $0.value.count < $1.value.count })?.key {
            candidates = candidates.filter { vendor($0.model) != main } + candidates.filter { vendor($0.model) == main }
        }
        let origins = Set(sessions.map(\.origin))
        var refusals: [String] = []
        for agent in candidates {
            do {
                let gate = try await SendGate.open(agent: agent, env: env)
                if let refused = origins.map(gate.decide).first(where: { !$0.allowed }) {
                    refusals.append("\(agent.harness.title): \(refused.reason)")
                } else {
                    return agent
                }
            } catch {
                refusals.append("\(agent.harness.title): \(error.localizedDescription)")
            }
        }
        throw Failure(message: "No reviewer may get every sampled session. " + refusals.joined(separator: " ")
                          + " Pick the reviewer yourself, or narrow the sessions.")
    }

    /// The company behind a model, from its sampling family: `opus`, `claude-sonnet-5-5` → anthropic.
    static func vendor(_ model: String) -> String {
        let family = Sampling.family(model.lowercased())
        if family.hasPrefix("claude") || ["opus", "sonnet", "haiku"].contains(family) { return "anthropic" }
        // `gpt-6.1-sol`, and `o3`, `o4-mini` (family `o`).
        if family == "gpt" || family == "o" { return "openai" }
        if family == "gemini" { return "google" }
        return family
    }

    /// Asks a running batch to stop after its current calls.
    public static func pause(_ batchID: String, env: HarnessEnvironment) throws {
        try BatchStore(env: env).update(batchID) { $0.paused = true }
    }

    /// Continues a paused batch from where it stopped, as a new run.
    public static func resume(_ batchID: String, retryErrors: Bool = false, environment: LabEnvironment?, akit: URL,
                              env: HarnessEnvironment) async throws -> LabRun {
        guard let current = BatchStore(env: env).load(batchID) else { throw Failure(message: "No batch \(batchID).") }
        guard current.sessions.contains(where: { $0.status != .done }) || current.unfinished else {
            throw Failure(message: "The batch is done; nothing to resume.")
        }
        let batch = try BatchStore(env: env).update(batchID) { batch in
            batch.paused = false
            batch.pauseReason = nil
            if retryErrors {
                // The old result of a failed session stays until the retry succeeds: notes files
                // are replaced only by a successful review.
                for index in batch.sessions.indices where batch.sessions[index].status == .error {
                    batch.sessions[index].status = .pending
                }
            }
        }
        let title = (retryErrors ? "Error analysis (retry errors)" : "Error analysis (resumed)") + ": \(batch.sessions.count) sessions"
        return try await queueRun(batchID: batchID, runID: RunSpec.newID(), title: title, environment: environment, akit: akit, env: env)
    }
}

/// One batch run in its terminal tab.
enum BatchRunner {
    static func isAuthorizationError(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("401") || lower.contains("403") || lower.contains("unauthorized") || lower.contains("authentication")
            || lower.contains("not logged in") || lower.contains("forbidden")
    }

    /// The batch file is read and written by both workers; changes go through here.
    actor State {
        private(set) var batch: Batch
        let store: BatchStore
        /// The pause as last read from the file: a pause this worker sets differs from it.
        private var filePause: (paused: Bool, reason: String?)

        init(batch: Batch, store: BatchStore) {
            self.batch = batch
            self.store = store
            filePause = (batch.paused, batch.pauseReason)
        }

        /// Pause and resume are written into the file by another process (the app, `akit
        /// analysis batch pause|resume`): read it before every write so neither is written over.
        /// Only a pause this worker set itself (after an account problem) is added.
        private func save() {
            let mine = batch
            let pausing = mine.paused && !filePause.paused
            let ownReason = mine.pauseReason != filePause.reason ? mine.pauseReason : nil
            if let saved = try? store.update(mine.runID, { disk in
                let paused = disk.paused || pausing
                let reason = paused ? disk.pauseReason ?? ownReason : nil
                disk = mine
                disk.paused = paused
                disk.pauseReason = reason
            }) {
                sync(saved)
            }
        }

        private func sync(_ saved: Batch) {
            batch.paused = saved.paused
            batch.pauseReason = saved.pauseReason
            filePause = (saved.paused, saved.pauseReason)
        }

        func update(_ key: String, _ change: (inout Batch.Session) -> Void) {
            guard let index = batch.sessions.firstIndex(where: { $0.pick.sessionKey == key }) else { return }
            change(&batch.sessions[index])
            save()
        }

        /// The next pending session, unless the user asked to pause.
        func next() -> Batch.Session? {
            if let saved = store.load(batch.runID) { sync(saved) }
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
        // A batch paused while its run was still queued stays paused: Resume clears a pause.
        if batch.paused {
            out("Batch \(batchID) is paused; resume it to go on.")
            let coverage = batch.coverage
            return RunResult(batch: BatchProgress(done: coverage.done, failed: batch.sessions.filter { $0.status == .error }.count,
                                                  total: coverage.total, paused: true))
        }
        // A session left running by a run that died starts again.
        batch = try BatchStore(env: env).update(batchID) { batch in
            for index in batch.sessions.indices where batch.sessions[index].status == .running { batch.sessions[index].status = .pending }
        }
        let state = State(batch: batch, store: BatchStore(env: env))

        // Account checks once at the start; each session's own origin is checked per call.
        let notesGate = try await SendGate.open(agent: batch.notesAgent, env: env)
        let matchingGate = batch.matchingAgent == batch.notesAgent ? notesGate : try await SendGate.open(agent: batch.matchingAgent, env: env)
        let modeStore = ModeStore(env: env)
        let modes = try await modeStore.list()
        var found: [String: [Exemplar]] = [:]
        for mode in Matching.routable(modes) { found[mode.id] = try modeStore.exemplars(of: mode.id) }
        let exemplars = found
        // Judges of active modes run on every session of the batch, as part of it.
        var judged: [(mode: Mode, agent: LabAgent, gate: SendGate)] = []
        for (id, judge) in ValidationStore(env: env).judges() {
            guard let mode = modes.first(where: { $0.id == id && $0.isCurrent && $0.status == .active }) else { continue }
            judged.append((mode, judge, judge == batch.notesAgent ? notesGate : try await SendGate.open(agent: judge, env: env)))
        }
        let judges = judged
        let config = NotesPipeline.Config(notes: batch.notesAgent, language: batch.language)
        let work = run.folder.appending(path: "work", directoryHint: .isDirectory)

        phase(.agent)
        out("Batch \(batchID): \(batch.sessions.count) sessions, \(Batches.parallelism) at a time, notes by \(batch.notesAgent.label).")
        let snapshot = batch
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<Batches.parallelism {
                group.addTask {
                    while !Cancellation.isCancelled, let session = await state.next() {
                        await process(session, batch: snapshot, config: config, modes: modes, exemplars: exemplars, judges: judges,
                                      notesGate: notesGate, matchingGate: matchingGate, state: state, work: work, env: env, out: out)
                    }
                }
            }
        }
        guard !Cancellation.isCancelled else { throw CancellationError() }
        batch = await state.batch

        let open = batch.sessions.contains { $0.status == .pending || $0.status == .running }
        if !batch.paused, !open, batch.unfinished {
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
                        judges: [(mode: Mode, agent: LabAgent, gate: SendGate)], notesGate: SendGate, matchingGate: SendGate, state: State, work: URL, env: HarnessEnvironment,
                        out: @escaping @Sendable (String) -> Void) async {
        let key = session.pick.sessionKey
        let harness = SessionKey.harness(of: key)
        let target = NotesPipeline.Target(harness: harness, file: URL(filePath: session.pick.file))
        do {
            guard FileManager.default.fileExists(atPath: session.pick.file) else { throw Batches.Failure(message: "The session file is gone.") }
            let notes = try await NotesPipeline.review(target, config: config, notesGate: notesGate, verifierGate: notesGate, runID: batch.runID,
                                                       workFolder: work, env: env, out: { _ in })
            await state.update(key) { $0.steps = ["notes", "verifier"] }
            _ = try await Matching.route(notes, modes: modes, exemplars: exemplars, agent: batch.matchingAgent, gate: matchingGate,
                                         origin: notes.origin, runID: batch.runID, workFolder: work, env: env)
            for judge in judges {
                try await Judges.run(mode: judge.mode, sessions: [(key, session.pick.file)], agent: judge.agent, gate: judge.gate,
                                     runID: batch.runID, workFolder: work, env: env)
            }
            await state.update(key) {
                $0.steps = ["notes", "verifier", "matching"] + (judges.isEmpty ? [] : ["checks"])
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
            // After an authorization error the accounts are checked again; one that can't be
            // determined, or that changed, stops the batch.
            if isAuthorizationError(message) {
                let gates: [(agent: LabAgent, gate: SendGate)] = [(batch.notesAgent, notesGate), (batch.matchingAgent, matchingGate)]
                    + judges.map { ($0.agent, $0.gate) }
                if let reason = await accountProblem(gates, env: env) {
                    await state.finish {
                        $0.paused = true
                        $0.pauseReason = reason
                    }
                    out("Paused: \(reason)")
                }
            }
        }
    }

    /// Why the batch can't go on: the account of an agent it sends to (notes and verifier,
    /// matching, judges) can't be determined any more, or isn't the one checked at the start.
    static func accountProblem(_ gates: [(agent: LabAgent, gate: SendGate)], env: HarnessEnvironment) async -> String? {
        var checked = Set<LabAgent>()
        for (agent, start) in gates where checked.insert(agent).inserted {
            do {
                let now = try await SendGate.open(agent: agent, env: env).destination
                if !now.matches(start.destination) { return "The account of \(agent.label) changed to \(now.label) during the batch." }
            } catch {
                return error.localizedDescription
            }
        }
        return nil
    }

    /// Once all sessions are done: code checks of active modes over the batch's sessions,
    /// clustering of the unmatched notes, seed activation by batch matches, and the notes for
    /// the precision spot check.
    static func finishBatch(state: State, modeStore: ModeStore, gate: SendGate, work: URL, env: HarnessEnvironment,
                            out: @escaping @Sendable (String) -> Void) async {
        let batch = await state.batch
        let finished = Set(batch.finishedSessions ?? [])
        let keys = Set(batch.sessions.filter { $0.status == .done && !finished.contains($0.pick.sessionKey) }.map(\.pick.sessionKey))
        let pool = NotesStore(env: env).all().filter { keys.contains($0.sessionKey) }
        do {
            var modes = try await modeStore.list()
            let checked = try AnalysisUpkeep.runChecks(of: modes, env: env)
            if !checked.isEmpty { out("Code checks: \(checked.joined(separator: ", ")).") }
            // Seeds become active after matches in two independent batches: only this batch's own
            // routes count (not ones reused from an earlier review), with the sessions behind them.
            var matched: [String: Set<String>] = [:]
            for notes in pool {
                for route in Matching.currentRoutes(notes).values where route.runID == batch.runID {
                    if let mode = route.modeID { matched[ModeStore.resolve(mode, in: modes), default: []].insert(notes.sessionKey) }
                }
            }
            for mode in modes where matched[mode.id] != nil && mode.origin.isSeed {
                let updated = try await modeStore.recordBatchMatch(mode.id, runID: batch.runID, sessions: matched[mode.id]?.sorted() ?? [])
                if updated.status == .active, mode.status != .active { out("Seed \(mode.name) is now active (matched in two batches).") }
            }
            // Candidates this batch's matching found again become modes, before new ones are made.
            for mode in try await Clustering.promoteCandidates(store: modeStore, env: env) { out("Candidate \(mode.name) is now a mode.") }
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
                $0.candidates += created.map(\.id)
                $0.spotCheck += spot
                $0.finishedSessions = (($0.finishedSessions ?? []) + keys.sorted())
            }
        } catch {
            out("The end of the batch failed: \(error.localizedDescription). Resume the batch to try again.")
        }
    }
}
