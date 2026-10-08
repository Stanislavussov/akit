import Foundation
import Testing
import AKitFoundation
@testable import AKitSessions

/// Pi's `--mode json` stream read into the same items as its session log.
struct PiStreamTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-pistream-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    func json(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    /// One turn: the prompt, a failing tool call, a secrets read, the report.
    let messages: [[String: Any]] = [
        ["role": "user", "content": [["type": "text", "text": "Fix the parser"]], "timestamp": 1_790_000_000_000.0],
        ["role": "assistant", "model": "kimi-k3", "provider": "opencode-go", "stopReason": "toolUse",
         "usage": ["input": 100, "output": 20, "cacheRead": 50, "cacheWrite": 0, "cost": ["total": 0.01]],
         "content": [["type": "text", "text": "Running the tests"],
                     ["type": "toolCall", "id": "c1", "name": "bash", "arguments": ["command": "swift test"]],
                     ["type": "toolCall", "id": "c2", "name": "read", "arguments": ["path": "/Users/me/.pi/agent/auth.json"]]]],
        ["role": "toolResult", "toolCallId": "c1", "toolName": "bash", "content": [["type": "text", "text": "1 failure"]], "isError": true],
        ["role": "toolResult", "toolCallId": "c2", "toolName": "read", "content": [["type": "text", "text": "{\"key\":\"x\"}"]],
         "isError": false],
        ["role": "assistant", "model": "kimi-k3", "provider": "opencode-go", "stopReason": "stop",
         "usage": ["input": 10, "output": 5, "cacheRead": 150, "cacheWrite": 0, "cost": ["total": 0.002]],
         "content": [["type": "text", "text": "Done: the parser is fixed"]]],
    ]

    @Test func streamReadsLikeTheSessionLog() throws {
        var stream = [json(["type": "agent_start"]), "Warning: No project session found with id x, creating it"]
        for message in messages {
            stream.append(json(["type": "message_start", "message": message]))
            stream.append(json(["type": "message_end", "message": message]))
        }
        stream.append(json(["type": "agent_settled"]))
        let fromStream = PiSessions.transcript(ofStream: stream)

        var log = [json(["type": "session", "version": 3, "id": "s1", "timestamp": "2026-09-20T10:00:00.000Z", "cwd": "/work"])]
        var parent: Any = NSNull()
        for (index, message) in messages.enumerated() {
            log.append(json(["type": "message", "id": "m\(index)", "parentId": parent, "message": message]))
            parent = "m\(index)"
        }
        let file = home.appending(path: "s1.jsonl")
        try Data(log.joined(separator: "\n").utf8).write(to: file)
        let fromLog = try PiSessions.transcript(of: file)

        #expect(fromStream.items.map(\.kind) == [
            .user, .assistant, .toolCall(name: "bash"), .toolCall(name: "read"), .toolResult(name: "bash", isError: true),
            .toolResult(name: "read", isError: false), .assistant,
        ])
        #expect(fromStream.items.map(\.kind) == fromLog.items.map(\.kind))
        #expect(fromStream.items.map(\.text) == fromLog.items.map(\.text))
        // Timestamps differ by design: the log stamps entries, the stream only messages.
        #expect(fromStream.usage.models == fromLog.usage.models && fromStream.usage.peakContext == fromLog.usage.peakContext)
        #expect(fromStream.usage.toolErrors == 1 && fromStream.usage.tools == fromLog.usage.tools && fromStream.models == ["kimi-k3"])
        // Tool calls are the arguments as JSON text, which checks parse.
        let call = try #require(fromStream.items.first { $0.kind == .toolCall(name: "bash") })
        #expect((try JSONSerialization.jsonObject(with: Data(call.text.utf8)) as? [String: Any])?["command"] as? String == "swift test")
        // The secrets file's content is hidden, as in the log.
        #expect(!fromStream.items.contains { $0.text.contains("\"key\"") })
        #expect(fromStream.items[0].timestamp == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(fromStream.usage.models.first?.tokens.output == 25)
    }

    @Test func aHiddenFailedResultKeepsItsOutcome() {
        // An extension refuses a write to .env, and a read of .env fails: both texts are hidden.
        let stream = [
            ["role": "assistant", "model": "kimi-k3", "content": [
                ["type": "toolCall", "id": "c1", "name": "write", "arguments": ["path": "/work/.env", "content": "A=1"]],
                ["type": "toolCall", "id": "c2", "name": "read", "arguments": ["path": "/work/.env.local"]]]],
            ["role": "toolResult", "toolCallId": "c1", "toolName": "write",
             "content": [["type": "text", "text": "Blocked write: /work/.env is protected"]], "isError": true],
            ["role": "toolResult", "toolCallId": "c2", "toolName": "read",
             "content": [["type": "text", "text": "ENOENT: no such file or directory"]], "isError": true],
        ].flatMap { [json(["type": "message_start", "message": $0]), json(["type": "message_end", "message": $0])] }
        let items = PiSessions.transcript(ofStream: stream).items
        let results = items.filter { if case .toolResult = $0.kind { true } else { false } }
        #expect(results.map(\.text) == [SecretFilter.hiddenOutput, SecretFilter.hiddenOutput])
        #expect(results.map { $0.resultOutcome?.outcome } == [.rejected, .inputMistake])
        let signals = FailureSignals(items)
        #expect(signals.rejected == 1 && signals.toolErrors == 1)
    }
}
