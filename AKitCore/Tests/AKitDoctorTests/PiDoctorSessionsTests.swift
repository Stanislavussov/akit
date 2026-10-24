import Foundation
import Testing
import AKitFoundation
@testable import AKitDoctor

/// Pi doctor's "Context from recent sessions": made-up Pi session files in a temporary fake home,
/// imported into that home's own index; `pi` is a fake runner.
struct PiDoctorSessionsTests {
    let home: URL
    let fm = FileManager.default
    /// A fixed "now": the sessions below fall in its last 30 days.
    let now = ISO8601DateFormatter().date(from: "2026-09-25T12:00:00Z")!

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-pidoctor-sessions-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var env: HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home, variables: ["HOME": home.path], executableSearchPaths: [home.appending(path: "bin")])
    }

    var project: URL { home.appending(path: "Projects/app") }

    func write(_ path: String, _ text: String) throws {
        let url = home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func json(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    /// `count` Pi sessions in the project, one a day from 2026-09-01; each lists the notes MCP
    /// server's tool and makes one request; the first reads pdf-tools' SKILL.md.
    func writeSessions(_ count: Int) throws {
        for day in 1...count {
            let date = String(format: "2026-09-%02d", day)
            let id = String(format: "s%02d", day)
            func message(_ entry: String, _ second: String, _ body: [String: Any]) -> [String: Any] {
                ["type": "message", "id": "\(id)\(entry)", "parentId": NSNull(), "timestamp": "\(date)T10:00:\(second).000Z", "message": body]
            }
            var content: [[String: Any]] = [["type": "text", "text": "Done"]]
            if day == 1 {
                content.append(["type": "toolCall", "id": "c1", "name": "read",
                                "arguments": ["path": home.appending(path: ".pi/agent/skills/pdf-tools/SKILL.md").path]])
                content.append(["type": "toolCall", "id": "c2", "name": "mcp__web__fetch", "arguments": ["url": "https://example.com"]])
            }
            let lines: [[String: Any]] = [
                ["type": "session", "version": 3, "id": id, "timestamp": "\(date)T10:00:00.000Z", "cwd": project.path],
                message("a", "01", ["role": "system", "content": "", "sections": [
                    "tools": "<tools>\n- read: Read file contents\n- mcp__notes__search: Search the notes\n- mcp__web__fetch: Fetch a page\n</tools>"]]),
                message("b", "02", ["role": "user", "content": [["type": "text", "text": "Go"]]]),
                message("c", "03", ["role": "assistant", "provider": "anthropic", "model": "claude", "content": content,
                                    "usage": ["input": 100, "output": 5, "cacheRead": 0, "cacheWrite": 0, "totalTokens": 105,
                                              "cost": ["total": 0.1]]]),
            ]
            try write(".pi/agent/sessions/--app--/\(date)T10-00-00-000Z_\(id).jsonl",
                      try lines.map(json).joined(separator: "\n") + "\n")
        }
    }

    func setUp() throws {
        try write("bin/pi", "#!/bin/sh\n")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.appending(path: "bin/pi").path)
        try write("bin/notes-mcp", "#!/bin/sh\n")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.appending(path: "bin/notes-mcp").path)
        try write(".pi/agent/settings.json", "{}")
        try write(".pi/agent/mcp.json", #"{"mcpServers": {"notes": {"command": "notes-mcp"}, "web": {"command": "notes-mcp", "exposure": "direct"}}}"#)
        try write(".pi/agent/skills/pdf-tools/SKILL.md", "---\nname: pdf-tools\ndescription: Read PDFs.\n---\nBody")
        try write(".pi/agent/skills/slides/SKILL.md", "---\nname: slides\ndescription: Make slide decks from notes.\n---\nBody")
        try write(".pi/agent/AGENTS.md", "# Rules\n\n## Style\nShort sentences.\n")
        try write("Projects/app/AGENTS.md", "# App\n\n## Style\nShort sentences.\n\n## Build\nmake build\n")
    }

    func check() async -> PiDoctor.Report {
        await PiDoctor.check(env: env, projects: [], runner: { _, _, _, _ in .init(status: 0, output: "1.0.4") }, now: now)
    }

    func section(_ report: PiDoctor.Report) -> [PiDoctor.Line] {
        report.sections.first { $0.title == "Context from recent sessions" }?.lines ?? []
    }

    @Test func noSessionsIsOneLine() async throws {
        try setUp()
        let lines = section(await check())
        #expect(lines.map(\.text) == ["no Pi sessions in the last 30 days: nothing to judge the context by"])
    }

    @Test func enoughSessionsSuggestTheUncalledSkillAndServerAndTheRepeatedSection() async throws {
        try setUp()
        try writeSessions(20)
        let report = await check()
        let lines = section(report)
        #expect(lines.first?.text == "20 Pi sessions on 20 days in the last 30 days, 20 requests", "\(report.text)")
        let suggestions = lines.filter { $0.level == .suggestion }
        #expect(suggestions.map(\.command) == [
            "akit skills set slides --harness pi --state off",
            "akit mcp set notes --harness pi --off everywhere",
            "akit mcp set web --harness pi --exposure deferred",
            "akit instructions remove ~/Projects/app/AGENTS.md --line 3",
        ], "\(report.text)")
        #expect(suggestions.map(\.screen) == ["skills", "mcp", "mcp", "instructions"])
        #expect(suggestions[2].text == "MCP server web is direct: its 1 tool is declared in every request, but Pi called one 1 time in 20 sessions")
        #expect(suggestions[3].text.hasPrefix("## Style is in ~/.pi/agent/AGENTS.md:3 and ~/Projects/app/AGENTS.md:3: the model gets it twice"))
        // Suggestions are not problems.
        #expect(report.problems == 0 && report.suggestions == 4)
        #expect(report.text.contains("$ akit skills set slides --harness pi --state off"))
    }

    @Test func fewSessionsOnlySayHowManySkillsWaitForTheBar() async throws {
        try setUp()
        try writeSessions(3)
        let lines = section(await check())
        #expect(lines.contains { $0.text.hasPrefix("1 global skill not called yet; AKit suggests turning skills off after 20 Pi sessions on 14 days") })
        // The repeated section doesn't need a bar: it is in every request.
        #expect(lines.filter { $0.level == .suggestion }.map(\.screen) == ["instructions"])
    }
}
