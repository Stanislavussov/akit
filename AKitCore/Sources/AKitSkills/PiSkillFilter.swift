import Foundation

/// Pi's own rule for the override entries of a `skills` setting (Pi 1.0.4,
/// `dist/core/package-manager.js`: `isEnabledByOverrides`, `matchesAnyPattern`,
/// `matchesAnyExactPattern`). A skill Pi finds by itself is on unless `!glob` matches it;
/// `+path` turns it back on and `-path` off, by exact path. Plain entries are extra skill
/// paths, not filters.
enum PiSkillFilter {
    /// Whether Pi loads the skill file `place` with these `skills` entries.
    static func isEnabled(_ place: Skill.Place, entries: [String]) -> Bool {
        let targets = Targets(place)
        var enabled = true
        let excludes = entries.filter { $0.hasPrefix("!") }.map { String($0.dropFirst()) }
        if excludes.contains(where: targets.matches(glob:)) { enabled = false }
        if entries.contains(where: { $0.hasPrefix("+") && targets.isExact(String($0.dropFirst())) }) { enabled = true }
        if entries.contains(where: { $0.hasPrefix("-") && targets.isExact(String($0.dropFirst())) }) { enabled = false }
        return enabled
    }

    /// The entries with every `!`, `+` and `-` entry that names exactly this skill taken out
    /// (as `pi config` does), then one entry added if the skill still isn't in `enabled`.
    static func entries(_ entries: [String], setting place: Skill.Place, enabled: Bool) -> [String] {
        let targets = Targets(place)
        var result = entries.filter { entry in
            guard let first = entry.first, "!+-".contains(first) else { return true }
            return !targets.isExact(String(entry.dropFirst()))
        }
        if isEnabled(place, entries: result) != enabled {
            result.append((enabled ? "+" : "-") + place.relativePath)
        }
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
            let folderRelative = (relative as NSString).deletingLastPathComponent
            self.folderRelative = isSkillFile ? folderRelative : nil
            folderName = isSkillFile ? folder.lastPathComponent : nil
            folderAbsolute = isSkillFile ? folder.path : nil
        }

        func matches(glob pattern: String) -> Bool {
            [relative, name, absolute, folderRelative, folderName, folderAbsolute].compactMap { $0 }
                .contains { Glob.matches(pattern, $0) }
        }

        func isExact(_ pattern: String) -> Bool {
            let normalized = pattern.hasPrefix("./") ? String(pattern.dropFirst(2)) : pattern
            return [relative, absolute, folderRelative, folderAbsolute].contains(normalized)
        }
    }
}

/// The part of minimatch (Pi's matcher, default options) that `skills` entries use: `*`, `?`,
/// `**`, `[…]` classes and `{a,b}` alternatives; `*` and `?` never match `/`, and no wildcard
/// matches a leading `.` of a path segment. A pattern starting with `#` matches nothing.
enum Glob {
    static func matches(_ pattern: String, _ path: String) -> Bool {
        guard !pattern.hasPrefix("#") else { return false }
        return expandBraces(pattern).contains { alternative in
            matchSegments(Array(alternative.split(separator: "/", omittingEmptySubsequences: false).map(String.init))[...],
                          Array(path.split(separator: "/", omittingEmptySubsequences: false).map(String.init))[...])
        }
    }

    /// `a{b,c}d` → `abd`, `acd`; nested and repeated groups too. At most 64 alternatives.
    static func expandBraces(_ pattern: String) -> [String] {
        let chars = Array(pattern)
        guard let open = chars.firstIndex(of: "{") else { return [pattern] }
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
        guard let close, !commas.isEmpty else { return [pattern] }
        let prefix = String(chars[..<open]), suffix = String(chars[(close + 1)...])
        let bounds = [open] + commas + [close]
        var result: [String] = []
        for index in 0..<(bounds.count - 1) {
            let part = String(chars[(bounds[index] + 1)..<bounds[index + 1]])
            for expanded in expandBraces(prefix + part + suffix) where result.count < 64 { result.append(expanded) }
        }
        return result
    }

    private static func matchSegments(_ pattern: ArraySlice<String>, _ path: ArraySlice<String>) -> Bool {
        guard let first = pattern.first else { return path.isEmpty }
        if first == "**" {
            // Zero or more segments, none of them hidden.
            var rest = path
            while true {
                if matchSegments(pattern.dropFirst(), rest) { return true }
                guard let next = rest.first, !next.hasPrefix(".") else { return false }
                rest = rest.dropFirst()
            }
        }
        guard let segment = path.first, matchSegment(Array(first)[...], Array(segment)[...], atStart: true) else { return false }
        return matchSegments(pattern.dropFirst(), path.dropFirst())
    }

    private static func matchSegment(_ pattern: ArraySlice<Character>, _ text: ArraySlice<Character>, atStart: Bool) -> Bool {
        guard let token = pattern.first else { return text.isEmpty }
        // A leading dot is matched only by a literal dot.
        if atStart, text.first == ".", token != "." { return false }
        switch token {
        case "*":
            var rest = text
            while true {
                if matchSegment(pattern.dropFirst(), rest, atStart: false) { return true }
                guard !rest.isEmpty else { return false }
                rest = rest.dropFirst()
            }
        case "?":
            guard !text.isEmpty else { return false }
            return matchSegment(pattern.dropFirst(), text.dropFirst(), atStart: false)
        case "[":
            guard let close = pattern.dropFirst().firstIndex(of: "]"), let char = text.first else {
                return text.first == "[" && matchSegment(pattern.dropFirst(), text.dropFirst(), atStart: false)
            }
            var set = pattern[(pattern.startIndex + 1)..<close]
            let negated = set.first == "!" || set.first == "^"
            if negated { set = set.dropFirst() }
            var found = false
            var index = set.startIndex
            while index < set.endIndex {
                let low = set[index]
                if index + 2 < set.endIndex, set[index + 1] == "-" {
                    if low <= char && char <= set[index + 2] { found = true }
                    index += 3
                } else {
                    if low == char { found = true }
                    index += 1
                }
            }
            guard found != negated else { return false }
            return matchSegment(pattern[(close + 1)...], text.dropFirst(), atStart: false)
        case "\\":
            guard pattern.count > 1, text.first == pattern[pattern.startIndex + 1] else { return false }
            return matchSegment(pattern.dropFirst(2), text.dropFirst(), atStart: false)
        default:
            guard text.first == token else { return false }
            return matchSegment(pattern.dropFirst(), text.dropFirst(), atStart: false)
        }
    }
}
