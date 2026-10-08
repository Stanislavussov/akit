import AKitBrain
import AKitErrorAnalysis
import AKitFoundation
import AKitLab
import AKitModel
import AKitSessions
import AppKit
import Foundation

/// Lab: queuing runs, starting them in a terminal, reading their folders.
extension AppModel {
    /// The `akit` a run's tab runs. A development build uses its own worktree's debug build
    /// when there is one (so the tab runs the same code); otherwise `~/.local/bin/akit`.
    static var labAkit: URL? {
        let fm = FileManager.default
        if !BuildInfo.current.isProduction, let source = BuildInfo.current.sourceURL {
            let debug = source.appending(path: "AKitCore/.build/debug/akit")
            if fm.isExecutableFile(atPath: debug.path) { return debug }
        }
        let installed = HarnessEnvironment.current.homeDirectory.appending(path: ".local/bin/akit")
        return fm.isExecutableFile(atPath: installed.path) ? installed : nil
    }

    /// Why runs can't start from AKit, or nil: no akit command, or one too old for Lab.
    /// `option`: an `akit lab` option the run needs (an older akit would ignore what it asks for).
    func labProblem(needing option: String? = nil) async -> String? {
        guard let akit = Self.labAkit else {
            return "The akit command is not installed. In the AKit folder run: make install-cli"
        }
        let result = await ProcessRunner.run(akit, arguments: ["lab", "--help"],
                                             environment: HarnessEnvironment.current.variables, timeout: 10)
        guard let result, result.succeeded, option.map(result.output.contains) ?? true else {
            return "\(akit.tildePath) is older than this AKit. In the AKit folder run: make install-cli"
        }
        return nil
    }

    func reloadLab() async {
        let env = HarnessEnvironment.current
        let known = labSendsChanged
        let logged = labRunCosts
        let unpricedBefore = labUnpricedRuns
        let (runs, tasks, batches, controlTasks, sends, costs, checked) = await Task.detached {
            () -> ([LabRun], [String: ReplayTask], [String: Batch], [String: ControlTask], Date?, [String: RunCost]?, Set<String>) in
            let runs = LabStore.list(env: env)
            var tasks: [String: ReplayTask] = [:]
            for commit in Set(runs.compactMap(\.spec.commit)) { tasks[commit] = ReplayTasks.cached(commit, env: env) }
            // Batch files change while a batch runs (progress per session), run.json doesn't.
            let store = BatchStore(env: env)
            var batches: [String: Batch] = [:]
            for id in Set(runs.compactMap(\.spec.batch)) { batches[id] = store.load(id) }
            var controlTasks: [String: ControlTask] = [:]
            for id in Set(runs.compactMap(\.spec.controlTask)) { controlTasks[id] = ControlTasks.load(id, env: env) }
            let sends = try? SendLog.file(env: env).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            // The log grows with every call: read it again only when it changed.
            var costs = sends == known ? nil : SendLog.runCosts(SendLog.records(env: env))
            // Runs older than the send log: their own agent log, read once when they have ended.
            var unpriced = unpricedBefore
            let current = costs ?? logged
            let missing = runs.filter { !$0.isActive && current[$0.id] == nil && !unpriced.contains($0.id) }
            if !missing.isEmpty {
                var filled = current
                for run in missing {
                    if let cost = RunCost.fromAgentLog(run.folder.appending(path: "agent.jsonl")) {
                        filled[run.id] = cost
                    } else {
                        unpriced.insert(run.id)
                    }
                }
                costs = filled
            }
            return (runs, tasks, batches, controlTasks, sends, costs, unpriced)
        }.value
        labUnpricedRuns = checked
        if runs != labRuns { labRuns = runs }
        if tasks != labTasks { labTasks = tasks }
        if batches != labBatches { labBatches = batches }
        if controlTasks != labControlTasks { labControlTasks = controlTasks }
        if sends != labSendsChanged { labSendsChanged = sends }
        if let costs, costs != labRunCosts { labRunCosts = costs }
    }

    /// Keeps the Lab badge and the queue current while AKit runs: reloads the runs, and
    /// starts the next queued one when nothing runs (a worker that died can't do it). After a
    /// start fails, it waits for the user (Start) instead of failing run after run.
    func watchLab() async {
        while !Task.isCancelled {
            await reloadLab()
            let waiting = labRuns.contains { $0.status == .queued && $0.launch == nil }
            if waiting, !labAutoStartPaused, !labRuns.contains(where: \.isActive), Self.labAkit != nil {
                do {
                    try await LabQueue.startNext(env: .current)
                } catch {
                    labAutoStartPaused = true
                }
                await reloadLab()
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// Queues a review of a Claude Code session by `agent` and starts the queue.
    func queueReview(of session: SessionSummary, agent: LabAgent, environment: LabEnvironment?) async throws -> LabRun {
        if let problem = await labProblem(needing: "--mode") { throw LabStore.Failure(message: problem) }
        guard let akit = Self.labAkit else { throw LabStore.Failure(message: "The akit command is not installed.") }
        let run = try await LabRuns.newReview(transcript: session.file, harness: session.harness, title: session.title, agent: agent,
                                              environment: environment, akit: akit, env: .current)
        // Queued either way; a start that fails marks the run with the reason.
        try? await startLabQueue()
        return run
    }

    /// Queues repeats × setups replays of a commit and starts the queue.
    func queueReplays(commit: String, repo: URL, setups: [LabSetup], repeats: Int, environment: LabEnvironment?,
                      keep: Bool) async throws -> [LabRun] {
        if let problem = await labProblem() { throw LabStore.Failure(message: problem) }
        guard let akit = Self.labAkit else { throw LabStore.Failure(message: "The akit command is not installed.") }
        let runs = try await LabRuns.newReplays(commit: commit, repo: repo, setups: setups, repeats: repeats,
                                                environment: environment, keep: keep, akit: akit, env: .current)
        try? await startLabQueue()
        return runs
    }

    /// Samples sessions of the index for an error analysis batch (`akit lab new analysis`), not
    /// queued yet. `notesAgent` nil: a reviewer of another model family, when the sending policy
    /// allows one; sessions it may not get are left out.
    func drawAnalysis(filter: Sampling.Filter, size: Int, notesAgent: LabAgent?) async throws -> Batches.Sample {
        try await Task.detached {
            try await Batches.draw(filter: filter, size: size, notesAgent: notesAgent, env: .current)
        }.value
    }

    /// Queues a drawn sample as a batch.
    func queueAnalysis(_ sample: Batches.Sample, matchingAgent: LabAgent?, language: LabLanguage,
                       environment: LabEnvironment?) async throws -> LabRun {
        let akit = try await analysisAkit()
        let run = try await Task.detached {
            try await Batches.queue(sample, matchingAgent: matchingAgent, language: language, environment: environment, akit: akit,
                                    env: .current)
        }.value
        try? await startLabQueue()
        return run
    }

    /// A batch over the labeled bootstrap sessions (`akit analysis bootstrap notes`).
    func queueBootstrapNotes(_ sessions: [(key: String, file: String)], agent: LabAgent, environment: LabEnvironment?) async throws -> LabRun {
        let akit = try await analysisAkit()
        let run = try await Task.detached {
            try await Batches.newFixed(sessions: sessions, title: "Bootstrap: model notes on \(sessions.count) labeled sessions",
                                       notesAgent: agent, environment: environment, akit: akit, env: .current)
        }.value
        try? await startLabQueue()
        return run
    }

    /// Asks a running batch to stop after its current calls (`akit analysis batch pause`).
    func pauseBatch(_ id: String) async throws {
        try await Task.detached { try Batches.pause(id, env: .current) }.value
        await reloadLab()
    }

    /// Continues a batch as a new run, or reruns only its failed sessions (`akit analysis batch resume`).
    /// `environment` nil: the one suggested, as for a new batch.
    func resumeBatch(_ id: String, retryErrors: Bool, environment: LabEnvironment?) async throws -> LabRun {
        let akit = try await analysisAkit()
        let run = try await Task.detached {
            try await Batches.resume(id, retryErrors: retryErrors, environment: environment, akit: akit, env: .current)
        }.value
        try? await startLabQueue()
        return run
    }

    /// Queues control cells (`akit analysis control run`): repeats × tasks × setups.
    /// `toQueue` and `maxCost`: what the user confirmed; refused when more cells would run now, or
    /// a newer cell recorded a higher cost.
    func queueControlRuns(tasks: [ControlTask], setups: [ControlSetup], repeats: Int, toQueue: Int, maxCost: Double?,
                          environment: LabEnvironment?, keep: Bool) async throws -> (runs: [LabRun], skipped: Int) {
        let akit = try await analysisAkit()
        try await checkHiddenTests(tasks)
        // Cells in AKit's own repository get denied commands; an older akit would ignore them.
        if tasks.contains(where: { !ControlSetup.defaultDenied(repo: $0.mainFolder).isEmpty }),
           let problem = await labProblem(needing: "denied commands") { throw LabStore.Failure(message: problem) }
        let queued = try await Task.detached {
            let counts = ControlRuns.plan(tasks: tasks, setups: setups, repeats: repeats, env: .current)
            if counts.toQueue > toQueue {
                throw LabStore.Failure(message: "\(counts.toQueue) cells would run now, not the \(toQueue) you confirmed; check it again.")
            }
            let estimate = ControlRuns.estimate(cells: counts.toQueue, agent: setups[0].agent, repo: tasks.first?.mainFolder, env: .current)
            if let maxCost, let high = estimate.high, high > maxCost {
                throw LabStore.Failure(message: String(format: "A cell recorded a higher cost since the estimate: its high end is now $%.2f, "
                                                           + "above the $%.2f you confirmed; check it again.", high, maxCost))
            }
            return try await ControlRuns.newControlRuns(tasks: tasks, setups: setups, repeats: repeats, environment: environment, keep: keep,
                                                        akit: akit, env: .current)
        }.value
        if !queued.runs.isEmpty { try? await startLabQueue() }
        return queued
    }

    /// Cells of a commit task: an older akit can't read the task and would stop with an error.
    private func checkHiddenTests(_ tasks: [ControlTask]) async throws {
        guard tasks.contains(where: { if case .hiddenTests = $0.oracle { true } else { false } }) else { return }
        if let problem = await labProblem(needing: "hidden tests") { throw LabStore.Failure(message: problem) }
    }

    /// Brain layers a layer eval or a layer set can take: every one but core (the home folder's layer).
    var evaluableLayers: [String] { (brain?.layers.map(\.name) ?? []).filter { $0 != "core" }.sorted() }

    /// The fields of a layer and the layers it requires, as the render asks them.
    func layerFields(of layer: String) -> [LayerField] {
        let byName = Dictionary((brain?.layers ?? []).map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        guard byName[layer] != nil else { return [] }
        return Brain.requiredClosure(of: layer, in: byName).sorted().flatMap { byName[$0]?.fields ?? [] }
    }

    /// A brain layer as an eval's setups for these tasks (`akit analysis control run --layer`):
    /// rendered from the brain with the layer set's answers, checked against each task's base
    /// commit. Writes nothing.
    func prepareLayerEval(layer: String, tasks: [ControlTask], agent: LabAgent, sanity: Bool) async throws -> LayerSetups.Prepared {
        let brain = brainRoot, projects = projectsRoot, store = projectStore, homeSkills = claudeHomeSkills
        return try await Task.detached {
            try await LayerSetups.prepare(layer: layer, tasks: tasks, answers: LayerSets.load(layer, env: .current)?.answers ?? [:], agent: agent,
                                          sanity: sanity, homeSkills: homeSkills, brain: brain, store: store, projectsRoot: projects, env: .current)
        }.value
    }

    /// Claude Code's skills outside any project: a layer skill with one of these names overlaps.
    private var claudeHomeSkills: Set<String> {
        Set(skills.filter { skill in
            guard skill.visibleTo.contains(.claudeCode) else { return false }
            if case .project = skill.scope { return false }
            return true
        }.map(\.name))
    }

    /// An eval of the layer's set (Brain → layer → Evaluate…, `akit analysis control
    /// evaluate`): rendered, its cells counted and their cost and time estimated. Writes nothing.
    func planLayerEval(layer: String, agent: LabAgent, repeats: Int, sanity: Bool, continuing: String?,
                       denied: [String]?) async throws -> LayerEvals.EvalPlan {
        let brain = brainRoot, projects = projectsRoot, store = projectStore, homeSkills = claudeHomeSkills
        return try await Task.detached {
            try await LayerEvals.plan(layer: layer, agent: agent, repeats: repeats, sanity: sanity, continuing: continuing, denied: denied,
                                      homeSkills: homeSkills, brain: brain, store: store, projectsRoot: projects, env: .current)
        }.value
    }

    /// Queues a planned eval, or only its calibration cell: the monthly limit first, then the
    /// eval folder, then the cells.
    /// `maxCost`: the high end of the estimate the user confirmed; a higher one refuses.
    func queueLayerEval(_ plan: LayerEvals.EvalPlan, calibrateOnly: Bool, maxCost: Double?, environment: LabEnvironment?,
                        keep: Bool) async throws -> (runs: [LabRun], skipped: Int) {
        try await checkLayerAkit(plan.prepared)
        guard let akit = Self.labAkit else { throw LabStore.Failure(message: "The akit command is not installed.") }
        let queued = try await Task.detached {
            try await LayerEvals.queue(plan, calibrateOnly: calibrateOnly, maxCost: maxCost, environment: environment, keep: keep, akit: akit, env: .current)
        }.value
        if !queued.runs.isEmpty { try? await startLabQueue() }
        return queued
    }

    /// An older akit would run layer cells without the layer, or without their denied commands.
    private func checkLayerAkit(_ prepared: LayerSetups.Prepared) async throws {
        if let problem = await labProblem(needing: "brain layer") { throw LabStore.Failure(message: problem) }
        if !prepared.denied.isEmpty, let problem = await labProblem(needing: "denied commands") { throw LabStore.Failure(message: problem) }
        try await checkHiddenTests(prepared.runnable)
    }

    /// Queues a prepared layer eval (Run Cells… with a brain layer) as Evaluate… does
    /// (`LayerEvals.queue`): counted and estimated again under the eval's lock, refused when
    /// more cells would run than `toQueue` or the high end is above the confirmed `maxCost`, the
    /// monthly limit, the eval folder, then the cells.
    func queueLayerCells(_ prepared: LayerSetups.Prepared, repeats: Int, toQueue: Int, maxCost: Double, environment: LabEnvironment?,
                         keep: Bool) async throws -> (runs: [LabRun], skipped: Int) {
        try await checkLayerAkit(prepared)
        guard let akit = Self.labAkit else { throw LabStore.Failure(message: "The akit command is not installed.") }
        let queued = try await Task.detached {
            try await LayerEvals.queue(prepared, repeats: repeats, toQueue: toQueue, maxCost: maxCost, environment: environment, keep: keep,
                                       akit: akit, env: .current)
        }.value
        if !queued.runs.isEmpty { try? await startLabQueue() }
        return queued
    }

    /// The akit a batch or control run's tab runs; it must know the run kinds error analysis adds.
    private func analysisAkit() async throws -> URL {
        if let problem = await labProblem(needing: "analysis") { throw LabStore.Failure(message: problem) }
        guard let akit = Self.labAkit else { throw LabStore.Failure(message: "The akit command is not installed.") }
        return akit
    }

    func replayCandidates(in repo: URL) async -> [ReplayTasks.Candidate] {
        await ReplayTasks.candidates(repo: repo, env: .current)
    }

    func replayDraft(commit: String, repo: URL) async throws -> ReplayTasks.Draft {
        try await ReplayTasks.draft(commit: commit, repo: repo, env: .current)
    }

    /// Checks a commit as a task now (two builds, a few minutes): the Lab screen's
    /// `akit lab task`. `progress` gets the last line printed.
    func checkTask(_ draft: ReplayTasks.Draft, progress: @escaping @MainActor (String) -> Void) async throws -> ReplayTask {
        try await Task.detached(priority: .userInitiated) {
            try await ReplayTasks.validate(draft, env: .current) { line in Task { @MainActor in progress(line) } }
        }.value
    }

    var defaultModelAndEffort: (model: String, effort: String) { LabRuns.defaultModelAndEffort(env: .current) }

    func defaultAgent(_ harness: LabHarness) -> LabAgent { LabRuns.defaultAgent(harness, env: .current) }

    /// The reviewer a session starts with; reads a Pi session's file, off the main actor.
    func ownReviewer(of session: SessionSummary) async -> LabAgent {
        let file = session.file, harness = session.harness
        return await Task.detached { LabRuns.ownReviewer(of: file, harness: harness, env: .current) }.value
    }

    /// Harnesses that can write a review: the installed ones.
    var labHarnesses: [LabHarness] {
        LabHarness.allCases.filter { HarnessEnvironment.current.findExecutable($0.command) != nil }
    }

    func labModels(for harness: LabHarness) async -> [String] {
        await LabRuns.models(for: harness, env: .current)
    }

    /// Starts the next queued run when nothing runs, then reloads.
    func startLabQueue() async throws {
        defer { Task { await reloadLab() } }
        labAutoStartPaused = false
        do {
            try await LabQueue.startNext(env: .current)
        } catch {
            labAutoStartPaused = true
            throw error
        }
    }

    func suggestedEnvironment(for folder: URL) async -> LabEnvironment {
        await Launcher.suggested(for: folder, env: .current)
    }

    var labEnvironments: [LabEnvironment] { Launcher.available(env: .current) }

    func cancel(_ run: LabRun) async throws {
        try await LabStore.cancel(run, env: .current)
        await reloadLab()
    }

    func remove(_ run: LabRun) async throws {
        try LabStore.remove(run)
        await reloadLab()
    }

    /// Selects the run's tab in Orca or herdr, then brings Orca to the front (switching a
    /// tab alone leaves AKit on top, so nothing seems to happen).
    func showTab(of run: LabRun) async throws {
        guard let launch = run.launch else { return }
        try await Launcher.show(launch, env: .current)
        if let app = Launcher.app(for: launch.environment, env: .current) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
        }
    }
}
