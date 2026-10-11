import Foundation

/// An in-app guide (`docs/guides/<name>.<language>.md`) read into collapsible sections.
/// The Markdown is kept to a small subset so the same file reads well on GitHub and in the
/// app: `#` title, `##` sections, `###` and `####` subsections, paragraphs, `- ` bullets (two
/// levels), `1. ` numbered items, `> ` callouts, fenced code blocks, `![caption](images/x.png)`
/// screenshots on their own line, and inline Markdown; a link `[text](#id)` opens that section.
/// A line `<!-- section: id -->` right after a heading gives the section an id a screen can open.
public struct GuideDocument: Sendable, Hashable {
    public enum Block: Sendable, Hashable {
        /// Inline Markdown text.
        case paragraph(String)
        /// A bullet item; level 0 or 1.
        case bullet(level: Int, text: String)
        case numbered(number: Int, text: String)
        /// A tip or warning: the lines of a `> ` quote, joined.
        case callout(String)
        case code(String)
        /// A screenshot: a path next to the guide file and the caption under it, which says
        /// what the picture shows (search reads it).
        case image(path: String, caption: String)
    }

    public struct Section: Sendable, Hashable, Identifiable {
        /// The id from `<!-- section: id -->`, else one made from the title.
        public var id: String
        public var title: String
        public var blocks: [Block]
        public var subsections: [Section]

        /// Whether the section or one of its subsections mentions `text` (case-insensitive).
        public func contains(_ text: String) -> Bool {
            title.localizedCaseInsensitiveContains(text)
                || blocks.contains { $0.plainText.localizedCaseInsensitiveContains(text) }
                || subsections.contains { $0.contains(text) }
        }
    }

    public var title: String
    /// What comes before the first section.
    public var intro: [Block]
    public var sections: [Section]

    /// The ids from a top section down to the section with this id.
    public func path(to id: String) -> [String]? {
        func find(_ sections: [Section]) -> [String]? {
            for section in sections {
                if section.id == id { return [section.id] }
                if let rest = find(section.subsections) { return [section.id] + rest }
            }
            return nil
        }
        return find(sections)
    }

    public static func parse(_ text: String) -> GuideDocument {
        var document = GuideDocument(title: "", intro: [], sections: [])
        var paragraph: [String] = []
        var callout: [String] = []
        var code: [String]?
        var taken = Set<String>()
        // Indexes from `document.sections` down to the section being read; empty in the intro.
        var current: [Int] = []

        func append(_ block: Block) {
            if current.isEmpty {
                document.intro.append(block)
            } else {
                edit(&document.sections, current[...]) { $0.blocks.append(block) }
            }
        }
        func flush() {
            if !paragraph.isEmpty {
                append(.paragraph(paragraph.joined(separator: " ")))
                paragraph = []
            }
            if !callout.isEmpty {
                append(.callout(callout.joined(separator: " ")))
                callout = []
            }
        }
        func uniqueID(_ base: String) -> String {
            var id = base.isEmpty ? "section" : base
            var counter = 2
            while taken.contains(id) {
                id = "\(base)-\(counter)"
                counter += 1
            }
            taken.insert(id)
            return id
        }
        // A heading of `depth` 0 (`##`), 1 (`###`) or 2 (`####`); one without a parent moves up.
        func open(_ title: String, depth: Int) {
            flush()
            let section = Section(id: uniqueID(slug(title)), title: title, blocks: [], subsections: [])
            let parent = Array(current.prefix(depth))
            if parent.isEmpty {
                document.sections.append(section)
                current = [document.sections.count - 1]
            } else {
                var index = 0
                edit(&document.sections, parent[...]) {
                    $0.subsections.append(section)
                    index = $0.subsections.count - 1
                }
                current = parent + [index]
            }
        }

        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if var lines = code {
                if line.hasPrefix("```") {
                    append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    lines.append(raw)
                    code = lines
                }
                continue
            }
            if line.hasPrefix("```") {
                flush()
                code = []
                continue
            }
            if let id = sectionID(line) {
                // Gives the heading just read its id.
                guard !current.isEmpty else { continue }
                edit(&document.sections, current[...]) { section in
                    guard section.blocks.isEmpty, section.subsections.isEmpty else { return }
                    taken.remove(section.id)
                    section.id = uniqueID(id)
                }
                continue
            }
            if line.isEmpty || line.hasPrefix("<!--") {
                flush()
                continue
            }
            if line.hasPrefix("#### ") {
                open(String(line.dropFirst(5)), depth: 2)
            } else if line.hasPrefix("### ") {
                open(String(line.dropFirst(4)), depth: 1)
            } else if line.hasPrefix("## ") {
                open(String(line.dropFirst(3)), depth: 0)
            } else if line.hasPrefix("# ") {
                flush()
                document.title = String(line.dropFirst(2))
            } else if let (caption, path) = image(line) {
                flush()
                append(.image(path: path, caption: caption))
            } else if line.hasPrefix(">") {
                if !paragraph.isEmpty {
                    append(.paragraph(paragraph.joined(separator: " ")))
                    paragraph = []
                }
                callout.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flush()
                let indent = raw.prefix { $0 == " " }.count
                append(.bullet(level: indent >= 2 ? 1 : 0, text: String(line.dropFirst(2))))
            } else if let (number, rest) = numbered(line) {
                flush()
                append(.numbered(number: number, text: rest))
            } else if !callout.isEmpty {
                callout.append(line)
            } else {
                paragraph.append(line)
            }
        }
        if let lines = code { append(.code(lines.joined(separator: "\n"))) }
        flush()
        return document
    }

    /// Changes the section at `path` (indexes from `sections` down).
    private static func edit(_ sections: inout [Section], _ path: ArraySlice<Int>, _ change: (inout Section) -> Void) {
        guard let first = path.first else { return }
        if path.count == 1 {
            change(&sections[first])
        } else {
            edit(&sections[first].subsections, path.dropFirst(), change)
        }
    }

    /// `![caption](images/name.png)` alone on a line → (caption, path).
    static func image(_ line: String) -> (String, String)? {
        guard line.hasPrefix("!["), line.hasSuffix(")"), let middle = line.range(of: "](", options: .backwards) else { return nil }
        let caption = String(line[line.index(line.startIndex, offsetBy: 2)..<middle.lowerBound])
        let path = String(line[middle.upperBound...].dropLast())
        return path.isEmpty ? nil : (caption, path)
    }

    /// `<!-- section: id -->` → `id`.
    static func sectionID(_ line: String) -> String? {
        guard line.hasPrefix("<!--"), line.hasSuffix("-->"), let colon = line.range(of: "section:") else { return nil }
        let id = line[colon.upperBound...].dropLast(3).trimmingCharacters(in: .whitespaces)
        return id.isEmpty ? nil : id
    }

    /// `12. text` → (12, "text").
    static func numbered(_ line: String) -> (Int, String)? {
        guard let dot = line.firstIndex(of: "."), let number = Int(line[..<dot]), number >= 0,
              line.index(after: dot) < line.endIndex, line[line.index(after: dot)] == " " else { return nil }
        return (number, String(line[line.index(dot, offsetBy: 2)...]))
    }

    /// Letters and digits of a title, lower-cased and joined by `-`.
    static func slug(_ title: String) -> String {
        title.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: "-")
    }
}

extension GuideDocument.Block {
    /// The text without Markdown marks, for search.
    public var plainText: String {
        let text: String = switch self {
        case .paragraph(let text), .callout(let text), .code(let text): text
        case .bullet(_, let text), .numbered(_, let text): text
        case .image(_, let caption): caption
        }
        return text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
    }
}
