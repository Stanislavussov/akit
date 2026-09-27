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
