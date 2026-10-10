import Foundation
import Testing
import AKitFoundation
@testable import AKitInsights
@testable import AKitSessions

/// The tools a session had available (`tool_listings`), read from Claude Code's prompt snapshots and
/// deferred tools and from Pi's `tools` section. Same temporary fake home as the other import tests.
extension InsightsImportTests {
    static func attachment(_ uuid: String, _ time: String, _ attachment: [String: Any], sidechain: Bool = false) -> [String: Any] {
        ["type": "attachment", "uuid": uuid, "sessionId": "s1", "isSidechain": sidechain, "cwd": "/work/app",
         "timestamp": "2026-09-20T10:00:\(time).000Z", "attachment": attachment]
    }

    static func snapshot(_ uuid: String, _ time: String, tools: [String]?, sidechain: Bool = false) -> [String: Any] {
        var body: [String: Any] = ["type": "prompt_snapshot", "systemPrompt": ["You are Claude Code."]]
        if let tools { body["tools"] = tools.map { ["name": $0, "description": "About \($0)", "input_schema": [:]] } }
        return attachment(uuid, time, body, sidechain: sidechain)
    }

    func toolRows() throws -> [String] {
        try database().rows("SELECT tool, is_subagent, COALESCE(server, '-'), session_key FROM tool_listings ORDER BY is_subagent, tool")
            .map { "\($0[0].text ?? "")/\($0[1].int ?? -1)/\($0[2].text ?? "")/\($0[3].text ?? "")" }
    }

    @Test func claudeToolsFromSnapshotsAndDeferredDeltas() throws {
        try write(claudeFile, lines: [
            // The first snapshots often carry no tools; a later one has them.
            Self.snapshot("P1", "00", tools: nil),
            // Read comes deferred first; the snapshot then says the session has its full list.
            Self.attachment("D0", "00", ["type": "deferred_tools_delta", "addedNames": ["Read"], "removedNames": []]),
            Self.attachment("D1", "01", ["type": "deferred_tools_delta",
                                         "addedNames": ["mcp__docs__search", "mcp__docs__fetch", "WebFetch"],
                                         "addedLines": ["mcp__docs__search", "mcp__docs__fetch", "WebFetch"], "removedNames": []]),
            Self.snapshot("P2", "02", tools: ["Read", "Bash", "Skill"]),
            // Removed later: still available for part of the session.
            Self.attachment("D2", "03", ["type": "deferred_tools_delta", "addedNames": [], "removedNames": ["WebFetch"]]),
            // A repeated snapshot (after a compaction) keeps each tool's first time.
            Self.snapshot("P3", "09", tools: ["Read", "Bash", "Skill"]),
        ])
        try write(subagentFile, lines: [Self.snapshot("SP1", "10", tools: ["Read", "Grep"], sidechain: true)])
        try runImport()

        #expect(try toolRows() == [
            "Bash/0/-/claude:s1", "Read/0/-/claude:s1", "Skill/0/-/claude:s1", "WebFetch/0/-/claude:s1",
            "mcp__docs__fetch/0/docs/claude:s1", "mcp__docs__search/0/docs/claude:s1",
            "Grep/1/-/claude:s1", "Read/1/-/claude:s1",
        ])
        let first = try #require(JSONLines.date("2026-09-20T10:00:00.000Z")).timeIntervalSince1970
        #expect(try database().value("SELECT ts FROM tool_listings WHERE tool = 'Read' AND is_subagent = 0")?.double == first)
        let via = try database().rows("SELECT tool, via FROM tool_listings WHERE is_subagent = 0 ORDER BY tool")
            .map { "\($0[0].text ?? "")=\($0[1].text ?? "")" }
        #expect(via == ["Bash=snapshot", "Read=snapshot", "Skill=snapshot", "WebFetch=deferred",
                        "mcp__docs__fetch=deferred", "mcp__docs__search=deferred"])

        // An appended snapshot with a new tool adds it; the others keep their first time.
        try append(claudeFile, lines: [Self.snapshot("P4", "20", tools: ["Read", "Bash", "Skill", "Agent"])])
        try runImport()
        #expect(try count("SELECT COUNT(*) FROM tool_listings WHERE is_subagent = 0") == 7)
        #expect(try database().value("SELECT ts FROM tool_listings WHERE tool = 'Read' AND is_subagent = 0")?.double == first)

        // A parser bump re-reads the files: the same rows, no doubles.
        var bumped = SessionImporter(env: env)
        bumped.claudeParser = ClaudeFacts.parserVersion + 1
        try runImport(bumped)
        #expect(try count("SELECT COUNT(*) FROM tool_listings") == 9)
        #expect(try count("SELECT COUNT(*) FROM tool_listings WHERE parser_version = ?", ClaudeFacts.parserVersion + 1) == 9)
    }

    @Test func claudeSessionWithoutSnapshotHasNoToolList() throws {
        try write(claudeFile, lines: claudeSession())
        try runImport()
        #expect(try count("SELECT COUNT(*) FROM tool_listings") == 0)
        #expect(try count("SELECT COUNT(*) FROM tool_calls") > 0)
    }

    @Test func piToolsSectionListsTools() throws {
        let system = Self.piMessage("y1", nil, "00", ["role": "system", "content": "", "sections": [
            "preamble": "You are pi.",
            "tools": "<tools>\n- read: Read file contents\n- bash: Execute commands\n- mcp__docs__search: Search the docs\n</tools>",
        ]])
        try write(piFile("sa"), lines: [Self.piHeader("sa"), system] + Array(piParent().dropFirst()))
        // Pi before 1.0 recorded no system message: no tool list.
        try write(piFile("sb", started: "2026-09-21T10-00-00-000Z"), lines: [Self.piHeader("sb")] + Array(piParent().dropFirst()))
        try runImport()

        #expect(try toolRows() == ["bash/0/-/pi:sa", "mcp__docs__search/0/docs/pi:sa", "read/0/-/pi:sa"])
        #expect(try count("SELECT COUNT(*) FROM tool_listings WHERE harness = 'pi'") == 3)
        #expect(try count("SELECT COUNT(*) FROM tool_listings WHERE via = 'pi'") == 3)
        #expect(PiLogFormat.toolNames(inToolsSection: "<tools>\n- read: Read\n-: nameless\nplain text\n</tools>") == ["read"])
        // Bullets inside a description are no tools.
        #expect(PiLogFormat.toolNames(inToolsSection: "- web_fetch: Fetch a page\n- Use with care: it may be slow\n- a/b: path\n- mcp.x-y_z: ok")
                == ["web_fetch", "mcp.x-y_z"])
    }
}
