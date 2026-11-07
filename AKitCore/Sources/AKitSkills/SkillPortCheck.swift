import AKitFoundation
import Foundation

/// The validation of a ported skill (`docs/design/skill-port.md`): Claude Code leftovers (lint),
/// what Pi needs to load it (structure), and numbers and headings of the original the port lost
/// (meaning). Structure problems fail; leftovers and losses are warnings.
public enum SkillPortCheck {
    public struct Hit: Codable, Sendable, Hashable {
        public let file: String
        public let line: Int
        public let text: String
        public let rule: String
    }

    public struct Report: Codable, Sendable, Hashable {
        public enum Verdict: String, Codable, Sendable { case pass, warnings, fail }
        public var hits: [Hit]
        /// What stops Pi from loading the skill as it is.
        public var problems: [String]
        /// Numbers of the original's text not found in the port (thresholds, limits, counts).
        public var missingNumbers: [String]
        public var missingHeadings: [String]

        public var verdict: Verdict {
            if !problems.isEmpty { return .fail }
            return hits.isEmpty && missingNumbers.isEmpty && missingHeadings.isEmpty ? .pass : .warnings
        }

        /// Text lines for the terminal: the verdict, then each finding.
        public var lines: [String] {
            var lines = ["Check: \(verdict.rawValue)"]
            lines += problems.map { "  ✗ \($0)" }
            lines += hits.map { "  ! \($0.file):\($0.line) [\($0.rule)] \($0.text)" }
            if !missingNumbers.isEmpty { lines.append("  ! Numbers of the original missing in the port: \(missingNumbers.joined(separator: ", "))") }
            lines += missingHeadings.map { "  ! Heading missing in the port: \($0)" }
            return lines
        }
    }

    /// Claude Code constructs Pi has no counterpart for; each match is a leftover.
    public static let rules: [(id: String, pattern: String)] = [
        ("Agent(", #"\bAgent\("#),
        ("subagent_type", #"subagent_type"#),
        ("AskUserQuestion", #"AskUserQuestion"#),
        ("TodoWrite", #"TodoWrite"#),
        ("TaskCreate", #"TaskCreate"#),
        ("mcp__", #"mcp__"#),
        ("Skill(", #"\bSkill\("#),
        ("state_write/state_read", #"state_write|state_read"#),
        ("notepad_", #"notepad_"#),
        ("model=", #"\bmodel\s*="#),
        ("/oh-my-claudecode:", #"/oh-my-claudecode:"#),
        ("~/.claude", #"~/\.claude"#),
        (".omc/", #"\.omc/"#),
        ("[MAGIC KEYWORD", #"\[MAGIC KEYWORD"#),
    ]

    /// Every rule match in every text, by file and line.
    public static func lint(_ texts: [String: String]) -> [Hit] {
        let compiled = rules.compactMap { rule in (try? NSRegularExpression(pattern: rule.pattern)).map { (rule.id, $0) } }
        var hits: [Hit] = []
        for path in texts.keys.sorted() {
            for (index, line) in texts[path]!.components(separatedBy: "\n").enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                for (id, regex) in compiled where regex.firstMatch(in: line, range: range) != nil {
                    let shown = line.trimmingCharacters(in: .whitespaces)
                    hits.append(Hit(file: path, line: index + 1, text: shown.count > 200 ? String(shown.prefix(200)) + "…" : shown, rule: id))
                }
            }
        }
        return hits
    }

    /// What Pi needs: a header with `name` and `description`, the name its folder's and by Pi's
    /// rules, the description at most `SkillScanner.piDescriptionWarning` characters, and every
    /// `references/…`, `scripts/…` or `assets/…` path SKILL.md names present.
    public static func structure(folderName: String, texts: [String: String], paths: Set<String>) -> [String] {
        guard let skill = texts[SkillPort.skillFile] else { return ["There is no \(SkillPort.skillFile)."] }
        guard Frontmatter.header(in: skill.components(separatedBy: "\n")) != nil else {
            return ["\(SkillPort.skillFile) has no frontmatter (--- … ---)."]
        }
        var problems: [String] = []
        let fields = Frontmatter.parse(skill)
        if let name = fields["name"], !name.isEmpty {
            if name != folderName { problems.append("name “\(name)” is not the folder's name “\(folderName)”.") }
            problems += PiNameRule.problems(name)
        } else {
            problems.append("The frontmatter has no name.")
        }
        let description = fields["description"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if description.isEmpty { problems.append("The frontmatter has no description: Pi doesn't load a skill without one.") }
        if description.count > SkillScanner.piDescriptionWarning {
            problems.append("The description has \(description.count) characters; Pi allows \(SkillScanner.piDescriptionWarning).")
        }
        for path in referencedPaths(skill) where !paths.contains(path) && !paths.contains(where: { $0.hasPrefix(path + "/") }) {
            problems.append("SKILL.md names \(path), which is not in the port.")
        }
        return problems
    }

    /// `references/x.md`, `scripts/run.sh`… named in a text, without trailing punctuation.
    static func referencedPaths(_ text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"(?<![\w/.-])(?:references|scripts|assets)/[A-Za-z0-9._/-]*[A-Za-z0-9_-]"#) else { return [] }
        let found = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
        return Array(Set(found)).sorted()
    }

    /// Numbers and headings of each original text (SKILL.md without its header) that its port
    /// lacks.
    public static func meaning(original: [String: String], ported: [String: String]) -> (numbers: [String], headings: [String]) {
        var numbers = Set<String>()
        var headings: [String] = []
        for path in original.keys.sorted() {
            guard let old = original[path], let new = ported[path] else { continue }
            let before = path == SkillPort.skillFile ? body(old) : old
            let after = path == SkillPort.skillFile ? body(new) : new
            numbers.formUnion(tokens(#"(?<![\w.])\d+(?:\.\d+)?%?"#, in: before).subtracting(tokens(#"(?<![\w.])\d+(?:\.\d+)?%?"#, in: after)))
            let had = headingLines(after)
            headings += headingLines(before).filter { !had.contains($0) }.map { path == SkillPort.skillFile ? $0 : "\($0) (\(path))" }
        }
        return (numbers.sorted { ($0.count, $0) < ($1.count, $1) }, headings)
    }

    static func body(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard let header = Frontmatter.header(in: lines) else { return text }
        return lines[(header.upperBound + 1)...].joined(separator: "\n")
    }

    static func tokens(_ pattern: String, in text: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return Set(regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } })
    }

    static func headingLines(_ text: String) -> [String] {
        var inFence = false
        return text.components(separatedBy: "\n").compactMap { line in
            if line.hasPrefix("```") { inFence.toggle() }
            guard !inFence, line.hasPrefix("#"), line.drop(while: { $0 == "#" }).first == " " else { return nil }
            return line.trimmingCharacters(in: .whitespaces)
        }
    }

    /// The full check of a draft.
    public static func check(_ draft: SkillPort.Draft) -> Report {
        let meaning = meaning(original: draft.originals, ported: draft.texts)
        return Report(hits: lint(draft.texts), problems: structure(folderName: draft.name, texts: draft.texts, paths: draft.paths),
                      missingNumbers: meaning.numbers, missingHeadings: meaning.headings)
    }

    /// An installed Pi skill folder, with no original to compare: lint and structure.
    public static func check(folder: URL) throws -> Report {
        let files = try SkillPort.read(folder)
        return Report(hits: lint(files.texts),
                      problems: structure(folderName: folder.standardizedFileURL.lastPathComponent, texts: files.texts,
                                          paths: Set(files.texts.keys).union(files.binaries)),
                      missingNumbers: [], missingHeadings: [])
    }
}
