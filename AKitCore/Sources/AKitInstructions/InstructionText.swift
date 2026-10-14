import Foundation

/// One part of an instruction file: the text from one `##` heading to the next (decided D11,
/// `docs/design/instructions.md`), the text before the first heading (the lead), or AKit's
/// marked block of the core layer, which is one section whatever headings it has.
public struct InstructionSection: Hashable, Sendable {
    /// The `##` heading without its marks; nil for the lead and for AKit's block.
    public let heading: String?
    /// The section's lines as in the file, heading included.
    public let text: String
    /// The core layer's block (`<!-- akit:core:start -->` … end): it changes in the brain.
    public let isAKitBlock: Bool
    /// 1-based line of its first line in the file.
    public let line: Int

    public init(heading: String?, text: String, isAKitBlock: Bool, line: Int) {
        self.heading = heading
        self.text = text
        self.isAKitBlock = isAKitBlock
        self.line = line
    }

    public var bytes: Int { text.utf8.count }
    /// Only blank lines (a lead before the first heading that is empty).
    public var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

public enum InstructionText {
    /// The text's lines, split at `\n` only, each keeping a `\r` before it: joined with `\n`
    /// they give the text back byte for byte. (A Swift String treats `\r\n` as one Character,
    /// so `split(separator: "\n")` would leave a CRLF file as one line.)
    public static func lines(_ text: String) -> [String] {
        text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map { String(String.UnicodeScalarView($0)) }
    }

    /// The core layer's block markers (`AKitProjectSetup.InstructionsBlock` writes them).
    public static let akitStart = "<!-- akit:core:start -->"
    public static let akitEnd = "<!-- akit:core:end -->"

    /// The file split into sections, in order; blank leads are left out. Headings inside
    /// fenced code blocks don't split.
    public static func sections(_ text: String) -> [InstructionSection] {
        let lines = Self.lines(text)
        var result: [InstructionSection] = []
        var current: [String] = [], heading: String?, start = 1, inBlock = false
        var fence: Fence?

        func flush(next: Int) {
            if !current.isEmpty {
                let section = InstructionSection(heading: heading, text: current.joined(separator: "\n"), isAKitBlock: inBlock, line: start)
                // A lead that is blank, or only a `# Title`, is not a section (D11).
                let titleOnly = section.heading == nil && !section.isAKitBlock && current.allSatisfy { line in
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty || trimmed.hasPrefix("# ")
                }
                if !titleOnly { result.append(section) }
            }
            current = []
            heading = nil
            start = next
        }

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\r", with: "")
            if let open = fence {
                if open.closes(trimmed) { fence = nil }
                current.append(line)
                continue
            }
            if let open = Fence(opening: trimmed) {
                fence = open
                current.append(line)
                continue
            }
            if trimmed == akitStart, !inBlock {
                flush(next: index + 1)
                inBlock = true
                current.append(line)
                continue
            }
            if inBlock {
                current.append(line)
                if trimmed == akitEnd {
                    flush(next: index + 2)
                    inBlock = false
                }
                continue
            }
            if trimmed.hasPrefix("## ") {
                flush(next: index + 1)
                heading = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            }
            current.append(line)
        }
        flush(next: lines.count + 1)
        // A file that ends with a newline has an empty last line: not a section of its own.
        return result
    }

    /// Claude Code's imports: `@path` words outside code spans and fences, in the file's order,
    /// once each. Any word can be one (`@README`, `@package.json`): the caller keeps only the
    /// paths that exist, so `@mentions` drop out there.
    public static func imports(in text: String) -> [String] {
        var found: [String] = []
        var fence: Fence?
        for line in Self.lines(text) {
            let trimmed = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\r", with: "")
            if let open = fence {
                if open.closes(trimmed) { fence = nil }
                continue
            }
            if let open = Fence(opening: trimmed) {
                fence = open
                continue
            }
            // Code spans: every second part between backticks.
            let outside = line.split(separator: "`", omittingEmptySubsequences: false).enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
            for part in outside {
                for word in part.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" }) where word.hasPrefix("@") && word.count > 1 {
                    // Punctuation after the path ("see @docs/a.md.") is not part of it.
                    var clean = String(word.dropFirst())
                    while let last = clean.last, ",;:)]}\"'.".contains(last) { clean.removeLast() }
                    guard !clean.isEmpty, !found.contains(clean) else { continue }
                    found.append(clean)
                }
            }
        }
        return found
    }

    /// The text two sections are compared by (decided D13): line ends, trailing spaces, blank
    /// lines, the heading's level and its letter case don't count. Lines in a fenced code block
    /// stay as they are (`# install` in a shell example is not a heading).
    public static func normalized(_ section: InstructionSection) -> String {
        var lines: [String] = []
        var fence: Fence?
        for raw in Self.lines(section.text.replacingOccurrences(of: "\r\n", with: "\n")) {
            var line = String(raw)
            while line.last == " " || line.last == "\t" || line.last == "\r" { line.removeLast() }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if open.closes(trimmed) { fence = nil }
            } else if let open = Fence(opening: trimmed) {
                fence = open
            } else {
                let marks = line.prefix { $0 == "#" }.count
                if (1...6).contains(marks), line.dropFirst(marks).first == " " {
                    line = line.dropFirst(marks).trimmingCharacters(in: .whitespaces).lowercased()
                }
            }
            if line.isEmpty { continue }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// The keys of the `---` front matter at the very top of the file; empty without one.
    public static func frontMatterKeys(_ text: String) -> Set<String> {
        let lines = Self.lines(text.replacingOccurrences(of: "\r\n", with: "\n"))
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [] }
        var keys: Set<String> = []
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { return keys }
            guard let first = line.first, first != " ", first != "\t", first != "-", first != "#",
                  let colon = line.firstIndex(of: ":") else { continue }
            keys.insert(line[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: " \"'")))
        }
        return []  // never closed: not front matter
    }
}

/// A fenced code block's opening line: three or more backticks or tildes. It closes at a line
/// of the same character, at least as long, with nothing else (CommonMark). A backtick opener
/// can't have a backtick after it (```` ```x``` ```` is inline code, not a fence).
struct Fence {
    let mark: Character
    let length: Int

    init?(opening line: String) {
        guard let first = line.first, first == "`" || first == "~" else { return nil }
        let length = line.prefix { $0 == first }.count
        guard length >= 3 else { return nil }
        if first == "`", line.dropFirst(length).contains("`") { return nil }
        mark = first
        self.length = length
    }

    func closes(_ line: String) -> Bool {
        let run = line.prefix { $0 == mark }.count
        return run >= length && line.dropFirst(run).allSatisfy { $0 == " " || $0 == "\t" }
    }
}
