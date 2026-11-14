import Foundation

/// Anthropic API list prices, dollars per million tokens (first-party API, 2026-10-06 table).
/// Claude Code records no cost, so a session's tool costs are estimated from these; the UI says
/// "estimated" wherever they are used. Unknown models get no price.
public struct ClaudePrice: Sendable, Hashable {
    public let input: Double
    public let output: Double
    public let cacheWrite: Double
    public let cacheRead: Double

    init(input: Double, output: Double, cacheRead: Double? = nil) {
        self.input = input
        self.output = output
        cacheWrite = input * 1.25
        self.cacheRead = cacheRead ?? input * 0.1
    }

    /// Longest prefix first, so `claude-opus-4-5` doesn't match `claude-opus-4`.
    private static let table: [(String, ClaudePrice)] = [
        ("claude-fable-5-1", .init(input: 10, output: 50, cacheRead: 0.25)),
        ("claude-mythos-5-1", .init(input: 10, output: 50, cacheRead: 0.25)),
        ("claude-fable-5", .init(input: 10, output: 50)),
        ("claude-opus-5-5", .init(input: 4, output: 20, cacheRead: 0.2)),
        ("claude-opus-5", .init(input: 5, output: 25)),
        ("claude-opus-4-8", .init(input: 5, output: 25)),
        ("claude-opus-4-7", .init(input: 5, output: 25)),
        ("claude-opus-4-6", .init(input: 5, output: 25)),
        ("claude-opus-4-5", .init(input: 5, output: 25)),
        ("claude-opus-4-1", .init(input: 15, output: 75)),
        ("claude-opus-4", .init(input: 15, output: 75)),
        ("claude-sonnet-5-5", .init(input: 2, output: 10, cacheRead: 0.2)),
        ("claude-sonnet-5", .init(input: 2, output: 10)),
        ("claude-sonnet-4", .init(input: 3, output: 15)),
        ("claude-3-7-sonnet", .init(input: 3, output: 15)),
        ("claude-haiku-5-5", .init(input: 0.1, output: 0.5)),
        ("claude-haiku-4-5", .init(input: 1, output: 5)),
        ("claude-3-5-haiku", .init(input: 0.8, output: 4)),
    ]

    /// `claude-opus-5-5[1m]`, `us.anthropic.claude-sonnet-4-5-20250929-v1:0` → their price.
    public static func of(model: String) -> ClaudePrice? {
        let lowered = model.lowercased()
        let name = lowered.range(of: "claude-").map { String(lowered[$0.lowerBound...]) } ?? lowered
        return table.first { name.hasPrefix($0.0) }?.1
    }
}
