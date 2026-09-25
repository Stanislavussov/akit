import Foundation
import Testing
@testable import AKitCore

/// Session history in a temporary fake home. Never touches the real one.
struct SessionTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-sessions-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var env: HarnessEnvironment { HarnessEnvironment(homeDirectory: home) }

    func write(_ path: String, lines: [[String: Any]]) throws {
        let url = home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = try lines.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
            .joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: url)
    }

    // MARK: Claude Code

    let claudeFile = ".claude/projects/-work-app/1111.jsonl"

    func claudeSession(extra: [[String: Any]] = []) -> [[String: Any]] {
        [
            ["type": "permission-mode", "permissionMode": "default", "sessionId": "1111"],
            ["type": "attachment", "cwd": "/work/app", "version": "2.1.282", "timestamp": "2026-09-20T10:00:00.000Z",
             "attachment": ["type": "date", "date": "2026-09-20"]],
            ["type": "user", "isMeta": true, "timestamp": "2026-09-20T10:00:01.000Z",
             "message": ["role": "user", "content": "<local-command-caveat>Caveat</local-command-caveat>"]],
            ["type": "user", "timestamp": "2026-09-20T10:00:02.000Z",
             "message": ["role": "user", "content": "<command-name>/model</command-name>\n<command-args>opus</command-args>"]],
            ["type": "user", "cwd": "/work/app", "timestamp": "2026-09-20T10:00:03.000Z",
             "message": ["role": "user", "content": "Fix the login bug\nplease"]],
            ["type": "assistant", "timestamp": "2026-09-20T10:00:04.000Z",
             "message": ["role": "assistant", "model": "claude-opus-5-5", "content": [
                 ["type": "thinking", "thinking": "Look at auth.swift", "signature": "x"],
                 ["type": "tool_use", "id": "t1", "name": "Read", "input": ["file_path": "/work/app/auth.swift"]],
             ]]],
            ["type": "user", "timestamp": "2026-09-20T10:00:05.000Z",
             "message": ["role": "user", "content": [
                 ["type": "tool_result", "tool_use_id": "t1", "content": [["type": "text", "text": "func login()"]]],
             ]]],
            ["type": "assistant", "isSidechain": true, "message": ["role": "assistant", "content": [["type": "text", "text": "subagent"]]]],
            ["type": "system", "subtype": "turn_duration", "durationMs": 10],
            ["type": "assistant", "timestamp": "2026-09-20T10:00:06.000Z",
             "message": ["role": "assistant", "model": "claude-opus-5-5", "content": [["type": "text", "text": "Fixed."]]]],
            ["type": "ai-title", "aiTitle": "Old title", "sessionId": "1111"],
        ] + extra
    }

    @Test func claudeSummaryUsesLatestTitleAndCwd() throws {
        try write(claudeFile, lines: claudeSession(extra: [["type": "ai-title", "aiTitle": "Fix login bug", "sessionId": "1111"]]))
        try fm.createDirectory(at: home.appending(path: ".claude/projects/-work-app/1111/subagents"), withIntermediateDirectories: true)

        let sessions = ClaudeCodeAdapter().sessions(in: env)
        let session = try #require(sessions.first)
        #expect(sessions.count == 1) // the subagents folder is not a session
        #expect(session.harness == .claudeCode)
        #expect(session.title == "Fix login bug")
        #expect(session.project?.path == "/work/app")
        #expect(session.harnessVersion == "2.1.282")
        #expect(session.started == JSONLines.date("2026-09-20T10:00:00.000Z"))
    }

    @Test func claudeTitleFallsBackToFirstTypedPrompt() throws {
        var lines = claudeSession()
        lines.removeLast() // no ai-title
        try write(claudeFile, lines: lines)
        #expect(ClaudeCodeAdapter().sessions(in: env).first?.title == "Fix the login bug")
    }

    @Test func claudeTranscriptSkipsMetaAndSidechains() throws {
        try write(claudeFile, lines: claudeSession())
        let adapter = ClaudeCodeAdapter()
        let transcript = try adapter.transcript(of: try #require(adapter.sessions(in: env).first))

        #expect(transcript.items.map(\.kind) == [
            .event("Command"), .user, .thinking, .toolCall(name: "Read"),
            .toolResult(name: "Read", isError: false), .assistant,
        ])
        #expect(transcript.items[0].text == "/model opus")
        #expect(transcript.items[3].text.contains("\"file_path\" : \"/work/app/auth.swift\""))
        #expect(transcript.items[4].text == "func login()")
        #expect(transcript.models == ["claude-opus-5-5"])
    }

    @Test func claudeFileWithoutConversationIsSkipped() throws {
        try write(claudeFile, lines: [["type": "permission-mode", "permissionMode": "default", "sessionId": "1111"]])
        #expect(ClaudeCodeAdapter().sessions(in: env).isEmpty)
    }

    // MARK: Pi

    let piFile = ".pi/agent/sessions/--work-app--/2026-09-20T10-00-00-000Z_abcd.jsonl"

    func piSession() -> [[String: Any]] {
        [
            ["type": "session", "version": 3, "id": "abcd", "timestamp": "2026-09-20T10:00:00.000Z", "cwd": "/work/app"],
            ["type": "model_change", "id": "a1", "parentId": NSNull(), "timestamp": "2026-09-20T10:00:00.100Z",
             "provider": "anthropic", "modelId": "claude-opus-5-5"],
            ["type": "message", "id": "a2", "parentId": "a1", "timestamp": "2026-09-20T10:00:01.000Z",
             "message": ["role": "user", "content": [["type": "text", "text": "<skill name=\"tdd\">body</skill>\n\nAdd tests"]]]],
            // An abandoned branch from a2.
            ["type": "message", "id": "b1", "parentId": "a2", "timestamp": "2026-09-20T10:00:02.000Z",
             "message": ["role": "assistant", "content": [["type": "text", "text": "abandoned"]], "model": "old"]],
            ["type": "message", "id": "a3", "parentId": "a2", "timestamp": "2026-09-20T10:00:03.000Z",
             "message": ["role": "assistant", "model": "claude-opus-5-5", "content": [
                 ["type": "thinking", "thinking": "\u{1B}[38;2;1;2;3mThinking:\u{1B}[39m plan"],
                 ["type": "toolCall", "id": "c1", "name": "bash", "arguments": ["command": "swift test"]],
             ]]],
            ["type": "message", "id": "a4", "parentId": "a3", "timestamp": "2026-09-20T10:00:04.000Z",
             "message": ["role": "toolResult", "toolCallId": "c1", "toolName": "bash",
                         "content": [["type": "text", "text": "1 failure"]], "isError": true]],
            ["type": "custom", "id": "a5", "parentId": "a4", "customType": "state", "data": ["x": 1]],
            ["type": "session_info", "id": "a6", "parentId": "a5", "name": "Test run"],
        ]
    }

    @Test func piSummaryReadsHeaderAndName() throws {
        try fm.createDirectory(at: home.appending(path: ".pi/agent"), withIntermediateDirectories: true)
        try write(piFile, lines: piSession())

        let session = try #require(PiAdapter().sessions(in: env).first)
        #expect(session.harness == .pi)
        #expect(session.title == "Test run")
        #expect(session.project?.path == "/work/app")
    }

    @Test func piTitleSkipsExpandedSkill() throws {
        var lines = piSession()
        lines.removeLast()
        try write(piFile, lines: lines)
        #expect(PiAdapter().sessions(in: env).first?.title == "Add tests")
    }

    @Test func piTranscriptFollowsTheActiveBranch() throws {
        try write(piFile, lines: piSession())
        let adapter = PiAdapter()
        let transcript = try adapter.transcript(of: try #require(adapter.sessions(in: env).first))

        #expect(transcript.items.map(\.kind) == [
            .event("Model"), .user, .thinking, .toolCall(name: "bash"), .toolResult(name: "bash", isError: true),
        ])
        #expect(!transcript.items.contains { $0.text == "abandoned" })
        #expect(transcript.items[2].text == "Thinking: plan")
        #expect(transcript.models == ["claude-opus-5-5"])
    }

    @Test func piSessionFolderFromEnvironment() throws {
        let custom = HarnessEnvironment(homeDirectory: home, variables: ["PI_CODING_AGENT_SESSION_DIR": "~/pi-sessions"])
        try write("pi-sessions/--work-app--/s.jsonl", lines: piSession())
        #expect(PiAdapter().sessions(in: custom).count == 1)
        #expect(PiAdapter().sessions(in: env).isEmpty)
    }

    @Test func scannerListsInstalledHarnessesNewestFirst() throws {
        try write(claudeFile, lines: claudeSession())
        try write(piFile, lines: piSession())
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: home.appending(path: claudeFile).path)

        let sessions = SessionScanner.scan(installations: HarnessCatalog.detectAll(in: env), in: env)
        #expect(sessions.map(\.harness) == [.pi, .claudeCode])
    }
}
