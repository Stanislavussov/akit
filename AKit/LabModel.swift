import AKitErrorAnalysis
import AKitFoundation
import AKitLab
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
        let (runs, tasks, batches, controlTasks, sends) = await Task.detached {
            () -> ([LabRun], [String: ReplayTask], [String: Batch], [String: ControlTask], Date?) in
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
            return (runs, tasks, batches, controlTasks, sends)
        }.value
        if runs != labRuns { labRuns = runs }
        if tasks != labTasks { labTasks = tasks }
        if batches != labBatches { labBatches = batches }
        if controlTasks != labControlTasks { labControlTasks = controlTasks }
        if sends != labSendsChanged { labSendsChanged = sends }
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
    func queueControlRuns(tasks: [ControlTask], setups: [ControlSetup], repeats: Int, environment: LabEnvironment?,
                          keep: Bool) async throws -> (runs: [LabRun], skipped: Int) {
        let akit = try await analysisAkit()
        let queued = try await Task.detached {
            try await ControlRuns.newControlRuns(tasks: tasks, setups: setups, repeats: repeats, environment: environment, keep: keep,
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
