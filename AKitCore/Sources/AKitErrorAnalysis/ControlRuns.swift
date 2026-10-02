import AKitFoundation
import AKitLab
import AKitSessions
import Foundation

/// Control cells as Lab runs (`docs/design/error-analysis.md`, "Controlled evals"): queued
/// as repeats × tasks × setups, run in isolated clones by `ControlCell`, judged here.
public enum ControlRuns {
    /// The cell key: the done key of the task (input) and of the setup with the base commit
    /// and the repeat number (config). The setup's name is a label, not part of what runs.
    public static func cellKey(task: ControlTask, setup: ControlSetup, repeatIndex: Int) -> String {
        struct Input: Encodable {
            let id: String
            let prompt: String
            let oracle: ControlTask.Oracle
            let successMode: Bool
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let input = (try? encoder.encode(Input(id: task.id, prompt: task.prompt, oracle: task.oracle,
                                               successMode: task.successMode == true))) ?? Data()
        let config = StepConfig(step: "control", harness: setup.agent.harness.rawValue, model: setup.agent.model, extra: [
            "effort": setup.agent.effort, "base": task.base, "repeat": String(repeatIndex),
            "patchFile": setup.patch?.file ?? "", "patchText": setup.patch?.text ?? "", "readOnly": setup.readOnly ? "1" : "0",
        ])
        return DoneKey.make(input: input, configs: [config])
    }

    /// Queues `repeats` cells of each task and setup, interleaved (1 of each, then 2 of each…)
    /// so a partly done comparison is still fair. Cells whose key already has a finished result,
    /// or that are queued or running, are skipped. A flagged cell isn't run again: it counts as
    /// failed, so a re-roll can't make a bad outcome go away.
    public static func newControlRuns(tasks: [ControlTask], setups: [ControlSetup], repeats: Int, environment: LabEnvironment?,
                                      keep: Bool, akit: URL, env: HarnessEnvironment) async throws -> (runs: [LabRun], skipped: Int) {
        guard !tasks.isEmpty, !setups.isEmpty, repeats > 0 else {
            throw LabStore.Failure(message: "Pick at least one task, one setup and one repeat.")
        }
        // A test oracle that fails on its reference commit can't tell a fix from noise.
        if let red = tasks.first(where: { $0.referenceGreen == false }) {
            throw LabStore.Failure(message: "The tests of \(red.id) fail on its reference commit; fix the test command or the reference "
                                       + "first (akit analysis control task check \(red.id)).")
        }
        let existing = LabStore.list(env: env).filter { $0.spec.kind == .control }
        var done = Set(existing.compactMap { run -> String? in
            run.status == .finished ? run.result?.control?.key : nil
        })
        let byID = Dictionary(tasks.map { ($0.id, $0) }) { first, _ in first }
        for run in existing where run.status == .queued || run.status == .running {
            guard let task = run.spec.controlTask.flatMap({ byID[$0] }), let setup = run.spec.controlSetup else { continue }
            done.insert(cellKey(task: task, setup: setup, repeatIndex: run.spec.repeatIndex ?? 1))
        }
        let folder = URL(filePath: tasks[0].repo, directoryHint: .isDirectory)
        let chosen: LabEnvironment
        if let environment { chosen = environment } else { chosen = await Launcher.suggested(for: folder, env: env) }
        var runs: [LabRun] = []
        var skipped = 0
        let start = Date.now
        for index in 1...repeats {
            for task in tasks {
                for setup in setups {
                    guard !done.contains(cellKey(task: task, setup: setup, repeatIndex: index)) else {
                        skipped += 1
                        continue
                    }
                    // Creation times one millisecond apart keep the queue in this order.
                    let created = start.addingTimeInterval(Double(runs.count) / 1000)
                    let spec = RunSpec(id: RunSpec.newID(at: created), kind: .control,
                                       title: "Control \(JSONLines.titleLine(task.title, limit: 40)) · \(setup.name) · \(index)/\(repeats)",
                                       createdAt: created, folder: task.repo, environment: chosen, akit: akit.path, agent: setup.agent,
                                       repo: task.repo, repeatIndex: index, repeats: repeats, keep: keep, controlTask: task.id,
                                       controlSetup: setup)
                    runs.append(try LabStore.create(spec, env: env))
                }
            }
        }
        return (runs, skipped)
    }

    /// One cell: the sending policy first (repository code goes to the setup's agent), then
    /// the agent in a clone, then the oracle.
    static func execute(_ run: LabRun, env: HarnessEnvironment, phase: @escaping @Sendable (RunState.Phase) -> Void,
                        out: @escaping @Sendable (String) -> Void) async throws -> RunResult {
        guard let id = run.spec.controlTask, let setup = run.spec.controlSetup else {
            throw LabWorker.Failure(message: "The run names no control task or setup.")
        }
        guard let task = ControlTasks.load(id, env: env) else { throw LabWorker.Failure(message: "The control task \(id) is gone.") }
        let gate = try await SendGate.open(agent: setup.agent, env: env)
        try gate.check(.code(setup.agent.harness))
        // A task made from a session sends its user's turn: that session's origin must be allowed
        // too, and the turn is scrubbed with the user's own patterns.
        if case .session(let key) = task.source { try gate.check(ControlTasks.origin(of: key, env: env)) }
        let prompt = gate.scrub(task.prompt).text
        try SendLog.checkLimit(estimate: nil, settings: gate.settings, env: env)
        guard !Cancellation.isCancelled else { throw CancellationError() }
        out("Control task “\(task.title)” from \(String(task.base.prefix(7))) · \(setup.label) · \(task.oracle.label)")
        let testCommand: String? = if case .tests(let command) = task.oracle { command } else { nil }
        let facts = try await ControlCell.run(run, setup: setup, repo: URL(filePath: task.repo, directoryHint: .isDirectory),
                                              base: task.base, prompt: prompt, testCommand: testCommand, env: env,
                                              phase: phase, out: out)
        let session: String? = if case .session(let key) = task.source { key.description } else { nil }
        let logError = SendLog.appendAfterRun(SendRecord(purpose: "control", session: session, runID: run.id, destination: gate.destination,
                                                         model: setup.agent.model, inputCharacters: prompt.count, usage: facts.usage),
                                              env: env, out: out)
        let control = outcome(task: task, setup: setup, repeatIndex: run.spec.repeatIndex ?? 1, facts: facts)
        return RunResult(metrics: facts.metrics, leaks: control.leaks, agentError: facts.agentError ?? logError, control: control)
    }

    /// The oracle's verdict on a cell, with its guard and leak flags.
    static func outcome(task: ControlTask, setup: ControlSetup, repeatIndex: Int, facts: ControlCell.Facts) -> ControlOutcome {
        var outcome = ControlOutcome(key: cellKey(task: task, setup: setup, repeatIndex: repeatIndex), passed: false, oracle: "",
                                     testsDropped: facts.testsDropped, changedTestFiles: facts.changedTestFiles,
                                     leaks: facts.transcript.map { leaks(in: $0, task: task) } ?? [])
        switch task.oracle {
        case .tests:
            outcome.passed = facts.tests?.passed ?? false
            outcome.oracle = facts.tests?.detail ?? "the tests didn't run"
        case .assertion(let modeID):
            guard let check = CodeChecks.check(for: modeID) else {
                outcome.oracle = "no code check for \(modeID)"
                break
            }
            guard let transcript = facts.transcript else {
                outcome.oracle = "no transcript to check for \(modeID)"
                break
            }
            let verdict = check.check(transcript)
            // A failure or efficiency mode passes when absent; a success mode when present.
            outcome.passed = task.successMode == true ? verdict.positive : !verdict.positive
            outcome.oracle = "\(modeID): \(verdict.positive ? "present" : "not present")" + (verdict.detail.map { " (\($0))" } ?? "")
            outcome.checkSteps = verdict.steps
        }
        return outcome
    }

    /// Signs the cell saw the exemplar: tool calls naming its session id, reading the
    /// session history of Claude Code or Pi, a `session_search` tool, or the real repository
    /// (which holds the later fix). Tool results aren't searched: harnesses mention their own
    /// folders there.
    static func leaks(in transcript: SessionTranscript, task: ControlTask) -> [String] {
        let calls = transcript.items.compactMap { item -> (name: String, text: String)? in
            if case .toolCall(let name) = item.kind { (name, item.text) } else { nil }
        }
        var found: [String] = []
        if case .session(let key) = task.source, calls.contains(where: { $0.text.contains(key.nativeID) }) {
            found.append("the exemplar session \(key)")
        }
        if calls.contains(where: { $0.text.contains(".claude/projects") || $0.text.contains(".pi/agent/sessions")
            || $0.name.contains("session_search") }) {
            found.append("the session history")
        }
        let repo = URL(filePath: task.repo).standardizedFileURL.path
        if calls.contains(where: { $0.text.contains(repo) }) { found.append("the real repository") }
        return found
    }
}
