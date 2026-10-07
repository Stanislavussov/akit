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
        // Over the whole session: the size once per call.
        #expect(footprint.sessionTokens(unused) == unused * 3)
        let rest = try #require(footprint.parts.first { $0.use == .conversation })
        #expect(footprint.sessionTokens(of: rest) == 20000 - footprint.setupTokens * 3)
        #expect(footprint.parts.reduce(0) { $0 + footprint.sessionTokens(of: $1) } <= 20000 + footprint.parts.count)
    }

    @Test func estimatesBiggerThanTheFirstCallAreScaledDown() throws {
        var lines = session
        lines[8] = call("m1", context: 500, tools: [("Read", [:])])
        let footprint = try #require(try footprint(lines))
        #expect(footprint.parts.allSatisfy { $0.use != .conversation })
        let total = footprint.parts.reduce(0) { $0 + $1.tokens }
        #expect(total <= 500 && total > 450)
        // A call smaller than the setup holds only part of it.
        let weight = 500.0 / Double(footprint.setupTokens) + 2
        #expect(abs(footprint.callWeight - min(3, weight)) < 0.01)
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
            call("b", context: 200, tools: [("WebFetch", [:]), ("mcp__docs__search", [:]), ("Read", [:]),
                                            ("Bash", ["command": "rm -rf build"])]),
            result("b-0", "Request timed out after 30s"),
            result("b-1", "The user doesn't want to proceed with this tool use. The tool use was rejected."),
            // b-2 never got a result. The auto mode classifier timing out: the command never ran.
            result("b-3", "claude-sonnet-5 is temporarily unavailable (timed out), so auto mode cannot determine the safety of Bash"),
            secret,
            result("c-0", "Exit code 1\nKEY=abc"),
            // Two parallel calls stopped together: each result has its own entry, then one interrupt line.
            call("d", context: 400, tools: [("Read", ["file_path": "/w/.env"]), ("Grep", [:])]),
            result("d-0", "The user doesn't want to proceed with this tool use. The tool use was rejected."),
            result("d-1", "The user doesn't want to proceed with this tool use. The tool use was rejected."),
            ["type": "user", "message": ["content": [["type": "text", "text": "[Request interrupted by user for tool use]"]]]],
        ]
        let text = try lines.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n")
        try Data(text.utf8).write(to: file)
        let tools = try ClaudeSessions.overview(of: file).tools
        func tool(_ name: String) -> ToolOutcomes.Tool? { tools.tools.first { $0.name == name } }
        #expect(tools.calls == 11 && tools.tools.first?.name == "Bash", "most calls first, then by name")
        #expect(tool("Bash")?.count(.transient) == 1)
        // Both stopped calls, the secret file's read too (classified from its real text).
        #expect(tool("Read")?.count(.interrupted) == 2 && tool("Grep")?.count(.interrupted) == 1)
        #expect(tool("Read")?.count(.rejected) == 0)
        #expect(tool("Bash")?.count(.ok) == 1 && tool("Bash")?.count(.commandFailed) == 2, "whatever the output mentions")
        #expect(tool("Bash")?.examples[.commandFailed] == "Exit code 1: error: build failed")
        #expect(tool("Edit")?.count(.inputMistake) == 1)
        #expect(tool("Read")?.count(.noResult) == 1)
        #expect(tool("WebFetch")?.count(.transient) == 1)
        #expect(tool("mcp__docs__search")?.count(.rejected) == 1 && tool("mcp__docs__search")?.displayName == "docs: search")
        #expect(tools.failed == 5 && tools.deterministicFailures == 3)
        #expect(abs(tools.share(tools.failed) - 5.0 / 11) < 0.0001)
        #expect(tool("Bash")?.count(.commandFailed) == 2 && tool("Bash")?.examples[.commandFailed]?.contains("KEY") == false)
    }

    // MARK: Pi

    @Test func piSessionsSplitTheirRecordedSystemPrompt() throws {
        let skill = folder.appending(path: "skills/demo/SKILL.md").path
        let agents = folder.appending(path: "work/AGENTS.md").path
        let x400 = self.x400
        func message(_ fields: [String: Any]) -> [String: Any] { ["type": "message", "id": UUID().uuidString, "message": fields] }
        func assistant(_ id: String, context: Int, calls: [(String, String, [String: Any])] = []) -> [String: Any] {
            message(["role": "assistant", "model": "glm", "responseId": id,
                     "usage": ["input": context - 100, "cacheRead": 100, "cacheWrite": 0, "output": 5],
                     "content": calls.map { ["type": "toolCall", "id": $0.0, "name": $0.1, "arguments": $0.2] }])
        }
        func result(_ id: String, _ name: String, _ text: String, error: Bool) -> [String: Any] {
            message(["role": "toolResult", "toolCallId": id, "toolName": name, "isError": error,
                     "content": [["type": "text", "text": text]]])
        }
        let lines: [[String: Any]] = [
            ["type": "session", "version": "3", "id": "s", "cwd": folder.appending(path: "work").path],
            message(["role": "system", "content": "", "sections": [
                "preamble": "You are an expert coding assistant operating inside pi." + x400,
                "tools": "<tools>\n- read: Read file contents\n- bash: Execute bash commands\n- web_fetch: Fetch a page\n"
                    + "- mcp__docs__search: Search the docs\n</tools>",
                "project_context": "<project_context>\nProject-specific instructions and guidelines:\n\n"
                    + "<project_instructions path=\"\(agents)\">\n# Rules\n\(x400)\n</project_instructions>\n</project_context>",
                "skills": "<skills>\nUse the read tool to load a skill's file.\n<available_skills>\n"
                    + "  <skill>\n    <name>demo</name>\n    <description>\(x400)</description>\n    <location>\(skill)</location>\n  </skill>\n"
                    + "  <skill>\n    <name>idle</name>\n    <description>\(x400)</description>\n    <location>/x/idle/SKILL.md</location>\n  </skill>\n"
                    + "</available_skills>\n</skills>",
            ]]),
            message(["role": "user", "content": [["type": "text", "text": "fix it"]]]),
            assistant("r1", context: 3000, calls: [("c1", "read", ["path": skill]), ("c2", "bash", ["command": "make"])]),
            result("c1", "read", "skill text", error: false),
            result("c2", "bash", "Timeout: 5s\nmake: *** [all] Error 2\n\nCommand exited with code 2", error: true),
            assistant("r2", context: 4000, calls: [("c3", "edit", ["path": "a.swift"]), ("c4", "bash", ["command": "sleep 99"])]),
            result("c3", "edit", "Could not find the exact text in a.swift", error: true),
            result("c4", "bash", "sleeping\n\nCommand aborted", error: true),
        ]
        let file = folder.appending(path: "pi.jsonl")
        let text = try lines.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n")
        try Data(text.utf8).write(to: file)
        let overview = try PiSessions.overview(of: file)
        let footprint = try #require(overview.footprint)
        func part(_ group: ContextFootprint.Group, _ name: String) -> ContextFootprint.Part? {
            footprint.parts.first { $0.group == group && $0.name == name }
        }
        #expect(footprint.harness == .pi && footprint.callContexts == [3000, 4000])
        // Reading a listed SKILL.md is using the skill; its path is where to edit it.
        #expect(part(.skills, "demo")?.use == .used && part(.skills, "demo")?.source == skill)
        #expect(part(.skills, "idle")?.use == .unused)
        #expect(part(.rules, "AGENTS.md")?.source == agents && part(.rules, "AGENTS.md")?.use == .always)
        #expect(part(.tools, "read")?.use == .used && part(.tools, "web_fetch")?.use == .unused)
        #expect(part(.tools, "read")?.source == "Built into Pi" && part(.tools, "web_fetch")?.source == "An extension")
        #expect(part(.mcp, "docs")?.use == .unused)
        #expect(part(.systemPrompt, "Preamble")?.use == .always)
        #expect(footprint.parts.first { $0.use == .conversation }?.detail?.contains("tool schemas") == true)
        // Pi's error texts.
        let tools = overview.tools
        #expect(tools.tools.first { $0.name == "bash" }?.count(.commandFailed) == 1, "a failed command, whatever it printed")
        #expect(tools.tools.first { $0.name == "bash" }?.count(.interrupted) == 1)
        #expect(tools.tools.first { $0.name == "edit" }?.count(.inputMistake) == 1)
    }

    @Test func piSessionsWithoutASystemMessageHaveOnlyToolCalls() throws {
        let file = folder.appending(path: "old.jsonl")
        try Data(#"{"type":"session","version":"3","id":"s","cwd":"/w"}"#.utf8).write(to: file)
        let overview = try PiSessions.overview(of: file)
        #expect(overview.footprint == nil && overview.tools.calls == 0)
    }
}
