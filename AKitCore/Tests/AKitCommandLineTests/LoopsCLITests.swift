import Foundation
import Testing
import AKitFoundation
import AKitInsights
@testable import AKitCommandLine

/// `akit stats loops` and `akit loop-check` over a made-up home.
struct LoopsCLITests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-loops-\(UUID().uuidString)")
        try fm.createDirectory(at: home.appending(path: "work"), withIntermediateDirectories: true)
    }

    var env: HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home, variables: ["HOME": home.path],
                           executableSearchPaths: [URL(filePath: "/usr/bin"), URL(filePath: "/bin")])
    }

    func akit(_ arguments: String..., stdin: String = "") async -> (code: Int32, out: String, err: String) {
        var out: [String] = [], err: [String] = []
        let code = await AKitCLI.run(arguments, env: env, cwd: home.appending(path: "work"), projectsRoot: home.appending(path: "Projects"),
                                     hostName: "TestMac.local", installedTargets: ["claude"], out: { out.append($0) },
                                     err: { err.append($0) }, input: { Data(stdin.utf8) }, hardwareHash: { "test-hardware" })
        return (code, out.joined(separator: "\n"), err.joined(separator: "\n"))
    }

    func write(_ path: String, _ lines: [[String: Any]]) throws {
        let url = home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = try lines.map { String(decoding: try JSONSerialization.data(withJSONObject: $0, options: .sortedKeys), as: UTF8.self) }
        try Data((text.joined(separator: "\n") + "\n").utf8).write(to: url)
    }

    let error = "pnpm db:migrate error: relation users already exists at migrate.ts line 12"

    /// A Claude Code session: the same error three times, each answered by an edit of the same file.
    func writeClaudeLoop() throws {
        let start = Date().addingTimeInterval(-3600)
        var lines: [[String: Any]] = []
        func time(_ second: Int) -> String { start.addingTimeInterval(Double(second)).formatted(.iso8601) }
        for (turn, ask) in [error, error + " (again)", "still the same: " + error].enumerated() {
            let base = turn * 10
            lines.append(["type": "user", "cwd": home.appending(path: "work").path, "sessionId": "c1", "uuid": "u\(turn)", "timestamp": time(base),
                          "message": ["role": "user", "content": ask]])
            lines.append(["type": "assistant", "sessionId": "c1", "uuid": "a\(turn)", "timestamp": time(base + 1),
                          "message": ["id": "m\(turn)", "model": "claude-sonnet-5-5", "role": "assistant",
                                      "content": [["type": "tool_use", "id": "t\(turn)", "name": "Edit",
                                                   "input": ["file_path": "/work/0001.sql", "old_string": "a", "new_string": "b\(turn)"]]],
                                      "usage": ["input_tokens": 10, "output_tokens": 5]]])
            lines.append(["type": "user", "sessionId": "c1", "uuid": "r\(turn)", "timestamp": time(base + 2),
                          "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t\(turn)", "content": "ok"]]]])
            lines.append(["type": "assistant", "sessionId": "c1", "uuid": "b\(turn)", "timestamp": time(base + 3),
                          "message": ["id": "n\(turn)", "model": "claude-sonnet-5-5", "role": "assistant",
                                      "content": [["type": "text", "text": "Changed the CREATE TABLE statements in 0001.sql. Try again."]],
                                      "usage": ["input_tokens": 10, "output_tokens": 5]]])
        }
        try write(".claude/projects/-work/c1.jsonl", lines)
    }

    @Test func statsLoopsGroupsByModelWithAdvice() async throws {
        try writeClaudeLoop()
        let plain = await akit("stats", "loops")
        #expect(plain.code == 0, "\(plain)")
        #expect(plain.out.contains("1 of 1 scanned sessions"), "\(plain.out)")
        #expect(plain.out.contains("claude-sonnet-5-5 · thinking not recorded: 1 loop in 1 session, up to 3 asks"), "\(plain.out)")
        #expect(plain.out.contains("Claude Code: /effort high or /model"), "\(plain.out)")
        #expect(plain.out.contains("claude:c1  steps 0–"), "\(plain.out)")

        let json = await akit("stats", "loops", "--json")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.out.utf8)) as? [String: Any], "\(json)")
        #expect(object["version"] as? Int == 1 && object["sessionsWithLoops"] as? Int == 1)
        let loop = try #require((object["loops"] as? [[String: Any]])?.first)
        #expect(loop["asks"] as? Int == 3 && loop["model"] as? String == "claude-sonnet-5-5" && loop["sessionKey"] as? String == "claude:c1")
        #expect(await akit("stats", "loops", "--unused").code == 2)
    }

    @Test func statsLoopsSaysWhenThereAreNone() async throws {
        try write(".claude/projects/-work/c2.jsonl", [
            ["type": "user", "cwd": home.appending(path: "work").path, "sessionId": "c2", "uuid": "u0",
             "timestamp": Date().addingTimeInterval(-60).formatted(.iso8601), "message": ["role": "user", "content": "Add a button"]],
        ])
        let plain = await akit("stats", "loops")
        #expect(plain.code == 0 && plain.out.contains("No session where the same ask got almost the same answer 3 times in a row."), "\(plain)")
    }

    @Test func loopCheckReadsAPiLog() async throws {
        var lines: [[String: Any]] = [
            ["type": "session", "version": 3, "id": "p1", "timestamp": "2026-10-28T10:00:00Z", "cwd": "/work"],
            ["type": "model_change", "id": "e1", "timestamp": "2026-10-28T10:00:00Z", "provider": "openrouter", "modelId": "qwen"],
            ["type": "thinking_level_change", "id": "e2", "timestamp": "2026-10-28T10:00:00Z", "thinkingLevel": "low"],
        ]
        for turn in 0..<3 {
            lines.append(["type": "message", "id": "u\(turn)", "timestamp": "2026-10-28T10:0\(turn):00Z",
                          "message": ["role": "user", "content": [["type": "text", "text": turn == 2 ? "still " + error : error]]]])
            lines.append(["type": "message", "id": "a\(turn)", "timestamp": "2026-10-28T10:0\(turn):01Z",
                          "message": ["role": "assistant", "content": [
                            ["type": "toolCall", "id": "t\(turn)", "name": "edit", "arguments": ["path": "/work/0001.sql", "oldText": "a", "newText": "b"]],
                            ["type": "text", "text": "Changed the CREATE TABLE statements. Try again."]]]])
        }
        // Pi follows parentId links from the last entry: each entry's parent is the one before it.
        for index in lines.indices.dropFirst(1) { lines[index]["parentId"] = lines[index - 1]["id"] }
        try write("pi.jsonl", lines)
        let input = #"{"transcript_path":"\#(home.appending(path: "pi.jsonl").path)"}"#
        let check = await akit("loop-check", "--harness", "pi", stdin: input)
        #expect(check.code == 0, "\(check)")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(check.out.utf8)) as? [String: Any], "\(check)")
        let loop = try #require(object["loop"] as? [String: Any], "\(check.out)")
        #expect(loop["asks"] as? Int == 3 && loop["model"] as? String == "openrouter/qwen" && loop["thinking"] as? String == "low")
        #expect((loop["advice"] as? String)?.contains("Pi: ⌥T or Shift+Tab") == true)

        #expect(await akit("loop-check", "--harness", "claude", stdin: input).code == 1)
        #expect(await akit("loop-check", "--harness", "pi", stdin: "{}").err.contains("transcript_path"))
    }
}
