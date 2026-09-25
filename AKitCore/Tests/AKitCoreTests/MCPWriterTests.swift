import Foundation
import Testing
@testable import AKitCore

/// Adding MCP servers, in a temporary fake home with an in-memory secret store.
struct MCPWriterTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-mcpw-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var env: HarnessEnvironment { HarnessEnvironment(homeDirectory: home) }
    var project: URL { home.appending(path: "Projects/app", directoryHint: .isDirectory) }

    func write(_ path: String, _ text: String) throws {
        let url = home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func read(_ path: String) throws -> [String: Any] {
        try ConfigText.jsonObject(try Data(contentsOf: home.appending(path: path)), jsonc: true)
    }

    func targets() throws -> [MCPWriteTarget] {
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        return MCPWriter.targets(installations: HarnessCatalog.detectAll(in: env), projects: [project], in: env)
    }

    var grafana: MCPDraft {
        MCPDraft(name: "grafana", command: "/opt/homebrew/bin/mcp-grafana", arguments: ["-t", "stdio"],
                 environment: [.init(key: "GRAFANA_URL", value: "https://grafana.example.com"),
                               .init(key: "GRAFANA_TOKEN", value: "glsa_secret_value_123", isSecret: true)])
    }

    @Test func targetsGroupSharedFilesAndUseClaudeCLIForItsState() throws {
        try write(".claude/settings.json", "{}")
        try write(".pi/agent/settings.json", #"{"packages": ["npm:pi-mcp-adapter"]}"#)
        let all = try targets()
        let shared = try #require(all.first { $0.file.path == project.appending(path: ".mcp.json").path })
        #expect(shared.harnesses == [.claudeCode, .pi])
        #expect(shared.isShared)
        #expect(shared.claudeScope == nil)
        #expect(all.first { $0.layer == "User" && $0.harnesses == [.claudeCode] }?.claudeScope == "user")
        #expect(all.first { $0.layer == "Local" }?.claudeScope == "local")
        #expect(all.first { $0.layer == "Pi project" }?.isShared == false)
    }

    @Test func sharedFileGetsReferenceAndEnvScript() async throws {
        try write(".claude/settings.json", "{}")
        try write("Projects/app/.mcp.json", #"{"mcpServers": {"old": {"command": "x", "env": {"K": "literal-secret-abc"}}}}"#)
        let target = try #require(try targets().first { $0.file.lastPathComponent == ".mcp.json" })

        let plan = try MCPWriter.plan(grafana, into: target, secretMode: .environment, home: home)
        #expect(plan.secretNames == ["GRAFANA_TOKEN"])
        #expect(!plan.replaces)
        let shown = plan.diff.map { "\($0)" }.joined() + plan.entryJSON
        #expect(!shown.contains("glsa_secret_value_123"))
        #expect(!shown.contains("literal-secret-abc"))

        let store = MemorySecretStore()
        let outcome = try await MCPWriter.apply(plan, secrets: store, home: home) { _, _ in Issue.record("no CLI") }
        #expect(store.value("GRAFANA_TOKEN") == "glsa_secret_value_123")
        #expect(outcome.backup.map { fm.fileExists(atPath: $0.path) } == true)
        #expect(outcome.notes.first?.contains("source ~/.akit/env.sh") == true)

        let written = try read("Projects/app/.mcp.json")
        let server = try #require((written["mcpServers"] as? [String: Any])?["grafana"] as? [String: Any])
        #expect(server["command"] as? String == "/opt/homebrew/bin/mcp-grafana")
        #expect(server["env"] as? [String: String] == ["GRAFANA_URL": "https://grafana.example.com",
                                                       "GRAFANA_TOKEN": "${GRAFANA_TOKEN}"])
        #expect((written["mcpServers"] as? [String: Any])?["old"] != nil)
        let script = try String(contentsOf: home.appending(path: ".akit/env.sh"), encoding: .utf8)
        #expect(script.contains("export GRAFANA_TOKEN=\"$(/usr/bin/security find-generic-password -s 'AKit MCP' -a 'GRAFANA_TOKEN' -w 2>/dev/null)\""))
        #expect(!script.contains("glsa_secret_value_123"))
    }

    @Test func keychainLookupWrapsStdioCommand() throws {
        try write(".claude/settings.json", "{}")
        let target = try #require(try targets().first { $0.file.lastPathComponent == ".mcp.json" })
        let plan = try MCPWriter.plan(grafana, into: target, secretMode: .keychainLookup, home: home)
        let entry = try ConfigText.jsonObject(Data(plan.entryCompact.utf8), jsonc: false)
        #expect(entry["command"] as? String == "/bin/sh")
        let args = try #require(entry["args"] as? [String])
        #expect(args.first == "-c")
        #expect(args[1] == #"GRAFANA_TOKEN="$(/usr/bin/security find-generic-password -s 'AKit MCP' -a 'GRAFANA_TOKEN' -w)" && export GRAFANA_TOKEN && exec "$0" "$@""#)
        #expect(Array(args.dropFirst(2)) == ["/opt/homebrew/bin/mcp-grafana", "-t", "stdio"])
        #expect(entry["env"] as? [String: String] == ["GRAFANA_URL": "https://grafana.example.com"])
    }

    @Test func piOwnFileUsesCommandValuesAndClaudeHTTPUsesHeadersHelper() throws {
        try write(".claude/settings.json", "{}")
        try write(".pi/agent/settings.json", #"{"packages": ["npm:pi-mcp-adapter"]}"#)
        let all = try targets()
        let remote = MCPDraft(name: "linear", transport: .http, url: "https://mcp.linear.app/mcp",
                              headers: [.init(key: "Authorization", value: "Bearer lin_api_x", isSecret: true)])

        let pi = try #require(all.first { $0.layer == "Pi global" })
        let piEntry = try ConfigText.jsonObject(Data(try MCPWriter.plan(remote, into: pi, secretMode: .keychainLookup, home: home).entryCompact.utf8), jsonc: false)
        #expect((piEntry["headers"] as? [String: String])?["Authorization"]
                == "!/usr/bin/security find-generic-password -s 'AKit MCP' -a 'LINEAR_AUTHORIZATION' -w")

        let claude = try #require(all.first { $0.claudeScope == "user" })
        let plan = try MCPWriter.plan(remote, into: claude, secretMode: .keychainLookup, home: home)
        let entry = try ConfigText.jsonObject(Data(plan.entryCompact.utf8), jsonc: false)
        #expect(entry["headers"] == nil)
        #expect((entry["headersHelper"] as? String)?.hasPrefix(#"printf '{"Authorization":"%s"}' "$(/usr/bin/security"#) == true)
        #expect(plan.diff.isEmpty)
    }

    @Test func claudeStateIsChangedThroughCLI() async throws {
        try write(".claude/settings.json", "{}")
        try write(".claude.json", #"{"mcpServers": {"grafana": {"command": "old"}}}"#)
        let target = try #require(try targets().first { $0.claudeScope == "user" })
        let plan = try MCPWriter.plan(grafana, into: target, secretMode: .environment, home: home)
        #expect(plan.replaces)
        let calls = CallLog()
        _ = try await MCPWriter.apply(plan, secrets: MemorySecretStore(), home: home) { args, _ in calls.add(args) }
        #expect(calls.all.map { Array($0.prefix(4)) } == [["mcp", "remove", "--scope", "user"], ["mcp", "add-json", "--scope", "user"]])
        #expect(calls.all.last?.last?.contains("${GRAFANA_TOKEN}") == true)
        #expect(try String(contentsOf: home.appending(path: ".claude.json"), encoding: .utf8).contains("old")) // untouched by AKit
    }

    @Test func applyRefusesWhenFileChangedAfterPreview() async throws {
        try write(".claude/settings.json", "{}")
        let target = try #require(try targets().first { $0.file.lastPathComponent == ".mcp.json" })
        let plan = try MCPWriter.plan(grafana, into: target, secretMode: .environment, home: home)
        try write("Projects/app/.mcp.json", "{}")
        let store = MemorySecretStore()
        await #expect(throws: ConfigTextError.self) {
            try await MCPWriter.apply(plan, secrets: store, home: home) { _, _ in }
        }
        #expect(store.value("GRAFANA_TOKEN") == nil)
    }

    @Test func openCodeDialectAndCommentedFilesAreBlocked() throws {
        try write(".config/opencode/opencode.json", #"{"model": "x"}"#)
        let target = try #require(try targets().first { $0.dialect == .openCode && $0.scope == .global })
        let plan = try MCPWriter.plan(grafana, into: target, secretMode: .environment, home: home)
        let entry = try ConfigText.jsonObject(Data(plan.entryCompact.utf8), jsonc: false)
        #expect(entry["type"] as? String == "local")
        #expect(entry["command"] as? [String] == ["/opt/homebrew/bin/mcp-grafana", "-t", "stdio"])
        #expect((entry["environment"] as? [String: String])?["GRAFANA_TOKEN"] == "{env:GRAFANA_TOKEN}")

        try fm.removeItem(at: home.appending(path: ".config/opencode/opencode.json"))
        try write(".config/opencode/opencode.jsonc", "{\n  // mine\n}")
        let blocked = try #require(try targets().first { $0.dialect == .openCode && $0.scope == .global })
        #expect(blocked.blockedReason != nil)
    }

    @Test func pastedJSONShapes() throws {
        let claude = try MCPDraft.parse(json: #"{"mcpServers": {"gh": {"type": "http", "url": "https://x/mcp", "headers": {"Authorization": "Bearer ghp_abcdefghijklmnopqrstuvwxyz0123456789"}}}}"#)
        #expect(claude.map(\.name) == ["gh"])
        #expect(claude.first?.transport == .http)
        #expect(claude.first?.headers.first?.isSecret == true)

        let bare = try MCPDraft.parse(json: #""fs": {"command": "npx", "args": ["-y", "fs"], "env": {"ROOT": "/tmp", "API_KEY": "${KEY}"}}"#)
        #expect(bare.first?.name == "fs")
        #expect(bare.first?.arguments == ["-y", "fs"])
        #expect(bare.first?.environment.map(\.isSecret) == [false, false]) // a reference is not a secret

        let single = try MCPDraft.parse(json: #"{"command": ["npx", "-y", "srv"], "environment": {"TOKEN": "abc12345"}}"#)
        #expect(single.first?.name == "")
        #expect(single.first?.command == "npx")
        #expect(single.first?.arguments == ["-y", "srv"])
        #expect(single.first?.environment.first?.isSecret == true)

        #expect(throws: ConfigTextError.self) { try MCPDraft.parse(json: #"{"a": 1}"#) }
        #expect(throws: ConfigTextError.self) { try MCPDraft.parse(json: "nope") }
    }

    @Test func draftValidation() {
        #expect(MCPDraft().problems.contains("Name is required."))
        #expect(MCPDraft(name: "a b", command: "x").problems.first?.contains("Name may only") == true)
        #expect(MCPDraft(name: "a", transport: .http, url: "nope").problems == ["URL must look like https://host/path."])
        #expect(MCPDraft(name: "a", command: "x", environment: [.init(key: "T", value: "", isSecret: true)]).problems == ["Secret T is empty."])
    }

    @Test func diffLines() {
        #expect(TextDiff.lines(from: "a\nb\nc", to: "a\nx\nc") == [.same("a"), .removed("b"), .added("x"), .same("c")])
        #expect(TextDiff.lines(from: "", to: "a") == [.added("a")])
    }
}

private final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    func add(_ call: [String]) { lock.withLock { calls.append(call) } }
    var all: [[String]] { lock.withLock { calls } }
}

struct ArgumentLineTests {
    @Test func splitAndJoin() {
        #expect(MCPDraft.splitArguments(#"-y "@scope/pkg" --dir 'my folder' a\ b """#) == ["-y", "@scope/pkg", "--dir", "my folder", "a b", ""])
        let args = ["-t", "stdio", "with space", "it's"]
        #expect(MCPDraft.splitArguments(MCPDraft.joinArguments(args)) == args)
    }
}
