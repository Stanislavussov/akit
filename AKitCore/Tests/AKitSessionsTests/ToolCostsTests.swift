import Foundation
import Testing
import AKitModel
@testable import AKitSessions

struct ToolCostsTests {
    private func line(_ message: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["type": "message_end", "message": message])
        return String(decoding: data, as: UTF8.self)
    }

    private func assistant(context: Int, output: Int, cost: Double, calls: [(String, String, [String: Any])]) -> String {
        line(["role": "assistant", "model": "m", "provider": "p",
              "usage": ["input": context, "output": output, "cacheRead": 0, "cacheWrite": 0, "cost": ["total": cost]],
              "content": calls.map { ["type": "toolCall", "id": $0.0, "name": $0.1, "arguments": $0.2] }])
    }

    private func result(_ id: String, _ name: String, _ text: String) -> String {
        line(["role": "toolResult", "toolCallId": id, "toolName": name, "content": [["type": "text", "text": text]]])
    }

    @Test func resultsShareTheGrowthAndPayForLaterRequests() {
        let lines = [
            assistant(context: 1000, output: 100, cost: 0.1,
                      calls: [("a", "mcp__figma__get_design", [:]), ("b", "bash", ["command": "cd x && agent-browser open url"])]),
            result("a", "mcp__figma__get_design", String(repeating: "x", count: 300)),
            result("b", "bash", String(repeating: "y", count: 100)),
            assistant(context: 1900, output: 50, cost: 0.19, calls: []),
            assistant(context: 2000, output: 50, cost: 0.2, calls: []),
        ]
        let costs = PiSessions.transcript(ofStream: lines).usage.toolCosts
        let figma = try! #require(costs.tools.first { $0.name == "mcp__figma__get_design" })
        let browser = try! #require(costs.tools.first { $0.name == "bash: agent-browser" })
        // Growth 1900 − 1000 − 100 = 800, split 3:1 by result length.
        #expect(figma.added == 600 && browser.added == 200)
        // Read again by the third request.
        #expect(figma.reread == 600 && browser.reread == 200)
        // 600/1900 × 0.19 + 600/2000 × 0.2
        #expect(abs((figma.cost ?? 0) - 0.12) < 0.0001)
        #expect(costs.servers.map(\.name) == ["figma"])
        #expect(costs.tools.first?.name == "mcp__figma__get_design")
    }

    @Test func compactionEndsTheRereads() {
        var trace = ToolTrace()
        trace.response(key: "1", tokens: TokenCounts(input: 100, output: 10), cost: nil)
        trace.call(id: "a", tool: "Read")
        trace.result(id: "a", length: 10)
        trace.response(key: "2", tokens: TokenCounts(input: 300, output: 10), cost: nil)
        trace.response(key: "2", tokens: TokenCounts(input: 300, output: 20), cost: nil) // same response, later line
        trace.response(key: "3", tokens: TokenCounts(input: 350, output: 10), cost: nil)
        trace.compaction()
        trace.response(key: "4", tokens: TokenCounts(input: 50, output: 10), cost: nil)
        let read = try! #require(trace.costs.tools.first)
        #expect(read.added == 190 && read.reread == 190 && read.cost == nil && read.calls == 1)
    }

    @Test func shellProgramSkipsCdEnvAndLaunchers() {
        #expect(ToolCosts.program(of: "cd /tmp && FOO=1 npx agent-browser snapshot") == "agent-browser")
        #expect(ToolCosts.program(of: "/usr/bin/git status") == "git")
        #expect(ToolCosts.key(tool: "Read", input: ["file_path": "x"]) == "Read")
    }
}
