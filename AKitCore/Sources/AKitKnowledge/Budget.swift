import Foundation

/// The token budget of an agent answer (K19): tokens ≈ UTF-8 bytes / 4, counted on the JSON the
/// command prints, so `--max-tokens` caps what the agent reads.
public enum Budget {
    /// The default cap of `kb search` and `kb show` (K19: a first guess, tuned from real logs).
    public static let defaultTokens = 4000

    /// About how many tokens a text costs: its UTF-8 bytes / 4, rounded up.
    public static func tokens(_ text: String) -> Int { (text.utf8.count + 3) / 4 }

    /// The JSON the CLI prints (pretty, sorted keys, slashes as they are).
    public static func json(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// The tokens of `value` as JSON, its own `tokens` field included: set twice, as the number's
    /// digits count too.
    static func measure<T: Encodable>(_ value: inout T, field: WritableKeyPath<T, Int>) -> Int {
        value[keyPath: field] = tokens(json(value))
        value[keyPath: field] = tokens(json(value))
        return value[keyPath: field]
    }
}
