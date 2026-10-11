import Foundation

/// Full-text search over every guide and the app's screens: section titles, button names
/// (the bold words of a guide), screenshot captions and the text itself. A query is a few
/// words; all of them must be found, each as the start of a word, in any order. Case, `ё`
/// and Russian word endings don't matter.
public struct GuideSearch: Sendable {
    public enum Kind: Int, Sendable, Hashable {
        /// A screen of the app (a sidebar item).
        case feature
        /// A section title.
        case heading
        /// A button, tab or field name: the query is inside bold text.
        case button
        /// A screenshot, found by its caption.
        case screenshot
        case text
    }

    /// A screen of the app: its name, its one-line summary and its section in a guide.
    public struct Feature: Sendable, Hashable {
        public var id: String
        public var title: String
        public var summary: String
        public var guide: String
        public var section: String

        public init(id: String, title: String, summary: String, guide: String, section: String) {
            self.id = id
            self.title = title
            self.summary = summary
            self.guide = guide
            self.section = section
        }
    }

    public struct Hit: Sendable, Hashable, Identifiable {
        public var id: Int
        public var kind: Kind
        /// The guide's id and the section to open in it.
        public var guide: String
        public var section: String?
        /// Guide title, then section titles down to the place.
        public var breadcrumb: [String]
        /// The screen's, section's or button's name; for text and screenshots the section title.
        public var title: String
        /// The text around the first found word, without Markdown marks.
        public var snippet: String
        /// The screenshot's path, for a screenshot hit.
        public var image: String?
        /// The screen's id, for a feature hit.
        public var feature: String?
    }

    private struct Entry: Sendable {
        var kind: Kind
        var guide: String
        var section: String?
        var breadcrumb: [String]
        var title: String
        var text: String
        var words: [Word]
        /// The parts of `text` that were bold.
        var bold: [Range<String.Index>] = []
        /// Words of the titles above: they may complete a match, not make one.
        var context: [String]
        var image: String?
        var feature: String?
        /// A screen's one-line summary: shown whole instead of a cut of `text`.
        var summary: String?
    }

    struct Word: Sendable, Hashable {
        var text: String
        var range: Range<String.Index>
        var bold: Bool
    }

    private var entries: [Entry] = []

    public init(guides: [(id: String, title: String, document: GuideDocument)], features: [Feature] = []) {
        let titles = Dictionary(guides.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        for feature in features {
            let text = "\(feature.title). \(feature.summary)"
            entries.append(Entry(kind: .feature, guide: feature.guide, section: feature.section,
                                 breadcrumb: [titles[feature.guide] ?? feature.guide], title: feature.title, text: text,
                                 words: Self.words(text), context: [], feature: feature.id, summary: feature.summary))
        }
        for (id, title, document) in guides {
            add(document.intro, guide: id, section: nil, breadcrumb: [title], title: document.title)
            for section in document.sections { add(section, guide: id, breadcrumb: [title]) }
        }
    }

    private mutating func add(_ section: GuideDocument.Section, guide: String, breadcrumb: [String]) {
        let context = breadcrumb.dropFirst().flatMap { Self.words($0).map(\.text) }
        entries.append(Entry(kind: .heading, guide: guide, section: section.id, breadcrumb: breadcrumb, title: section.title,
                             text: section.title, words: Self.words(section.title), context: Array(context)))
        let path = breadcrumb + [section.title]
        add(section.blocks, guide: guide, section: section.id, breadcrumb: path, title: section.title)
        for sub in section.subsections { add(sub, guide: guide, breadcrumb: path) }
    }

    private mutating func add(_ blocks: [GuideDocument.Block], guide: String, section: String?, breadcrumb: [String], title: String) {
        let context = breadcrumb.dropFirst().flatMap { Self.words($0).map(\.text) }
        for block in blocks {
            var image: String?
            if case .image(let path, _) = block { image = path }
            let (text, bold) = Self.plain(block)
            entries.append(Entry(kind: image == nil ? .text : .screenshot, guide: guide, section: section, breadcrumb: breadcrumb,
                                 title: title, text: text, words: Self.words(text, bold: bold), bold: bold, context: Array(context), image: image))
        }
    }

    /// The best hits first: screens, section titles, buttons, screenshots, then text; inside
    /// one kind in reading order.
    public func hits(for query: String, limit: Int = 80) -> [Hit] {
        let terms = Self.terms(query)
        guard !terms.isEmpty else { return [] }
        let phrase = Self.normalized(query).split(separator: " ").joined(separator: " ")
        var found: [(score: Int, order: Int, hit: Hit)] = []
        for (order, entry) in entries.enumerated() {
            var own: [Word] = []
            var missed = false
            for term in terms {
                if let word = entry.words.first(where: { $0.text.hasPrefix(term) }) {
                    own.append(word)
                } else if !entry.context.contains(where: { $0.hasPrefix(term) }) {
                    missed = true
                    break
                }
            }
            guard !missed, let first = own.min(by: { $0.range.lowerBound < $1.range.lowerBound }) else { continue }
            var kind = entry.kind
            var title = entry.title
            // On-screen names are English; a bold Russian phrase is a lead-in, not a button.
            if kind == .text, own.allSatisfy(\.bold), let name = Self.boldSpan(around: first, in: entry),
               !name.unicodeScalars.contains(where: { (0x0400...0x04FF).contains($0.value) }) {
                kind = .button
                title = name
            }
            var score = switch kind {
            case .feature: 100
            case .heading: 80
            case .button: 60
            case .screenshot: 50
            case .text: 20
            }
            if own.count == terms.count { score += 10 }
            if terms.count > 1, Self.normalized(entry.text).contains(phrase) { score += 15 }
            found.append((score, order, Hit(id: order, kind: kind, guide: entry.guide, section: entry.section, breadcrumb: entry.breadcrumb,
                                            title: title, snippet: entry.summary ?? Self.snippet(entry.text, around: first.range),
                                            image: entry.image, feature: entry.feature)))
        }
        return found.sorted { ($0.score, $1.order) > ($1.score, $0.order) }.prefix(limit).map(\.hit)
    }

    /// The places in `text` a query's words are found, for highlighting.
    public static func matches(of query: String, in text: String) -> [Range<String.Index>] {
        let terms = terms(query)
        guard !terms.isEmpty else { return [] }
        return words(text).filter { word in terms.contains { word.text.hasPrefix($0) } }.map(\.range)
    }

    /// The query's words as they are compared: lower-cased, without endings.
    static func terms(_ query: String) -> [String] {
        var seen = Set<String>()
        return words(query).map { stem($0.text) }.filter { seen.insert($0).inserted }
    }

    /// Lower case, `ё` as `е`, no accents.
    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Runs of letters and digits with their place in `text`; `bold` marks the ranges inside `**…**`.
    static func words(_ text: String, bold: [Range<String.Index>] = []) -> [Word] {
        var words: [Word] = []
        var start: String.Index?
        func close(_ end: String.Index) {
            guard let from = start else { return }
            let range = from..<end
            words.append(Word(text: normalized(String(text[range])), range: range,
                              bold: bold.contains { $0.lowerBound <= from && end <= $0.upperBound }))
            start = nil
        }
        for index in text.indices {
            let character = text[index]
            if character.isLetter || character.isNumber {
                if start == nil { start = index }
            } else {
                close(index)
            }
        }
        close(text.endIndex)
        return words
    }

    /// A word without its Russian case ending or English plural `s`, so that «скиллы» finds
    /// «скилл» and «скиллов». Short words stay whole.
    static func stem(_ word: String) -> String {
        guard word.count > 4 else { return word }
        // `й` is `и` after folding.
        let endings = ["иями", "ями", "ами", "ого", "ему", "ому", "ыми", "ими", "ов", "ев", "еи", "ам", "ям", "ах", "ях",
                       "ом", "ем", "ои", "ыи", "ии", "ая", "яя", "ое", "ее", "ые", "ие", "ую", "юю",
                       "а", "я", "о", "е", "ы", "и", "у", "ю", "ь", "s"]
        for ending in endings where word.hasSuffix(ending) && word.count - ending.count >= 4 {
            return String(word.dropLast(ending.count))
        }
        return word
    }

    /// A block's text without `**` and backticks, and where its bold parts are in that text.
    static func plain(_ block: GuideDocument.Block) -> (String, [Range<String.Index>]) {
        let source: String = switch block {
        case .paragraph(let text), .callout(let text), .code(let text): text
        case .bullet(_, let text), .numbered(_, let text): text
        case .image(_, let caption): caption
        }
        var text = ""
        var spans: [(Int, Int)] = []
        var open: Int?
        // `[text](#id)` reads as its text.
        var rest = source.replacing(/\[([^\]]+)\]\([^)\s]*\)/) { $0.output.1 }[...]
        while let mark = rest.range(of: "**") {
            text += rest[..<mark.lowerBound].replacingOccurrences(of: "`", with: "")
            if let from = open {
                spans.append((from, text.count))
                open = nil
            } else {
                open = text.count
            }
            rest = rest[mark.upperBound...]
        }
        text += rest.replacingOccurrences(of: "`", with: "")
        let ranges = spans.map { text.index(text.startIndex, offsetBy: $0.0)..<text.index(text.startIndex, offsetBy: $0.1) }
        return (text, ranges)
    }

    /// The whole bold name the word is part of: «Move to Project…» for `project`.
    private static func boldSpan(around word: Word, in entry: Entry) -> String? {
        entry.bold.first { $0.lowerBound <= word.range.lowerBound && word.range.upperBound <= $0.upperBound }
            .map { String(entry.text[$0]) }
    }

    /// About 200 characters of `text` around `range`, cut at word ends.
    static func snippet(_ text: String, around range: Range<String.Index>, length: Int = 200) -> String {
        guard text.count > length else { return text }
        let lead = min(text.distance(from: text.startIndex, to: range.lowerBound), 60)
        var from = text.index(range.lowerBound, offsetBy: -lead)
        while from > text.startIndex, from < range.lowerBound, text[text.index(before: from)] != " " { from = text.index(after: from) }
        var to = text.index(from, offsetBy: length, limitedBy: text.endIndex) ?? text.endIndex
        while to < text.endIndex, to > range.upperBound, text[to] != " " { to = text.index(before: to) }
        if to < range.upperBound { to = range.upperBound }
        return (from > text.startIndex ? "…" : "") + text[from..<to].trimmingCharacters(in: .whitespaces) + (to < text.endIndex ? "…" : "")
    }
}
