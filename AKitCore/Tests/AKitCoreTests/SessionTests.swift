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

    @Test func claudeHidesOutputOfSecretFilesAndMasksTokens() throws {
        var lines = claudeSession()
        lines.append(["type": "assistant", "message": ["role": "assistant", "content": [
            ["type": "tool_use", "id": "t2", "name": "Bash", "input": ["command": "cat .env"]],
        ]]])
        lines.append(["type": "user", "message": ["role": "user", "content": [
            ["type": "tool_result", "tool_use_id": "t2", "content": "DB_PASSWORD=hunter2hunter2"],
        ]]])
        lines.append(["type": "user", "message": ["role": "user", "content": "use key sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123"]])
        try write(claudeFile, lines: lines)
        let adapter = ClaudeCodeAdapter()
        let items = try adapter.transcript(of: try #require(adapter.sessions(in: env).first)).items

        #expect(items.contains { $0.kind == .toolResult(name: "Bash", isError: false) && $0.text == SecretFilter.hiddenOutput })
        #expect(!items.contains { $0.text.contains("hunter2") || $0.text.contains("sk-ant-api03") })
    }

    @Test func claudeShellModeOutputOfSecretFileIsHidden() throws {
        var lines = claudeSession()
        lines += [
            ["type": "user", "message": ["role": "user", "content": "<bash-input>cat .env</bash-input>"]],
            ["type": "user", "message": ["role": "user", "content": "<bash-stdout>DB=hunter2</bash-stdout><bash-stderr></bash-stderr>"]],
            ["type": "user", "message": ["role": "user", "content": "<bash-input>ls</bash-input>"]],
            ["type": "user", "message": ["role": "user", "content": "<bash-stdout>README.md</bash-stdout>"]],
        ]
        try write(claudeFile, lines: lines)
        let adapter = ClaudeCodeAdapter()
        let items = try adapter.transcript(of: try #require(adapter.sessions(in: env).first)).items.suffix(4)
        #expect(items.map(\.kind) == [.event("Shell"), .event("Shell output"), .event("Shell"), .event("Shell output")])
        #expect(items.map(\.text) == ["$ cat .env", SecretFilter.hiddenOutput, "$ ls", "README.md"])
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

    @Test func piHidesOutputOfSecretFiles() throws {
        var lines = piSession()
        lines.append(["type": "message", "id": "a7", "parentId": "a6", "message": ["role": "assistant", "content": [
            ["type": "toolCall", "id": "c2", "name": "read", "arguments": ["path": "/Users/me/.pi/agent/auth.json"]],
        ]]])
        lines.append(["type": "message", "id": "a8", "parentId": "a7", "message": [
            "role": "toolResult", "toolCallId": "c2", "toolName": "read", "isError": false,
            "content": [["type": "text", "text": "{\"access\": \"secret-value-123456\"}"]],
        ]])
        try write(piFile, lines: lines)
        let adapter = PiAdapter()
        let items = try adapter.transcript(of: try #require(adapter.sessions(in: env).first)).items
        #expect(items.last?.text == SecretFilter.hiddenOutput)
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

    // MARK: System prompt

    @Test func claudeRecordedPromptWithToolsAndInitialContext() throws {
        let snapshot: [String: Any] = ["type": "attachment", "attachment": [
            "type": "prompt_snapshot", "systemPrompt": ["You are Claude Code.", "# Harness"],
            "tools": [["name": "Bash", "description": "Run a command", "schema": ["type": "object"]]],
        ]]
        // Real order: the typed prompt, then the context of the first request, then the answer.
        var lines = claudeSession()
        let prompt = try #require(lines.firstIndex { ClaudeSessions.promptText($0) != nil })
        lines.insert(contentsOf: [
            ["type": "attachment", "attachment": ["type": "instructions", "files": [
                ["path": "/home/.claude/CLAUDE.md", "type": "User", "content": "Be brief."],
            ]]],
            ["type": "attachment", "attachment": ["type": "credential_org", "org": "secret-org"]],
            ["type": "attachment", "attachment": ["type": "future_type", "text": "unknown, not shown"]],
            ["type": "attachment", "attachment": ["type": "skill_listing", "content": "- tdd: tests first", "skillCount": 1]],
            ["type": "attachment", "attachment": ["type": "prompt_snapshot", "systemPrompt": ["You are Claude Code.", "# Harness"]]],
            snapshot,
        ], at: prompt + 1)
        lines.append(["type": "attachment", "attachment": ["type": "date", "date": "later, not initial"]])
        try write(claudeFile, lines: lines)

        let adapter = ClaudeCodeAdapter()
        let session = try #require(adapter.sessions(in: env).first)
        let recorded = try #require(try adapter.recordedPrompt(in: session))
        #expect(recorded.sections == ["You are Claude Code.", "# Harness"])
        #expect(recorded.tools.map(\.name) == ["Bash"])
        #expect(recorded.tools.first?.schema.contains("\"type\" : \"object\"") == true)
        #expect(recorded.context.map(\.title) == ["Date", "CLAUDE.md · User", "Skills (1)"])
        #expect(recorded.context[1].source == "/home/.claude/CLAUDE.md")
        #expect(!recorded.context.contains {
            $0.text.contains("secret-org") || $0.text.contains("later") || $0.text.contains("unknown")
        })
    }

    @Test func claudeSessionWithoutSnapshotHasNoPrompt() throws {
        try write(claudeFile, lines: claudeSession())
        let adapter = ClaudeCodeAdapter()
        let session = try #require(adapter.sessions(in: env).first)
        #expect(try adapter.recordedPrompt(in: session) == nil)
    }

    /// A stand-in `pi` that behaves like the probe extension: writes the prompt file.
    func fakePi(_ body: String) throws -> HarnessEnvironment {
        let url = home.appending(path: "bin/pi")
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        try fm.createDirectory(at: home.appending(path: "work/app"), withIntermediateDirectories: true)
        return HarnessEnvironment(homeDirectory: home, executableSearchPaths: [home.appending(path: "bin")])
    }

    @Test func piCaptureRunsWithoutSessionInTheProject() async throws {
        let env = try fakePi("""
        case "$*" in *--no-session*--offline*-p*-e*) ;; *) echo "unexpected: $*"; exit 2;; esac
        printf '{"systemPrompt":"You are pi in %s","tools":[{"name":"read","description":"Read files","parameters":{"type":"object"}}],"contextFiles":["/p/AGENTS.md"],"skills":["tdd"]}' "$(basename "$(pwd)")" > "$AKIT_PROMPT_OUT"
        """)
        let prompt = try #require(try await PiAdapter().capturePrompt(in: home.appending(path: "work/app"), env: env))
        #expect(prompt.systemPrompt == "You are pi in app")
        #expect(prompt.tools.map(\.name) == ["read"])
        #expect(prompt.context.map(\.title) == ["Context files (1)", "Skills (1)"])
    }

    @Test func piCaptureFailureShowsPiOutput() async throws {
        let env = try fakePi("echo 'No model configured'; exit 1")
        await #expect(throws: PiPromptProbe.ProbeError.self) {
            _ = try await PiAdapter().capturePrompt(in: home.appending(path: "work/app"), env: env)
        }
        do {
            _ = try await PiAdapter().capturePrompt(in: home.appending(path: "work/app"), env: env)
        } catch {
            #expect(error.localizedDescription.contains("No model configured"))
        }
    }

    @Test func piCaptureWithoutExecutableIsNil() async throws {
        #expect(try await PiAdapter().capturePrompt(in: home, env: env) == nil)
    }
}
