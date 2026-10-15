import AKitFoundation
import Foundation

/// What the user looks at when they ask: the screen, a short summary of what it shows, and
/// the element they asked about (a row, a metric, a badge), with its visible values.
public struct AskContext: Sendable, Hashable {
    public struct Element: Sendable, Hashable {
        public var title: String
        /// Short `label: value` lines, as on screen.
        public var facts: String

        public init(title: String, facts: String) {
            self.title = title
            self.facts = facts
        }
    }

    /// The sidebar section's id, which is also its section id in the screens guide.
    public var screen: String
    public var screenTitle: String
    public var summary: String
    public var element: Element?

    public init(screen: String, screenTitle: String, summary: String, element: Element? = nil) {
        self.screen = screen
        self.screenTitle = screenTitle
        self.summary = summary
        self.element = element
    }

    /// The context as it is sent: the screen, what it shows, the element.
    public var text: String {
        var lines = ["Screen: \(screenTitle)"]
        let summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty { lines += ["What the screen shows now:", summary] }
        if let element {
            lines.append("The question is about: \(element.title)")
            let facts = element.facts.trimmingCharacters(in: .whitespacesAndNewlines)
            if !facts.isEmpty { lines.append(facts) }
        }
        return lines.joined(separator: "\n")
    }
}

extension AskContext {
    /// Stands for a text that must not leave as screen data.
    public static let redacted = "‹session text›"

    /// The context with every occurrence of `texts` replaced by `redacted`, in the summary, the
    /// element's title and its facts. Ask AKit sends setup data (names, counts, ids, statuses),
    /// never text from sessions: this is the backstop for session titles (first prompts), mode
    /// names and definitions, and notes that a fact line might still quote.
    ///
    /// Whole words only, case-insensitive, with any non-letters between them, so a slug of the
    /// text (`fix-the-login-bug-1a2b`) is caught too. Only texts of at least 3 words or 16
    /// characters count: a short title such as "status" would blank out ordinary words. Linear in
    /// the words of the context times the texts that start with each word, so thousands of
    /// session titles are fine; still, call it off the main actor.
    ///
    /// `ids`: ids made from session words (an emergent mode's slug, a session task's prompt
    /// slug). They count whatever their length, matched as one exact token, case-insensitive:
    /// not inside a longer token of letters, digits, `-` or `_`, so `export-1a2b` is caught and
    /// a plain "Export" isn't.
    ///
    /// `names`: names made from session words (an emergent mode's name), matched like `texts`
    /// as whole word sequences but whatever their length: "Scope creep" is caught, the word
    /// "scope" alone isn't.
    public func redacting(_ texts: [String], ids: [String] = [], names: [String] = []) -> AskContext {
        let ids = Set(ids.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }).sorted { $0.count > $1.count }
        var byFirst: [String: [[String]]] = [:]
        for text in texts {
            let words = Self.words(text).map(\.word)
            guard let first = words.first, words.count >= 3 || text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 16 else { continue }
            byFirst[first, default: []].append(words)
        }
        for name in names {
            let words = Self.words(name).map(\.word)
            if let first = words.first { byFirst[first, default: []].append(words) }
        }
        guard !byFirst.isEmpty || !ids.isEmpty else { return self }
        for key in byFirst.keys { byFirst[key]?.sort { $0.count > $1.count } }
        func clean(_ text: String) -> String {
            let words = Self.words(text)
            var cuts: [Range<String.Index>] = []
            var index = 0
            while index < words.count {
                // Progress: the longest match from here, else one word on.
                var matched = 1
                for needle in byFirst[words[index].word] ?? [] where index + needle.count <= words.count {
                    if zip(needle, words[index..<(index + needle.count)]).allSatisfy({ $0 == $1.word }) {
                        cuts.append(words[index].range.lowerBound..<words[index + needle.count - 1].range.upperBound)
                        matched = needle.count
                        break
                    }
                }
                index += matched
            }
            var result = text
            for cut in cuts.reversed() { result.replaceSubrange(cut, with: Self.redacted) }
            for id in ids { result = Self.replacingToken(id, in: result) }
            return result
        }
        var copy = self
        copy.summary = clean(summary)
        copy.element = element.map { Element(title: clean($0.title), facts: clean($0.facts)) }
        return copy
    }

    /// `text` with every whole-token occurrence of `token` replaced by `redacted`.
    static func replacingToken(_ token: String, in text: String) -> String {
        func joins(_ character: Character) -> Bool { character.isLetter || character.isNumber || character == "-" || character == "_" }
        var result = text
        var from = result.startIndex
        while let found = result.range(of: token, options: .caseInsensitive, range: from..<result.endIndex) {
            let before = found.lowerBound > result.startIndex ? result[result.index(before: found.lowerBound)] : nil
            let after = found.upperBound < result.endIndex ? result[found.upperBound] : nil
            if before.map(joins) != true && after.map(joins) != true {
                result.replaceSubrange(found, with: redacted)
                from = result.index(found.lowerBound, offsetBy: redacted.count)
            } else {
                // Progress: on past the first character of this match.
                from = result.index(after: found.lowerBound)
            }
        }
        return result
    }

    /// Runs of letters and digits, lower-cased, with their place in `text`.
    static func words(_ text: String) -> [(word: String, range: Range<String.Index>)] {
        var found: [(word: String, range: Range<String.Index>)] = []
        var start: String.Index?
        for index in text.indices {
            if text[index].isLetter || text[index].isNumber {
                if start == nil { start = index }
            } else if let from = start {
                found.append((text[from..<index].lowercased(), from..<index))
                start = nil
            }
        }
        if let from = start { found.append((text[from...].lowercased(), from..<text.endIndex)) }
        return found
    }
}

/// One message of an Ask AKit chat.
public struct AskTurn: Sendable, Hashable {
    public enum Role: Sendable, Hashable {
        case user
        case assistant
    }

    public var role: Role
    public var text: String

    public init(role: Role, text: String) {
        self.role = role
        self.text = text
    }
}

/// Ask AKit: a question about the screen, answered in one model call from AKit's own guides
/// and the data on the screen (`docs/design/ask-akit.md`). This part is pure: the guide sections
/// picked, the text sent, and the answer read back. The app opens the send gate and calls.
public enum AskAKit {
    /// A guide as the prompt and the search see it.
    public typealias Guide = (id: String, title: String, document: GuideDocument)

    /// The screens guide: every screen's own section has the screen's id.
    public static let screensGuide = "screens"
    /// The glossary guide (`docs/guides/terms.ru.md`): its matching entries always go first.
    public static let glossaryGuide = "terms"
    /// Guide text sent with one question, at most.
    public static let guideBudget = 40_000
    /// The glossary's share of it, at most.
    public static let glossaryBudget = 8_000
    /// Earlier turns sent with a question, at most.
    public static let historyBudget = 12_000
    public static let historyTurns = 8
    /// One earlier turn longer than this is cut.
    public static let turnLimit = 4_000
    /// A question longer than this is cut (the panel says so).
    public static let questionLimit = turnLimit

    /// The JSON answer Claude Code checks (Pi gets it in the prompt).
    public static let schema = #"{"type":"object","properties":{"answer":{"type":"string"}},"required":["answer"],"additionalProperties":false}"#

    /// A guide section: sent with a question, or cited by an answer.
    public struct Source: Sendable, Hashable, Identifiable {
        public var guide: String
        public var section: String
        public var title: String
        public var id: String { "\(guide)#\(section)" }

        public init(guide: String, section: String, title: String) {
            self.guide = guide
            self.section = section
            self.title = title
        }
    }

    public struct Prepared: Sendable {
        public let system: String
        public let input: String
        /// The guide sections sent, in reading order.
        public let sources: [Source]
    }

    /// The text of one call: the system prompt with the picked guide sections, and the input
    /// with the screen, the earlier turns and the question. `language`: the language to answer
    /// in, for a question AKit wrote itself (Ask AKit About This); nil = the question's own.
    public static func prepare(question: String, context: AskContext, history: [AskTurn], guides: [Guide],
                               search: GuideSearch? = nil, budget: Int = guideBudget, language: String? = nil) -> Prepared {
        let pieces = select(question: question, context: context, guides: guides,
                            search: search ?? GuideSearch(guides: guides), budget: budget)
        let guideText = pieces.map(\.text).joined(separator: "\n\n")
        let system = """
            You are Ask AKit, the helper inside AKit, a macOS app that shows and manages the setup of AI coding agents (Claude Code, Pi): their skills, MCP servers, instruction files, sessions, usage, insights, Lab and error analysis.
            The user asks what something on the screen means or how to use it. Answer from the guide sections below and the screen data in the input.
            - \(language.map { "Answer in \($0)." } ?? "Answer in the language of the question.")
            - Use plain, short sentences: one idea per sentence. Short Markdown: paragraphs, `- ` lists, **bold**.
            - Say what the thing means, why it matters, and what to do about it, using the numbers on the screen when they help.
            - Quote button, tab and field names exactly as on screen, in **bold** (they are English).
            - When the guides don't cover the question, say so plainly. Don't invent buttons, numbers or features.
            - Cite the guide sections you used as Markdown links in the form [title](guide#section), as the headings below give them, e.g. [Skills](screens#skills).
            Answer with JSON only: {"answer": "<your Markdown answer>"}.

            # Guide sections

            \(guideText.isEmpty ? "(none found)" : guideText)
            """
        var input = [context.text]
        let earlier = recent(history)
        if !earlier.isEmpty {
            input.append("Earlier in this chat:\n" + earlier.map { "\($0.role == .user ? "User" : "Ask AKit"): \($0.text)" }
                .joined(separator: "\n\n"))
        }
        input.append("Question: \(String(question.trimmingCharacters(in: .whitespacesAndNewlines).prefix(questionLimit)))")
        return Prepared(system: system, input: input.joined(separator: "\n\n"),
                        sources: pieces.map { Source(guide: $0.guide, section: $0.id, title: $0.title) })
    }

    /// The answer's Markdown: the "answer" of the JSON asked for, or the text as it came when
    /// the model answered without JSON.
    public static func answer(from text: String) -> String {
        if let field = answerField(in: text) { return field.trimmingCharacters(in: .whitespacesAndNewlines) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The guide sections an answer links to, in order, once each: `[title](guide#id)`, or
    /// `[title](#id)` found in any guide (the screens guide first). Links to sections no guide
    /// has, and web links, are left out.
    public static func sources(in answer: String, guides: [Guide]) -> [Source] {
        var ids: [String: [String: String]] = [:]
        for guide in guides {
            var titles: [String: String] = [:]
            func add(_ section: GuideDocument.Section) {
                titles[section.id] = section.title
                section.subsections.forEach(add)
            }
            guide.document.sections.forEach(add)
            ids[guide.id] = titles
        }
        let order = guides.map(\.id).sorted { ($0 == screensGuide ? 0 : 1) < ($1 == screensGuide ? 0 : 1) }
        var found: [Source] = []
        for match in answer.matches(of: /\[([^\]]+)\]\(([^)\s]+)\)/) {
            let target = String(match.output.2)
            guard !target.contains(":"), let hash = target.firstIndex(of: "#") else { continue }
            let named = String(target[..<hash])
            let section = String(target[target.index(after: hash)...])
            let guide = named.isEmpty ? order.first { ids[$0]?[section] != nil } : named
            guard let guide, let title = ids[guide]?[section] else { continue }
            let source = Source(guide: guide, section: section, title: title)
            if !found.contains(source) { found.append(source) }
        }
        return found
    }

    /// The newest turns that fit: at most `historyTurns`, `historyBudget` characters in all,
    /// each cut at `turnLimit`; oldest first.
    static func recent(_ history: [AskTurn]) -> [AskTurn] {
        var kept: [AskTurn] = []
        var used = 0
        for turn in history.reversed().prefix(historyTurns) {
            var turn = turn
            if turn.text.count > turnLimit { turn.text = String(turn.text.prefix(turnLimit)) + "…" }
            guard used + turn.text.count <= historyBudget else { break }
            used += turn.text.count
            kept.append(turn)
        }
        return kept.reversed()
    }

    // MARK: - Picking guide sections

    /// A section's own text (without its subsections), as sent.
    struct Piece: Hashable {
        var guide: String
        var id: String
        var title: String
        /// Reading order across all guides.
        var order: Int
        /// The ids from the top section down to this one.
        var path: [String]
        var text: String
    }

    /// Whole sections, at most `budget` characters: the screen's own section and what's on it,
    /// the glossary entries for the question's words, the sections the search ranks best for the
    /// question and the element, then more of the screen's sections while room is left.
    static func select(question: String, context: AskContext, guides: [Guide], search: GuideSearch, budget: Int) -> [Piece] {
        let pieces = Self.pieces(guides)
        let byKey = Dictionary(pieces.map { ("\($0.guide)#\($0.id)", $0) }, uniquingKeysWith: { first, _ in first })
        var chosen: [Piece] = []
        var used = 0
        @discardableResult
        func take(_ piece: Piece, limit: Int = budget) -> Bool {
            guard !chosen.contains(piece), used + piece.text.count <= min(limit, budget) else { return false }
            chosen.append(piece)
            used += piece.text.count
            return true
        }

        // The screen: its own section, then its first subsection (what's on the screen). Its own
        // section always goes, cut at a line to fit when it is longer than the budget.
        let screen = pieces.filter { $0.guide == screensGuide && $0.path.contains(context.screen) }
        if let own = screen.first(where: { $0.id == context.screen }), !take(own) {
            var cut = own
            let note = "\n… (cut to fit)"
            let room = max(0, budget - used - note.count)
            var text = String(own.text.prefix(room))
            if let line = text.lastIndex(of: "\n") { text = String(text[..<line]) }
            cut.text = text + note
            if cut.text.count <= budget - used {
                chosen.append(cut)
                used += cut.text.count
            }
        }
        if let first = screen.first(where: { $0.path.count == (screen.first?.path.count ?? 0) + 1 }) { take(first, limit: budget / 2) }

        // Ranked: the whole question and the element's title weigh more than one of their words.
        let element = context.element?.title ?? ""
        var queries: [(String, Int)] = [(question, 3)]
        if !element.isEmpty { queries.append((element, 3)) }
        var words: [String] = []
        for term in GuideSearch.terms(question + " " + element) where term.count >= 4 && !stopWords.contains(term) && !words.contains(term) {
            words.append(term)
        }
        queries += words.prefix(12).map { ($0, 1) }
        var scores: [String: Int] = [:]
        for (query, weight) in queries {
            var seen = Set<String>()
            for hit in search.hits(for: query, limit: 60) {
                guard let section = hit.section else { continue }
                let key = "\(hit.guide)#\(section)"
                // One hit per section and query: a section that says the word ten times isn't ten times better.
                guard seen.insert(key).inserted else { continue }
                let kind = switch hit.kind {
                case .feature: 5
                case .heading: 4
                case .button: 3
                case .screenshot: 2
                case .text: 1
                }
                scores[key, default: 0] += kind * weight
            }
        }

        // A section of the user's screen is likelier the one meant.
        for piece in screen where scores["\(piece.guide)#\(piece.id)"] != nil { scores["\(piece.guide)#\(piece.id)", default: 0] += 2 }

        // The glossary first, within its share.
        let glossaryLimit = used + glossaryBudget
        for key in ranked(scores) where key.hasPrefix(glossaryGuide + "#") {
            if let piece = byKey[key] { take(piece, limit: glossaryLimit) }
        }
        for key in ranked(scores) {
            if let piece = byKey[key] { take(piece) }
        }
        for piece in screen { take(piece) }
        return chosen.sorted { $0.order < $1.order }
    }

    private static func ranked(_ scores: [String: Int]) -> [String] {
        scores.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
    }

    /// Question words that find everything and mean nothing.
    static let stopWords: Set<String> = [
        "что", "это", "такое", "значит", "означает", "почему", "зачем", "когда", "можно", "нужно", "делать", "сделать",
        "этот", "эта", "здесь", "тут", "какой", "какая", "какие", "where", "what", "does", "mean", "means", "this", "that",
        "with", "about", "should", "here", "there", "which", "when", "why", "how",
    ].reduce(into: Set<String>()) { set, word in set.formUnion(GuideSearch.terms(word)) }

    /// Every section of every guide as a piece, in reading order.
    static func pieces(_ guides: [Guide]) -> [Piece] {
        var pieces: [Piece] = []
        func add(_ section: GuideDocument.Section, guide: String, path: [String], titles: [String], depth: Int) {
            let path = path + [section.id]
            let titles = titles + [section.title]
            var lines = [String(repeating: "#", count: min(depth + 2, 6)) + " \(titles.joined(separator: " › ")) (link: \(guide)#\(section.id))"]
            lines += section.blocks.map { text(of: $0, guide: guide) }
            pieces.append(Piece(guide: guide, id: section.id, title: section.title, order: pieces.count, path: path,
                                text: lines.joined(separator: "\n")))
            for sub in section.subsections { add(sub, guide: guide, path: path, titles: titles, depth: depth + 1) }
        }
        for guide in guides {
            for section in guide.document.sections { add(section, guide: guide.id, path: [], titles: [guide.title], depth: 0) }
        }
        return pieces
    }

    /// A block as Markdown, with this guide's `(#id)` links made `(guide#id)`.
    static func text(of block: GuideDocument.Block, guide: String) -> String {
        let text: String = switch block {
        case .paragraph(let text): text
        case .bullet(let level, let text): (level > 0 ? "  - " : "- ") + text
        case .numbered(let number, let text): "\(number). \(text)"
        case .callout(let text): "> \(text)"
        case .code(let text): "```\n\(text)\n```"
        case .image(_, let caption): "[Screenshot: \(caption)]"
        }
        if case .code = block { return text }
        return text.replacing(/\]\(#/) { _ in "](\(guide)#" }
    }

    /// The "answer" of the JSON object in the text: the whole text, or from one of the first 64
    /// `{` to the last `}` (prose or a fence around it). At most 65 parses, not one per pair.
    static func answerField(in text: String) -> String? {
        func parse(_ part: Substring) -> String? {
            (try? JSONSerialization.jsonObject(with: Data(part.utf8)) as? [String: Any])?["answer"] as? String
        }
        if let whole = parse(text[...]) { return whole }
        guard let end = text.lastIndex(of: "}") else { return nil }
        for start in text.indices.lazy.filter({ text[$0] == "{" }).prefix(64) where start < end {
            if let found = parse(text[start...end]) { return found }
        }
        return nil
    }

    // MARK: - Links in an answer

    /// What a link in an answer may open.
    public enum LinkTarget: Equatable, Sendable {
        /// A guide section a guide has: the Guide window opens it.
        case guide(Source)
        /// An `https` page: the browser opens it.
        case web(URL)
        /// Anything else (a file, an app's own scheme, a section no guide has): nothing opens.
        case discard
    }

    public static func linkTarget(_ url: URL, guides: [Guide]) -> LinkTarget {
        if url.scheme?.lowercased() == "https", url.host() != nil { return .web(url) }
        guard url.scheme == nil, url.relativeString.contains("#") else { return .discard }
        return sources(in: "[link](\(url.relativeString))", guides: guides).first.map { .guide($0) } ?? .discard
    }
}
