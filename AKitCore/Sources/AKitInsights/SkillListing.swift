import AKitFoundation
import AKitHarnesses
import Foundation

/// `akit stats listing` and the Insights screen's Skill Listing box: how big Claude Code's skill
/// listing was in each session, against the budget it had, and what would make every description
/// fit. Facts checked in Claude Code 2.1.296's binary (session-insights.md, "Skill listing budget"):
///
/// - budget (characters) = `SLASH_COMMAND_TOOL_CHAR_BUDGET` when set, else context window ×
///   characters per token × `skillListingBudgetFraction` (default 0.01; a number in (0, 1]);
///   characters per token is 4 for the models in Claude Code's older list (claude-3*, Opus and
///   Sonnet 4.0–4.6, Haiku 4.5) and 3 for every other model;
/// - an entry costs its name + 4 + its description (`description + " - " + when_to_use`, cut at
///   `skillListingMaxDescChars`, default 1536, to that many characters with "…"), a name-only entry
///   its name + 2, and the entries are joined by newlines;
/// - over budget, the most-used skills keep their descriptions, the rest are listed by name only.
///
/// Only recorded sizes: the descriptions' characters from the index; a session's context window is
/// 1M when one of its requests recorded more than 200,000 tokens of context, else 200k.
public struct ListingReport: Encodable, Equatable, Sendable {
    public struct Settings: Encodable, Equatable, Sendable {
        public let fraction: Double
        /// `default`, `~/.claude/settings.json`, or the project's `.claude/settings.json`.
        public let fractionFrom: String
        public let maxDescChars: Int
        public let maxDescCharsFrom: String
        /// `SLASH_COMMAND_TOOL_CHAR_BUDGET` (the command's environment; the app never sees a shell's).
        public let envBudget: Int?
        /// The file Raise Budget… writes: where the fraction is set now, else `~/.claude/settings.json`.
        public let file: String
        public let problems: [String]
    }

    public struct Sessions: Encodable, Equatable, Sendable {
        /// Main Claude Code sessions in the window with a skill listing.
        public let count: Int
        public let overBudget: Int
        public let share: Double
        /// The listing's size in characters as it was sent (name-only entries included): median and p90.
        public let medianChars: Int
        public let p90Chars: Int
        /// The same with every description: what the skills would need.
        public let medianFullChars: Int
        /// The budget of the median session.
        public let medianBudget: Int
    }

    public struct Fit: Encodable, Equatable, Sendable {
        /// Sessions still over budget.
        public let overBudget: Int
        /// The fraction that would have kept every description in every session; nil when all fit,
        /// above 1 when even the whole budget can't.
        public let neededFraction: Double?
        /// ≈ tokens per request the restored descriptions add (median over the sessions over budget).
        public let extraTokensPerRequest: Int
    }

    let version: Int
    public let days: Int
    public let project: String?
    public let settings: Settings
    public let sessions: Sessions
    /// As it is.
    public let now: Fit
    /// After the recommendations are done (their skills out of the listing), nil without any.
    public let afterFixes: Fit?
    /// The skills the recommendations take out of the listing.
    public let fixSkills: [String]
    public let notes: [String]

    /// Raise Budget… is offered only when the fixes alone can't fit every description.
    public var raiseTo: Double? {
        // The shell's SLASH_COMMAND_TOOL_CHAR_BUDGET wins over the fraction: raising it would change nothing.
        guard settings.envBudget == nil else { return nil }
        let fit = afterFixes ?? now
        guard fit.overBudget > 0, let needed = fit.neededFraction, needed <= 1 else { return nil }
        return needed
    }
}

public enum SkillListing {
    public static let defaultFraction = 0.01
    public static let defaultMaxDescChars = 1536
    static let envKey = "SLASH_COMMAND_TOOL_CHAR_BUDGET"
    /// Claude Code's `cF`: models whose listing budget counts 4 characters per token (others 3).
    static let fourCharModels: Set<String> = [
        "claude-3-opus", "claude-3-sonnet", "claude-3-haiku", "claude-3-5-sonnet", "claude-3-5-haiku", "claude-3-7-sonnet",
        "claude-opus-4-0", "claude-opus-4-1", "claude-opus-4-5", "claude-opus-4-6", "claude-sonnet-4-0", "claude-sonnet-4-5",
        "claude-sonnet-4-6", "claude-haiku-4-5",
    ]

    /// Characters per token of the budget: 4 for the older models (and an unknown one), else 3.
    /// Bedrock and Vertex ids are their base model: `us.anthropic.claude-sonnet-4-5-20250929-v1:0`,
    /// `claude-sonnet-4-5@20250929`.
    static func charsPerToken(model: String?) -> Int {
        guard var name = model?.lowercased(), !name.isEmpty else { return 4 }
        if let bracket = name.firstIndex(of: "[") { name = String(name[..<bracket]) }
        if let at = name.firstIndex(of: "@") { name = String(name[..<at]) }
        if let range = name.range(of: "anthropic.") { name = String(name[range.upperBound...]) }
        if let version = name.range(of: #"-v\d+(:\d+)?$"#, options: .regularExpression) { name = String(name[..<version.lowerBound]) }
        name = name.replacingOccurrences(of: ".", with: "-").replacingOccurrences(of: "_", with: "-")
        // A dated id (`claude-sonnet-4-5-20250929`) is its family.
        if let dash = name.lastIndex(of: "-"), name[name.index(after: dash)...].count == 8,
           name[name.index(after: dash)...].allSatisfy(\.isNumber) {
            name = String(name[..<dash])
        }
        return fourCharModels.contains(name) ? 4 : 3
    }

    /// The budget in characters for one session.
    static func budget(context: Int, model: String?, fraction: Double, envBudget: Int?) -> Int {
        if let envBudget, envBudget > 0 { return envBudget }
        return max(1, Int((Double(context * charsPerToken(model: model)) * fraction).rounded(.down)))
    }

    /// The fraction that fits `chars` in this session's context.
    static func fraction(for chars: Int, context: Int, model: String?) -> Double {
        Double(chars) / Double(context * charsPerToken(model: model))
    }

    /// Rounds a fraction up to 3 decimals (0.0137 → 0.014).
    static func roundUp(_ value: Double) -> Double { (value * 1000).rounded(.up) / 1000 }

    // MARK: - Settings

    static func userFile(_ env: HarnessEnvironment) -> URL? {
        HarnessCatalog.configRoot(of: .claudeCode, in: env)?.appending(path: "settings.json")
    }

    /// The two keys from `~/.claude/settings.json` and, in a project, its `.claude/settings.json`
    /// (the project's win, as in Claude Code). `settings.local.json` is never read.
    public static func settings(env: HarnessEnvironment, project: URL?, environment: [String: String] = [:]) -> ListingReport.Settings {
        let home = env.homeDirectory
        var fraction = defaultFraction, fractionFrom = "default", maxDesc = defaultMaxDescChars, maxDescFrom = "default"
        var problems: [String] = []
        let user = userFile(env)
        var file = user.map { FileWalk.tilde($0, home: home) } ?? "~/.claude/settings.json"
        for url in [user, project?.appending(path: ".claude/settings.json")].compactMap({ $0 }) {
            let shown = FileWalk.tilde(url, home: home)
            let value: JSONValue
            do {
                guard let read = try SettingsFile.read(url, home: home) else { continue }
                value = read.value
            } catch {
                problems.append(error.message)
                continue
            }
            if let raw = value.value(at: ["skillListingBudgetFraction"]) {
                if case .number(let text) = raw, let number = Double(text), number > 0, number <= 1 {
                    fraction = number
                    fractionFrom = shown
                    file = shown
                } else {
                    problems.append("\(shown): skillListingBudgetFraction must be a number above 0 and at most 1; Claude Code ignores it.")
                }
            }
            if let raw = value.value(at: ["skillListingMaxDescChars"]) {
                if case .number(let text) = raw, let number = Int(text), number > 0 {
                    maxDesc = number
                    maxDescFrom = shown
                } else {
                    problems.append("\(shown): skillListingMaxDescChars must be a whole number above 0; Claude Code ignores it.")
                }
            }
        }
        let envBudget = environment[envKey].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }.flatMap { $0 > 0 ? $0 : nil }
        return .init(fraction: fraction, fractionFrom: fractionFrom, maxDescChars: maxDesc, maxDescCharsFrom: maxDescFrom,
                     envBudget: envBudget, file: file, problems: problems)
    }

    // MARK: - Report

    /// One session's listing: each skill with the characters it was sent with (nil: by name only)
    /// and the characters its full description has (the most any session had).
    struct Session {
        var skills: [String: Int?] = [:]
        var model: String?
        var maxContext = 0
        var requests = 0
    }

    /// The listing of the scope's main Claude Code sessions in the last `days` days. `dropping`:
    /// the skills the recommendations take out of the listing, for the after-fixes fit.
    public static func report(_ database: IndexDatabase, days: Int = InsightsStats.defaultDays, project: String? = nil,
                              bindings: BindingSet = .default, settings: ListingReport.Settings, dropping: Set<String> = [],
                              now: Date = Date()) throws -> ListingReport {
        let from = now.addingTimeInterval(-Double(days) * 86_400)
        let scope = InsightsStats.Scope(project: project, bindings: bindings, from: from, to: now)
        let (scoped, values) = scope.cte
        var sessions: [String: Session] = [:]
        for row in try database.rows("""
            WITH \(scoped) SELECT l.session_key, l.skill, MAX(CASE WHEN l.desc_hash IS NOT NULL THEN l.desc_chars END)
            FROM skill_listings l JOIN scoped s ON s.key = l.session_key
            WHERE l.harness = 'claude' AND l.is_subagent = 0 GROUP BY l.session_key, l.skill
            """, values) {
            guard let key = row[0].text, let skill = row[1].text else { continue }
            sessions[key, default: Session()].skills[skill] = row[2].int
        }
        for row in try database.rows("""
            WITH \(scoped) SELECT r.session_key, MAX(COALESCE(r.input, 0) + COALESCE(r.cache_read, 0) + COALESCE(r.cache_write, 0)), COUNT(*)
            FROM requests r JOIN scoped s ON s.key = r.session_key WHERE r.is_subagent = 0 GROUP BY r.session_key
            """, values) {
            guard let key = row[0].text, sessions[key] != nil else { continue }
            sessions[key]?.maxContext = row[1].int ?? 0
            sessions[key]?.requests = row[2].int ?? 0
        }
        // The model of most of a session's main requests (ties: the name that sorts first).
        for row in try database.rows("""
            WITH \(scoped) SELECT r.session_key, r.model, COUNT(*) AS n FROM requests r JOIN scoped s ON s.key = r.session_key
            WHERE r.is_subagent = 0 AND r.model IS NOT NULL GROUP BY r.session_key, r.model ORDER BY r.session_key, n DESC, r.model
            """, values) {
            guard let key = row[0].text, sessions[key] != nil, sessions[key]?.model == nil else { continue }
            sessions[key]?.model = row[1].text
        }
        var full: [String: Int] = [:]
        for row in try database.rows("SELECT skill, MAX(desc_chars) FROM skill_listings WHERE harness = 'claude' AND desc_hash IS NOT NULL GROUP BY skill") {
            if let skill = row[0].text { full[skill] = row[1].int ?? 0 }
        }
        let calibration = try ContextSize.calibration(database)

        struct Measured { let sent: Int; let full: Int; let budget: Int; let context: Int; let model: String? }
        // JavaScript string lengths: UTF-16 units (the descriptions' characters are recorded the same way).
        func entry(_ name: String, _ chars: Int?) -> Int {
            chars.map { name.utf16.count + 4 + min($0, settings.maxDescChars) } ?? name.utf16.count + 2
        }
        func measure(_ session: Session, without: Set<String>) -> Measured {
            let kept = session.skills.filter { !without.contains($0.key) }
            let joins = max(0, kept.count - 1)
            let sent = kept.reduce(0) { $0 + entry($1.key, $1.value) } + joins
            let whole = kept.reduce(0) { $0 + entry($1.key, (full[$1.key]).flatMap { $0 > 0 ? $0 : nil }) } + joins
            let context = session.maxContext > 200_000 ? 1_000_000 : 200_000
            return Measured(sent: sent, full: whole, budget: budget(context: context, model: session.model, fraction: settings.fraction,
                                                                    envBudget: settings.envBudget),
                            context: context, model: session.model)
        }
        func fit(_ measured: [Measured]) -> ListingReport.Fit {
            let over = measured.filter { $0.full > $0.budget }
            let needed = over.map { fraction(for: $0.full, context: $0.context, model: $0.model) }.max().map(roundUp)
            let restored = over.map { max(0, $0.full - min($0.sent, $0.budget)) }.sorted()
            let median = restored.isEmpty ? 0 : restored[restored.count / 2]
            return .init(overBudget: over.count, neededFraction: needed,
                         extraTokensPerRequest: ContextSize.approxTokens(chars: median, script: .latin, calibration: calibration).tokens)
        }
        let all = sessions.values.filter { !$0.skills.isEmpty }.map { measure($0, without: []) }
        let sent = all.map(\.sent).sorted(), whole = all.map(\.full).sorted(), budgets = all.map(\.budget).sorted()
        let now = fit(all)
        let fixing = dropping.intersection(Set(sessions.values.flatMap(\.skills.keys)))
        let after = fixing.isEmpty ? nil : fit(sessions.values.filter { !$0.skills.isEmpty }.map { measure($0, without: fixing) })
        var notes: [String] = []
        if settings.envBudget != nil {
            notes.append("\(envKey) is set in this shell: Claude Code uses it instead of skillListingBudgetFraction (the app started from Finder doesn't see it).")
        }
        notes.append("A session's context window counts as 1M when a request of it recorded more than 200,000 tokens, else 200k.")
        notes.append("A skill listed by name only because of a user's own name-only setting counts as if the budget had dropped it.")
        notes.append("Claude Code always keeps the descriptions of its bundled skills; AKit can't tell them apart in the listing, so which skills lose theirs isn't modeled, only the total.")
        return ListingReport(
            version: 1, days: days, project: project, settings: settings,
            sessions: .init(count: all.count, overBudget: now.overBudget,
                            share: all.isEmpty ? 0 : (Double(now.overBudget) / Double(all.count) * 1000).rounded() / 1000,
                            medianChars: InsightsStats.rank(sent, 0.5), p90Chars: InsightsStats.rank(sent, 0.9),
                            medianFullChars: InsightsStats.rank(whole, 0.5), medianBudget: InsightsStats.rank(budgets, 0.5)),
            now: now, afterFixes: after, fixSkills: fixing.sorted(), notes: notes)
    }

    /// The skills a set of recommendations takes out of the listing (manual, moved, a plugin disabled).
    public static func fixSkills(_ report: RecommendReport) -> Set<String> {
        Set(report.recommendations.flatMap { item in item.evidence.skills ?? (item.skill == Recommender.wholePlugin ? [] : [item.skill]) })
    }

    // MARK: - Raise Budget

    /// Raise Budget…: `skillListingBudgetFraction` set to `fraction` in the file the setting is read
    /// from (`settings.file`), through `SettingsFile` (backup, refused when the key changed since).
    public static func raise(to fraction: Double, settings: ListingReport.Settings, env: HarnessEnvironment) throws -> SettingsFile.Change {
        let home = env.homeDirectory
        let file = settings.file.hasPrefix("~/") ? home.appending(path: String(settings.file.dropFirst(2))) : URL(filePath: settings.file)
        return try SettingsFile.change(file, edits: [.set(["skillListingBudgetFraction"], .number(String(format: "%.3f", fraction)))], home: home)
    }
}
