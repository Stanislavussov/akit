import Foundation
import Testing
import AKitFoundation
import AKitLab
import AKitSessions
@testable import AKitErrorAnalysis

/// Lab's analyzer reads the log lines, the index's scanner reads the transcript: both count
/// interrupts, rejections, tool errors and repeated calls by the same rules.
struct FailureSignalsParityTests {
    let folder: URL
    let fm = FileManager.default

    init() throws {
        folder = fm.temporaryDirectory.appending(path: "akit-signals-\(UUID().uuidString)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func write(_ url: URL, _ lines: [[String: Any]]) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = try lines.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
            .joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: url)
    }

    func time(_ second: Int) -> String {
        ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_790_000_000 + Double(second)))
    }

    func call(_ id: String, at second: Int, _ tools: [(id: String, name: String, input: [String: Any])], sidechain: Bool = false) -> [String: Any] {
        ["type": "assistant", "isSidechain": sidechain, "timestamp": time(second),
         "message": ["id": id, "model": "claude-opus-5-5", "role": "assistant",
                     "content": tools.map { ["type": "tool_use", "id": $0.id, "name": $0.name, "input": $0.input] },
                     "usage": ["input_tokens": 50, "cache_creation_input_tokens": 10, "cache_read_input_tokens": 100, "output_tokens": 5]]]
    }

    func results(at second: Int, _ results: [(id: String, text: String, error: Bool)], text: String? = nil,
                 meta: Bool = false, sidechain: Bool = false) -> [String: Any] {
        var content: [[String: Any]] = results.map {
            ["type": "tool_result", "tool_use_id": $0.id, "is_error": $0.error, "content": [["type": "text", "text": $0.text]]]
        }
        if let text { content.append(["type": "text", "text": text]) }
        return ["type": "user", "isMeta": meta, "isSidechain": sidechain, "timestamp": time(second),
                "message": ["role": "user", "content": content]]
    }

    func prompt(_ text: String, at second: Int, meta: Bool = false, sidechain: Bool = false) -> [String: Any] {
        ["type": "user", "isMeta": meta, "isSidechain": sidechain, "timestamp": time(second), "message": ["role": "user", "content": text]]
    }

    @Test func labAndScannerAgree() throws {
        let refusal = "The user doesn't want to proceed with this tool use. The tool use was rejected."
        let read: [String: Any] = ["file_path": "/p/a.swift"]
        let file = folder.appending(path: "-p/s1.jsonl")
        try write(file, [
            prompt("Fix the bug", at: 0),
            // Three reads of the same file in a row (results between): one repeat run.
            call("m1", at: 1, [("t1", "Read", read)]), results(at: 2, [("t1", "func a()", false)]),
            call("m2", at: 3, [("t2", "Read", read)]), results(at: 4, [("t2", "func a()", false)]),
            call("m3", at: 5, [("t3", "Read", read)]), results(at: 6, [("t3", "func a()", false)]),
            // Two builds in a row, then a test, then the build again: no repeat.
            call("m4", at: 7, [("t4", "Bash", ["command": "swift build"])]), results(at: 8, [("t4", "Exit code 1\nerror: x", true)]),
            call("m5", at: 9, [("t5", "Bash", ["command": "swift build"])]), results(at: 10, [("t5", "Exit code 1\nerror: x", true)]),
            call("m6", at: 11, [("t6", "Bash", ["command": "swift test"])]), results(at: 12, [("t6", "ok", false)]),
            call("m7", at: 13, [("t7", "Bash", ["command": "swift build"])]), results(at: 14, [("t7", "ok", false)]),
            // A refusal with a reason: rejected.
            call("m8", at: 15, [("t8", "Edit", ["file_path": "/p/a.swift", "old_string": "a", "new_string": "b"])]),
            results(at: 16, [("t8", refusal, true)]),
            // Esc at the permission prompt of two parallel calls: an interrupt, not two refusals.
            call("m9", at: 17, [("t9", "Write", ["file_path": "/p/b.swift", "content": "b"]),
                                ("t10", "Write", ["file_path": "/p/c.swift", "content": "c"])]),
            results(at: 18, [("t9", refusal, true), ("t10", refusal, true)], text: "[Request interrupted by user for tool use]"),
            // A tool stopped while it ran: neither an error nor an interrupt of its own.
            call("m10", at: 19, [("t11", "Bash", ["command": "sleep 100"])]),
            results(at: 20, [("t11", "[Request interrupted by user for tool use]", true)]),
            prompt("[Request interrupted by user]", at: 21),
            // The marker inside other text is not an interrupt; meta lines and side chains don't count.
            prompt("Why did the log say [Request interrupted by user]?", at: 22),
            prompt("[Request interrupted by user]", at: 23, meta: true),
            prompt("[Request interrupted by user]", at: 24, sidechain: true),
            call("x1", at: 25, [("s1", "Read", read)], sidechain: true),
            results(at: 26, [("s1", "missing", true)], sidechain: true),
            call("m11", at: 27, [("t12", "Read", ["file_path": "/p/missing.swift"])]),
            results(at: 28, [("t12", "File does not exist.", true)]),
        ])
        // A subagent's own file: its interrupts and errors are not the session's.
        try write(folder.appending(path: "-p/s1/subagents/agent-1.jsonl"), [
            prompt("[Request interrupted by user]", at: 30),
            call("a1", at: 31, [("u1", "Bash", ["command": "false"])]), results(at: 32, [("u1", "Exit code 1", true)]),
        ])

        let lab = try SessionAnalyzer.analyze(file: file)
        let summary = SessionSummary(harness: .claudeCode, file: file, title: "s1", project: nil, started: nil, modified: .now, size: 0)
        let transcript = try SessionReader.transcript(of: summary)
        let index = SignalScanner.signals(of: transcript.items)

        #expect(lab.interrupts == 2 && lab.rejected == 1 && lab.toolErrors == 3 && lab.repeatedCalls == 1)
        #expect(index.interrupts == lab.interrupts)
        #expect(index.rejected == lab.rejected)
        #expect(index.toolErrors == lab.toolErrors)
        #expect(index.repeatedCalls == lab.repeatedCalls)
        // The session view's "failed" is the same count.
        #expect(transcript.usage.toolErrors == lab.toolErrors)
    }
}
