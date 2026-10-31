import Foundation
import Testing
import AKitFoundation
@testable import AKitLab

/// The Log… of Ask Pi answers (K34): Pi's json stream read into steps, the call record, the
/// thinking level per model.
struct KnowledgeAskLogTests {
    static let stream = [
        #"{"type":"session","id":"s1"}"#,
        #"{"type":"message_end","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Search the base first."},{"type":"toolCall","name":"bash"}]}}"#,
        #"{"type":"tool_execution_start","toolName":"bash","toolCallId":"c1","args":{"command":"akit kb search orders"}}"#,
        #"{"type":"tool_execution_start","toolName":"mcp__gitlab__get_issue","toolCallId":"c2","args":{"id":42}}"#,
        #"{"type":"tool_execution_end","toolName":"mcp__gitlab__get_issue","toolCallId":"c2","isError":true,"result":{"content":[{"type":"text","text":"not found"}]}}"#,
        #"{"type":"tool_execution_end","toolName":"bash","toolCallId":"c1","result":{"content":[{"type":"text","text":"payments/orders-api token=ghp_abcdefghijklmnopqrstuvwxyz0123456789"}]}}"#,
        #"{"type":"tool_execution_start","toolName":"read","args":{"path":"areas/payments/billing.md"}}"#,
        ##"{"type":"tool_execution_end","toolName":"read","result":"# billing"}"##,
        #"{"type":"tool_execution_start","toolName":"bash","args":{"command":"sleep 100"}}"#,
        #"{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"Billing reads it."}]}}"#,
        #"{"type":"message_end","message":{"role":"assistant","stopReason":"error","errorMessage":"rate limited"}}"#,
    ]

    @Test func theStreamBecomesStepsInOrderWithResultsAndTimes() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let times = KnowledgeAskLog.ToolTimes(starts: [t0, t0.addingTimeInterval(1), t0.addingTimeInterval(5), t0.addingTimeInterval(9)],
                                              ends: [t0.addingTimeInterval(2), t0.addingTimeInterval(4), t0.addingTimeInterval(6)])
        let steps = KnowledgeAskLog.steps(Self.stream, times: times)
        #expect(steps.map(\.kind) == [.thinking, .tool, .tool, .tool, .tool, .text, .error])
        #expect(steps[0].detail == "Search the base first.")
        // c1 ended after c2: matched by call id, not order.
        #expect(steps[1].tool == "bash" && steps[1].summary == "akit kb search orders" && steps[1].duration == 4)
        #expect(steps[1].result?.contains("payments/orders-api") == true && steps[1].result?.contains("ghp_") == false, "results are masked")
        #expect(steps[2].tool == "mcp__gitlab__get_issue" && steps[2].isError && steps[2].result == "not found" && steps[2].duration == 1)
        #expect(steps[2].summary == #"{"id":42}"# && steps[2].detail.contains("\"id\" : 42"))
        // No call ids: matched by tool name.
        #expect(steps[3].summary == "areas/payments/billing.md" && steps[3].result == "# billing" && steps[3].duration == 1)
        #expect(steps[4].result == nil && steps[4].ended == nil, "a call that never ended (stopped)")
        #expect(steps[5].detail == "Billing reads it." && steps[6].detail == "rate limited")
    }

    @Test func thinkingIsRememberedPerModel() {
        let levels = LabHarness.pi.efforts
        let remembered = ["opencode-go/gpt-6-luna": "high", "zai/glm-5": "turbo"]
        #expect(KnowledgeAskLog.thinking(for: "opencode-go/gpt-6-luna", remembered: remembered, fallback: "low", levels: levels) == "high")
        #expect(KnowledgeAskLog.thinking(for: "anthropic/new", remembered: remembered, fallback: "low", levels: levels) == "low", "never used: Lab's default")
        #expect(KnowledgeAskLog.thinking(for: "zai/glm-5", remembered: remembered, fallback: "low", levels: levels) == "low", "a level Pi doesn't offer")
        #expect(KnowledgeAskLog.thinking(for: "x", remembered: [:], fallback: "", levels: levels) == "medium")
    }

    @Test func theFullLogNamesTheCallAndEachStep() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "akit-ask-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = HarnessEnvironment(homeDirectory: home, variables: ["HOME": home.path], executableSearchPaths: [])
        let note = KnowledgeAsk.Note(base: "work", baseRoot: "/tmp/kb", id: "payments/orders-api", path: "areas/payments/orders-api.md", title: "orders-api")
        let chat = try KnowledgeAsk.newChat(note: note, cwd: home, env: env)
        try FileManager.default.createDirectory(at: chat.folder.appending(path: "streams"), withIntermediateDirectories: true)
        try Self.stream.joined(separator: "\n").write(to: chat.folder.appending(path: "streams/q1.jsonl"), atomically: true, encoding: .utf8)
        var entry = KnowledgeAsk.Entry(id: "q1", question: "Who reads it?", asked: .now, answer: "Billing reads it.", session: "s1")
        entry.model = "opencode-go/gpt-6-luna"
        try KnowledgeAsk.append(entry, to: chat)

        // A chat from before K34: no call file, the stream still shows.
        let old = KnowledgeAskLog.load(entry, in: chat)
        #expect(old.call == nil && old.steps.count == 7)
        #expect(KnowledgeAskLog.fullLog(chat).contains("No call record"))

        let call = KnowledgeAskLog.Call(pi: "/bin/pi", arguments: ["-p", "--thinking", "high", "--", "The prompt"], cwd: home.path,
                                        model: "opencode-go/gpt-6-luna", thinking: "high", fork: nil, session: "/s/x_s1.jsonl",
                                        started: Date(timeIntervalSince1970: 0), ended: Date(timeIntervalSince1970: 12), exitStatus: 0, error: nil,
                                        usage: SendUsage(input: 40, cached: 0, output: 9, cost: 0.01), tools: nil)
        try KnowledgeAskLog.save(call, question: 1, in: chat)
        let log = KnowledgeAskLog.fullLog(chat)
        for part in ["Ask Pi log: payments/orders-api", "## q1: Who reads it?", "thinking high", "12.0 s, exit status 0", "Tokens: 40 in, 0 cached, 9 out, $0.0100",
                     "  --thinking", "Prompt sent:\nThe prompt", "- bash: akit kb search orders", "- mcp__gitlab__get_issue FAILED", "No result (stopped?)",
                     "- Pi thought:", "- Model error: rate limited", "Answer:\nBilling reads it."] {
            #expect(log.contains(part), "\(part)")
        }
        #expect(!log.contains("ghp_abcdefghijklmnopqrstuvwxyz0123456789"))
    }
}
