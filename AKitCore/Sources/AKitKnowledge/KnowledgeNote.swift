import AKitFoundation
import Foundation
import Yams

/// A Markdown note of a base: its `---` frontmatter (read with Yams, never written back), its
/// title and its `##` sections. Edits are text edits (P4): only the bytes of the changed section
/// change; the frontmatter, line ends, a BOM and every other byte stay as they were.
public struct KnowledgeNote: Sendable, Equatable {
    public struct Failure: Error, LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// One `## Heading` and the text up to the next heading of level 1 or 2.
    public struct Section: Sendable, Equatable {
        public let heading: String
        /// The heading line, its line end included.
        public let headingRange: Range<String.Index>
        /// The section's text after the heading line, up to the next `#`/`##` heading or the end.
        public let bodyRange: Range<String.Index>
    }

    public let text: String

    public init(text: String) { self.text = text }

    /// nil when the file can't be read or isn't UTF-8 (a note is never rewritten from lossy text).
    public static func load(_ url: URL) -> KnowledgeNote? {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return nil }
        return KnowledgeNote(text: text)
    }

    /// Writes the text atomically, byte for byte.
    public func write(to url: URL) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    // MARK: - Frontmatter

    /// The lines of the text, each with its line end.
    private var lines: [Substring] {
        var result: [Substring] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text[start...].firstIndex(where: \.isNewline).map { text.index(after: $0) } ?? text.endIndex
            result.append(text[start..<end])
            start = end
        }
        return result
    }

    /// Where the body starts: after the closing `---` line, or the start without frontmatter.
    private var bodyStart: String.Index {
        let lines = lines
        guard let header = Frontmatter.header(in: lines.map { String($0).trimmingCharacters(in: .newlines) }) else { return text.startIndex }
        return lines[header.upperBound].endIndex
    }

    /// The frontmatter as YAML values (lists and maps included); empty without one or when it doesn't parse.
    public var frontmatter: [String: Any] {
        let lines = lines
        guard let header = Frontmatter.header(in: lines.map { String($0).trimmingCharacters(in: .newlines) }) else { return [:] }
        let yaml = lines[header].joined()
        return ((try? Yams.load(yaml: yaml)) as? [String: Any]) ?? [:]
    }

    private func string(_ key: String) -> String? {
        guard let value = frontmatter[key] else { return nil }
        let text = "\(value)".trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    public var kind: String? { string("kind") }
    /// Whether `description:` holds a line: what agents read before they open the note.
    public var hasDescription: Bool {
        guard let value = frontmatter["description"], !(value is NSNull) else { return false }
        return !"\(value)".trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    /// The repository's git remote URL, or a `~/` path (K12).
    public var repo: String? { string("repo") }
    /// The system's folder on this Mac, a `~/` or absolute path (K27): a repository's local
    /// copy, or a folder without git like a local wiki.
    public var path: String? { string("path") }
    /// Paths inside the repository (K12); one string counts as a list of one.
    public var files: [String] {
        switch frontmatter["files"] {
        case let list as [Any]: list.map { "\($0)" }
        case let one as String: [one]
        default: []
        }
    }

    // MARK: - Properties (frontmatter edits, P4)

    /// A property's value: one string, or a list written `[a, b]`. JSON: a string or an array.
    public enum PropertyValue: Sendable, Equatable, Encodable {
        case string(String)
        case list([String])

        /// A parsed frontmatter value: a YAML list is a list, an empty value "", anything else its text.
        public init(_ value: Any) {
            if let list = value as? [Any] { self = .list(list.map { "\($0)" }) } else { self = .string(value is NSNull ? "" : "\(value)") }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let text): try container.encode(text)
            case .list(let items): try container.encode(items)
            }
        }

        /// As a form shows it: a list as `[a, b]`.
        public var display: String {
            switch self {
            case .string(let text): text
            case .list(let items): "[" + items.joined(separator: ", ") + "]"
            }
        }

        /// `[a, b]` is a list (empty items dropped); anything else is one string, trimmed.
        public static func parse(_ text: String) -> PropertyValue {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { return .string(trimmed) }
            return .list(trimmed.dropFirst().dropLast().split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        }

        /// The value as it is written after `key: `.
        var yaml: String {
            switch self {
            case .string(let text): Self.scalar(text)
            case .list(let items): "[" + items.map(Self.flowItem).joined(separator: ", ") + "]"
            }
        }

        /// The text bare when YAML reads it back as exactly this string, else double-quoted.
        static func scalar(_ text: String) -> String {
            reads("k: \(text)", as: text) ? text : quoted(text)
        }

        /// A list item bare when YAML reads `[item]` back as exactly it, else double-quoted.
        static func flowItem(_ text: String) -> String {
            guard !text.contains(where: \.isNewline), !text.isEmpty,
                  let list = (try? Yams.load(yaml: "k: [\(text)]") as? [String: Any])?["k"] as? [Any],
                  list.count == 1, list[0] as? String == text else { return quoted(text) }
            return text
        }

        private static func reads(_ yaml: String, as text: String) -> Bool {
            !text.isEmpty && !text.contains(where: \.isNewline)
                && ((try? Yams.load(yaml: yaml)) as? [String: Any])?["k"] as? String == text
        }

        private static func quoted(_ text: String) -> String {
            var escaped = ""
            for scalar in text.unicodeScalars {
                switch scalar {
                case "\\": escaped += "\\\\"
                case "\"": escaped += "\\\""
                case "\n": escaped += "\\n"
                case "\r": escaped += "\\r"
                case "\t": escaped += "\\t"
                default: escaped.unicodeScalars.append(scalar)
                }
            }
            return "\"\(escaped)\""
        }

        /// Whether a parsed frontmatter value is this one.
        func matches(_ value: Any?) -> Bool {
            switch self {
            case .string(let text): (value as? String) == text
            case .list(let items): (value as? [Any])?.map { "\($0)" } == items
            }
        }
    }

    /// The frontmatter's top-level keys and values (empty without one or when it doesn't parse).
    public var properties: [String: PropertyValue] { frontmatter.mapValues(PropertyValue.init) }

    /// A frontmatter key AKit writes: letters, digits, `_`, `-` and `.`, starting with a letter,
    /// digit or `_`.
    public static func validKey(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first, key.count <= 64,
              CharacterSet.alphanumerics.contains(first) || first == "_" else { return false }
        return key.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "_-.".unicodeScalars.contains($0) }
    }

    /// The lines of a top-level `key:` in the frontmatter (with its indented or `- ` lines);
    /// nil when the header has no such key.
    private func span(of key: String, in lines: [Substring], header: Range<Int>) -> Range<Int>? {
        let quotes = CharacterSet(charactersIn: "\"'")
        for index in header {
            let line = lines[index].trimmingCharacters(in: .newlines)
            guard let first = line.first, !" \t#-".contains(first), let colon = line.firstIndex(of: ":") else { continue }
            let after = line[line.index(after: colon)...]
            guard after.isEmpty || after.first == " " || after.first == "\t",
                  line[..<colon].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: quotes) == key else { continue }
            var end = index + 1
            var next = index + 1
            while next < header.upperBound {
                let following = lines[next].trimmingCharacters(in: .newlines)
                if following.trimmingCharacters(in: .whitespaces).isEmpty {
                    next += 1
                    continue
                }
                guard following.hasPrefix(" ") || following.hasPrefix("\t") || following.hasPrefix("- ") || following == "-" else { break }
                next += 1
                end = next
            }
            return index..<end
        }
        return nil
    }

    /// The note with `key: value` in its frontmatter: that key's line (and its continuation lines)
    /// replaced, else a new line before the closing `---`, else a new frontmatter block at the
    /// start. Every other byte stays (P4), the note's own line end is used. Refused when the
    /// frontmatter doesn't read back with exactly this value (a broken header is never touched).
    public func setting(_ key: String, to value: PropertyValue) throws(Failure) -> KnowledgeNote {
        guard Self.validKey(key) else {
            throw Failure(message: "“\(key)” can't be a property: letters, digits, _, - and . (like repo or owner).")
        }
        let lines = lines
        let line = "\(key): \(value.yaml)" + lineEnd
        let edited: String
        if let header = Frontmatter.header(in: lines.map { String($0).trimmingCharacters(in: .newlines) }) {
            if !header.isEmpty, (try? Yams.load(yaml: lines[header].joined())) as? [String: Any] == nil {
                throw Failure(message: "The note's frontmatter isn't valid YAML, so AKit doesn't change it. Fix it in Edit first.")
            }
            var copy = lines.map(String.init)
            if let span = span(of: key, in: lines, header: header) {
                copy.replaceSubrange(span, with: [line])
            } else {
                copy.insert(line, at: header.upperBound)
            }
            edited = copy.joined()
        } else {
            let bom = text.hasPrefix("\u{FEFF}") ? "\u{FEFF}" : ""
            edited = bom + "---" + lineEnd + line + "---" + lineEnd + text.dropFirst(bom.isEmpty ? 0 : 1)
        }
        let note = KnowledgeNote(text: edited)
        guard value.matches(note.frontmatter[key]) else {
            throw Failure(message: "Writing \(key) would break the note's frontmatter, so nothing was changed.")
        }
        return note
    }

    /// The note without `key` in its frontmatter (its line and continuation lines removed); the
    /// frontmatter block too when nothing is left in it. Unchanged when the key isn't there.
    public func removing(_ key: String) -> KnowledgeNote {
        let lines = lines
        guard let header = Frontmatter.header(in: lines.map { String($0).trimmingCharacters(in: .newlines) }),
              let span = span(of: key, in: lines, header: header) else { return self }
        var copy = lines.map(String.init)
        copy.removeSubrange(span)
        let left = header.count - span.count
        if left == 0 {
            // Only the `---` lines are left: remove them too, keeping a BOM.
            let bom = copy[0].hasPrefix("\u{FEFF}") ? "\u{FEFF}" : ""
            copy.removeSubrange(0...1)
            return KnowledgeNote(text: bom + copy.joined())
        }
        return KnowledgeNote(text: copy.joined())
    }

    /// The first `# ` heading of the body; nil without one.
    public var title: String? {
        for line in body.split(whereSeparator: \.isNewline) where line.hasPrefix("# ") {
            let title = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            if !title.isEmpty { return title }
        }
        return nil
    }

    /// The text after the frontmatter.
    public var body: Substring { text[bodyStart...] }

    // MARK: - Sections

    /// The `##` sections in order; headings inside fenced code blocks don't count.
    public var sections: [Section] {
        var found: [(heading: String, line: Range<String.Index>)] = []
        var ends: [String.Index] = []
        var fence: String?
        for line in lines where line.startIndex >= bodyStart {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let open = fence {
                if trimmed.hasPrefix(open) { fence = nil }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = String(trimmed.prefix(3))
                continue
            }
            let level = line.prefix { $0 == "#" }.count
            guard level == 1 || level == 2, line.dropFirst(level).first == " " else { continue }
            ends.append(line.startIndex)
            if level == 2 { found.append((line.dropFirst(3).trimmingCharacters(in: .whitespacesAndNewlines), line.startIndex..<line.endIndex)) }
        }
        return found.map { section in
            let end = ends.first { $0 > section.line.lowerBound } ?? text.endIndex
            return Section(heading: section.heading, headingRange: section.line, bodyRange: section.line.upperBound..<end)
        }
    }

    /// The first section with this heading (case and spaces as written, NFC).
    public func section(_ heading: String) -> Section? {
        let wanted = heading.trimmingCharacters(in: .whitespaces).precomposedStringWithCanonicalMapping
        return sections.first { $0.heading.precomposedStringWithCanonicalMapping == wanted }
    }

    /// The section's body replaced by `body` (a line end added when it has none); every other byte kept.
    public func replacingSection(_ heading: String, with body: String) throws(Failure) -> KnowledgeNote {
        guard let section = section(heading) else { throw Failure(message: "The note has no section “## \(heading)”.") }
        var newBody = body
        if !newBody.isEmpty, !Self.endsLine(newBody) { newBody += lineEnd }
        // Keep the blank line before the next heading when the old body had one.
        if section.bodyRange.upperBound < text.endIndex, Self.endsBlank(text[section.bodyRange]), !Self.endsBlank(newBody) {
            newBody += lineEnd
        }
        var edited = text
        edited.replaceSubrange(section.bodyRange, with: newBody)
        return KnowledgeNote(text: edited)
    }

    /// `## heading` and `body` added at the end; the text before them is kept byte for byte.
    public func appendingSection(_ heading: String, body: String) -> KnowledgeNote {
        var edited = text
        if !edited.isEmpty, !Self.endsLine(edited) { edited += lineEnd }
        if !edited.isEmpty, !Self.endsBlank(edited) { edited += lineEnd }
        edited += "## \(heading)" + lineEnd + body
        if !body.isEmpty, !Self.endsLine(body) { edited += lineEnd }
        return KnowledgeNote(text: edited)
    }

    /// Ends with a line end (`\n` or `\r\n`, one Character in Swift).
    private static func endsLine(_ text: some StringProtocol) -> Bool { text.last?.isNewline == true }

    /// Ends with an empty line: two line ends in a row.
    private static func endsBlank(_ text: some StringProtocol) -> Bool {
        endsLine(text) && text.dropLast().last?.isNewline == true
    }

    /// The note's own line end: `\r\n` when its first line ends so, else `\n`.
    private var lineEnd: String {
        guard let first = text.firstIndex(where: \.isNewline) else { return "\n" }
        return text[first] == "\r\n" ? "\r\n" : "\n"
    }
}
