import AKitFoundation
import Foundation

/// A repeated correction the model found and code checked: reactions from at least 2 sessions,
/// shown verbatim from the logs, and the rule proposed for them.
public struct CorrectionPattern: Codable, Hashable, Sendable, Identifiable {
    /// `p-` and 8 hex of the reactions' places: the same reactions give the same id.
    public let id: String
    /// ≤ 15 words.
    public let title: String
    /// 1–4 imperative lines for the agent, in English.
    public let rule: [String]
    /// The user's words, verbatim from the logs.
    public let reactions: [CorrectionExcerpt]
    /// The project the reactions all come from; nil: two or more projects (or none), so global.
    public let scope: String?
    public let found: Date

    public var sessions: Int { Set(reactions.map(\.sessionKey)).count }
    /// `key#step` of each reaction: the same correction in the log, whatever the pick called it.
    public var places: Set<String> { Set(reactions.map { "\($0.sessionKey)#\($0.step)" }) }

    static func id(of reactions: [CorrectionExcerpt]) -> String {
        "p-" + Checksum.sha256(Data(reactions.map { "\($0.sessionKey)#\($0.step)" }.sorted().joined(separator: "\n").utf8)).prefix(8)
    }
}

/// A pattern's rule written into an instruction file. Its mark in the spool is the before/after
/// anchor of the verdict.
public struct CorrectionRule: Codable, Hashable, Sendable, Identifiable {
    /// The pattern's id.
    public let id: String
    public let title: String
    public let rule: [String]
    /// The verdict's scope: a project id, or nil for every session on this Mac.
    public let scope: String?
    /// `global` (Brain → Global Instructions) or the instruction file's path.
    public let target: String
    public let applied: Date
    public let places: [String]
    /// When Remove Rule… took it out again; it then has no verdict.
    public var removed: Date?

    public var isGlobal: Bool { target == CorrectionRules.globalTarget }
}

/// `~/.akit/corrections/state.json`: the last Find Pattern… result, the dismissed patterns and the
/// applied rules. Local to this Mac: it holds the user's words from session logs.
public struct CorrectionsState: Codable, Equatable, Sendable {
    public var patterns: [CorrectionPattern] = []
    /// Ids and lowercased titles of dismissed patterns.
    public var dismissed: [String] = []
    public var rules: [CorrectionRule] = []

    public init(patterns: [CorrectionPattern] = [], dismissed: [String] = [], rules: [CorrectionRule] = []) {
        self.patterns = patterns
        self.dismissed = dismissed
        self.rules = rules
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        patterns = (try? container.decodeIfPresent([CorrectionPattern].self, forKey: .patterns)) ?? []
        dismissed = (try? container.decodeIfPresent([String].self, forKey: .dismissed)) ?? []
        rules = (try? container.decodeIfPresent([CorrectionRule].self, forKey: .rules)) ?? []
    }

    private enum CodingKeys: String, CodingKey { case patterns, dismissed, rules }

    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    public static func file(env: HarnessEnvironment) -> URL {
        env.homeDirectory.appending(path: ".akit/corrections/state.json")
    }

    /// Empty when there is no file yet.
    public static func load(env: HarnessEnvironment) throws(Failure) -> CorrectionsState {
        let url = file(env: env)
        guard FileManager.default.fileExists(atPath: url.path) else { return CorrectionsState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url), let state = try? decoder.decode(CorrectionsState.self, from: data) else {
            throw Failure(message: "\(url.path) can't be read. Fix or move it, then try again.")
        }
        return state
    }

    public func save(env: HarnessEnvironment) throws(Failure) {
        let url = Self.file(env: env)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try encoder.encode(self).write(to: url, options: .atomic)
        } catch {
            throw Failure(message: "Couldn't write \(url.path): \(error.localizedDescription)")
        }
    }

    /// Whether a pattern is shown: not dismissed and not applied already (same reactions, or a
    /// rule with the same title).
    public func shows(_ pattern: CorrectionPattern) -> Bool {
        let title = pattern.title.lowercased()
        if dismissed.contains(pattern.id) || dismissed.contains(title) { return false }
        return !rules.contains { rule in
            rule.removed == nil && (rule.title.lowercased() == title || pattern.places.isSubset(of: Set(rule.places)))
        }
    }

    /// The patterns still shown.
    public var shown: [CorrectionPattern] { patterns.filter(shows) }

    public func pattern(_ id: String) -> CorrectionPattern? { patterns.first { $0.id == id } }

    public mutating func dismiss(_ pattern: CorrectionPattern) {
        for key in [pattern.id, pattern.title.lowercased()] where !dismissed.contains(key) { dismissed.append(key) }
    }
}
