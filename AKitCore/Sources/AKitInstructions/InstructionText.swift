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

    public var bytes: Int { text.utf8.count }
    /// Only blank lines (a lead before the first heading that is empty).
    public var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

public enum InstructionText {
    /// The core layer's block markers (`AKitProjectSetup.InstructionsBlock` writes them).
    public static let akitStart = "<!-- akit:core:start -->"
    public static let akitEnd = "<!-- akit:core:end -->"

    /// The file split into sections, in order; blank leads are left out. Headings inside
    /// fenced code blocks don't split.
    public static func sections(_ text: String) -> [InstructionSection] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var result: [InstructionSection] = []
        var current: [String] = [], heading: String?, start = 1, inBlock = false
        var fence: String?

        func flush(next: Int) {
            if !current.isEmpty {
                let section = InstructionSection(heading: heading, text: current.joined(separator: "\n"), isAKitBlock: inBlock, line: start)
                if !(section.isBlank && section.heading == nil && !section.isAKitBlock) { result.append(section) }
            }
            current = []
            heading = nil
            start = next
        }

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\r", with: "")
            if let open = fence {
                if trimmed.hasPrefix(open) { fence = nil }
                current.append(line)
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = String(trimmed.prefix(3))
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

    /// Claude Code's imports: `@path` words outside code spans and fences, where the path has
    /// a `/` or ends in `.md` (so `@mentions` don't count). In the file's order, once each.
    public static func imports(in text: String) -> [String] {
        var found: [String] = []
        var fence: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if trimmed.hasPrefix(open) { fence = nil }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = String(trimmed.prefix(3))
                continue
            }
            // Code spans: every second part between backticks.
            let outside = line.split(separator: "`", omittingEmptySubsequences: false).enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
            for part in outside {
                for word in part.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" }) where word.hasPrefix("@") && word.count > 1 {
                    // Punctuation after the path ("see @docs/a.md.") is not part of it.
                    var clean = String(word.dropFirst())
                    while let last = clean.last, ",;:)]}\"'.".contains(last) { clean.removeLast() }
                    guard clean.contains("/") || clean.lowercased().hasSuffix(".md"), !found.contains(clean) else { continue }
                    found.append(clean)
                }
            }
        }
        return found
    }

    /// The text two sections are compared by (decided D13): line ends, trailing spaces, blank
    /// lines and the heading's level don't count.
    public static func normalized(_ section: InstructionSection) -> String {
        var lines: [String] = []
        for raw in section.text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(raw)
            while line.last == " " || line.last == "\t" { line.removeLast() }
            if line.hasPrefix("#") { line = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces) }
            if line.isEmpty { continue }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}
