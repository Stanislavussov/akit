import Foundation

/// Find in a text as a person reads it (a note's Find bar, the words of a search hit): every place
/// `query` is, ignoring case and accents (`е` finds `ё`), left to right and not overlapping. A
/// query of only spaces finds nothing.
public enum TextFind {
    static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    public static func ranges(of query: String, in text: AttributedString) -> [Range<AttributedString.Index>] {
        guard !query.allSatisfy(\.isWhitespace) else { return [] }
        var found: [Range<AttributedString.Index>] = []
        var start = text.startIndex
        while start < text.endIndex, let range = text[start...].range(of: query, options: options), !range.isEmpty {
            found.append(range)
            start = range.upperBound
        }
        return found
    }

    public static func ranges(of query: String, in text: String) -> [Range<String.Index>] {
        guard !query.allSatisfy(\.isWhitespace) else { return [] }
        var found: [Range<String.Index>] = []
        var start = text.startIndex
        while start < text.endIndex, let range = text.range(of: query, options: options, range: start..<text.endIndex), !range.isEmpty {
            found.append(range)
            start = range.upperBound
        }
        return found
    }
}
