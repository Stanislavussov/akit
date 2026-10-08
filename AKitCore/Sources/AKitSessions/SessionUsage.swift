import AKitModel
import Foundation

/// What one model did in a session.
public struct ModelUsage: Identifiable, Sendable, Hashable, Codable {
    public var id: String { [provider, model].compactMap(\.self).joined(separator: "/") }
    public let model: String
    public let provider: String?
    /// Model responses (API requests).
    public var requests: Int
    public var tokens: TokenCounts
    /// In US dollars, when the harness records it (Pi does, Claude Code doesn't).
    public var cost: Double?

    public init(model: String, provider: String? = nil, requests: Int, tokens: TokenCounts, cost: Double? = nil) {
        self.model = model
        self.provider = provider
        self.requests = requests
        self.tokens = tokens
        self.cost = cost
    }
}

public struct ToolCount: Sendable, Hashable, Codable {
    public let name: String
    public let calls: Int
}

/// Tokens, models and activity of one session.
public struct SessionUsage: Sendable, Hashable {
    /// The main conversation, by model in order of first use.
    public var models: [ModelUsage] = []
    /// Subagents started from the session (their own files or side chains).
    public var subagentModels: [ModelUsage] = []
    public var subagentRuns = 0
    /// Largest and last request context of the main conversation.
    public var peakContext = 0
    public var lastContext = 0
    /// Time the harness spent working on prompts, when recorded (Claude Code).
    public var activeTime: TimeInterval?
    public var firstActivity: Date?
    public var lastActivity: Date?

    public var userPrompts = 0
    public var toolCalls = 0
    /// Failed tool calls, without rejected and interrupted ones (`FailureSignals`).
    public var toolErrors = 0
    public var compactions = 0
    /// Most used first.
    public var tools: [ToolCount] = []

    public init() {}

    public var tokens: TokenCounts { models.reduce(TokenCounts()) { $0 + $1.tokens } }
    public var subagentTokens: TokenCounts { subagentModels.reduce(TokenCounts()) { $0 + $1.tokens } }
    public var requests: Int { models.reduce(0) { $0 + $1.requests } }
    /// nil when no model has a recorded cost.
    public var cost: Double? { Self.sum((models + subagentModels).map(\.cost)) }
    public var hasTokens: Bool { !models.isEmpty || !subagentModels.isEmpty }

    static func sum(_ costs: [Double?]) -> Double? {
        let known = costs.compactMap(\.self)
        return known.isEmpty ? nil : known.reduce(0, +)
    }
}

/// Adds up usage per model. A response recorded on several lines (Claude Code writes
/// one line per content block, each with the same usage) is counted once: the last
/// line of a response id wins.
struct UsageCounter {
    private struct Response {
        let model: String
        let provider: String?
        let tokens: TokenCounts
        let cost: Double?
    }

    private var order: [String] = []
    private var responses: [String: Response] = [:]

    mutating func record(id: String?, model: String?, provider: String? = nil, tokens: TokenCounts, cost: Double? = nil) {
        guard let model, !model.isEmpty, model != "<synthetic>" else { return }
        let key = id ?? "#\(order.count)"
        if responses[key] == nil { order.append(key) }
        responses[key] = Response(model: model, provider: provider, tokens: tokens, cost: cost)
    }

    /// Context of each response, in order.
    var contexts: [Int] { order.compactMap { responses[$0]?.tokens.context } }

    var models: [ModelUsage] {
        var result: [ModelUsage] = []
        for key in order {
            guard let response = responses[key] else { continue }
            let usage = ModelUsage(model: response.model, provider: response.provider, requests: 1,
                                   tokens: response.tokens, cost: response.cost)
            if let index = result.firstIndex(where: { $0.id == usage.id }) {
                result[index].requests += 1
                result[index].tokens = result[index].tokens + usage.tokens
                result[index].cost = SessionUsage.sum([result[index].cost, usage.cost])
            } else {
                result.append(usage)
            }
        }
        return result
    }
}
