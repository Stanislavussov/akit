import Foundation
import Testing
import AKitFoundation
import AKitSessions
@testable import AKitCommandLine
@testable import AKitInsights

/// `akit stats tools`: tools and MCP servers available and called over a window. Facts are written
/// straight into a temporary index in a temporary fake home (see `InsightsStatsTests`).
extension InsightsStatsTests {
    func toolListing(_ id: String, _ tools: [String], at ts: Double, subagent: Bool = false, harness: String = "claude",
                     via: String = "snapshot", in db: IndexDatabase) throws {
        for tool in tools {
            try db.run("""
                INSERT INTO tool_listings(harness, session_key, is_subagent, tool, server, via, ts, source_id, parser_version)
                VALUES(?, ?, ?, ?, ?, ?, ?, 0, 3)
                """, harness, "\(harness):\(id)", subagent, tool, MCPServers.server(ofTool: tool), via, ts)
        }
    }

    func toolCall(_ id: String, _ name: String, at ts: Double, subagent: Bool = false, harness: String = "claude",
                  in db: IndexDatabase) throws {
        try db.run("""
            INSERT INTO tool_calls(harness, event_key, session_key, ts, name, is_subagent, source_id, parser_version)
            VALUES(?, ?, ?, ?, ?, ?, 0, 3)
            """, harness, UUID().uuidString, "\(harness):\(id)", ts, name, subagent)
    }

    func tools(_ db: IndexDatabase, days: Int = 30, project: String? = nil) throws -> ToolsReport {
        try ToolStats.report(db, days: days, project: project, now: now)
    }

    func tool(_ name: String, in report: ToolsReport) throws -> ToolsReport.Tool {
        try #require(report.tools.first { $0.name == name }, "\(name) in \(report.tools.map(\.name))")
    }

    @Test func unusedToolsAndServersInTheWindow() throws {
        let db = try database()
        let docs = ["mcp__docs__search", "mcp__docs__fetch"], idle = ["mcp__idle__ping", "mcp__idle__pong"]
        try session("s1", started: at(3), in: db)
        try toolListing("s1", ["Read", "Bash", "WebFetch"] + docs + idle, at: at(3), in: db)
        try toolCall("s1", "Read", at: at(3, 13), in: db)
        try toolCall("s1", "Read", at: at(3, 14), in: db)
        try toolCall("s1", "mcp__docs__search", at: at(3, 15), in: db)
        try session("s2", started: at(1), in: db)
        try toolListing("s2", ["Read", "Bash"] + idle, at: at(1), in: db)
        // A subagent run's call counts for the session's tool.
        try toolCall("s2", "Bash", at: at(1, 13), subagent: true, in: db)
        // A tool only a subagent run had is not the session's.
        try toolListing("s2", ["Grep"], at: at(1, 13), subagent: true, in: db)

        let report = try tools(db)
        #expect(report.summary == .init(sessions: 2, sessionsWithToolList: 2, calls: 4))
        #expect(!report.tools.contains { $0.name == "Grep" })
        let read = try tool("Read", in: report)
        #expect(read.availableSessions == 2 && read.availableDays == 2 && read.calls == 2 && read.calledSessions == 1 && !read.unused)
        #expect(read.lastCall == iso(at(3, 14)) && read.server == nil && read.harnesses == ["claude"])
        #expect(try tool("Bash", in: report).calls == 1)
        let fetch = try tool("WebFetch", in: report)
        #expect(fetch.unused && fetch.calls == 0 && fetch.lastCall == nil && fetch.availableSessions == 1)
        // Unused first, most available first; then used ones by calls.
        #expect(report.tools.map(\.name) == ["mcp__idle__ping", "mcp__idle__pong", "WebFetch", "mcp__docs__fetch",
                                             "Read", "Bash", "mcp__docs__search"])

        // MCP servers: aggregated from their tools.
        #expect(report.servers.map(\.name) == ["idle", "docs"])
        let server = try #require(report.servers.first { $0.name == "docs" })
        #expect(server == .init(name: "docs", tools: 2, toolsCalled: 1, calls: 1, availableSessions: 1, lastCall: iso(at(3, 15)),
                                unused: false, unusedTools: ["mcp__docs__fetch"]))
        let unused = try #require(report.servers.first { $0.name == "idle" })
        #expect(unused.unused && unused.availableSessions == 2 && unused.unusedTools == idle.sorted() && unused.toolsCalled == 0)

        let only = report.unusedOnly()
        #expect(only.tools.allSatisfy(\.unused) && only.tools.count == 4 && only.servers.map(\.name) == ["idle"])
        #expect(only.summary == report.summary)
    }

    @Test func toolWindowEdgesAndLastCallBeforeIt() throws {
        let db = try database()
        // Started 31 days ago: out of a 30-day window, in a 60-day one.
        try session("old", started: at(31), in: db)
        try toolListing("old", ["Read", "WebSearch"], at: at(31), in: db)
        try toolCall("old", "WebSearch", at: at(31, 13), in: db)
        try session("new", started: at(2), in: db)
        try toolListing("new", ["Read", "WebSearch"], at: at(2), in: db)
        try toolCall("new", "Read", at: at(2, 13), in: db)
        // An older session without a recorded tool list: its calls count, it adds no availability.
        try session("bare", started: at(1), in: db)
        try toolCall("bare", "Edit", at: at(1, 13), in: db)

        let month = try tools(db)
        let search = try tool("WebSearch", in: month)
        #expect(search.unused && search.availableSessions == 1, "the call was in a session before the window")
        #expect(search.lastCall == iso(at(31, 13)), "the last call looks before the window")
        let edit = try tool("Edit", in: month)
        #expect(edit.availableSessions == 0 && edit.calls == 1 && !edit.unused)
        #expect(month.summary.sessions == 2 && month.summary.sessionsWithToolList == 1)
        #expect(month.notes.contains(ToolStats.noListNote))

        let twoMonths = try tools(db, days: 60)
        let wider = try tool("WebSearch", in: twoMonths)
        #expect(!wider.unused && wider.calls == 1 && wider.availableSessions == 2)
        #expect(try tool("Read", in: twoMonths).availableDays == 2)
    }

    @Test func aResumedOlderSessionsCallTodayIsAUse() throws {
        let db = try database()
        // Started 40 days ago, out of the window; resumed today and called a tool.
        try session("old", started: at(40), in: db)
        try toolListing("old", ["Read", "mcp__docs__search"], at: at(40), in: db)
        try toolCall("old", "mcp__docs__search", at: at(0, 13), in: db)
        try session("new", started: at(2), in: db)
        try toolListing("new", ["Read", "mcp__docs__search"], at: at(2), in: db)

        let report = try tools(db)
        let search = try tool("mcp__docs__search", in: report)
        #expect(!search.unused && search.calls == 1 && search.lastCall == iso(at(0, 13)) && search.availableSessions == 1)
        #expect(try #require(report.servers.first).unused == false)
        // An unused row's last call is always before the window.
        for row in report.tools where row.unused {
            #expect(row.lastCall.map { $0 < iso(now.timeIntervalSince1970 - 30 * 86_400) } ?? true, "\(row)")
        }
        #expect(try tool("Read", in: report).unused)
    }

    @Test func builtInToolsCountOnlyInSessionsWithAFullList() throws {
        let db = try database()
        // Claude Code wrote only its deferred tools here: the built-in ones are unknown.
        try session("d", started: at(2), in: db)
        try toolListing("d", ["mcp__docs__search", "WebFetch"], at: at(2), via: "deferred", in: db)
        try session("s", started: at(1), in: db)
        try toolListing("s", ["Read", "Bash"], at: at(1), in: db)
        try toolListing("s", ["mcp__docs__search", "CronCreate"], at: at(1), via: "deferred", in: db)

        let report = try tools(db)
        #expect(report.summary.sessions == 2 && report.summary.sessionsWithToolList == 1)
        #expect(try tool("mcp__docs__search", in: report).availableSessions == 2, "MCP tools count in every listing")
        #expect(try tool("Read", in: report).availableSessions == 1)
        #expect(try tool("CronCreate", in: report).availableSessions == 1, "a deferred built-in counts where the full list is known")
        #expect(!report.tools.contains { $0.name == "WebFetch" }, "a session without its full list says nothing about built-in tools")
        #expect(report.notes.contains(ToolStats.noListNote))
    }

    @Test func filesStillToBeReReadGetANote() throws {
        let db = try database()
        try session("s", started: at(1), in: db)
        try toolListing("s", ["Read"], at: at(1), in: db)
        #expect(!(try tools(db)).notes.contains { $0.contains("read again") })
        for (path, version) in [("/a.jsonl", 2), ("/b.jsonl", 2), ("/c.jsonl", 3)] {
            try db.run("""
                INSERT INTO sources(path, generation, harness, kind, parser_version, state) VALUES(?, 1, 'claude', 'session', ?, 'active')
                """, path, version)
        }
        try db.run("INSERT INTO sources(path, generation, harness, kind, parser_version, state) VALUES('/gone.jsonl', 1, 'claude', 'session', 1, 'gone')")
        #expect(try tools(db).notes.contains(ToolStats.rereadNote(2)))
    }

    @Test func toolStatsFollowTheProjectScope() throws {
        let db = try database()
        for id in ["a", "b"] {
            try session(id, started: at(2), in: db)
            try toolListing(id, ["Read", "Bash"], at: at(2), in: db)
        }
        try bind("a", to: "github.com/o/r", .exact, in: db)
        try toolCall("b", "Bash", at: at(2, 13), in: db)
        let project = try tools(db, project: "github.com/o/r")
        #expect(project.summary.sessions == 1 && project.scope.project == "github.com/o/r")
        #expect(try tool("Bash", in: project).unused, "the call was in another project's session")
        #expect(try tool("Bash", in: project).lastCall == nil)
        #expect(try !tool("Bash", in: tools(db)).unused)
    }

    @Test func skillCalledBeforeItsDescriptionChangedIsNotUnused() throws {
        let db = try database()
        try session("s1", started: at(20), in: db)
        try listing("s1", "tdd", at: at(20), hash: "A", in: db)
        try session("s2", started: at(10), in: db)
        try listing("s2", "tdd", at: at(10), hash: "A", in: db)
        try call("s2", "tdd", at: at(10, 13), in: db)
        // The description changed 3 days ago: the call columns count from then on.
        try session("s3", started: at(3), in: db)
        try listing("s3", "tdd", at: at(3), hash: "B", in: db)

        let tdd = try skill("tdd", in: try report(db))
        #expect(tdd.modelCalls == 0 && tdd.windowStart == iso(at(3)), "\(tdd)")
        #expect(!tdd.unused && tdd.lastCall == iso(at(10, 13)))
        #expect(try report(db, .init(top: nil, unusedOnly: true)).skills.isEmpty)
    }

    @Test func skillsKnowTheirLastCallAndUnusedFilter() throws {
        let db = try database()
        try session("old", started: at(40), in: db)
        try listing("old", "tdd", at: at(40), hash: "A", in: db)
        try call("old", "tdd", at: at(40, 13), in: db)
        try session("s1", started: at(2), in: db)
        for name in ["tdd", "lint"] { try listing("s1", name, at: at(2), hash: name, in: db) }
        try call("s1", "lint", at: at(2, 13), by: "user", kind: "skill", in: db)
        try call("s1", "tdd", at: at(2, 14), by: "user", kind: "command", in: db)  // a built-in command is no call

        let all = try report(db)
        #expect(try skill("tdd", in: all).lastCall == iso(at(40, 13)) && skill("tdd", in: all).unused)
        #expect(try skill("lint", in: all).lastCall == iso(at(2, 13)) && !skill("lint", in: all).unused)
        let unused = try report(db, .init(top: nil, unusedOnly: true))
        #expect(unused.skills.map(\.name) == ["tdd"] && unused.omitted.skills == 0)
    }
}
