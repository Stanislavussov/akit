import Foundation
import Yams

/// A flow file (docs/design/flows.md F2, F3, F19): a column of steps for Pi, each with its agent,
/// model, skills, tools and route table. AKit writes it; the Pi extension `akit-flow.ts` runs it.
public struct Flow: Codable, Equatable, Sendable {
    /// The `akit-flow-format` this build writes and reads. An extension that meets a newer one refuses (F20).
    public static let currentFormat = 1
    /// The lowest Pi the runner supports (flows.md, "Pi facts").
    public static let defaultMinPi = "1.0.4"

    public var format: Int
    public var name: String
    public var minPi: String
    /// The flow's tools; each step's tools are a subset (F13).
    public var tools: [String]
    public var steps: [FlowStep]

    public init(format: Int = Flow.currentFormat, name: String, minPi: String = Flow.defaultMinPi, tools: [String] = [],
                steps: [FlowStep]) {
        self.format = format
        self.name = name
        self.minPi = minPi
        self.tools = tools
        self.steps = steps
    }

    enum CodingKeys: String, CodingKey {
        case format = "akit-flow-format", name, minPi, tools, steps
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decode(Int.self, forKey: .format)
        name = try c.decode(String.self, forKey: .name)
        minPi = try c.decodeIfPresent(String.self, forKey: .minPi) ?? Flow.defaultMinPi
        tools = try c.decodeIfPresent([String].self, forKey: .tools) ?? []
        steps = try c.decodeIfPresent([FlowStep].self, forKey: .steps) ?? []
    }

    public func step(_ id: String) -> FlowStep? { steps.first { $0.id == id } }
    public func index(of id: String) -> Int? { steps.firstIndex { $0.id == id } }

    public struct ReadError: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Reads a flow file's YAML. A missing field or a wrong type is a `ReadError` naming it.
    public static func decode(yaml: String) throws(ReadError) -> Flow {
        do {
            return try YAMLDecoder().decode(Flow.self, from: yaml)
        } catch let DecodingError.keyNotFound(key, context) {
            throw ReadError(message: "missing \(path(context.codingPath + [key]))")
        } catch let DecodingError.typeMismatch(_, context) {
            throw ReadError(message: "wrong type at \(path(context.codingPath))")
        } catch let DecodingError.valueNotFound(_, context) {
            throw ReadError(message: "no value at \(path(context.codingPath))")
        } catch let DecodingError.dataCorrupted(context) {
            throw ReadError(message: "bad value at \(path(context.codingPath)): \(context.debugDescription)")
        } catch {
            throw ReadError(message: "not YAML: \(error)")
        }
    }

    /// The flow as YAML, keys sorted so the same flow always gives the same text.
    public func yaml() throws -> String {
        let encoder = YAMLEncoder()
        encoder.options.sortKeys = true
        return try encoder.encode(self)
    }

    private static func path(_ keys: [CodingKey]) -> String {
        keys.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
    }
}

/// One card of the column (F2, F14).
public struct FlowStep: Codable, Equatable, Sendable {
    public static let defaultMaxLoops = 3

    public var id: String
    /// From the agent list; `implementer` and `reviewer` are the pair F6's model rule compares.
    public var agent: String
    public var model: String
    public var thinking: String?
    /// What the step does, in the model's words; the runner puts it after the task.
    public var prompt: String?
    public var skills: [String]
    public var tools: [String]
    /// Paths the step may write (`edit` / `write`); empty means anywhere in the worktree.
    public var paths: [String]
    /// Whether the step may run `bash`. Default: yes, unless `paths` restricts writes (F15).
    public var bash: Bool
    /// The per-step `-e` list of extensions a child loads (F15).
    public var extensions: [String]
    public var gate: Bool
    /// Check commands the runner runs at the step's end (F5, F19 rules).
    public var checks: [String]
    public var maxLoops: Int
    /// `outcome:reason` → next step id or `end`; `outcome:*` is the fallback (F19).
    public var routes: [String: String]

    public init(id: String, agent: String, model: String, thinking: String? = nil, prompt: String? = nil, skills: [String] = [], tools: [String] = [],
                paths: [String] = [], bash: Bool? = nil, extensions: [String] = [], gate: Bool = false, checks: [String] = [],
                maxLoops: Int = FlowStep.defaultMaxLoops, routes: [String: String] = [:]) {
        self.id = id
        self.agent = agent
        self.model = model
        self.thinking = thinking
        self.prompt = prompt
        self.skills = skills
        self.tools = tools
        self.paths = paths
        self.bash = bash ?? paths.isEmpty
        self.extensions = extensions
        self.gate = gate
        self.checks = checks
        self.maxLoops = maxLoops
        self.routes = routes
    }

    enum CodingKeys: String, CodingKey {
        case id, agent, model, thinking, prompt, skills, tools, paths, bash, extensions, gate, checks, maxLoops, routes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        agent = try c.decode(String.self, forKey: .agent)
        model = try c.decode(String.self, forKey: .model)
        thinking = try c.decodeIfPresent(String.self, forKey: .thinking)
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt)
        skills = try c.decodeIfPresent([String].self, forKey: .skills) ?? []
        tools = try c.decodeIfPresent([String].self, forKey: .tools) ?? []
        paths = try c.decodeIfPresent([String].self, forKey: .paths) ?? []
        bash = try c.decodeIfPresent(Bool.self, forKey: .bash) ?? paths.isEmpty
        extensions = try c.decodeIfPresent([String].self, forKey: .extensions) ?? []
        gate = try c.decodeIfPresent(Bool.self, forKey: .gate) ?? false
        checks = try c.decodeIfPresent([String].self, forKey: .checks) ?? []
        maxLoops = try c.decodeIfPresent(Int.self, forKey: .maxLoops) ?? FlowStep.defaultMaxLoops
        routes = try c.decodeIfPresent([String: String].self, forKey: .routes) ?? [:]
    }

    /// Empty lists and the empty route table are left out, so the file holds only what was set.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(agent, forKey: .agent)
        try c.encode(model, forKey: .model)
        try c.encodeIfPresent(thinking, forKey: .thinking)
        try c.encodeIfPresent(prompt, forKey: .prompt)
        for (list, key) in [(skills, CodingKeys.skills), (tools, .tools), (paths, .paths), (extensions, .extensions), (checks, .checks)]
        where !list.isEmpty {
            try c.encode(list, forKey: key)
        }
        try c.encode(bash, forKey: .bash)
        try c.encode(gate, forKey: .gate)
        try c.encode(maxLoops, forKey: .maxLoops)
        if !routes.isEmpty { try c.encode(routes, forKey: .routes) }
    }
}

/// What a step ends with, from its `flow_handoff` (F4).
public enum FlowOutcome: String, Codable, CaseIterable, Sendable {
    case done, failed, blocked
}
