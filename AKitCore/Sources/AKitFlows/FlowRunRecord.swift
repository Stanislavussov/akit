import AKitFoundation
import Foundation

/// Tokens of a step or a run as Pi's JSON events gave them. A field Pi did not give is `nil`
/// (unknown), never zero (F20).
public struct FlowTokens: Codable, Equatable, Sendable {
    public var input: Int?
    public var output: Int?
    public var cacheRead: Int?
    public var cost: Double?

    public init(input: Int? = nil, output: Int? = nil, cacheRead: Int? = nil, cost: Double? = nil) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cost = cost
    }

    init(_ value: JSONValue?) {
        input = value?.member("input")?.int
        output = value?.member("output")?.int
        cacheRead = value?.member("cache_read")?.int
        cost = value?.member("cost")?.double
    }
}

/// One line of `events.jsonl` of a known type.
public struct FlowEvent: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case runStart = "run-start", stepStart = "step-start", stepEnd = "step-end", gate, deviation, runEnd = "run-end"
        /// `STOP` or an unanswered gate stopped the run before a step; `/flow resume` goes on.
        case halted
        /// Edits made between steps (at a gate) were committed before the next step.
        case gateEdits = "gate-edits"
        /// `/flow resume` picked the run up again (and removed `STOP`).
        case resume
        /// The user's answer at a loop limit or a missing route: more, accept, again or stop.
        case decision
        /// The user settled a step's dispute with a rejection: maker, judge or note.
        case dispute
        /// `/flow resume` met a flow changed since the run started: `taken` says whether the run took it.
        case flowChanged = "flow-changed"
    }

    public var kind: Kind
    public var time: String?
    public var step: String?
    public var attempt: Int?
    public var outcome: FlowOutcome?
    public var reason: String?
    public var tokens: FlowTokens?
    public var raw: JSONValue

    /// A string field of the line (`rule`, `detail`, `tool`, `input`, `action`, `stop` …).
    public func text(_ key: String) -> String? { raw.member(key)?.string }
}

/// A handoff file (F4, `akit-flow-handoff/1`).
public struct FlowHandoff: Equatable, Sendable {
    public struct File: Equatable, Sendable {
        public var path: String
        public var change: String
    }

    public var fileName: String
    public var schemaVersion: Int
    public var run: String?
    public var flow: String?
    public var stepIndex: Int?
    public var stepID: String?
    public var attempt: Int?
    public var session: String?
    /// The child's session file, relative to the run folder (`sessions/<file>.jsonl`).
    public var sessionFile: String?
    public var outcome: FlowOutcome?
    public var reason: String?
    public var next: String?
    public var goal: String?
    public var done: [String]
    public var files: [File]
    /// What git saw the step change (the runner's truth); nil in records from before it, and
    /// for a checks step that passes the previous work on.
    public var changed: [File]?
    /// The planner's plan as data: ordered steps and the check command the checks step also runs.
    public var planSteps: [String] = []
    public var planCheck: String?
    public var openQuestions: [String]
    public var notes: String?
    public var tokens: FlowTokens
    public var deviations: Int?
    /// The step's check evidence, relative to the run folder (`evidence/NN-<step>-aN-checks.json`).
    public var evidence: String?
    /// The runner wrote this handoff from the model's text: the step never called `flow_handoff`.
    public var fallback: Bool = false
}

/// One run folder `<project>/.pi/akit-flow/runs/<id>/`, read tolerantly. `events.jsonl` is the
/// truth; `run.json` is only a cache, used for what the events do not say (the Pi version).
public struct FlowRun: Sendable {
    public static let runSchema = "akit-flow-run"
    public static let eventSchema = "akit-flow-event"
    public static let handoffSchema = "akit-flow-handoff"
    /// The highest schema number of each kind this AKit reads; a newer one makes the run read-only.
    public static let supportedVersion = 1

    public var id: String
    public var folder: URL
    public var flow: String?
    public var task: String?
    /// The project's main checkout and the run's worktree, from `run.json` or the run-start event.
    public var project: String?
    public var worktree: String?
    public var piVersion: String?
    public var events: [FlowEvent]
    /// Lines with a type this AKit does not know, kept as they were.
    public var unknownEvents: [JSONValue]
    /// Lines that are not JSON objects.
    public var badLines: Int
    public var handoffs: [FlowHandoff]
    /// A record with a newer schema number: shown, never changed ("update AKit").
    public var readOnly: Bool
    public var problems: [String]

    /// The state after the last step that started, from the events.
    public var state: FlowRunState? {
        var visits: [String: Int] = [:]
        var last: String?
        for event in events where event.kind == .stepStart {
            guard let step = event.step else { continue }
            visits[step, default: 0] += 1
            last = step
        }
        return last.map { FlowRunState(step: $0, visits: visits) }
    }

    public var finished: Bool { events.contains { $0.kind == .runEnd } }

    /// Every step-end's tokens added up; a field is unknown when any step lacks it.
    public var tokens: FlowTokens {
        let ends = events.filter { $0.kind == .stepEnd }.map { $0.tokens ?? FlowTokens() }
        guard !ends.isEmpty else { return FlowTokens() }
        func sum<T: AdditiveArithmetic>(_ key: KeyPath<FlowTokens, T?>) -> T? {
            ends.reduce(T.zero as T?) { total, next in total.flatMap { t in next[keyPath: key].map { t + $0 } } }
        }
        return FlowTokens(input: sum(\.input), output: sum(\.output), cacheRead: sum(\.cacheRead), cost: sum(\.cost))
    }

    public static func read(_ folder: URL) -> FlowRun {
        var run = FlowRun(id: folder.lastPathComponent, folder: folder, flow: nil, task: nil, project: nil, worktree: nil, piVersion: nil, events: [], unknownEvents: [], badLines: 0,
                          handoffs: [], readOnly: false, problems: [])
        if let data = try? Data(contentsOf: folder.appending(path: "run.json")) {
            if let cache = try? JSONValue.parse(data) {
                run.check(cache.member("schema")?.string, kind: runSchema, in: "run.json")
                run.flow = cache.member("flow")?.string
                run.task = cache.member("task")?.string
                run.project = cache.member("project")?.string
                run.worktree = cache.member("worktree")?.string
                run.piVersion = cache.member("pi")?.string ?? cache.member("piVersion")?.string
            } else {
                run.problems.append("run.json is not JSON (a cache; the events are read instead).")
            }
        }
        if let text = try? String(contentsOf: folder.appending(path: "events.jsonl"), encoding: .utf8) {
            for line in text.split(whereSeparator: \.isNewline) where !line.allSatisfy(\.isWhitespace) {
                guard let value = try? JSONValue.parse(Data(line.utf8)), value.objectMembers != nil else {
                    run.badLines += 1
                    continue
                }
                run.check(value.member("schema")?.string, kind: eventSchema, in: "events.jsonl")
                guard let kind = value.member("type")?.string.flatMap(FlowEvent.Kind.init(rawValue:)) else {
                    run.unknownEvents.append(value)
                    continue
                }
                let event = FlowEvent(kind: kind, time: value.member("time")?.string, step: value.member("step")?.string,
                                      attempt: value.member("attempt")?.int,
                                      outcome: value.member("outcome")?.string.flatMap(FlowOutcome.init(rawValue:)),
                                      reason: value.member("reason")?.string,
                                      tokens: value.member("tokens").map { FlowTokens($0) }, raw: value)
                if kind == .runStart {
                    run.flow = event.text("flow") ?? run.flow
                    run.task = event.text("task") ?? run.task
                    run.worktree = event.text("worktree") ?? run.worktree
                }
                run.events.append(event)
            }
        } else {
            run.problems.append("No events.jsonl.")
        }
        if run.badLines > 0 { run.problems.append("\(run.badLines) line(s) of events.jsonl are not JSON objects.") }
        let handoffs = folder.appending(path: "handoffs")
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: handoffs.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
        for name in names {
            guard let data = try? Data(contentsOf: handoffs.appending(path: name)), let value = try? JSONValue.parse(data),
                  value.objectMembers != nil else {
                run.problems.append("handoffs/\(name) is not a JSON object.")
                continue
            }
            if let handoff = run.handoff(value, fileName: name) { run.handoffs.append(handoff) }
        }
        return run
    }

    /// Notes a schema of the wrong kind, and marks the run read-only on a newer number.
    @discardableResult
    private mutating func check(_ schema: String?, kind: String, in file: String) -> Int? {
        guard let schema else { return nil }
        let parts = schema.split(separator: "/", maxSplits: 1)
        guard parts.count == 2, parts[0] == kind, let number = Int(parts[1]) else {
            problems.append("\(file): unknown schema \(schema).")
            return nil
        }
        if number > Self.supportedVersion, !readOnly {
            readOnly = true
            problems.append("\(file) has schema \(schema), newer than this AKit reads; read-only, update AKit.")
        }
        return number
    }

    private mutating func handoff(_ value: JSONValue, fileName: String) -> FlowHandoff? {
        guard let version = check(value.member("schema")?.string, kind: Self.handoffSchema, in: "handoffs/\(fileName)") else {
            if value.member("schema") == nil { problems.append("handoffs/\(fileName) has no schema.") }
            return nil
        }
        let step = value.member("step"), from = value.member("from")
        func files(_ key: String) -> [FlowHandoff.File]? {
            value.member(key)?.array.map { list in
                list.compactMap { file in
                    file.member("path")?.string.map { FlowHandoff.File(path: $0, change: file.member("change")?.string ?? "") }
                }
            }
        }
        let plan = value.member("plan")
        return FlowHandoff(fileName: fileName, schemaVersion: version, run: value.member("run")?.string,
                           flow: value.member("flow")?.string, stepIndex: step?.member("index")?.int,
                           stepID: step?.member("id")?.string, attempt: step?.member("attempt")?.int,
                           session: value.member("session")?.string, sessionFile: value.member("session_file")?.string,
                           outcome: from?.member("outcome")?.string.flatMap(FlowOutcome.init(rawValue:)),
                           reason: from?.member("reason")?.string, next: value.member("next")?.member("step")?.string,
                           goal: value.member("goal")?.string, done: value.member("done")?.strings ?? [], files: files("files") ?? [],
                           changed: files("changed"), planSteps: plan?.member("steps")?.strings ?? [],
                           planCheck: plan?.member("check")?.string.flatMap { $0.isEmpty ? nil : $0 },
                           openQuestions: value.member("open_questions")?.strings ?? [], notes: value.member("notes")?.string,
                           tokens: FlowTokens(value.member("tokens")), deviations: value.member("deviations")?.int,
                           evidence: value.member("evidence")?.string, fallback: value.member("fallback") == .bool(true))
    }

    /// The runs of a project, newest first (run ids start with the date and time).
    public static func runs(project: URL) -> [FlowRun] {
        let root = project.appending(path: ".pi/akit-flow/runs")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted(by: >).map { read(root.appending(path: $0)) }
    }
}

extension JSONValue {
    func member(_ key: String) -> JSONValue? {
        guard case .object(let members) = self else { return nil }
        return members[key]
    }

    var string: String? {
        if case .string(let text) = self { return text }
        return nil
    }

    var int: Int? {
        if case .number(let text) = self { return Int(text) }
        return nil
    }

    var double: Double? {
        if case .number(let text) = self { return Double(text) }
        return nil
    }

    var array: [JSONValue]? {
        if case .array(let items) = self { return items }
        return nil
    }

    var strings: [String]? { array?.compactMap(\.string) }
}
