import Foundation

/// Pi's own rule for the override entries of a `skills` setting (Pi 1.0.4,
/// `dist/core/package-manager.js`: `isEnabledByOverrides`, `matchesAnyPattern`,
/// `matchesAnyExactPattern`). A skill Pi finds by itself is on unless `!glob` matches it;
/// `+path` turns it back on and `-path` off, by exact path. Plain entries are extra skill
/// paths, not filters.
enum PiSkillFilter {
    /// Whether Pi loads the skill file `place` with these `skills` entries; nil when an `!`
    /// entry uses glob syntax AKit doesn't read (extglobs, POSIX classes, `{1..3}`).
    static func isEnabled(_ place: Skill.Place, entries: [String]) -> Bool? {
        let targets = Targets(place)
        var enabled = true
        for exclude in entries where exclude.hasPrefix("!") {
            switch targets.matches(glob: String(exclude.dropFirst())) {
            case nil: return nil
            case true?: enabled = false
            case false?: break
            }
        }
        if entries.contains(where: { $0.hasPrefix("+") && targets.isExact(String($0.dropFirst())) }) { enabled = true }
        if entries.contains(where: { $0.hasPrefix("-") && targets.isExact(String($0.dropFirst())) }) { enabled = false }
        return enabled
    }

    /// The `!` entries AKit can't read, for messages.
    static func unreadable(_ entries: [String]) -> [String] {
        entries.filter { $0.hasPrefix("!") && Glob.matches(String($0.dropFirst()), "x") == nil }
    }

    /// The entries with every `!`, `+` and `-` entry that names exactly this skill taken out
    /// (as `pi config` does), then one entry added if the skill still isn't in `enabled`.
    /// nil when the result can't be known (an unreadable `!` entry).
    static func entries(_ entries: [String], setting place: Skill.Place, enabled: Bool) -> [String]? {
        let targets = Targets(place)
        var result = entries.filter { entry in
            guard let first = entry.first, "!+-".contains(first) else { return true }
            return !targets.isExact(String(entry.dropFirst()))
        }
        guard let now = isEnabled(place, entries: result) else { return nil }
        if now != enabled { result.append((enabled ? "+" : "-") + place.relativePath) }
        return result
    }

    /// The names Pi matches a skill file by.
    struct Targets {
        let relative: String
        let name: String
        let absolute: String
        /// For a `SKILL.md`: its folder, relative, by name and absolute.
        let folderRelative: String?
        let folderName: String?
        let folderAbsolute: String?

        init(_ place: Skill.Place) {
            relative = place.relativePath
            name = place.file.lastPathComponent
            absolute = place.file.path
            let isSkillFile = name == "SKILL.md"
            let folder = place.file.deletingLastPathComponent()
            folderRelative = isSkillFile ? (relative as NSString).deletingLastPathComponent : nil
            folderName = isSkillFile ? folder.lastPathComponent : nil
            folderAbsolute = isSkillFile ? folder.path : nil
        }

        /// nil: the glob uses syntax AKit doesn't read.
        func matches(glob pattern: String) -> Bool? {
            var matched = false
            for target in [relative, name, absolute, folderRelative, folderName, folderAbsolute].compactMap({ $0 }) {
                guard let result = Glob.matches(pattern, target) else { return nil }
                if result { matched = true }
            }
            return matched
        }

        func isExact(_ pattern: String) -> Bool {
            let normalized = pattern.hasPrefix("./") ? String(pattern.dropFirst(2)) : pattern
            return [relative, absolute, folderRelative, folderAbsolute].contains(normalized)
        }
    }
}

/// The part of minimatch 10 (Pi's matcher, default options) that `skills` entries use: `*`, `?`,
/// `**`, `[…]` classes and `{a,b}` alternatives. `*` and `?` never match `/`, `*` never matches an
/// empty segment, no wildcard matches a leading `.` of a segment, a trailing `**` needs at least
/// one segment, and repeated slashes count as one. A pattern starting with `#` matches nothing.
/// Extglobs (`@(…)`, `+(…)`, `!(…)`, `?(…)`, `*(…)`), POSIX classes (`[[:alpha:]]`) and ranges
/// (`{1..3}`) are not read: `matches` returns nil. Work is bounded: brace expansion stops at
/// `maxAlternatives`, and matching is dynamic programming, linear in pattern × text.
enum Glob {
    static let maxAlternatives = 256

    /// nil when the pattern uses syntax AKit doesn't read, or expands to too many alternatives.
    static func matches(_ pattern: String, _ path: String) -> Bool? {
        guard isReadable(pattern) else { return nil }
        guard !pattern.hasPrefix("#") else { return false }
        guard let alternatives = expandBraces(pattern) else { return nil }
        let pathAbsolute = path.hasPrefix("/")
        let pathSegments = path.split(separator: "/").map { Array($0) }
        for alternative in alternatives where alternative.hasPrefix("/") == pathAbsolute {
            let segments = alternative.split(separator: "/").map { String($0) }
            if matchSegments(segments, pathSegments) { return true }
        }
        return false
    }

    /// No extglob, POSIX class or numeric/letter range.
    static func isReadable(_ pattern: String) -> Bool {
        let chars = Array(pattern)
        for index in chars.indices.dropLast() where chars[index + 1] == "(" && "@+!?*".contains(chars[index]) { return false }
        if pattern.contains("[:") && pattern.contains(":]") { return false }
        if pattern.range(of: #"\{[^{}]*\.\.[^{}]*\}"#, options: .regularExpression) != nil { return false }
        return true
    }

    /// `a{b,c}d` → `abd`, `acd`; nested and repeated groups too. nil above `maxAlternatives`:
    /// every call either stops or adds one alternative, so the calls are bounded too.
    static func expandBraces(_ pattern: String) -> [String]? {
        var result: [String] = []
        return expand(Array(pattern), into: &result) ? result : nil
    }

    private static func expand(_ chars: [Character], into result: inout [String]) -> Bool {
        guard result.count < maxAlternatives else { return false }
        guard let open = chars.firstIndex(of: "{") else {
            result.append(String(chars))
            return true
        }
        var depth = 0
        var close: Int?
        var commas: [Int] = []
        for index in open..<chars.count {
            switch chars[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { close = index }
            case "," where depth == 1: commas.append(index)
            default: break
            }
            if close != nil { break }
        }
        guard let close, !commas.isEmpty else {
            // Not a group (no comma, or never closed): taken as it is.
            result.append(String(chars))
            return true
        }
        let bounds = [open] + commas + [close]
        for index in 0..<(bounds.count - 1) {
            let part = Array(chars[(bounds[index] + 1)..<bounds[index + 1]])
            guard expand(Array(chars[..<open]) + part + Array(chars[(close + 1)...]), into: &result) else { return false }
        }
        return true
    }

    /// Segments by dynamic programming: `**` takes zero or more segments (one or more at the
    /// end), none of them hidden.
    private static func matchSegments(_ pattern: [String], _ path: [[Character]]) -> Bool {
        let tokens = pattern.map { $0 == "**" ? nil : tokenize($0) }
        // reach[i][j]: the first i pattern segments match the first j path segments.
        var reach = Array(repeating: Array(repeating: false, count: path.count + 1), count: pattern.count + 1)
        reach[0][0] = true
        for i in 0..<pattern.count {
            for j in 0...path.count where reach[i][j] {
                if let segment = tokens[i] {
                    if j < path.count, matchSegment(segment, path[j]) { reach[i + 1][j + 1] = true }
                } else {
                    if i < pattern.count - 1 { reach[i + 1][j] = true }
                    var k = j
                    while k < path.count, path[k].first != "." {
                        k += 1
                        reach[i + 1][k] = true
                    }
                }
            }
        }
        return reach[pattern.count][path.count]
    }

    enum Token: Equatable {
        case literal(Character), any, star
        case set([ClosedRange<Character>], negated: Bool)
    }

    private static func tokenize(_ segment: String) -> [Token] {
        let chars = Array(segment)
        var tokens: [Token] = []
        var index = 0
        while index < chars.count {
            let char = chars[index]
            switch char {
            case "*":
                if tokens.last != .star { tokens.append(.star) }
            case "?":
                tokens.append(.any)
            case "\\" where index + 1 < chars.count:
                index += 1
                tokens.append(.literal(chars[index]))
            case "[":
                var end = index + 1
                if end < chars.count, chars[end] == "!" || chars[end] == "^" { end += 1 }
                if end < chars.count, chars[end] == "]" { end += 1 }
                while end < chars.count, chars[end] != "]" { end += 1 }
                guard end < chars.count else {
                    tokens.append(.literal("["))
                    break
                }
                var at = index + 1
                let negated = chars[at] == "!" || chars[at] == "^"
                if negated { at += 1 }
                var ranges: [ClosedRange<Character>] = []
                while at < end {
                    if at + 2 < end, chars[at + 1] == "-", chars[at] <= chars[at + 2] {
                        ranges.append(chars[at]...chars[at + 2])
                        at += 3
                    } else {
                        ranges.append(chars[at]...chars[at])
                        at += 1
                    }
                }
                tokens.append(.set(ranges, negated: negated))
                index = end
            default:
                tokens.append(.literal(char))
            }
            index += 1
        }
        return tokens
    }

    /// One segment by dynamic programming over (token, character). An empty segment never
    /// matches; a leading `.` only matches a literal dot.
    private static func matchSegment(_ tokens: [Token], _ text: [Character]) -> Bool {
        guard !text.isEmpty else { return false }
        if text.first == ".", tokens.first != .literal(".") { return false }
        var row = Array(repeating: false, count: text.count + 1)
        row[0] = true
        for token in tokens {
            var next = Array(repeating: false, count: text.count + 1)
            if token == .star {
                var seen = false
                for j in 0...text.count {
                    if row[j] { seen = true }
                    next[j] = seen
                }
            } else {
                for j in 0..<text.count where row[j] {
                    let char = text[j]
                    let fits: Bool = switch token {
                    case .literal(let expected): char == expected
                    case .any: true
                    case .set(let ranges, let negated): ranges.contains { $0.contains(char) } != negated
                    case .star: false
                    }
                    if fits { next[j + 1] = true }
                }
            }
            row = next
        }
        return row[text.count]
    }
}
