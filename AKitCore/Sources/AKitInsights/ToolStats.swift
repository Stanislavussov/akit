import AKitFoundation
import AKitSessions
import Foundation

/// `akit stats tools`: which tools and MCP servers the sessions of a window had available, and which
/// of them were never called there. Availability uses the scope rules of `akit stats` (sessions started in
/// the last N days; for a project, bound to it at a confidence of the set). Calls are those made in the
/// window, in any of the scope's sessions (one started earlier and resumed counts too), so a row is
/// unused exactly when its last call is before the window or there is none. Only recorded data:
/// availability from the tool lists the harness wrote into the session (`tool_listings`), calls from
/// `tool_calls`. The JSON (`version` 1) is the contract for `/akit` and the Insights screen.
public struct ToolsReport: Encodable, Equatable, Sendable {
    public struct Summary: Encodable, Equatable, Sendable {
        /// Sessions in scope (main sessions; subagent runs belong to their parent).
        public let sessions: Int
        /// Of those, sessions whose full tool list was recorded (a Claude Code prompt snapshot with tools, Pi ≥ 1.0).
        public let sessionsWithToolList: Int
        /// Tool calls made in the window in the scope's sessions, subagent runs included.
        public let calls: Int
    }

    public struct Tool: Encodable, Equatable, Sendable, Identifiable {
        public var id: String { name }
        /// As the harness names it; an MCP tool is `mcp__<server>__<tool>`.
        public let name: String
        /// The MCP server of an MCP tool; nil for a built-in or extension tool.
        public let server: String?
        /// Harnesses that listed or called it (`claude`, `pi`).
        public let harnesses: [String]
        /// Main sessions where it was available (subagent runs are no sessions). A built-in tool counts only in
        /// sessions with a full tool list; an MCP tool in every session that listed it.
        public let availableSessions: Int
        /// Distinct local calendar days it was first available in a main session.
        public let availableDays: Int
        /// Calls made in the window, subagent runs included.
        public let calls: Int
        /// Sessions with at least one call.
        public let calledSessions: Int
        /// The latest call in the scope's sessions, also before the window; nil: never called there.
        public let lastCall: String?
        /// No call in the window: its last call is before the window, or there is none.
        public let unused: Bool
    }

    public struct Server: Encodable, Equatable, Sendable, Identifiable {
        public var id: String { name }
        /// The server part of its tools' names (`claude_ai_Claude_Docs` for `mcp__claude_ai_Claude_Docs__read`).
        public let name: String
        /// Its tools that were available or called in the window.
        public let tools: Int
        /// Of those, the tools with at least one call.
        public let toolsCalled: Int
        /// Calls of all its tools in the window.
        public let calls: Int
        /// Main sessions where at least one of its tools was available.
        public let availableSessions: Int
        /// The latest call of any of its tools in the scope's sessions, also before the window.
        public let lastCall: String?
        /// No call of any of its tools in the window.
        public let unused: Bool
        /// Its tools without a call in the window, by name.
        public let unusedTools: [String]
    }

    let version: Int
    let generated: String
    public let window: StatsReport.Window
    public let scope: StatsReport.Scope
    public let summary: Summary
    /// Unused first (most available sessions first), then used ones by calls.
    public let tools: [Tool]
    /// Same order as `tools`.
    public let servers: [Server]
    public let notes: [String]

    /// Only the unused tools and servers (`akit stats tools --unused`); the summary stays whole.
    public func unusedOnly() -> ToolsReport {
        ToolsReport(version: version, generated: generated, window: window, scope: scope, summary: summary,
                    tools: tools.filter(\.unused), servers: servers.filter(\.unused), notes: notes)
    }
}

public enum ToolStats {
    static let noListNote = "Built-in tools count as available only in sessions with a full tool list (a Claude Code prompt snapshot "
        + "with tools, Pi 1.0+); MCP and deferred tools count in every session that listed them; other sessions add only calls"
    static let subagentNote = "Calls in subagent runs count for the session's tools; a tool only a subagent run listed is never "
        + "available, and it is a row only when a subagent called it"
    /// Sessions with a full tool list: a Claude Code prompt snapshot with tools, or Pi's `tools` section.
    static let fullListVia = "('snapshot', 'pi')"

    /// While files read by an older parser are still waiting to be read again, their sessions have no tool list yet.
    static func rereadNote(_ files: Int) -> String {
        "\(files) session file\(files == 1 ? " is" : "s are") still to be read again for tool lists; Import Now goes on"
    }

    /// The report of `days` up to `now`, for `project` (nil: every session on this Mac). `importNotes`
    /// (what the import before it said) come first in its notes.
    public static func report(_ database: IndexDatabase, days: Int = InsightsStats.defaultDays, project: String? = nil,
                              bindings: BindingSet = .default, importNotes: [String] = [], now: Date = Date()) throws -> ToolsReport {
        let from = now.addingTimeInterval(-Double(days) * 86_400)
        let scope = InsightsStats.Scope(project: project, bindings: bindings, from: from, to: now)
        let (scoped, values) = scope.cte
        // The last call also looks before the window: "unused for 30 days, last called 52 days ago".
        let (ever, everValues) = InsightsStats.Scope(project: project, bindings: bindings, from: .distantPast, to: now)
            .cte(as: "ever")

        let fullList = """
            EXISTS(SELECT 1 FROM tool_listings f WHERE f.harness = l.harness AND f.session_key = l.session_key \
            AND f.is_subagent = 0 AND f.via IN \(fullListVia))
            """
        struct Row {
            var server: String?
            var harnesses = Set<String>()
            var sessions = 0, days = 0, calls = 0, calledSessions = 0
            var lastCall: Double?
        }
        var rows: [String: Row] = [:]
        func split(_ value: SQLValue) -> [String] { value.text?.split(separator: ",").map(String.init) ?? [] }
        for row in try database.rows("""
            WITH \(scoped) SELECT l.tool, MAX(l.server), GROUP_CONCAT(DISTINCT l.harness), COUNT(DISTINCT l.session_key),
              COUNT(DISTINCT date(l.ts, 'unixepoch', 'localtime'))
            FROM tool_listings l JOIN scoped s ON s.key = l.session_key
            WHERE l.is_subagent = 0 AND (l.server IS NOT NULL OR \(fullList)) GROUP BY l.tool
            """, values) {
            guard let tool = row[0].text else { continue }
            rows[tool] = Row(server: row[1].text, harnesses: Set(split(row[2])), sessions: row[3].int ?? 0, days: row[4].int ?? 0)
        }
        // Calls made in the window, in any of the scope's sessions: a resumed older session's call today is a use.
        for row in try database.rows("""
            WITH \(ever) SELECT c.name, GROUP_CONCAT(DISTINCT c.harness), COUNT(*), COUNT(DISTINCT c.session_key)
            FROM tool_calls c JOIN ever s ON s.key = c.session_key WHERE c.name IS NOT NULL AND c.ts >= ? GROUP BY c.name
            """, everValues + [from.timeIntervalSince1970]) {
            guard let tool = row[0].text else { continue }
            var entry = rows[tool] ?? Row(server: MCPServers.server(ofTool: tool))
            entry.harnesses.formUnion(split(row[1]))
            entry.calls = row[2].int ?? 0
            entry.calledSessions = row[3].int ?? 0
            rows[tool] = entry
        }
        for row in try database.rows("""
            WITH \(ever) SELECT c.name, MAX(c.ts) FROM tool_calls c JOIN ever s ON s.key = c.session_key
            WHERE c.name IS NOT NULL GROUP BY c.name
            """, everValues) {
            guard let tool = row[0].text, rows[tool] != nil else { continue }
            rows[tool]?.lastCall = row[1].double
        }
        func iso(_ ts: Double?) -> String? { ts.map { Date(timeIntervalSince1970: $0).formatted(.iso8601) } }

        let tools = rows.map { name, row in
            ToolsReport.Tool(name: name, server: row.server, harnesses: row.harnesses.sorted(), availableSessions: row.sessions,
                             availableDays: row.days, calls: row.calls, calledSessions: row.calledSessions,
                             lastCall: iso(row.lastCall), unused: row.calls == 0)
        }.sorted(by: order)

        var serverSessions: [String: Int] = [:]
        for row in try database.rows("""
            WITH \(scoped) SELECT l.server, COUNT(DISTINCT l.session_key) FROM tool_listings l JOIN scoped s ON s.key = l.session_key
            WHERE l.is_subagent = 0 AND l.server IS NOT NULL GROUP BY l.server
            """, values) {
            if let server = row[0].text { serverSessions[server] = row[1].int ?? 0 }
        }
        let servers = Dictionary(grouping: rows.filter { $0.value.server != nil }) { $0.value.server ?? "" }.map { name, members in
            let calls = members.reduce(0) { $0 + $1.value.calls }
            return ToolsReport.Server(
                name: name, tools: members.count, toolsCalled: members.filter { $0.value.calls > 0 }.count, calls: calls,
                availableSessions: serverSessions[name] ?? 0, lastCall: iso(members.compactMap(\.value.lastCall).max()),
                unused: calls == 0, unusedTools: members.filter { $0.value.calls == 0 }.map(\.key).sorted())
        }.sorted { ($0.unused ? 0 : 1, -($0.unused ? $0.availableSessions : $0.calls), $0.name)
            < ($1.unused ? 0 : 1, -($1.unused ? $1.availableSessions : $1.calls), $1.name) }

        let sessions = try database.rows("WITH \(scoped) SELECT COUNT(*) FROM scoped", values).first?[0].int ?? 0
        let listed = try database.rows("""
            WITH \(scoped) SELECT COUNT(DISTINCT l.session_key) FROM tool_listings l JOIN scoped s ON s.key = l.session_key
            WHERE l.is_subagent = 0 AND l.via IN \(fullListVia)
            """, values).first?[0].int ?? 0
        let stale = try database.value("""
            SELECT COUNT(*) FROM sources WHERE state = 'active' AND kind IN ('session', 'subagent')
            AND ((harness = 'claude' AND parser_version < ?) OR (harness = 'pi' AND parser_version < ?))
            """, ClaudeFacts.parserVersion, PiFacts.parserVersion)?.int ?? 0
        var notes = importNotes
        if stale > 0 { notes.append(rereadNote(stale)) }
        if listed < sessions { notes.append(noListNote) }
        notes.append(subagentNote)
        return ToolsReport(
            version: 1, generated: now.formatted(.iso8601),
            window: .init(from: from.formatted(.iso8601), to: now.formatted(.iso8601), days: days),
            scope: .init(project: project, bindings: bindings.names),
            summary: .init(sessions: sessions, sessionsWithToolList: listed, calls: tools.reduce(0) { $0 + $1.calls }),
            tools: tools, servers: servers, notes: notes)
    }

    /// Unused first, the most available first; then used ones, the most called first; then by name.
    static func order(_ a: ToolsReport.Tool, _ b: ToolsReport.Tool) -> Bool {
        func key(_ tool: ToolsReport.Tool) -> (Int, Int) { tool.unused ? (0, -tool.availableSessions) : (1, -tool.calls) }
        return (key(a).0, key(a).1, a.name) < (key(b).0, key(b).1, b.name)
    }
}
