import Foundation

/// What Claude Code charges per token, learned from the costs it saved itself
/// (`cost-state` lines), not from a price list. Used only for runs that saved no cost.
///
/// The rate is dollars per token the transcript shows, not per token the cost-state
/// counts: Claude Code also makes calls it doesn't write down (auto mode permission
/// checks, compaction, recaps, prompt suggestions), often 10–40% more tokens that are
/// paid for too. A saved run's cost divided by its transcript tokens counts them in.
/// One average per model, over all saved runs; a model with no saved cost gets no estimate.
struct ClaudeCostRates: Sendable {
    /// Dollars per transcript token.
    private var perToken: [String: Double] = [:]

    init(runs: [ClaudeUsage.Run]) {
        var dollars: [String: Double] = [:]
        var tokens: [String: Int] = [:]
        for run in runs {
            guard let saved = run.cost else { continue }
            var used: [String: Int] = [:]
            for item in run.responses { used[ClaudeUsage.baseModel(item.record.model), default: 0] += item.record.tokens.total }
            // Like `spread`: what the answering models don't account for (a quick title,
            // a model with no response) is theirs too, by their share of the tokens.
            let answered = saved.byModel.filter { (used[$0.key] ?? 0) > 0 }
            let answeredTokens = answered.keys.reduce(0) { $0 + used[$1]! }
            let leftover = max(saved.total - answered.values.reduce(0) { $0 + $1.cost }, 0)
            for (model, part) in answered where part.cost > 0 || leftover > 0 {
                let count = used[model]!
                dollars[model, default: 0] += part.cost + leftover * Double(count) / Double(answeredTokens)
                tokens[model, default: 0] += count
            }
        }
        for (model, count) in tokens { perToken[model] = dollars[model]! / Double(count) }
    }

    /// Estimated cost of a model's transcript tokens. nil = no saved cost to learn from.
    func cost(of tokens: TokenCounts, model: String) -> Double? {
        guard let rate = perToken[model], tokens.total > 0 else { return nil }
        return rate * Double(tokens.total)
    }

    /// A made-up cost-state for a run that has none, or nil when no model can be priced.
    func estimate(for records: [UsageRecord]) -> ClaudeUsage.CostState? {
        var tokens: [String: TokenCounts] = [:]
        for record in records {
            let model = ClaudeUsage.baseModel(record.model)
            tokens[model] = (tokens[model] ?? TokenCounts()) + record.tokens
        }
        var byModel: [String: ClaudeUsage.CostState.Part] = [:]
        for (model, used) in tokens {
            if let dollars = cost(of: used, model: model) { byModel[model] = .init(tokens: used, cost: dollars) }
        }
        guard !byModel.isEmpty else { return nil }
        return ClaudeUsage.CostState(total: byModel.values.reduce(0) { $0 + $1.cost }, byModel: byModel)
    }
}
