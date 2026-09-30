import AKitFoundation
import AKitLab
import AKitSessions
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
    func labProblem() async -> String? {
        guard let akit = Self.labAkit else {
            return "The akit command is not installed. In the AKit folder run: make install-cli"
        }
        let result = await ProcessRunner.run(akit, arguments: ["lab", "--help"],
                                             environment: HarnessEnvironment.current.variables, timeout: 10)
        guard result?.succeeded == true else {
            return "\(akit.tildePath) is older than this AKit and has no Lab. In the AKit folder run: make install-cli"
        }
        return nil
    }

    func reloadLab() async {
        let env = HarnessEnvironment.current
        let runs = await Task.detached { LabStore.list(env: env) }.value
        if runs != labRuns { labRuns = runs }
    }

    /// Queues a review of a Claude Code session and starts the queue.
    func queueReview(of session: SessionSummary, environment: LabEnvironment?) async throws -> LabRun {
        if let problem = await labProblem() { throw LabStore.Failure(message: problem) }
        guard let akit = Self.labAkit else { throw LabStore.Failure(message: "The akit command is not installed.") }
        let run = try await LabRuns.newReview(transcript: session.file, title: session.title, environment: environment,
                                              akit: akit, env: .current)
        try await startLabQueue()
        return run
    }

    /// Starts the next queued run when nothing runs, then reloads.
    func startLabQueue() async throws {
        defer { Task { await reloadLab() } }
        try await LabQueue.startNext(env: .current)
    }

    func suggestedEnvironment(for folder: URL) async -> LabEnvironment {
        await Launcher.suggested(for: folder, env: .current)
    }

    var labEnvironments: [LabEnvironment] { Launcher.available(env: .current) }

    func cancel(_ run: LabRun) async throws {
        try LabStore.cancel(run, env: .current)
        await reloadLab()
    }

    func remove(_ run: LabRun) async throws {
        try LabStore.remove(run)
        await reloadLab()
    }

    func showTab(of run: LabRun) async throws {
        guard let launch = run.launch else { return }
        try await Launcher.show(launch, env: .current)
    }
}
