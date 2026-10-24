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
    /// The repository's git remote URL, or a `~/` path (K12).
    public var repo: String? { string("repo") }
    /// Paths inside the repository (K12); one string counts as a list of one.
    public var files: [String] {
        switch frontmatter["files"] {
        case let list as [Any]: list.map { "\($0)" }
        case let one as String: [one]
        default: []
        }
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
