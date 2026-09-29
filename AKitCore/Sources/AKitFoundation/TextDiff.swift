import Foundation

/// Line diff for previews before AKit writes a file.
public enum TextDiff {
    public enum Line: Hashable, Sendable {
        case same(String), added(String), removed(String)
    }

    /// Longest-common-subsequence diff. Config files are small, O(n·m) is fine.
    public static func lines(from old: String, to new: String) -> [Line] {
        let a = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let b = new.isEmpty ? [] : new.components(separatedBy: "\n")
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var result: [Line] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                result.append(.same(a[i])); i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                result.append(.removed(a[i])); i += 1
            } else {
                result.append(.added(b[j])); j += 1
            }
        }
        result += a[i...].map(Line.removed) + b[j...].map(Line.added)
        return result
    }

    /// Changed lines with 3 lines of context, like `diff -u` without headers.
    public static func unified(_ diff: [Line]) -> [String] {
        let changed = diff.indices.filter { if case .same = diff[$0] { false } else { true } }
        var result: [String] = []
        var last = -1
        for index in diff.indices where changed.contains(where: { abs($0 - index) <= 3 }) {
            if last >= 0, index > last + 1 { result.append("  …") }
            switch diff[index] {
            case .same(let text): result.append("  " + text)
            case .added(let text): result.append("+ " + text)
            case .removed(let text): result.append("- " + text)
            }
            last = index
        }
        return result
    }
}
