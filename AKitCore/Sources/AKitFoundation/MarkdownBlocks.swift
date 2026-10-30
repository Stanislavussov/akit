import Foundation

/// Markdown a model or AKit wrote (a review comment, a summary, an answer), split into blocks
/// the app draws: headings, paragraphs, list items, tables, code, quotes and rules. Inline
/// styles (bold, code, links) stay in the text for the view to render. HTML comments are
/// dropped and `<sub>`/`<small>` lines become small text: GitLab hides or shrinks them too.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    /// A `<sub>` or `<small>` line: small, secondary text.
    case small(String)
    case bullet(level: Int, text: String)
    case numbered(number: String, level: Int, text: String)
    case quote(String)
    /// A fenced block; `language` is its info string (`suggestion`, `swift`, …).
    case code(language: String, text: String)
    case table(header: [String], rows: [[String]])
    case rule

    public static func parse(_ markdown: String) -> [MarkdownBlock] {
        let text = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let source = withoutComments(text).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var index = 0

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }

        while index < source.count {
            let line = source[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                let fence = String(trimmed.prefix { $0 == "`" || $0 == "~" })
                let language = trimmed.dropFirst(fence.count).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < source.count, !source[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(source[index])
                    index += 1
                }
                blocks.append(.code(language: language, text: code.joined(separator: "\n")))
                index += 1
                continue
            }
            if trimmed.isEmpty {
                flush()
            } else if let heading = heading(trimmed) {
                flush()
                blocks.append(heading)
            } else if isRule(trimmed) {
                flush()
                blocks.append(.rule)
            } else if trimmed.hasPrefix("|"), index + 1 < source.count, isTableSeparator(source[index + 1]) {
                flush()
                let header = cells(trimmed)
                var rows: [[String]] = []
                index += 2
                while index < source.count, source[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(cells(source[index].trimmingCharacters(in: .whitespaces)))
                    index += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            } else if trimmed.hasPrefix(">") {
                flush()
                var quoted: [String] = []
                while index < source.count, source[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quoted.append(String(source[index].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
                continue
            } else if let item = bullet(trimmed) {
                flush()
                blocks.append(.bullet(level: indent / 2, text: item))
            } else if let (number, item) = numbered(trimmed) {
                flush()
                blocks.append(.numbered(number: number, level: indent / 2, text: item))
            } else if let small = small(trimmed) {
                flush()
                blocks.append(.small(small))
            } else {
                paragraph.append(trimmed)
            }
            index += 1
        }
        flush()
        return blocks
    }

    static func withoutComments(_ text: String) -> String {
        var text = text
        while let start = text.range(of: "<!--"), let end = text.range(of: "-->", range: start.upperBound..<text.endIndex) {
            text.removeSubrange(start.lowerBound..<end.upperBound)
        }
        return text
    }

    static func heading(_ line: String) -> MarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return .heading(level: hashes, text: line.dropFirst(hashes).trimmingCharacters(in: .whitespaces))
    }

    static func isRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        return compact.count >= 3 && (Set(compact) == ["-"] || Set(compact) == ["*"] || Set(compact) == ["_"])
    }

    static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|"), trimmed.contains("-") else { return false }
        return trimmed.allSatisfy { "|-: ".contains($0) }
    }

    /// `| a | b \| c |` → `["a", "b | c"]`.
    static func cells(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in line {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "|" { cells.append(current); current = ""; continue }
            current.append(character)
        }
        cells.append(current)
        if line.hasPrefix("|") { cells.removeFirst() }
        if line.hasSuffix("|") && !line.hasSuffix("\\|") { cells.removeLast() }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func bullet(_ line: String) -> String? {
        for mark in ["- ", "* ", "+ "] where line.hasPrefix(mark) {
            let item = String(line.dropFirst(2))
            // A task box shows as a box.
            if item.hasPrefix("[ ] ") { return "☐ " + item.dropFirst(4) }
            if item.lowercased().hasPrefix("[x] ") { return "☑ " + item.dropFirst(4) }
            return item
        }
        return nil
    }

    static func numbered(_ line: String) -> (String, String)? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return (digits + ".", String(rest.dropFirst(2)))
    }

    /// `<sub>text</sub>` or `<small>text</small>` alone on a line.
    static func small(_ line: String) -> String? {
        for tag in ["sub", "small"] where line.hasPrefix("<\(tag)>") && line.hasSuffix("</\(tag)>") {
            return String(line.dropFirst(tag.count + 2).dropLast(tag.count + 3))
        }
        return nil
    }
}
