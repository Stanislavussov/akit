import Foundation
import Testing
import AKitFoundation
import AKitModel
@testable import AKitSessions

/// The context footprint of a Claude Code session file in a temporary folder.
struct ContextFootprintTests {
    let folder: URL
    let fm = FileManager.default

    init() throws {
        folder = fm.temporaryDirectory.appending(path: "akit-footprint-\(UUID().uuidString)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func footprint(_ lines: [[String: Any]]) throws -> ContextFootprint? {
        let file = folder.appending(path: "s.jsonl")
        let text = try lines.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
            .joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: file)
        return try ClaudeSessions.footprint(of: file)
    }

    func attachment(_ fields: [String: Any]) -> [String: Any] { ["type": "attachment", "attachment": fields] }

    func call(_ id: String, context: Int, tools: [(String, [String: Any])] = [], sidechain: Bool = false) -> [String: Any] {
        let blocks: [[String: Any]] = tools.enumerated().map { index, tool in
            ["type": "tool_use", "id": "\(id)-\(index)", "name": tool.0, "input": tool.1]
        }
        return ["type": "assistant", "isSidechain": sidechain,
                "message": ["id": id, "model": "claude-x", "content": blocks,
                            "usage": ["input_tokens": 0, "cache_read_input_tokens": context, "cache_creation_input_tokens": 0,
                                      "output_tokens": 10]]]
    }

    let x400 = String(repeating: "x", count: 400)  // ≈ 100 tokens

    var session: [[String: Any]] {
        [
            attachment(["type": "prompt_snapshot", "systemPrompt": ["# Harness\n" + x400, "Tone\n" + x400],
                        "tools": [["name": "Read", "description": x400, "input_schema": [:]],
                                  ["name": "Workflow", "description": x400 + x400, "input_schema": [:]],
                                  ["name": "mcp__docs__search", "description": x400, "input_schema": [:]]]]),
            attachment(["type": "instructions", "files": [["path": "/work/CLAUDE.md", "type": "Project", "content": x400]]]),
            attachment(["type": "skill_listing", "names": ["tdd", "omc:ralph"],
                        "content": "- tdd: " + x400 + "\n- omc:ralph: " + x400 + x400]),
            attachment(["type": "agent_listing_delta", "addedTypes": ["Explore", "planner"],
                        "addedLines": ["- Explore: " + x400, "- planner: " + x400]]),
            attachment(["type": "mcp_instructions_delta", "addedNames": ["claude", "claude-in-chrome"],
                        "addedBlocks": ["## claude-in-chrome\n" + x400]]),
            attachment(["type": "deferred_tools_delta", "addedNames": ["mcp__claude-in-chrome__navigate", "CronCreate"],
                        "addedLines": ["mcp__claude-in-chrome__navigate", "CronCreate"]]),
            attachment(["type": "hook_additional_context", "hookName": "SessionStart", "content": [x400]]),
            ["type": "user", "message": ["content": "<command-message>tdd</command-message>\n<command-name>/tdd</command-name>"]],
            call("m1", context: 5000, tools: [("Read", [:]), ("mcp__docs__search", [:]), ("Skill", ["skill": "ralph"])]),
            // A later snapshot (after a compaction) is not the first call's.
            attachment(["type": "prompt_snapshot", "systemPrompt": ["Short"]]),
            call("m1", context: 5000),
            // Attachments after the first answer are conversation, not setup.
            attachment(["type": "hook_additional_context", "hookName": "Later", "content": [x400 + x400 + x400]]),
            call("m2", context: 7000, tools: [("Agent", ["subagent_type": "Explore"]), ("Read", [:])]),
            call("side", context: 90000, tools: [("Workflow", [:])], sidechain: true),
            call("m3", context: 8000),
        ]
    }

    @Test func partsKnowTheirSizeAndWhetherTheSessionUsedThem() throws {
        let footprint = try #require(try footprint(session))
        func part(_ group: ContextFootprint.Group, _ name: String) -> ContextFootprint.Part? {
            footprint.parts.first { $0.group == group && $0.name == name }
        }
        // Three main calls, one per response id; the side chain's call isn't the session's.
        #expect(footprint.callContexts == [5000, 7000, 8000])
        #expect(part(.tools, "Read")?.use == .used && part(.tools, "Read")?.calls == 2)
        #expect(part(.tools, "Workflow")?.use == .unused, "only a side chain called it")
        #expect((200...205).contains(part(.tools, "Workflow")?.tokens ?? 0), "name, description and schema")
        #expect(part(.tools, "CronCreate")?.use == .unused)
        #expect(part(.skills, "omc:ralph")?.use == .used, "the model's ralph is the plugin's ralph")
        #expect(part(.skills, "omc:ralph")?.source == "plugin omc")
        // Only the user ran it: the model never needed its description.
        #expect(part(.skills, "tdd")?.use == .unused && part(.skills, "tdd")?.detail?.hasPrefix("Only you ran it") == true)
        #expect(part(.systemPrompt, "Short") == nil && part(.systemPrompt, "Tone")?.text?.hasPrefix("Tone") == true)
        #expect(part(.tools, "Workflow")?.source == "Built into Claude Code" && part(.tools, "Workflow")?.text?.hasPrefix("xxx") == true)
        #expect(part(.subagents, "Explore")?.use == .used && part(.subagents, "planner")?.use == .unused)
        #expect(part(.rules, "CLAUDE.md · Project")?.use == .always && part(.rules, "CLAUDE.md · Project")?.source == "/work/CLAUDE.md")
        #expect(part(.hooks, "SessionStart")?.use == .always)
        #expect(part(.hooks, "Later") == nil)
        #expect(part(.systemPrompt, "Harness")?.use == .always)
        // MCP tools add up per server; instructions name it.
        #expect(part(.mcp, "docs")?.use == .used && part(.mcp, "docs")?.calls == 1)
        let chrome = try #require(part(.mcp, "claude-in-chrome"))
        #expect(chrome.use == .unused && chrome.detail?.hasPrefix("1 tool and instructions") == true)
        #expect(part(.mcp, "claude") == nil, "the longest matching name gets the instructions")
    }

    @Test func sharesAreOfTheFirstCallAndOfTheWholeSession() throws {
        let footprint = try #require(try footprint(session))
        // The parts and the rest add up to the first call's recorded context.
        #expect(footprint.parts.reduce(0) { $0 + $1.tokens } == 5000)
        #expect(footprint.parts.first { $0.use == .conversation }?.tokens == 5000 - footprint.setupTokens)
        let unused = footprint.tokens(.unused)
        #expect(unused > 0)
        #expect(abs(footprint.shareOfFirstCall(unused) - Double(unused) / 5000) < 0.0001)
        // Sent with each of the 3 calls, out of 20,000 sent.
        #expect(abs(footprint.shareOfSession(unused) - Double(unused * 3) / 20000) < 0.0001)
        let calls = footprint.calls
        #expect(calls.map(\.context) == [5000, 7000, 8000])
        #expect(calls.allSatisfy { $0.unused == unused && $0.unused + $0.used + $0.always + $0.conversation == $0.context })
        #expect(calls[2].unusedShare < calls[0].unusedShare, "the same setup is a smaller part of a bigger call")
    }

    @Test func estimatesBiggerThanTheFirstCallAreScaledDown() throws {
        var lines = session
        lines[8] = call("m1", context: 500, tools: [("Read", [:])])
        let footprint = try #require(try footprint(lines))
        #expect(footprint.parts.allSatisfy { $0.use != .conversation })
        let total = footprint.parts.reduce(0) { $0 + $1.tokens }
        #expect(total <= 500 && total > 450)
    }

    @Test func noSnapshotMeansNoFootprint() throws {
        #expect(try footprint([call("m1", context: 100)]) == nil)
    }

    @Test func tokenEstimateCountsCyrillicDenser() {
        #expect(TokenEstimate.tokens(String(repeating: "a", count: 400)) == 100)
        #expect(TokenEstimate.tokens(String(repeating: "ж", count: 400)) == 160)
        #expect(TokenEstimate.tokens("") == 0)
    }

    func result(_ id: String, _ text: String, error: Bool = true) -> [String: Any] {
        ["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": id, "content": text, "is_error": error]]]]
    }

    @Test func toolCallsEndInKnownOutcomes() throws {
        let file = folder.appending(path: "t.jsonl")
        // A secret file's output never becomes an example.
        let secret = call("c", context: 300, tools: [("Bash", ["command": "grep KEY .env; false"])])
        let lines: [[String: Any]] = [
            call("a", context: 100, tools: [("Bash", [:]), ("Bash", [:]), ("Edit", [:]), ("Read", [:])]),
            result("a-0", "ok", error: false),
            result("a-1", "Exit code 1\nerror: build failed\nTimeout: 5000ms, no such file"),
            result("a-2", "<tool_use_error>String to replace not found in file.</tool_use_error>"),
            result("a-3", "The user doesn't want to proceed with this tool use."),
            // Claude Code writes a stopped call as a rejection followed by this line.
            ["type": "user", "message": ["content": [["type": "text", "text": "[Request interrupted by user for tool use]"]]]],
            call("b", context: 200, tools: [("WebFetch", [:]), ("mcp__docs__search", [:]), ("Read", [:])]),
            result("b-0", "Request timed out after 30s"),
            result("b-1", "The user doesn't want to proceed with this tool use. The tool use was rejected."),
            // b-2 never got a result.
            secret,
            result("c-0", "Exit code 1\nKEY=abc"),
        ]
        let text = try lines.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n")
        try Data(text.utf8).write(to: file)
        let tools = try ClaudeSessions.overview(of: file).tools
        func tool(_ name: String) -> ToolOutcomes.Tool? { tools.tools.first { $0.name == name } }
        #expect(tools.calls == 8 && tools.tools.first?.name == "Bash", "most calls first, then by name")
        #expect(tool("Bash")?.count(.ok) == 1 && tool("Bash")?.count(.commandFailed) == 2, "whatever the output mentions")
        #expect(tool("Bash")?.examples[.commandFailed] == "Exit code 1: error: build failed")
        #expect(tool("Edit")?.count(.inputMistake) == 1)
        #expect(tool("Read")?.count(.interrupted) == 1 && tool("Read")?.count(.noResult) == 1)
        #expect(tool("WebFetch")?.count(.transient) == 1)
        #expect(tool("mcp__docs__search")?.count(.rejected) == 1 && tool("mcp__docs__search")?.displayName == "docs: search")
        #expect(tools.failed == 4 && tools.deterministicFailures == 3)
        #expect(abs(tools.share(tools.failed) - 4.0 / 8) < 0.0001)
        #expect(tool("Bash")?.count(.commandFailed) == 2 && tool("Bash")?.examples[.commandFailed]?.contains("KEY") == false)
    }
}
