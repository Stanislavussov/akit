import Foundation

/// What Claude Code charges per token, learned from the costs it saved itself
/// (`cost-state` lines), not from a price list. Used only for sessions that ended
/// without saving a cost.
///
/// For each model the saved sessions give `cost = a·input + b·output + c·cacheRead + d·cacheWrite`
/// with unknown rates; with enough sessions they are found by least squares. The rates are
/// applied to a whole session's tokens, whose mix is like the sessions they came from.
/// With few sessions, or when that gives nothing sensible, the model's average dollars
/// per token is used. A model with no saved cost gets no estimate.
struct ClaudeCostRates: Sendable {
    private struct Rate: Sendable {
        /// Dollars per million input, output, cache read and cache write tokens.
        var linear: [Double]?
        /// Dollars per million tokens of any kind.
        var average: Double
    }

    private var byModel: [String: Rate] = [:]

    /// Sessions a model needs before its four rates are fitted.
    static let minimumSessions = 8

    init(costStates: [ClaudeSessions.CostState]) {
        var samples: [String: [(x: [Double], y: Double)]] = [:]
        for state in costStates {
            for (model, part) in state.byModel where part.cost > 0 && part.tokens.total > 0 {
                samples[model, default: []].append((Self.features(part.tokens), part.cost))
            }
        }
        for (model, rows) in samples {
            let tokens = rows.reduce(0) { $0 + $1.x.reduce(0, +) }
            let average = rows.reduce(0) { $0 + $1.y } / tokens
            let linear = rows.count >= Self.minimumSessions ? Self.leastSquares(rows) : nil
            byModel[model] = Rate(linear: linear, average: average)
        }
    }

    /// Estimated cost of a model's tokens in one session. nil = no saved cost to learn from.
    func cost(of tokens: TokenCounts, model: String) -> Double? {
        guard let rate = byModel[model], tokens.total > 0 else { return nil }
        let features = Self.features(tokens)
        let average = rate.average * features.reduce(0, +)
        guard let linear = rate.linear else { return average }
        let fitted = zip(linear, features).reduce(0) { $0 + $1.0 * $1.1 }
        // A mix unlike the sessions the rates came from can give nonsense: fall back.
        return fitted > average / 10 && fitted < average * 10 ? fitted : average
    }

    /// A made-up cost-state for a session that has none, or nil when no model can be priced.
    func estimate(for records: [UsageRecord]) -> ClaudeSessions.CostState? {
        var tokens: [String: TokenCounts] = [:]
        for record in records {
            let model = ClaudeSessions.baseModel(record.model)
            tokens[model] = (tokens[model] ?? TokenCounts()) + record.tokens
        }
        var byModel: [String: ClaudeSessions.CostState.Part] = [:]
        for (model, used) in tokens {
            if let dollars = cost(of: used, model: model) { byModel[model] = .init(tokens: used, cost: dollars) }
        }
        guard !byModel.isEmpty else { return nil }
        return ClaudeSessions.CostState(total: byModel.values.reduce(0) { $0 + $1.cost }, byModel: byModel)
    }

    private static func features(_ tokens: TokenCounts) -> [Double] {
        [tokens.input, tokens.output, tokens.cacheRead, tokens.cacheWrite].map { Double($0) / 1_000_000 }
    }

    /// Solves the normal equations `XᵀX·w = Xᵀy` by Gaussian elimination. nil when the
    /// sessions don't pin the rates down (e.g. a token kind that never occurs).
    static func leastSquares(_ rows: [(x: [Double], y: Double)]) -> [Double]? {
        let n = 4
        var a = Array(repeating: Array(repeating: 0.0, count: n + 1), count: n)
        for row in rows {
            for i in 0..<n {
                for j in 0..<n { a[i][j] += row.x[i] * row.x[j] }
                a[i][n] += row.x[i] * row.y
            }
        }
        let scale = (0..<n).map { a[$0][$0] }.max() ?? 0
        guard scale > 0 else { return nil }
        for column in 0..<n {
            guard let pivot = (column..<n).max(by: { abs(a[$0][column]) < abs(a[$1][column]) }),
                  abs(a[pivot][column]) > scale * 1e-12 else { return nil }
            a.swapAt(column, pivot)
            for row in 0..<n where row != column {
                let factor = a[row][column] / a[column][column]
                for k in column...n { a[row][k] -= factor * a[column][k] }
            }
        }
        return (0..<n).map { a[$0][n] / a[$0][$0] }
    }
}
