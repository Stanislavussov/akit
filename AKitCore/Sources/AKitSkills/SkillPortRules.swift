import AKitFoundation
import Foundation

/// The user's extra rules for Port to Pi (`docs/design/skill-port.md`, "Extra rules"): literal or
/// regex replacements for the deterministic pass, notes for the model pass, and tokens that must
/// not remain. Each replacement's FROM and each `forbid:` token is a lint rule of its own. A rules
/// text has one rule per line: `FROM => TO`, `re:PATTERN => TO`, `forbid: X`, `note: text`, and
/// `allow: <built-in rule>`, `answer: id=option` and `#` comments.
public struct SkillPortRules: Codable, Sendable, Hashable {
    public struct Replacement: Codable, Sendable, Hashable {
        public var from: String
        public var to: String
        public var isRegex: Bool

        public init(from: String, to: String, isRegex: Bool = false) {
            self.from = from
            self.to = to
            self.isRegex = isRegex
        }

        /// A literal starting with a word character matches only at a word start: `vi.` not in `navi.`.
        var pattern: String { isRegex ? from : Self.literal(from) }
        var template: String { isRegex ? to : NSRegularExpression.escapedTemplate(for: to) }
        public var line: String { (isRegex ? "re:" : "") + "\(from) => \(to)" }

        static func literal(_ text: String) -> String {
            let escaped = NSRegularExpression.escapedPattern(for: text)
            guard let first = text.unicodeScalars.first, CharacterSet.alphanumerics.contains(first) || first == "_" else { return escaped }
            return #"(?<![\w.])"# + escaped
        }
    }

    public var replacements: [Replacement] = []
    public var notes: [String] = []
    public var forbids: [String] = []
    /// Built-in lint rules turned off (`allow: AskUserQuestion`), for a Pi that has the thing.
    public var allows: [String] = []
    /// Saved answers to the port's questions (`answer: id=option`), so a re-port asks nothing.
    public var answers: [String: String] = [:]
    /// The change each lint rule came from (lint id → "package-manager: Switch npm to pnpm"), for
    /// grouping the report's hits.
    public var origins: [String: String] = [:]

    public init(replacements: [Replacement] = [], notes: [String] = [], forbids: [String] = [], allows: [String] = [],
                answers: [String: String] = [:], origins: [String: String] = [:]) {
        self.replacements = replacements
        self.notes = notes
        self.forbids = forbids
        self.allows = allows
        self.answers = answers
        self.origins = origins
    }

    /// The same rules with each lint rule marked as coming from `change` (unless marked already).
    public func labeled(_ change: String) -> SkillPortRules {
        var result = self
        for rule in lintRules where result.origins[rule.id] == nil { result.origins[rule.id] = change }
        return result
    }

    public var isEmpty: Bool { replacements.isEmpty && notes.isEmpty && forbids.isEmpty && allows.isEmpty && answers.isEmpty }

    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Reads a rules text; a line it can't read (no `=>`, an empty side, a bad regex) is an error with its number.
    public static func parse(_ text: String) throws -> SkillPortRules {
        var rules = SkillPortRules()
        for (index, raw) in text.components(separatedBy: .newlines).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            func fail(_ why: String) -> Failure { Failure(message: "Rules line \(index + 1): \(why): \(line)") }
            if line.hasPrefix("forbid:") {
                let token = line.dropFirst(7).trimmingCharacters(in: .whitespaces)
                guard !token.isEmpty else { throw fail("forbid: needs a token") }
                rules.forbids.append(token)
            } else if line.hasPrefix("allow:") {
                let rule = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                guard SkillPortCheck.rules.contains(where: { $0.id == rule }) else {
                    throw fail("allow: takes a built-in rule (\(SkillPortCheck.rules.map(\.id).joined(separator: ", ")))")
                }
                rules.allows.append(rule)
            } else if line.hasPrefix("answer:") {
                let pair = line.dropFirst(7).trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                guard pair.count == 2, !pair[0].isEmpty, !pair[1].isEmpty else { throw fail("answer: needs id=option") }
                rules.answers[pair[0]] = pair[1]
            } else if line.hasPrefix("note:") {
                let note = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard !note.isEmpty else { throw fail("note: needs a text") }
                rules.notes.append(note)
            } else {
                let isRegex = line.hasPrefix("re:")
                // A TO left empty deletes: `FROM =>` (the line's trailing space is trimmed).
                let body = (isRegex ? String(line.dropFirst(3)) : line) + (line.hasSuffix(" =>") ? " " : "")
                guard let arrow = body.range(of: " => ") else { throw fail("expected FROM => TO, re:PATTERN => TO, forbid: X or note: text") }
                let from = body[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
                let to = body[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
                guard !from.isEmpty else { throw fail("FROM is empty") }
                if isRegex, (try? NSRegularExpression(pattern: from)) == nil { throw fail("not a valid regular expression") }
                rules.replacements.append(Replacement(from: from, to: to, isRegex: isRegex))
            }
        }
        return rules
    }

    /// The rules as a rules text (what `parse` reads back).
    public var text: String {
        (answers.keys.sorted().map { "answer: \($0)=\(answers[$0]!)" } + replacements.map(\.line) + forbids.map { "forbid: \($0)" }
            + allows.map { "allow: \($0)" } + notes.map { "note: \($0)" }).joined(separator: "\n")
    }

    /// These rules, then `other`'s (a preset plus the command line's).
    public func merged(with other: SkillPortRules) -> SkillPortRules {
        SkillPortRules(replacements: replacements + other.replacements, notes: notes + other.notes, forbids: forbids + other.forbids,
                       allows: allows + other.allows, answers: answers.merging(other.answers) { $1 },
                       origins: origins.merging(other.origins) { first, _ in first })
    }

    /// The replacements in order on one text.
    public func apply(to text: String) -> String {
        replacements.reduce(text) { text, rule in
            guard let regex = try? NSRegularExpression(pattern: rule.pattern) else { return text }
            return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: rule.template)
        }
    }

    /// Lint rules: each replacement's FROM (unless its TO holds it again) and each forbidden token.
    /// The id names the user rule a hit came from.
    public var lintRules: [(id: String, pattern: String)] {
        replacements.filter { $0.isRegex || !$0.to.contains($0.from) }.map { ("rule: \($0.line)", $0.pattern) }
            + forbids.map { ("forbid: \($0)", Replacement.literal($0)) }
    }

    // MARK: Presets

    /// Shipped presets, by name: the bundled catalog's known pairs (`<from>-to-<to>`).
    public static var builtIns: [String: String] { SkillPortCatalog.bundled.presets }

    /// Saved presets: `~/.akit/port-presets/<name>.rules`, this Mac's own (no brain needed, and a
    /// work Mac's rules don't reach the brain).
    public static func presetsFolder(env: HarnessEnvironment) -> URL {
        env.homeDirectory.appending(path: ".akit/port-presets", directoryHint: .isDirectory)
    }

    /// Saved presets by name.
    public static func savedPresets(env: HarnessEnvironment) -> [String: String] {
        let folder = presetsFolder(env: env)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var result: [String: String] = [:]
        for file in files where file.pathExtension == "rules" {
            if let text = try? String(contentsOf: file, encoding: .utf8) { result[file.deletingPathExtension().lastPathComponent] = text }
        }
        return result
    }

    /// A preset's text: a saved one first, else a pair of the catalog (with the user's entries).
    public static func preset(_ name: String, env: HarnessEnvironment) -> String? {
        savedPresets(env: env)[name] ?? ((try? SkillPortCatalog.load(env: env)) ?? .bundled).presets[name]
    }

    /// Saves a preset after checking it parses and its name is a-z, 0-9 and hyphens. Returns the file.
    @discardableResult
    public static func save(preset name: String, text: String, env: HarnessEnvironment) throws -> URL {
        guard name.range(of: "^[a-z0-9][a-z0-9-]*$", options: .regularExpression) != nil else {
            throw Failure(message: "A preset name has only a-z, 0-9 and hyphens: \(name).")
        }
        guard builtIns[name] == nil else { throw Failure(message: "\(name) is a built-in preset; pick another name.") }
        _ = try parse(text)
        let file = presetsFolder(env: env).appending(path: "\(name).rules")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file, options: .atomic)
        return file
    }
}
