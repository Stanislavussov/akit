import Foundation

/// Token counts as the harness recorded them from the provider's responses.
public struct TokenCounts: Sendable, Hashable, Codable {
    /// Input tokens that were not read from or written to the cache.
    public var input = 0
    public var output = 0
    public var cacheRead = 0
    public var cacheWrite = 0
    /// Part of `output` spent on thinking, when the provider reports it.
    public var reasoning = 0

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0, reasoning: Int = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.reasoning = reasoning
    }

    /// Everything sent to the model in one request: the context size at that point.
    public var context: Int { input + cacheRead + cacheWrite }
    public var total: Int { context + output }

    public static func + (a: TokenCounts, b: TokenCounts) -> TokenCounts {
        TokenCounts(input: a.input + b.input, output: a.output + b.output, cacheRead: a.cacheRead + b.cacheRead,
                    cacheWrite: a.cacheWrite + b.cacheWrite, reasoning: a.reasoning + b.reasoning)
    }
}
