import Foundation

/// Read-only questions to the index.
enum IndexQueries {
    /// When each skill was first listed in a session. Exposure is always aggregated from the
    /// listing rows (one per listing and skill), never kept as a counter, so repeated initial
    /// listings and deltas count once.
    static func exposure(_ database: IndexDatabase, session: String, includeSubagents: Bool = false) throws -> [String: Date] {
        let rows = try database.rows("""
            SELECT skill, MIN(ts) FROM skill_listings
            WHERE session_key = ? AND (? OR is_subagent = 0) GROUP BY skill
            """, session, includeSubagents)
        var result: [String: Date] = [:]
        for row in rows {
            guard let skill = row[0].text else { continue }
            result[skill] = row[1].double.map(Date.init(timeIntervalSince1970:)) ?? .distantPast
        }
        return result
    }

    // MARK: - Bindings

    /// How sessions are bound to projects (`akit stats bindings`).
    struct BindingStats: Encodable, Equatable {
        struct Recent: Encodable, Equatable {
            let days: Int
            /// Main sessions started in those days, and those bound at a confidence of the set.
            let sessions: Int
            let bound: Int
            let share: Double?
        }

        /// The confidences that count as bound.
        let bindingSet: [String]
        /// Sessions per method and per confidence (`none`: no project).
        let byMethod: [String: Int]
        let byConfidence: [String: Int]
        /// Sessions no import has bound yet.
        let undecided: Int
        let recent: Recent
        /// Up to 10 folders of recent sessions not bound in the set, latest first. Local paths:
        /// shown to the user only, never written anywhere else.
        let unboundFolders: [String]
        /// Path templates that would bind sessions no binding covers yet, most sessions first.
        let suggestedTemplates: [TemplateSuggestion]
        let notes: [String]
    }

    /// `{repo}` where unbound session folders name a known repository, e.g. the worktrees
    /// of an agent workspace this akit doesn't know.
    struct TemplateSuggestion: Encodable, Equatable {
        let template: String
        let sessions: Int
        let repositories: [String]
    }

    static func bindingStats(_ database: IndexDatabase, set: BindingSet, notes: [String] = [], days: Int = 30,
                             home: String? = nil, templates: [String] = [], now: Date = Date()) throws -> BindingStats {
        var byMethod = Dictionary(uniqueKeysWithValues: BindingMethod.allCases.map { ($0.rawValue, 0) })
        var byConfidence = Dictionary(uniqueKeysWithValues: (Confidence.allCases.map(\.rawValue) + ["none"]).map { ($0, 0) })
        for row in try database.rows("""
            SELECT b.method, COALESCE(b.confidence, 'none'), COUNT(*) FROM bindings b JOIN sessions s ON s.key = b.session_key
            GROUP BY b.method, b.confidence
            """) {
            guard let method = row[0].text, let confidence = row[1].text, let count = row[2].int else { continue }
            byMethod[method, default: 0] += count
            byConfidence[confidence, default: 0] += count
        }
        let undecided = try database.value("""
            SELECT COUNT(*) FROM sessions s WHERE NOT EXISTS(SELECT 1 FROM bindings b WHERE b.session_key = s.key)
            """)?.int ?? 0
        let since = now.addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970
        let recent = try database.rows("""
            SELECT COUNT(*), COALESCE(SUM(b.confidence IN \(set.sqlList)), 0) FROM sessions s
            LEFT JOIN bindings b ON b.session_key = s.key WHERE s.started >= ?
            """, since).first
        let sessions = recent?[0].int ?? 0, bound = recent?[1].int ?? 0
        let unbound = try database.rows("""
            SELECT s.cwd, MAX(s.started) AS latest FROM sessions s LEFT JOIN bindings b ON b.session_key = s.key
            WHERE s.started >= ? AND s.cwd IS NOT NULL AND (b.confidence IS NULL OR b.confidence NOT IN \(set.sqlList))
            GROUP BY s.cwd ORDER BY latest DESC LIMIT 10
            """, since).compactMap { $0[0].text }
        return BindingStats(bindingSet: set.names, byMethod: byMethod, byConfidence: byConfidence, undecided: undecided,
                            recent: .init(days: days, sessions: sessions, bound: bound,
                                          share: sessions > 0 ? Double(bound) / Double(sessions) : nil),
                            unboundFolders: unbound,
                            suggestedTemplates: try suggestTemplates(database, set: set, home: home, templates: templates),
                            notes: notes)
    }

    /// For every session folder not bound in the set: the first folder name (below the root)
    /// that is a bound repository's name, with something below it, becomes `{repo}` of a template
    /// `<parents>/{repo}/*`. Templates already in use and ones covering a single session are left out.
    static func suggestTemplates(_ database: IndexDatabase, set: BindingSet, home: String?, templates: [String],
                                 limit: Int = 3) throws -> [TemplateSuggestion] {
        var names = Set<String>()
        for row in try database.rows("""
            SELECT DISTINCT project_id, repo_path FROM bindings WHERE confidence IN \(set.sqlList) AND project_id IS NOT NULL
            """) {
            if let id = row[0].text, !id.hasPrefix("local/"), let last = id.split(separator: "/").last { names.insert(last.lowercased()) }
            if let repo = row[1].text {
                names.insert((BindingPaths.mainFolder(ofCommonDir: repo) as NSString).lastPathComponent.lowercased())
            }
        }
        let homePath = home.map(BindingPaths.canonical)
        func tilde(_ path: String) -> String {
            guard let homePath, path.hasPrefix(homePath + "/") else { return path }
            return "~" + path.dropFirst(homePath.count)
        }
        let used = Set(templates)
        var found: [String: (sessions: Int, repositories: Set<String>)] = [:]
        for row in try database.rows("""
            SELECT s.cwd, COUNT(*) FROM sessions s LEFT JOIN bindings b ON b.session_key = s.key
            WHERE s.cwd IS NOT NULL AND (b.confidence IS NULL OR b.confidence NOT IN \(set.sqlList)) GROUP BY s.cwd
            """) {
            guard let cwd = row[0].text, let count = row[1].int else { continue }
            let parts = BindingPaths.canonical(cwd).split(separator: "/").map(String.init)
            guard parts.count >= 3,
                  let index = (1..<(parts.count - 1)).first(where: { names.contains(parts[$0].lowercased()) }) else { continue }
            let template = tilde("/" + parts[..<index].joined(separator: "/")) + "/{repo}/*"
            guard !used.contains(template) else { continue }
            found[template, default: (0, [])].sessions += count
            found[template, default: (0, [])].repositories.insert(parts[index])
        }
        return found.filter { $0.value.sessions > 1 }
            .map { TemplateSuggestion(template: $0.key, sessions: $0.value.sessions, repositories: $0.value.repositories.sorted()) }
            .sorted { ($0.sessions, $1.template) > ($1.sessions, $0.template) }
            .prefix(limit).map(\.self)
    }

    // MARK: - Debug stats

    /// Recorded skill use and context of one session, to check the parsers on real logs.
    /// Counts are of the main session unless named `subagent…`.
    struct SessionDebug: Encodable, Equatable {
        struct ToolOutput: Encodable, Equatable {
            let name: String
            let bytes: Int
        }

        let key: String
        let harness: String
        let harnessVersion: String?
        let started: String?
        let requests: Int
        /// Distinct skills listed to the model, and the sum of their description lengths.
        let listings: Int
        let listedChars: Int
        let modelCalls: Int
        /// Skills the user called (`/name` in Claude Code, `<skill>` in Pi). Rows without a kind
        /// (read by a parser before kinds, from log files deleted since) count here as before,
        /// built-in commands included.
        let userCalls: Int
        /// Built-in commands the user typed, like `/model` or `/clear`.
        let userCommands: Int
        let subagentCalls: Int
        /// Subagent log files of the session.
        let subagentRuns: Int
        /// Input + cache read + cache write of the first main request.
        let firstRequestContext: Int?
        let largestToolOutputs: [ToolOutput]
    }

    /// `session` is a native id or a key (`claude:<id>`); nil takes the latest `limit` sessions.
    static func debugStats(_ database: IndexDatabase, session: String? = nil, limit: Int = 20) throws -> [SessionDebug] {
        let rows = if let session {
            try database.rows("SELECT key, harness, harness_version, started FROM sessions WHERE key = ? OR native_id = ? ORDER BY started DESC",
                              session, session)
        } else {
            try database.rows("SELECT key, harness, harness_version, started FROM sessions ORDER BY started DESC LIMIT ?", limit)
        }
        return try rows.compactMap { row in
            guard let key = row[0].text else { return nil }
            func count(_ sql: String) throws -> Int { try database.value(sql, key)?.int ?? 0 }
            let listed = try database.rows("""
                SELECT COUNT(*), SUM(chars) FROM (SELECT MAX(desc_chars) AS chars FROM skill_listings
                WHERE session_key = ? AND is_subagent = 0 GROUP BY skill)
                """, key).first
            let first = try database.value("""
                SELECT COALESCE(input, 0) + COALESCE(cache_read, 0) + COALESCE(cache_write, 0) FROM requests
                WHERE session_key = ? AND is_subagent = 0 ORDER BY ts IS NULL, ts LIMIT 1
                """, key)?.int
            let outputs = try database.rows("""
                SELECT name, output_bytes FROM tool_calls WHERE session_key = ? AND is_subagent = 0 AND output_bytes IS NOT NULL
                ORDER BY output_bytes DESC LIMIT 5
                """, key).map { SessionDebug.ToolOutput(name: $0[0].text ?? "tool", bytes: $0[1].int ?? 0) }
            return SessionDebug(
                key: key, harness: row[1].text ?? "", harnessVersion: row[2].text,
                started: row[3].double.map { Date(timeIntervalSince1970: $0).formatted(.iso8601) },
                requests: try count("SELECT COUNT(*) FROM requests WHERE session_key = ? AND is_subagent = 0"),
                listings: listed?[0].int ?? 0, listedChars: listed?[1].int ?? 0,
                modelCalls: try count("SELECT COUNT(*) FROM skill_calls WHERE session_key = ? AND by = 'model' AND is_subagent = 0"),
                userCalls: try count("""
                    SELECT COUNT(*) FROM skill_calls WHERE session_key = ? AND by = 'user' AND is_subagent = 0
                    AND COALESCE(json_extract(extra, '$.kind'), 'skill') = 'skill'
                    """),
                userCommands: try count("""
                    SELECT COUNT(*) FROM skill_calls WHERE session_key = ? AND by = 'user' AND is_subagent = 0
                    AND json_extract(extra, '$.kind') = 'command'
                    """),
                subagentCalls: try count("SELECT COUNT(*) FROM skill_calls WHERE session_key = ? AND is_subagent = 1"),
                subagentRuns: try count("SELECT COUNT(DISTINCT path) FROM sources WHERE session_key = ? AND kind = 'subagent'"),
                firstRequestContext: first, largestToolOutputs: outputs)
        }
    }

    /// Signs that a parser no longer matches the logs, or can't re-read them.
    static func debugNotes(_ database: IndexDatabase, sessions: [SessionDebug]) throws -> [String] {
        var notes = sessions.filter { $0.harness == "claude" && $0.harnessVersion != nil && $0.requests > 0 && $0.listings == 0 }.map {
            "\($0.key) (Claude Code \($0.harnessVersion ?? "")) has requests but no skill listing; the log format may have changed"
        }
        let stale = try database.value("""
            SELECT COUNT(*) FROM sources WHERE state = 'gone' AND parser_version < CASE harness WHEN 'pi' THEN ? ELSE ? END
            """, PiFacts.parserVersion, ClaudeFacts.parserVersion)?.int ?? 0
        if stale > 0 { notes.append("\(stale) deleted log files were read by an older parser; their facts stay as read then") }
        return notes
    }
}
