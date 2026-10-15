import Foundation

/// Where a comment can sit in a GitLab diff (`docs/design/review.md`, "Positions"): an added
/// line gets only `new_line`, a removed line only `old_line`, an unchanged line both. Lines
/// outside the hunks are unchanged; their old number follows from the hunks before them.
public struct DiffPositions: Sendable {
    struct Hunk: Sendable {
        let oldStart: Int
        let oldCount: Int
        let newStart: Int
        let newCount: Int
        /// New line → old line for context lines, nil for added lines.
        let newLines: [Int: Int?]
        /// Removed old lines.
        let removed: Set<Int>
    }

    let hunks: [Hunk]

    public init(diff: String) {
        var hunks: [Hunk] = []
        var lines = diff.split(separator: "\n", omittingEmptySubsequences: false)[...]
        while let header = lines.first {
            lines = lines.dropFirst()
            guard header.hasPrefix("@@"), let numbers = DiffPositions.header(String(header)) else { continue }
            var old = numbers.oldStart
            var new = numbers.newStart
            var newLines: [Int: Int?] = [:]
            var removed = Set<Int>()
            while let line = lines.first, !line.hasPrefix("@@") {
                lines = lines.dropFirst()
                if line.hasPrefix("+") {
                    newLines[new] = .some(nil)
                    new += 1
                } else if line.hasPrefix("-") {
                    removed.insert(old)
                    old += 1
                } else if line.hasPrefix("\\") {
                    continue
                } else if line.isEmpty, lines.isEmpty {
                    break
                } else {
                    newLines[new] = old
                    old += 1
                    new += 1
                }
            }
            hunks.append(Hunk(oldStart: numbers.oldStart, oldCount: numbers.oldCount, newStart: numbers.newStart,
                              newCount: numbers.newCount, newLines: newLines, removed: removed))
        }
        self.hunks = hunks
    }

    /// `@@ -12,7 +12,9 @@` → (12, 7, 12, 9). A missing count is 1.
    static func header(_ line: String) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int)? {
        guard let match = line.firstMatch(of: /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/) else { return nil }
        return (Int(match.output.1) ?? 0, match.output.2.flatMap { Int($0) } ?? 1, Int(match.output.3) ?? 0, match.output.4.flatMap { Int($0) } ?? 1)
    }

    /// (old_line, new_line) for a line of the new file, or of the old file for `side: .old`;
    /// nil when GitLab can't hold a comment there (a removed line asked as new, a line past the
    /// hunks that the diff doesn't show and the arithmetic can't place).
    public func lines(for line: Int, side: ReviewFinding.Side) -> (old: Int?, new: Int?)? {
        guard line >= 1 else { return nil }
        if side == .old {
            if hunks.contains(where: { $0.removed.contains(line) }) { return (line, nil) }
            // An unchanged old line: its new number follows from the hunks before it.
            var shift = 0
            for hunk in hunks {
                if line < hunk.oldStart { break }
                if line < hunk.oldStart + hunk.oldCount {
                    guard let new = hunk.newLines.first(where: { $0.value == line })?.key else { return nil }
                    return (line, new)
                }
                shift += hunk.newCount - hunk.oldCount
            }
            return (line, line + shift)
        }
        var shift = 0
        for hunk in hunks {
            if line < hunk.newStart { break }
            if line < hunk.newStart + max(hunk.newCount, 1), let entry = hunk.newLines[line] {
                return (entry, line)
            }
            if line < hunk.newStart + hunk.newCount { return nil }
            shift += hunk.oldCount - hunk.newCount
        }
        return (line + shift, line)
    }

    /// Whether the line is part of the change (added, or a context line GitLab shows).
    public func isInDiff(_ line: Int, side: ReviewFinding.Side) -> Bool {
        side == .old ? hunks.contains { $0.removed.contains(line) || $0.newLines.values.contains(line) }
            : hunks.contains { $0.newLines[line] != nil }
    }
}
