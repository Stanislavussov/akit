import AKitFoundation
import Foundation

/// One attempt of a step in a run, as the Runs screen shows it (F7, F16, F17).
public struct FlowStepAttempt: Equatable, Sendable {
    public enum State: String, Codable, Sendable { case running, done, failed, blocked, halted }

    public var step: String
    public var attempt: Int
    public var started: Date?
    public var ended: Date?
    public var outcome: FlowOutcome?
    public var reason: String?
    public var tokens: FlowTokens?
    public var deviations: [FlowEvent]
    public var handoff: FlowHandoff?
    /// The check evidence, relative to the run folder.
    public var evidence: String?
    /// The child's session file, relative to the run folder.
    public var sessionFile: String?
    /// The step the run went to after this attempt, when the routes say it may not (FlowRouting.next).
    public var forbiddenNext: String?

    public var state: State {
        guard ended != nil || outcome != nil else { return .running }
        switch outcome {
        case .done: return .done
        case .failed: return .failed
        case .blocked: return .blocked
        case nil: return .halted
        }
    }

    public var seconds: Double? {
        guard let started, let ended else { return nil }
        return ended.timeIntervalSince(started)
    }
}

/// A run read for the Runs screen and `akit flow runs`: its attempts in order, and its status.
public struct FlowRunSummary: Sendable {
    public enum Status: String, Codable, Sendable { case running, halted, done, stopped, unknown }

    public var run: FlowRun
    public var attempts: [FlowStepAttempt]
    /// The flow file the run names, when Pi still has it (for the diagram and route checks).
    public var flow: Flow?
    public var status: Status
    /// A `STOP` file is in the run folder (the Stop button wrote it, the runner has not seen it yet).
    public var stopRequested: Bool
    /// The pid in the run's `lock` is a live process.
    public var locked: Bool
    /// Why the run stopped (`run-end`'s `stop`, or the last `halted`'s reason).
    public var stopReason: String?

    public var deviationCount: Int { attempts.reduce(0) { $0 + $1.deviations.count } + looseDeviations.count }
    /// Deviations logged outside a step (no step field).
    public var looseDeviations: [FlowEvent]

    public func attempts(of step: String) -> [FlowStepAttempt] { attempts.filter { $0.step == step } }

    public static let stopFile = "STOP"

    public init(_ run: FlowRun, flow: Flow?) {
        self.run = run
        self.flow = flow
        var attempts: [FlowStepAttempt] = []
        var loose: [FlowEvent] = []
        func open(_ step: String?, _ attempt: Int?) -> Int? {
            attempts.lastIndex { $0.step == step && (attempt == nil || $0.attempt == attempt) }
        }
        for event in run.events {
            switch event.kind {
            case .stepStart:
                guard let step = event.step else { continue }
                attempts.append(FlowStepAttempt(step: step, attempt: event.attempt ?? 1, started: Self.date(event.time), ended: nil,
                                                outcome: nil, reason: nil, tokens: nil, deviations: [], handoff: nil,
                                                evidence: nil, sessionFile: nil, forbiddenNext: nil))
            case .stepEnd:
                guard let index = open(event.step, event.attempt) else { continue }
                attempts[index].ended = Self.date(event.time)
                attempts[index].outcome = event.outcome
                attempts[index].reason = event.reason
                attempts[index].tokens = event.tokens
            case .deviation:
                if let index = open(event.step, event.attempt) { attempts[index].deviations.append(event) } else { loose.append(event) }
            default:
                continue
            }
        }
        for handoff in run.handoffs {
            guard let index = attempts.firstIndex(where: { $0.step == handoff.stepID && $0.attempt == (handoff.attempt ?? 1) }) else { continue }
            attempts[index].handoff = handoff
            attempts[index].evidence = handoff.evidence
            attempts[index].sessionFile = handoff.sessionFile
        }
        // Evidence without a handoff link: `evidence/NN-<step>-aN-checks.json` names its step and attempt inside (older runs: one file per step).
        for (index, attempt) in attempts.enumerated() where attempt.evidence == nil {
            attempts[index].evidence = Self.evidenceFile(run.folder, step: attempt.step, attempt: attempt.attempt)
        }
        if let flow { Self.flagForbidden(&attempts, flow: flow) }
        self.attempts = attempts
        looseDeviations = loose
        stopRequested = FileManager.default.fileExists(atPath: run.folder.appending(path: Self.stopFile).path)
        locked = Self.lockAlive(run.folder)
        let end = run.events.last { $0.kind == .runEnd }
        let lastHalt = run.events.lastIndex { $0.kind == .halted }
        let lastResume = run.events.lastIndex { $0.kind == .resume || $0.kind == .stepStart }
        if let end {
            stopReason = end.text("stop")
            status = end.text("stop") == FlowStop.done.rawValue ? .done : .stopped
        } else if let lastHalt, lastResume.map({ $0 < lastHalt }) ?? true {
            stopReason = run.events[lastHalt].reason
            status = .halted
        } else {
            stopReason = nil
            status = run.events.isEmpty ? .unknown : .running
        }
    }

    /// Each attempt's next attempt is checked against `FlowRouting.next` with the visits so far.
    static func flagForbidden(_ attempts: inout [FlowStepAttempt], flow: Flow) {
        var visits: [String: Int] = [:]
        for index in attempts.indices {
            visits[attempts[index].step, default: 0] += 1
            guard index + 1 < attempts.count, let outcome = attempts[index].outcome else { continue }
            let next = attempts[index + 1]
            // A rerun of the same attempt number (resume after a crash) is not a route.
            if next.step == attempts[index].step, next.attempt == attempts[index].attempt { continue }
            let decision = FlowRouting.next(flow: flow, state: FlowRunState(step: attempts[index].step, visits: visits),
                                            outcome: outcome, reason: attempts[index].reason ?? "")
            if decision.next != next.step { attempts[index].forbiddenNext = next.step }
        }
    }

    static func evidenceFile(_ folder: URL, step: String, attempt: Int) -> String? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.appending(path: "evidence").path)) ?? []
        for name in names.sorted() where name.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: folder.appending(path: "evidence/\(name)")),
                  let value = try? JSONValue.parse(data), value.member("step")?.member("id")?.string == step,
                  (value.member("step")?.member("attempt")?.int ?? 1) == attempt else { continue }
            return "evidence/\(name)"
        }
        return nil
    }

    static func lockAlive(_ folder: URL) -> Bool {
        guard let text = try? String(contentsOf: folder.appending(path: "lock"), encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    /// Writes `STOP` into the run folder: the runner halts before its next step (F19).
    public func requestStop() throws {
        try Data("STOP\n".utf8).write(to: run.folder.appending(path: Self.stopFile))
    }

    /// The runs of the projects, newest first, each with its flow file when Pi has it.
    public static func all(projects: [URL], env: HarnessEnvironment) -> [FlowRunSummary] {
        projects.flatMap { project -> [FlowRunSummary] in
            let flows = FlowFile.list(project: project, env: env)
            return FlowRun.runs(project: project).map { run in
                var run = run
                if run.project == nil { run.project = project.path }
                return FlowRunSummary(run, flow: flows.first { $0.name == run.flow }?.flow)
            }
        }
        .sorted { $0.run.id > $1.run.id }
    }
}

/// The plain form of a run for `akit flow runs --json`.
public struct FlowRunReport: Codable, Sendable {
    public struct Attempt: Codable, Sendable {
        public var step: String
        public var attempt: Int
        public var state: FlowStepAttempt.State
        public var reason: String?
        public var seconds: Double?
        public var tokens: FlowTokens?
        public var deviations: [String]
        public var evidence: String?
        public var session: String?
        public var forbiddenNext: String?
    }

    public var id: String
    public var flow: String?
    public var task: String?
    public var project: String?
    public var status: FlowRunSummary.Status
    public var stopReason: String?
    public var stopRequested: Bool
    public var pi: String?
    public var tokens: FlowTokens
    public var deviations: Int
    public var attempts: [Attempt]
    public var problems: [String]

    public init(_ summary: FlowRunSummary) {
        id = summary.run.id
        flow = summary.run.flow
        task = summary.run.task
        project = summary.run.project
        status = summary.status
        stopReason = summary.stopReason
        stopRequested = summary.stopRequested
        pi = summary.run.piVersion
        tokens = summary.run.tokens
        deviations = summary.deviationCount
        attempts = summary.attempts.map {
            Attempt(step: $0.step, attempt: $0.attempt, state: $0.state, reason: $0.reason, seconds: $0.seconds, tokens: $0.tokens,
                    deviations: $0.deviations.map(FlowRunReport.describe), evidence: $0.evidence, session: $0.sessionFile,
                    forbiddenNext: $0.forbiddenNext)
        }
        problems = summary.run.problems
    }

    /// `rule: detail` or `rule: tool input`, as the Runs screen quotes it.
    public static func describe(_ event: FlowEvent) -> String {
        let rule = event.text("rule") ?? "deviation"
        let what = [event.text("tool"), event.text("input") ?? event.text("detail")].compactMap { $0 }.joined(separator: " ")
        return what.isEmpty ? rule : "\(rule): \(what)"
    }
}

/// A step's check evidence (`evidence/NN-<step>-aN-checks.json`, `akit-flow-evidence/1`).
public struct FlowEvidence: Equatable, Sendable {
    public var command: String
    public var exit: Int?
    /// The last lines of the output.
    public var tail: [String]

    public static func read(_ file: URL) -> [FlowEvidence] {
        guard let data = try? Data(contentsOf: file), let value = try? JSONValue.parse(data) else { return [] }
        return (value.member("checks")?.array ?? []).compactMap { check in
            check.member("command")?.string.map {
                FlowEvidence(command: $0, exit: check.member("exit")?.int, tail: check.member("tail")?.strings ?? [])
            }
        }
    }
}
