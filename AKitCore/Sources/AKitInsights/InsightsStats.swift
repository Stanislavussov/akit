import AKitBrain
import AKitFoundation
import AKitHarnesses
import AKitSkills
import Foundation

/// `akit stats`: what every listed skill takes of the context and how often it is called, over a
/// window of days, for this Mac's sessions or one project's. The JSON (`version` 1) is the
/// contract for `/akit` and a later Insights screen. Sizes are estimates (≈), marked as such;
/// counts and first-request context are recorded.
public struct StatsReport: Encodable, Equatable, Sendable {
    public struct Window: Encodable, Equatable, Sendable {
        let from: String
        let to: String
        public let days: Int
    }

    public struct Scope: Encodable, Equatable, Sendable {
        /// nil: every session on this Mac.
        public let project: String?
        /// Binding confidences that count a session as the project's.
        public let bindings: [String]

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(project, forKey: .project)
            try container.encode(bindings, forKey: .bindings)
        }

        private enum CodingKeys: String, CodingKey { case project, bindings }
    }

    public struct ImportState: Encodable, Equatable, Sendable {
        /// When the index last read a file; nil before the first import.
        let last: String?
        /// Another import held the lock, so the index was read as it was.
        let running: Bool

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(last, forKey: .last)
            try container.encode(running, forKey: .running)
        }

        private enum CodingKeys: String, CodingKey { case last, running }
    }

    /// Recorded: input + cache read + cache write of each session's first main request.
    public struct FirstRequestContext: Encodable, Equatable, Sendable {
        public let median: Int
        public let p90: Int
    }

    public struct OwnerSummary: Encodable, Equatable, Sendable {
        public let owner: String
        public let skills: Int
        /// ≈ tokens per request if all of them are listed.
        public let approxTokens: Int
    }

    public struct Summary: Encodable, Equatable, Sendable {
        public let sessions: Int
        public let requests: Int
        public let firstRequestContext: FirstRequestContext
        /// ≈ listing tokens per main request of the sessions whose skill list was recorded with at
        /// least one description (name-only entries add no description tokens).
        public let approxListingTokensPerRequest: Int
        public let byOwner: [OwnerSummary]
    }

    public struct Owner: Encodable, Equatable, Sendable {
        public let kind: String
        public let name: String?

        init(_ owner: SkillOwner) {
            kind = owner.kind.rawValue
            name = owner.name
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(kind, forKey: .kind)
            try container.encode(name, forKey: .name)
        }

        private enum CodingKeys: String, CodingKey { case kind, name }
    }

    public struct SkillStats: Encodable, Equatable, Sendable {
        public let name: String
        public let owner: Owner
        /// Main sessions where it was listed with its description (subagent runs are no sessions; a
        /// skill listed by name only can't be picked by its description, so those sessions don't count).
        public let listedSessions: Int
        /// Distinct local calendar days it was listed with its description in a main session.
        public let listedDays: Int
        /// Calls by the model in Claude Code, subagents included, after the session's first listing.
        public let modelCalls: Int
        /// `/name` and `<skill>` calls by the user (built-in commands aren't skills).
        public let userCalls: Int
        /// Reads of its SKILL.md by the model in Pi. Pi records no skill list, so these only
        /// show the skill is used.
        public let piModelCalls: Int
        /// ≈ tokens of its description, as last listed.
        public let approxTokens: Int
        /// ≈ Σ over listed sessions of the session's own description tokens × main requests from
        /// the first listing on.
        public let approxContextSpace: Int
        /// Share of listed sessions with a model call.
        public let callRate: Double
        /// Start of its current description (see `DescriptionWindow`); counting starts at the
        /// later of this and the report window.
        public let windowStart: String
        /// Distinct description texts seen; text output only.
        public let descriptionVersions: Int

        private enum CodingKeys: String, CodingKey {
            case name, owner, listedSessions, listedDays, modelCalls, userCalls, piModelCalls, approxTokens,
                 approxContextSpace, callRate, windowStart
        }
    }

    public struct Omitted: Encodable, Equatable, Sendable {
        public let skills: Int
    }

    /// Claude Code lists a skill by name only, usually because its listing is over its budget, or
    /// because the user set it to `name-only`: the Claude sessions in scope whose main listing had
    /// such a skill. Counted only for a skill never listed with its description in that session (so
    /// the session doesn't count as listed for it) and listed with one somewhere in the index (a
    /// skill never described anywhere likely has an empty description: nothing was dropped).
    public struct DroppedDescriptions: Encodable, Equatable, Sendable {
        public struct Skill: Encodable, Equatable, Sendable {
            public let name: String
            /// Sessions where it was listed by name only and never with its description.
            public let sessions: Int
        }

        /// Claude sessions in scope with a skill listing.
        public let sessions: Int
        /// Of those, sessions with at least one such skill.
        public let withNameOnly: Int
        public let share: Double
        /// The skills that lost their description in the most sessions, most first.
        public let skills: [Skill]

        /// The finding in one line, as `akit stats` and the Insights screen show it; nil without Claude listings.
        public var text: String? {
            guard sessions > 0 else { return nil }
            var text = "Descriptions dropped by the harness: \(withNameOnly) of \(sessions) Claude session\(sessions == 1 ? "" : "s") "
                + "(\(Int((share * 100).rounded()))%) listed some skills by name only, usually because the listing was over "
                + "Claude Code's budget, or because of a user override"
            if !skills.isEmpty { text += "; most often " + skills.map { "\($0.name) (\($0.sessions))" }.joined(separator: ", ") }
            return text + ". Such sessions don't count as listed for those skills."
        }
    }

    let version: Int
    let generated: String
    public let window: Window
    public let scope: Scope
    let importState: ImportState
    public let summary: Summary
    public let skills: [SkillStats]
    public let omitted: Omitted
    public let droppedDescriptions: DroppedDescriptions
    public let notes: [String]

    private enum CodingKeys: String, CodingKey {
        case version, generated, window, scope, importState = "import", summary, skills, omitted, droppedDescriptions, notes
    }
}

public enum InsightsStats {
    public static let defaultDays = 30
    public static let defaultTop = 10
    /// Skills named in the "descriptions dropped" finding.
    static let droppedTop = 5
    static let piNote = "Pi records no skill list; Pi calls only protect skills"
    static let noBrainNote = "No brain on this Mac: owners of layer skills are unknown"

    public struct Options {
        var days = InsightsStats.defaultDays
        /// A project id; nil: every session on this Mac.
        var project: String?
        var bindings = BindingSet.default
        /// Skills shown, by ≈ context space; nil: all.
        var top: Int? = InsightsStats.defaultTop

        public init(days: Int = InsightsStats.defaultDays, project: String? = nil, bindings: BindingSet = .default,
                    top: Int? = InsightsStats.defaultTop) {
            self.days = days
            self.project = project
            self.bindings = bindings
            self.top = top
        }
    }

    /// What the index doesn't know: owners, descriptions (for the script), brain windows, other Macs.
    public struct Inputs {
        /// Missing names are unknown.
        var owners: [String: SkillOwner] = [:]
        /// Installed or brain descriptions by listed name, to tell Latin from Cyrillic.
        public var descriptions: [String: String] = [:]
        /// Window starts of brain skills (`DescriptionWindow.brainStarts`); win over the hash rule.
        var brainStarts: [String: Date] = [:]
        /// Other Macs' description hashes per skill, from their machine summaries in the brain.
        var otherMacHashes: [String: [DescriptionWindow.OtherMacHash]] = [:]
        var hasBrain = true
        /// Installed skills only Pi sees: it records no skill list, so there is no data on them.
        var piOnly: Set<String> = []
        public var importNotes: [String] = []
        public var importRunning = false

        public init() {}

        /// The memberwise init, written out because `init()` above replaces it.
        init(owners: [String: SkillOwner] = [:], descriptions: [String: String] = [:], brainStarts: [String: Date] = [:],
             otherMacHashes: [String: [DescriptionWindow.OtherMacHash]] = [:], hasBrain: Bool = true, piOnly: Set<String> = [],
             importNotes: [String] = [], importRunning: Bool = false) {
            self.owners = owners
            self.descriptions = descriptions
            self.brainStarts = brainStarts
            self.otherMacHashes = otherMacHashes
            self.hasBrain = hasBrain
            self.piOnly = piOnly
            self.importNotes = importNotes
            self.importRunning = importRunning
        }
    }

    /// Per skill, what the sessions in scope show from its counting start on.
    struct Tally {
        var listedSessions: Set<String> = []
        /// Distinct local days (`yyyy-MM-dd`) it was listed in a main session.
        var listedDays: Set<String> = []
        var modelCalls = 0
        var userCalls = 0
        var piModelCalls = 0
        var calledSessions: Set<String> = []
        var contextSpace = 0
        var latest: (first: Double, tokens: Int)?
    }

    /// The sessions counted: started between `from` and `to`; for a project, bound to it at a
    /// confidence of the set.
    struct Scope {
        var project: String?
        var bindings = BindingSet.default
        var from: Date
        var to: Date

        /// `scoped AS (…)` for a `WITH` clause, and its values.
        var cte: (sql: String, values: [any SQLBindable]) {
            var sql = "scoped AS (SELECT s.key FROM sessions s"
            var values: [any SQLBindable] = []
            if let project {
                sql += " JOIN bindings b ON b.session_key = s.key AND b.project_id = ? AND b.confidence IN \(bindings.sqlList)"
                values.append(project)
            }
            sql += " WHERE s.started >= ? AND s.started <= ?)"
            return (sql, values + [from.timeIntervalSince1970, to.timeIntervalSince1970])
        }

        /// `cte` plus `starts(skill, start)`: each skill's start, for counting from it.
        func cte(starts: [String: Date]) throws -> (sql: String, values: [any SQLBindable]) {
            let json = String(decoding: try JSONEncoder().encode(starts.mapValues(\.timeIntervalSince1970)), as: UTF8.self)
            let (sql, values) = cte
            return (sql + ", starts AS (SELECT key AS skill, value AS start FROM json_each(?))", values + [json])
        }
    }

    /// Calls that count: every model call, and the user's skill calls (not built-in commands), of `skill_calls c`.
    static let countedCallsSQL = "(c.by = 'model' OR COALESCE(json_extract(c.extra, '$.kind'), 'skill') = 'skill')"

    /// Skills listed in the scope's sessions (main or subagent).
    static func listedNames(_ database: IndexDatabase, scope: Scope) throws -> [String] {
        let (scoped, values) = scope.cte
        return try database.rows("""
            WITH \(scoped) SELECT DISTINCT l.skill FROM skill_listings l JOIN scoped s ON s.key = l.session_key
            """, values).compactMap { $0[0].text }
    }

    /// Listings, calls and ≈ context space per skill in the scope's sessions, each counted from the
    /// skill's start (skills without one aren't counted). Only described exposures count as listed
    /// (`desc_hash` not NULL): a skill listed by name only can't be picked by its description. Model
    /// and user calls count after the session's first listing of any kind; Pi lists nothing, so its
    /// calls count from the start on.
    static func tallies(_ database: IndexDatabase, scope: Scope, starts: [String: Date], descriptions: [String: String],
                        calibration: ContextSize.Calibration) throws -> [String: Tally] {
        let (ctes, values) = try scope.cte(starts: starts)
        let with = "WITH \(ctes)"

        var tallies: [String: Tally] = [:]
        // Main sessions: first described listing, own description size, main requests from then on.
        for row in try database.rows("""
            \(with), firsts AS (SELECT l.session_key, l.skill, MIN(l.ts) AS first, MAX(l.desc_chars) AS chars
              FROM skill_listings l JOIN scoped s ON s.key = l.session_key JOIN starts st ON st.skill = l.skill
              WHERE l.is_subagent = 0 AND l.desc_hash IS NOT NULL AND l.ts >= st.start GROUP BY l.session_key, l.skill)
            SELECT f.skill, f.session_key, f.first, f.chars, (SELECT COUNT(*) FROM requests r
              WHERE r.session_key = f.session_key AND r.is_subagent = 0 AND r.ts >= f.first) FROM firsts f
            """, values) {
            guard let skill = row[0].text, let session = row[1].text, let first = row[2].double else { continue }
            let script = descriptions[skill].map(ContextSize.script) ?? .latin
            let tokens = ContextSize.approxTokens(chars: row[3].int ?? 0, script: script, calibration: calibration).tokens
            var tally = tallies[skill] ?? Tally()
            tally.listedSessions.insert(session)
            tally.contextSpace += tokens * (row[4].int ?? 0)
            if first >= tally.latest?.first ?? -.infinity { tally.latest = (first, tokens) }
            tallies[skill] = tally
        }
        for row in try database.rows("""
            \(with) SELECT DISTINCT l.skill, date(l.ts, 'unixepoch', 'localtime') FROM skill_listings l
            JOIN scoped s ON s.key = l.session_key JOIN starts st ON st.skill = l.skill
            WHERE l.is_subagent = 0 AND l.desc_hash IS NOT NULL AND l.ts >= st.start
            """, values) {
            guard let skill = row[0].text, let day = row[1].text else { continue }
            tallies[skill, default: Tally()].listedDays.insert(day)
        }
        // Calls in sessions with a listing (main or subagent), from the first listing on.
        for row in try database.rows("""
            \(with), firsts AS (SELECT l.session_key, l.skill, MIN(l.ts) AS first
              FROM skill_listings l JOIN scoped s ON s.key = l.session_key JOIN starts st ON st.skill = l.skill
              WHERE l.ts >= st.start GROUP BY l.session_key, l.skill)
            SELECT c.skill, c.session_key, c.by, COUNT(*) FROM skill_calls c
            JOIN firsts f ON f.session_key = c.session_key AND f.skill = c.skill
            WHERE c.harness != 'pi' AND c.ts >= f.first AND \(countedCallsSQL) GROUP BY c.skill, c.session_key, c.by
            """, values) {
            guard let skill = row[0].text, let session = row[1].text, let count = row[3].int else { continue }
            var tally = tallies[skill] ?? Tally()
            if row[2].text == "model" {
                tally.modelCalls += count
                tally.calledSessions.insert(session)
            } else {
                tally.userCalls += count
            }
            tallies[skill] = tally
        }
        // Pi: no listing, so every call from the start on.
        for row in try database.rows("""
            \(with) SELECT c.skill, c.by, COUNT(*) FROM skill_calls c JOIN scoped s ON s.key = c.session_key
            JOIN starts st ON st.skill = c.skill WHERE c.harness = 'pi' AND c.ts >= st.start AND \(countedCallsSQL) GROUP BY c.skill, c.by
            """, values) {
            guard let skill = row[0].text, let count = row[2].int else { continue }
            if row[1].text == "model" {
                tallies[skill, default: Tally()].piModelCalls += count
            } else {
                tallies[skill, default: Tally()].userCalls += count
            }
        }
        return tallies
    }

    /// The "descriptions dropped by the harness" finding: Claude sessions in scope whose main listing
    /// had a skill by name only, and the skills that lost their description most often (see
    /// `StatsReport.DroppedDescriptions` for which name-only exposures count).
    static func droppedDescriptions(_ database: IndexDatabase, scope: Scope) throws -> StatsReport.DroppedDescriptions {
        let (scoped, values) = scope.cte
        let dropped = """
            dropped AS (SELECT DISTINCT l.session_key, l.skill FROM skill_listings l JOIN scoped s ON s.key = l.session_key
              WHERE l.harness = 'claude' AND l.is_subagent = 0 AND l.desc_hash IS NULL
                AND EXISTS(SELECT 1 FROM skill_listings d WHERE d.skill = l.skill AND d.desc_hash IS NOT NULL)
                AND NOT EXISTS(SELECT 1 FROM skill_listings d WHERE d.session_key = l.session_key AND d.skill = l.skill
                               AND d.is_subagent = 0 AND d.desc_hash IS NOT NULL))
            """
        let sessions = try database.rows("""
            WITH \(scoped) SELECT COUNT(DISTINCT l.session_key) FROM skill_listings l JOIN scoped s ON s.key = l.session_key
            WHERE l.harness = 'claude' AND l.is_subagent = 0
            """, values).first?[0].int ?? 0
        let withNameOnly = try database.rows("WITH \(scoped), \(dropped) SELECT COUNT(DISTINCT session_key) FROM dropped", values)
            .first?[0].int ?? 0
        let skills = try database.rows("""
            WITH \(scoped), \(dropped) SELECT skill, COUNT(*) AS n FROM dropped GROUP BY skill ORDER BY n DESC, skill LIMIT ?
            """, values + [droppedTop]).compactMap { row in
            row[0].text.map { StatsReport.DroppedDescriptions.Skill(name: $0, sessions: row[1].int ?? 0) }
        }
        return .init(sessions: sessions, withNameOnly: withNameOnly,
                     share: sessions > 0 ? (Double(withNameOnly) / Double(sessions) * 1000).rounded() / 1000 : 0, skills: skills)
    }

    public static func report(_ database: IndexDatabase, options: Options = Options(), inputs: Inputs = Inputs(),
                       now: Date = Date()) throws -> StatsReport {
        let from = now.addingTimeInterval(-Double(options.days) * 86_400)
        // Sessions in scope: started in the window; for a project, bound to it at a confidence of the set.
        let scope = Scope(project: options.project, bindings: options.bindings, from: from, to: now)
        let (scoped, scopeValues) = scope.cte
        let names = try listedNames(database, scope: scope)
        let hashStarts = try DescriptionWindow.hashStarts(database, otherMacs: inputs.otherMacHashes)
        var windowStarts: [String: Date] = [:]
        for name in names { windowStarts[name] = inputs.brainStarts[name] ?? hashStarts[name]?.date ?? from }
        let calibration = try ContextSize.calibration(database)
        // Counting starts at the later of the report window and the description window.
        let tallies = try tallies(database, scope: scope, starts: windowStarts.mapValues { max($0, from) },
                                  descriptions: inputs.descriptions, calibration: calibration)

        var skills = names.map { name -> StatsReport.SkillStats in
            let tally = tallies[name] ?? Tally()
            let listed = tally.listedSessions.count
            let called = tally.calledSessions.intersection(tally.listedSessions).count
            return StatsReport.SkillStats(
                name: name, owner: .init(inputs.owners[name] ?? .unknown), listedSessions: listed, listedDays: tally.listedDays.count,
                modelCalls: tally.modelCalls, userCalls: tally.userCalls, piModelCalls: tally.piModelCalls,
                approxTokens: tally.latest?.tokens ?? 0, approxContextSpace: tally.contextSpace,
                callRate: listed > 0 ? (Double(called) / Double(listed) * 1000).rounded() / 1000 : 0,
                windowStart: (windowStarts[name] ?? from).formatted(.iso8601),
                descriptionVersions: hashStarts[name]?.versions ?? 0)
        }
        skills.sort { ($0.approxContextSpace, $1.name) > ($1.approxContextSpace, $0.name) }

        let byOwner = SkillOwner.Kind.allCases.map { kind in
            let owned = skills.filter { $0.owner.kind == kind.rawValue }
            return StatsReport.OwnerSummary(owner: kind.rawValue, skills: owned.count, approxTokens: owned.reduce(0) { $0 + $1.approxTokens })
        }
        let sessions = try database.rows("WITH \(scoped) SELECT COUNT(*) FROM scoped", scopeValues).first?[0].int ?? 0
        let requests = try database.rows("""
            WITH \(scoped) SELECT COUNT(*) FROM requests r JOIN scoped s ON s.key = r.session_key WHERE r.is_subagent = 0
            """, scopeValues).first?[0].int ?? 0
        // Requests of the sessions with a described listing: the context space counts only those.
        let listedRequests = try database.rows("""
            WITH \(scoped) SELECT COUNT(*) FROM requests r JOIN scoped s ON s.key = r.session_key WHERE r.is_subagent = 0
            AND EXISTS(SELECT 1 FROM skill_listings l WHERE l.session_key = s.key AND l.is_subagent = 0 AND l.desc_hash IS NOT NULL)
            """, scopeValues).first?[0].int ?? 0
        let firstContexts = try database.rows("""
            WITH \(scoped) SELECT (SELECT COALESCE(r.input, 0) + COALESCE(r.cache_read, 0) + COALESCE(r.cache_write, 0)
              FROM requests r WHERE r.session_key = s.key AND r.is_subagent = 0 ORDER BY r.ts IS NULL, r.ts LIMIT 1) FROM scoped s
            """, scopeValues).compactMap { $0[0].int }.sorted()
        let space = skills.reduce(0) { $0 + $1.approxContextSpace }
        let shown = options.top.map { Array(skills.prefix(max(0, $0))) } ?? skills
        let last = try database.value("SELECT MAX(imported_at) FROM sources")?.double

        var notes = inputs.importNotes
        if !inputs.hasBrain { notes.append(noBrainNote) }
        notes.append("≈ tokens = description characters / k (\(calibration.describe))")
        notes.append(piNote)
        return StatsReport(
            version: 1, generated: now.formatted(.iso8601),
            window: .init(from: from.formatted(.iso8601), to: now.formatted(.iso8601), days: options.days),
            scope: .init(project: options.project, bindings: options.bindings.names),
            importState: .init(last: last.map { Date(timeIntervalSince1970: $0).formatted(.iso8601) }, running: inputs.importRunning),
            summary: .init(sessions: sessions, requests: requests,
                           firstRequestContext: .init(median: rank(firstContexts, 0.5), p90: rank(firstContexts, 0.9)),
                           approxListingTokensPerRequest: listedRequests > 0 ? Int((Double(space) / Double(listedRequests)).rounded()) : 0,
                           byOwner: byOwner),
            skills: shown, omitted: .init(skills: skills.count - shown.count),
            droppedDescriptions: try droppedDescriptions(database, scope: scope), notes: notes)
    }

    /// Owners from the skills installed on this Mac and, with a brain, which of them AKit rendered
    /// from it (`BrainLinks`); window starts of layer skills from the brain's git history.
    public static func inputs(env: HarnessEnvironment, database: IndexDatabase, brain: Brain?, projectsRoot: URL, hostName: String,
                       hardware: String?, run: CommandRunner? = nil) async throws -> Inputs {
        let names = try database.rows("SELECT DISTINCT skill FROM skill_listings").compactMap { $0[0].text }
        let installed = SkillScanner.scan(installations: HarnessCatalog.detectAll(in: env),
                                          extraProjects: ProjectFinder.projects(inRoots: [projectsRoot]), in: env)
        let links = try brain.map { brain in
            BrainLinks.links(for: installed, brain: brain,
                             folders: try projectFolders(database, env: env, projectsRoot: projectsRoot, hostName: hostName),
                             store: ProjectStore.current(brain: brain.root, home: env.homeDirectory))
        }
        let owners = SkillOwners.classify(names, installed: installed, links: links, layers: brain?.layers ?? [],
                                          home: env.homeDirectory)
        var descriptions: [String: String] = [:]
        for skill in installed {
            let name = if case .plugin(let plugin) = skill.scope { "\(plugin):\(skill.name)" } else { skill.name }
            if descriptions[name] == nil { descriptions[name] = skill.description }
        }
        for skill in brain?.skills ?? [] where descriptions[skill.name] == nil { descriptions[skill.name] = skill.description }
        var brainStarts: [String: Date] = [:]
        if let brain {
            let layerSkills = Set(owners.filter { $0.value.kind == .layer }.keys).intersection(brain.skills.map(\.name))
            brainStarts = await DescriptionWindow.brainStarts(brainRoot: brain.root, skills: layerSkills, database: database,
                                                              env: env, run: run)
        }
        var otherMacHashes: [String: [DescriptionWindow.OtherMacHash]] = [:]
        if let brain {
            let machine = MachineProfile.load(home: env.homeDirectory)
            otherMacHashes = UsageSummary.load(brain: brain.root, store: nil, ownership: UsageSummary.ownership(database, machine: machine, hardware: hardware))
                .descHashes
        }
        return Inputs(owners: owners, descriptions: descriptions, brainStarts: brainStarts, otherMacHashes: otherMacHashes,
                      hasBrain: brain != nil, piOnly: Set(installed.filter { $0.visibleTo == [.pi] }.map(\.name)))
    }

    /// Brain project ids → their folders on this Mac, without git: this Mac's home, the main
    /// checkout of every bound repository, and `local/…` folders under the projects root.
    static func projectFolders(_ database: IndexDatabase, env: HarnessEnvironment, projectsRoot: URL,
                               hostName: String) throws -> [String: URL] {
        let home = ProjectRecords.homeID(hostName: hostName, machineName: MachineProfile.load(home: env.homeDirectory).homeName)
        var folders = [home: env.homeDirectory]
        for row in try database.rows("SELECT DISTINCT project_id, repo_path FROM bindings WHERE project_id IS NOT NULL") {
            guard let id = row[0].text, folders[id] == nil else { continue }
            let folder: URL
            if let common = row[1].text {
                folder = URL(filePath: BindingPaths.mainFolder(ofCommonDir: common), directoryHint: .isDirectory)
            } else if id.hasPrefix("local/") {
                folder = projectsRoot.appending(path: String(id.dropFirst("local/".count)), directoryHint: .isDirectory)
            } else {
                continue
            }
            if FileWalk.isDirectory(folder) { folders[id] = folder }
        }
        return folders
    }

    /// Nearest-rank percentile of sorted values; 0 when empty.
    static func rank(_ sorted: [Int], _ fraction: Double) -> Int {
        guard !sorted.isEmpty else { return 0 }
        let index = Int((fraction * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(max(index, 0), sorted.count - 1)]
    }
}
