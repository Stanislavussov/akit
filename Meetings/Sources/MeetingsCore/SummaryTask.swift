import Foundation

/// The open tasks of a summary page (`- [ ] owner: text`).
public struct SummaryTask: Sendable, Equatable, Identifiable {
    public var owner: String
    public var text: String
    public var id: String { owner + ": " + text }

    public static func open(in summary: String) -> [SummaryTask] {
        summary.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- [ ] ") else { return nil }
            let rest = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            guard !rest.isEmpty else { return nil }
            if let colon = rest.firstIndex(of: ":"), rest.distance(from: rest.startIndex, to: colon) <= 40 {
                let owner = rest[..<colon].trimmingCharacters(in: .whitespaces)
                let text = rest[rest.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if !owner.isEmpty, !text.isEmpty { return SummaryTask(owner: owner, text: text) }
            }
            return SummaryTask(owner: "", text: rest)
        }
    }
}

/// The text of the summary's `## Summary` section on one line, cut after `maxSentences`
/// sentences (M25: the Work Log entry's summary).
public func summaryParagraph(_ summary: String, maxSentences: Int = 2) -> String? {
    var lines: [Substring] = []
    var inside = false
    for line in summary.split(whereSeparator: \.isNewline) {
        if line.hasPrefix("#") {
            if inside { break }
            inside = line.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased() == "summary"
            continue
        }
        if inside { lines.append(line) }
    }
    let text = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && $0 != "—" }.joined(separator: " ")
    guard !text.isEmpty else { return nil }
    var sentences: [String] = []
    var current = ""
    for character in text {
        current.append(character)
        if ".!?".contains(character) {
            sentences.append(current.trimmingCharacters(in: .whitespaces))
            current = ""
            if sentences.count == maxSentences { break }
        }
    }
    if sentences.count < maxSentences, !current.trimmingCharacters(in: .whitespaces).isEmpty { sentences.append(current.trimmingCharacters(in: .whitespaces)) }
    return sentences.joined(separator: " ")
}
