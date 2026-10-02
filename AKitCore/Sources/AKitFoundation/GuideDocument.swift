import Foundation

/// An in-app guide (`docs/guides/<name>.<language>.md`) read into collapsible sections.
/// The Markdown is kept to a small subset so the same file reads well on GitHub and in the
/// app: `#` title, `##` sections, `###` subsections, paragraphs, `- ` bullets (two levels),
/// `1. ` numbered items, `> ` callouts, fenced code blocks, and inline Markdown. A line
/// `<!-- section: id -->` right after a heading gives the section an id a screen can open.
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

    /// The section with this id, or the subsection's parent and the subsection.
    public func path(to id: String) -> [String]? {
        for section in sections {
            if section.id == id { return [section.id] }
            if let sub = section.subsections.first(where: { $0.id == id }) { return [section.id, sub.id] }
        }
        return nil
    }

    public static func parse(_ text: String) -> GuideDocument {
        var document = GuideDocument(title: "", intro: [], sections: [])
        var paragraph: [String] = []
        var callout: [String] = []
        var code: [String]?
        var taken = Set<String>()

        // Where blocks go now: the intro, a section, or a section's last subsection.
        func append(_ block: Block) {
            if document.sections.isEmpty {
                document.intro.append(block)
            } else if document.sections[document.sections.count - 1].subsections.isEmpty {
                document.sections[document.sections.count - 1].blocks.append(block)
            } else {
                let last = document.sections.count - 1
                document.sections[last].subsections[document.sections[last].subsections.count - 1].blocks.append(block)
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
                guard !document.sections.isEmpty else { continue }
                let last = document.sections.count - 1
                if document.sections[last].subsections.isEmpty, document.sections[last].blocks.isEmpty {
                    taken.remove(document.sections[last].id)
                    document.sections[last].id = uniqueID(id)
                } else if let sub = document.sections[last].subsections.indices.last, document.sections[last].subsections[sub].blocks.isEmpty {
                    taken.remove(document.sections[last].subsections[sub].id)
                    document.sections[last].subsections[sub].id = uniqueID(id)
                }
                continue
            }
            if line.isEmpty || line.hasPrefix("<!--") {
                flush()
                continue
            }
            if line.hasPrefix("### ") {
                flush()
                let title = String(line.dropFirst(4))
                let section = Section(id: uniqueID(slug(title)), title: title, blocks: [], subsections: [])
                if document.sections.isEmpty {
                    document.sections.append(section)
                } else {
                    document.sections[document.sections.count - 1].subsections.append(section)
                }
            } else if line.hasPrefix("## ") {
                flush()
                let title = String(line.dropFirst(3))
                document.sections.append(Section(id: uniqueID(slug(title)), title: title, blocks: [], subsections: []))
            } else if line.hasPrefix("# ") {
                flush()
                document.title = String(line.dropFirst(2))
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
        }
        return text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
    }
}
