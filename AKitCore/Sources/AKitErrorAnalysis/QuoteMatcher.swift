import Foundation

/// The verifier's code check: is a note's quote really in the transcript the model read
/// (`docs/design/error-analysis.md`, "Verifier")? Models re-wrap lines, curl quotes and wrap
/// the quote itself in quotes, so those differences are forgiven; the words are not.
public enum QuoteMatcher {
    /// Case-sensitive after whitespace runs become one space and curly quotes straight ones.
    /// A quote with `…` or `...` elisions matches when its parts appear in order.
    public static func matches(quote: String, in text: String) -> Bool {
        let parts = parts(of: quote)
        guard !parts.isEmpty else { return false }
        let text = normalized(text)
        var searchFrom = text.startIndex
        for part in parts {
            guard let found = text.range(of: part, range: searchFrom..<text.endIndex) else { return false }
            searchFrom = found.upperBound
        }
        return true
    }

    /// The quote's parts between `…` or `...` elisions, normalized, without wrapping quotes.
    static func parts(of quote: String) -> [String] {
        var quote = normalized(quote)
        if quote.count >= 2, let first = quote.first, first == quote.last, first == "\"" || first == "'" {
            quote = String(quote.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return quote.replacingOccurrences(of: "...", with: "…").components(separatedBy: "…")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func normalized(_ text: String) -> String {
        let straight = text
            .replacingOccurrences(of: "[\u{201C}\u{201D}\u{201E}\u{00AB}\u{00BB}]", with: "\"", options: .regularExpression)
            .replacingOccurrences(of: "[\u{2018}\u{2019}\u{201A}]", with: "'", options: .regularExpression)
        return straight.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
