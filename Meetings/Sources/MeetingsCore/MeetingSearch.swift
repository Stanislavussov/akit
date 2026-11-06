import Foundation

/// M23: search over the meetings: the title, tags, summary, transcript and own tabs of each, with
/// case and accents ignored. `#tag` words filter by tag. Local only; nothing is sent.
public enum MeetingSearch {
    /// One meeting's searchable text, read from its files.
    public struct Document: Sendable, Equatable {
        public struct Line: Sendable, Equatable {
            /// Where the line is: "Title", "Summary", "Transcript" or an own tab's name.
            public var place: String
            public var text: String
            var folded: String
        }

        public var id: String
        public var tags: [String]
        public var lines: [Line]

        public init(id: String, tags: [String], lines: [(place: String, text: String)]) {
            self.id = id
            self.tags = tags
            self.lines = lines.map { Line(place: $0.place, text: $0.text, folded: MeetingSearch.fold($0.text)) }
        }

        /// The text of one place, for Ask and Similar.
        public func text(_ place: String) -> String {
            lines.filter { $0.place == place }.map(\.text).joined(separator: "\n")
        }
    }

    public static func document(_ meeting: Meeting, store: MeetingStore) -> Document {
        var lines: [(place: String, text: String)] = [("Title", meeting.displayTitle)]
        lines += markdownLines(store.summary(meeting.id)).map { ("Summary", $0) }
        lines += meeting.segments.map { ("Transcript", "[\(timestamp($0.start))] \(meeting.speakerName($0.speaker)): \($0.text)") }
        for tab in meeting.tabs { lines += markdownLines(store.tab(meeting.id, tab)).map { (tab, $0) } }
        return Document(id: meeting.id, tags: meeting.tagList, lines: lines)
    }

    /// The non-empty lines of a page, without Markdown's `#`, `-` and `[ ]` marks.
    static func markdownLines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            var text = line.trimmingCharacters(in: .whitespaces)
            for mark in ["- [ ] ", "- [x] ", "- [X] ", "- ", "* "] where text.hasPrefix(mark) {
                text = String(text.dropFirst(mark.count))
                break
            }
            text = text.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).trimmingCharacters(in: .whitespaces)
            return text.isEmpty || text == "—" ? nil : text
        }
    }

    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// The search field's words: `#tag` words and plain words, both folded.
    public struct Query: Sendable, Equatable {
        public var words: [String]
        public var tags: [String]

        public init(_ text: String) {
            var words: [String] = []
            var tags: [String] = []
            for word in text.split(whereSeparator: \.isWhitespace).map(String.init) {
                if word.hasPrefix("#"), word.count > 1 { tags.append(MeetingSearch.fold(String(word.dropFirst()))) } else { words.append(MeetingSearch.fold(word)) }
            }
            self.words = words
            self.tags = tags
        }

        public var isEmpty: Bool { words.isEmpty && tags.isEmpty }
    }

    /// Where a meeting matched: the first line with the first word (nil for a tag-only search).
    public struct Hit: Sendable, Equatable {
        public var place: String?
        public var snippet: String?
    }

    /// Every word somewhere in the meeting (not all on one line), every `#tag` a tag of it (a
    /// tag matches from its start: `#rel` finds `release`). Nil when it does not match.
    public static func match(_ document: Document, _ query: Query) -> Hit? {
        // `#releaseplan` finds the tag "release plán": spaces out on both sides.
        let tags = document.tags.map { fold($0).replacingOccurrences(of: " ", with: "") }
        for tag in query.tags where !tags.contains(where: { $0.hasPrefix(tag) }) { return nil }
        for word in query.words where !document.lines.contains(where: { $0.folded.contains(word) }) {
            if !tags.contains(where: { $0.contains(word) }) { return nil }
        }
        guard let first = query.words.first else { return Hit(place: nil, snippet: nil) }
        // The line that holds the most words, the first such one.
        let best = document.lines.max { a, b in score(a, query) < score(b, query) }
        guard let best, score(best, query) > 0 else { return Hit(place: "Tags", snippet: document.tags.joined(separator: ", ")) }
        return Hit(place: best.place, snippet: snippet(best.text, around: query.words.first { best.folded.contains($0) } ?? first))
    }

    static func score(_ line: Document.Line, _ query: Query) -> Int {
        query.words.filter { line.folded.contains($0) }.count
    }

    /// About `width` characters of `text` around the first place of `word` (folded).
    static func snippet(_ text: String, around word: String, width: Int = 110) -> String {
        guard text.count > width else { return text }
        let folded = fold(text)
        // Folding keeps the characters' count for Latin and Cyrillic text, so offsets carry over.
        let offset = folded.range(of: word).map { folded.distance(from: folded.startIndex, to: $0.lowerBound) } ?? 0
        var start = max(0, min(offset - width / 3, text.count - width))
        // Start at a word: after the next space, when one is near and before the match.
        if start > 0, let space = text.dropFirst(start).prefix(min(20, max(0, offset - start))).firstIndex(of: " ") {
            start = text.distance(from: text.startIndex, to: space) + 1
        }
        let from = text.index(text.startIndex, offsetBy: start)
        let to = text.index(from, offsetBy: width, limitedBy: text.endIndex) ?? text.endIndex
        return (start > 0 ? "…" : "") + text[from..<to].trimmingCharacters(in: .whitespaces) + (to < text.endIndex ? "…" : "")
    }

    // MARK: Similar (M24)

    /// Up to `limit` meetings most like `id`, by the words of their title, tags and summary
    /// (TF-IDF cosine). Local, no model.
    public static func similar(to id: String, in documents: [Document], limit: Int = 5) -> [(id: String, score: Double)] {
        let bags = documents.map { doc in (doc.id, words(doc.lines.filter { $0.place == "Title" || $0.place == "Summary" }.map(\.folded) + doc.tags.map(fold))) }
        guard let mine = bags.first(where: { $0.0 == id })?.1, !mine.isEmpty else { return [] }
        var df: [String: Int] = [:]
        for (_, bag) in bags { for word in bag.keys { df[word, default: 0] += 1 } }
        let n = Double(bags.count)
        func vector(_ bag: [String: Int]) -> [String: Double] {
            bag.reduce(into: [:]) { result, item in result[item.key] = Double(item.value) * log((n + 1) / Double(df[item.key, default: 0] + 1)) }
        }
        let a = vector(mine)
        let normA = sqrt(a.values.reduce(0) { $0 + $1 * $1 })
        guard normA > 0 else { return [] }
        var scored: [(id: String, score: Double)] = []
        for (other, bag) in bags where other != id {
            let b = vector(bag)
            let dot = a.reduce(0) { $0 + $1.value * (b[$1.key] ?? 0) }
            let normB = sqrt(b.values.reduce(0) { $0 + $1 * $1 })
            if dot > 0, normB > 0 { scored.append((other, dot / (normA * normB))) }
        }
        return Array(scored.filter { $0.score >= 0.05 }.sorted { $0.score > $1.score }.prefix(limit))
    }

    /// Word counts of folded lines: letters and digits, 3 characters or more.
    static func words(_ lines: [String]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for line in lines {
            for word in line.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) where word.count >= 3 {
                counts[String(word), default: 0] += 1
            }
        }
        return counts
    }
}
