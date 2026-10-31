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
        let times = KnowledgeAskLog.ToolTimes(starts: ["c1": t0, "c2": t0.addingTimeInterval(1)], ends: ["c2": t0.addingTimeInterval(2), "c1": t0.addingTimeInterval(4)],
                                              unnamedStarts: [t0.addingTimeInterval(5), t0.addingTimeInterval(9)], unnamedEnds: [t0.addingTimeInterval(6)])
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

    /// Review: what Pi read from a secret file never shows, in the steps or the full log.
    @Test func secretFileOutputIsHidden() {
        let stream = [
            #"{"type":"tool_execution_start","toolName":"read","toolCallId":"r1","args":{"path":"/repo/.env"}}"#,
            #"{"type":"tool_execution_update","toolName":"read","toolCallId":"r1","partialResult":{"content":[{"type":"text","text":"DB_PASS=hunter2hunter2"}]}}"#,
            #"{"type":"tool_execution_end","toolName":"read","toolCallId":"r1","result":{"content":[{"type":"text","text":"DB_PASS=hunter2hunter2"}]}}"#,
            #"{"type":"message_end","message":{"role":"toolResult","toolCallId":"r1","content":[{"type":"text","text":"DB_PASS=hunter2hunter2"}]}}"#,
            #"{"type":"tool_execution_start","toolName":"bash","args":{"command":"cat ~/.pi/agent/mcp.json"}}"#,
            #"{"type":"tool_execution_end","toolName":"bash","result":{"content":[{"type":"text","text":"{\"my_secret\": \"s3cr3tvalue\"}"}]}}"#,
            #"{"type":"tool_execution_start","toolName":"bash","toolCallId":"b2","args":{"command":"cat README.md"}}"#,
            #"{"type":"tool_execution_end","toolName":"bash","toolCallId":"b2","result":{"content":[{"type":"text","text":"Hello"}]}}"#,
        ]
        let steps = KnowledgeAskLog.steps(stream)
        #expect(steps.map(\.result) == [SecretFilter.hiddenOutput, SecretFilter.hiddenOutput, "Hello"])
        let text = KnowledgeAskLog.text(of: KnowledgeAskLog.Answer(entry: KnowledgeAsk.Entry(id: "q1", question: "Q", asked: .now), call: nil, steps: steps,
                                                                    stream: URL(filePath: "/x")))
        #expect(!text.contains("hunter2") && !text.contains("s3cr3t"))
        let hider = PiSecretFiles()
        let written = stream.map { JSONMask.jsonLine(hider.line($0)) }.joined(separator: "\n")
        #expect(!written.contains("hunter2") && !written.contains("s3cr3t") && written.contains("Hello"))
    }

    /// Verification: Pi's toolResult message (`details.truncation.content`, `structuredContent`),
    /// `turn_end.toolResults[]` and `agent_end.messages[]` keep nothing of a secret call's output;
    /// a toolResult without a call id follows the tool's last call without one.
    @Test func everyResultShapeOfASecretCallIsHidden() {
        let result = #"{"role":"toolResult","toolCallId":"r1","toolName":"bash","isError":false,"timestamp":1,"content":[{"type":"text","text":"DB_PASS=hunter2hunter2"}],"details":{"truncation":{"content":"DB_PASS=hunter2hunter2"}},"structuredContent":{"full_output_path":"/tmp/pi-out-hunter2"}}"#
        let lines = [
            #"{"type":"message_end","message":{"role":"assistant","content":[{"type":"toolCall","id":"r1","name":"bash","arguments":{"command":"base64 < .env"}}]}}"#,
            #"{"type":"tool_execution_start","toolName":"bash","toolCallId":"r1","args":{"command":"base64 < .env"}}"#,
            #"{"type":"message_start","message":"# + result + "}",
            #"{"type":"message_end","message":"# + result + "}",
            #"{"type":"turn_end","message":{"role":"assistant","content":[]},"toolResults":["# + result + "]}",
            #"{"type":"agent_end","messages":["# + result + "]}",
            #"{"type":"tool_execution_start","toolName":"read","args":{"path":".e*"}}"#,
            #"{"type":"message_end","message":{"role":"toolResult","toolName":"read","content":[{"type":"text","text":"TOKEN=hunter2hunter2"}]}}"#,
            #"{"type":"tool_execution_start","toolName":"read","args":{"path":"README.md"}}"#,
            #"{"type":"message_end","message":{"role":"toolResult","toolName":"read","content":[{"type":"text","text":"Hello"}]}}"#,
        ]
        let hider = PiSecretFiles()
        let written = lines.map { JSONMask.jsonLine(hider.line($0)) }
        #expect(!written.joined().contains("hunter2"))
        #expect(written[3].contains("\"toolCallId\":\"r1\"") && written[3].contains("Hidden by AKit") && !written[3].contains("details"))
        #expect(written[1].contains("base64 < .env"), "the call itself stays readable")
        #expect(written.last?.contains("Hello") == true, "a later read of another file isn't hidden")
    }

    /// Review: values under a secret-naming key are masked, in tool arguments and in JSON inside a result.
    @Test func namedSecretsInArgumentsAreMasked() {
        let line = #"{"type":"tool_execution_start","toolName":"mcp__api__call","toolCallId":"m1","args":{"headers":{"X-Api-Key":"Zq8xLm2Pq"},"password":"hunter2abc","query":"orders"}}"#
        let masked = JSONMask.jsonLine(line)
        #expect(!masked.contains("Zq8xLm2Pq") && !masked.contains("hunter2abc") && masked.contains("orders"))
        let inner = JSONMask.string("Answer: {\"token\": \"abcdef\", \"name\": \"x\"}")
        #expect(!inner.contains("abcdef") && inner.contains("\"name\":\"x\""))
        #expect(JSONMask.jsonLine(masked) == masked, "masking masked text changes nothing")
        let step = KnowledgeAskLog.steps([line, #"{"type":"tool_execution_end","toolName":"mcp__api__call","toolCallId":"m1","result":"ok"}"#]).first
        #expect(step?.detail.contains("Zq8xLm2Pq") == false && step?.summary == "orders")
    }

    /// Lines that aren't whole JSON are skipped; an end with no start is a step of its own.
    @Test func brokenLinesAndAnEndWithoutStart() {
        let steps = KnowledgeAskLog.steps([
            "not json", #"{"type":"tool_execution_start","toolName":"bash","toolCallId":"c1","args":{"command":"ls""#,
            #"{"type":"tool_execution_end","toolName":"bash","toolCallId":"c9","result":"orphan"}"#,
            #"{"type":"tool_execution_start","toolName":"read","args":{"path":"a.md"}}"#,
            #"{"type":"tool_execution_end","toolName":"bash","toolCallId":"c1","result":"late"}"#,
        ])
        #expect(steps.count == 3)
        #expect(steps[0].orphan && steps[0].result == "orphan" && steps[0].summary == "result without start")
        #expect(steps[1].tool == "read" && steps[1].result == nil, "an end with a call id never closes a call without one")
        #expect(steps[2].orphan && steps[2].result == "late")
    }

    @Test func longResultsAreCutButCounted() {
        let big = String(repeating: "x", count: 5_000)
        let steps = KnowledgeAskLog.steps([#"{"type":"tool_execution_start","toolName":"read","toolCallId":"c1","args":{"path":"a"}}"#,
                                           #"{"type":"tool_execution_end","toolName":"read","toolCallId":"c1","result":"\#(big)"}"#], limit: 1_000)
        #expect(steps[0].result?.count == 1_000 && steps[0].resultCount == 5_000)
    }

    @Test func thinkingIsRememberedPerModel() {
        #expect(KnowledgeAskLog.thinking(for: "", remembered: ["": "high"], fallback: "low", levels: LabHarness.pi.efforts) == "high",
                "Pi's default model has a level of its own")
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
