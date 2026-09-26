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
}
