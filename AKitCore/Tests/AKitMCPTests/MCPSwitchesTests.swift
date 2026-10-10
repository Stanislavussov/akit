import Foundation
import Testing
import AKitFoundation
import AKitHarnesses
import AKitModel
@testable import AKitMCP

/// MCP switches in a temporary fake home: Claude Code's deny rule and `disabledMcpServers`,
/// Pi's `enabled: false`, the connectors key, remembered projects. Never touches the real one.
struct MCPSwitchesTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-mcp-switch-\(UUID().uuidString)")
        try fm.createDirectory(at: home.appending(path: ".pi/agent"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appending(path: ".claude"), withIntermediateDirectories: true)
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        try fm.createDirectory(at: worktree, withIntermediateDirectories: true)
    }

    var env: HarnessEnvironment { HarnessEnvironment(homeDirectory: home) }
    var project: URL { home.appending(path: "Projects/app", directoryHint: .isDirectory) }
    var worktree: URL { home.appending(path: "trees/app-feature", directoryHint: .isDirectory) }
    var family: MCPSwitches.Family { .init(main: project, worktrees: [worktree]) }
    var state: URL { home.appending(path: ".claude.json") }
    var settings: URL { home.appending(path: ".claude/settings.json") }

    func write(_ path: String, _ text: String) throws {
        let url = home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
    func json(_ url: URL) throws -> JSONValue { try JSONValue.parse(Data(contentsOf: url)) }

    func servers() -> [MCPServer] {
        MCPScanner.scan(installations: HarnessCatalog.detectAll(in: env), projects: [project], in: env).servers
    }

    func server(_ name: String, file: String? = nil) throws -> MCPServer {
        try #require(servers().first { $0.name == name && (file == nil || $0.file.path.hasSuffix(file!)) })
    }

    func status(_ server: MCPServer, _ harness: HarnessID) -> MCPSwitches.Status? {
        MCPSwitches.statuses(of: [server], projects: [project, worktree], in: env)[server.id]?[harness]
    }

    /// Several projects, one worktree path already known, history Claude Code keeps.
    func claudeState() throws {
        let key = project.standardizedFileURL.path
        try write(".claude.json", """
        {
          "numStartups": 42,
          "mcpServers": {"github": {"type": "http", "url": "https://api.example.com/mcp", "headers": {"Authorization": "Bearer ${TOKEN}"}}},
          "projects": {
            "\(key)": {"allowedTools": [], "history": [{"display": "hi"}], "disabledMcpServers": ["other"]},
            "/somewhere/else": {"allowedTools": ["Bash"], "mcpServers": {"local-db": {"command": "db", "env": {"PASSWORD": "hunter2"}}}}
          }
        }
        """)
    }

    // MARK: - Claude Code

    @Test func claudeOffInProjectReachesEveryWorktreeAndOnRemovesIt() throws {
        try claudeState()
        let original = try text(state)
        let github = try server("github")
        let options = try #require(MCPSwitches.options(for: github, harness: .claudeCode, in: env))
        #expect(options.modes == [.everywhere, .project])

        let plan = try MCPSwitches.plan(github, harness: .claudeCode, off: true, target: .projects([family]), in: env)
        #expect(plan.changes.count == 1)
        // The preview shows only the changed lists, never the other projects' servers or history.
        let shown = plan.changes.flatMap(\.diff).map { "\($0)" }.joined(separator: "\n")
        #expect(!shown.contains("hunter2") && !shown.contains("history") && !shown.contains("local-db"))
        try MCPSwitches.apply(plan, home: home)

        let after = try json(state)
        let key = project.standardizedFileURL.path, tree = worktree.standardizedFileURL.path
        #expect(after.value(at: ["projects", key, "disabledMcpServers"]) == .array([.string("other"), .string("github")]))
        #expect(after.value(at: ["projects", tree, "disabledMcpServers"]) == .array([.string("github")]))
        #expect(after.value(at: ["projects", tree, "allowedTools"]) == .array([]))
        #expect(after.value(at: ["projects", "/somewhere/else"]) == (try JSONValue.parse(Data(original.utf8))).value(at: ["projects", "/somewhere/else"]))
        #expect(after.value(at: ["numStartups"]) == .number("42"))
        #expect(status(github, .claudeCode)?.offIn == [key, tree].sorted())
        #expect(MCPSwitches.intents(home: home) == [.init(harness: "claude-code", server: "github", project: key)])

        let on = try MCPSwitches.plan(github, harness: .claudeCode, off: false, target: .projects([family]), in: env)
        try MCPSwitches.apply(on, home: home)
        let back = try json(state)
        #expect(back.value(at: ["projects", key, "disabledMcpServers"]) == .array([.string("other")]))
        #expect(back.value(at: ["projects", tree, "disabledMcpServers"]) == .array([]))
        #expect(MCPSwitches.intents(home: home).isEmpty)
        #expect(status(github, .claudeCode)?.isOn == true)
    }

    @Test func claudeStateFileRewrittenMeanwhileIsFineUnlessTheEntryChanged() throws {
        try claudeState()
        let github = try server("github")
        let plan = try MCPSwitches.plan(github, harness: .claudeCode, off: true, target: .projects([family]), in: env)
        // Claude Code rewrites its file (another key changes): the plan still applies on the fresh text.
        var value = try json(state)
        value.set(.number("43"), at: ["numStartups"])
        try Data(value.pretty.utf8).write(to: state)
        try MCPSwitches.apply(plan, home: home)
        #expect(try json(state).value(at: ["numStartups"]) == .number("43"))

        // The touched list changed after the preview: refused, nothing written.
        let again = try MCPSwitches.plan(github, harness: .claudeCode, off: false, target: .projects([family]), in: env)
        var changed = try json(state)
        changed.set(.array([.string("x")]), at: ["projects", project.standardizedFileURL.path, "disabledMcpServers"])
        try Data(changed.pretty.utf8).write(to: state)
        let before = try text(state)
        #expect(throws: MCPSwitches.Failure.self) { try MCPSwitches.apply(again, home: home) }
        #expect(try text(state) == before)
    }

    @Test func claudeOffEverywhereIsADenyRule() throws {
        try claudeState()
        try write(".claude/settings.json", "{\n  \"permissions\": {\n    \"allow\": [\"Bash(ls)\"]\n  },\n  \"apiKeyHelper\": \"print-key\"\n}\n")
        let original = try text(settings)
        let github = try server("github")
        let plan = try MCPSwitches.plan(github, harness: .claudeCode, off: true, target: .everywhere, in: env)
        #expect(!plan.changes.flatMap(\.diff).map { "\($0)" }.joined().contains("print-key"))
        try MCPSwitches.apply(plan, home: home)
        #expect(try json(settings).value(at: ["permissions", "deny"]) == .array([.string("mcp__github")]))
        #expect(status(github, .claudeCode)?.offEverywhere == true)
        try MCPSwitches.apply(try MCPSwitches.plan(github, harness: .claudeCode, off: false, target: .all, in: env), home: home)
        #expect(try text(settings) == original)
        #expect(MCPSwitches.denyRule("my.server/x") == "mcp__my_server_x")
    }

    @Test func projectServersOnlyOffInTheirProjectAndPluginsNotAtAll() throws {
        try claudeState()
        try write("Projects/app/.mcp.json", #"{"mcpServers": {"docs": {"command": "docs-mcp"}}}"#)
        let docs = try server("docs", file: ".mcp.json")
        let options = try #require(MCPSwitches.options(for: docs, harness: .claudeCode, in: env))
        #expect(options.modes == [.project])
        #expect(throws: MCPSwitches.Failure.self) { try MCPSwitches.plan(docs, harness: .claudeCode, off: true, target: .everywhere, in: env) }
        let elsewhere = MCPSwitches.Family(main: home.appending(path: "Projects/other"), worktrees: [])
        #expect(throws: MCPSwitches.Failure.self) { try MCPSwitches.plan(docs, harness: .claudeCode, off: true, target: .projects([elsewhere]), in: env) }

        let plugin = MCPServer(name: "p", file: home.appending(path: "plugin/.mcp.json"), keyPath: ["mcpServers"], scope: .plugin(name: "x"),
                               transport: .stdio, command: "p", arguments: [], url: nil, workingDirectory: nil, environment: [], headers: [],
                               variables: [], uses: [MCPUse(harness: .claudeCode, layer: "Plugin", precedence: 0, state: .active)],
                               isReadOnly: true, warnings: [])
        #expect(MCPSwitches.options(for: plugin, harness: .claudeCode, in: env)?.unavailable?.contains("/plugin") == true)
    }

    @Test func connectorsKey() throws {
        try write(".claude/settings.json", "{\"model\": \"opus\"}\n")
        #expect(MCPSwitches.connectorsOff(in: env) == false)
        try MCPSwitches.apply(try MCPSwitches.connectorsPlan(off: true, in: env), home: home)
        #expect(try text(settings) == "{\"model\": \"opus\", \"disableClaudeAiConnectors\": true}\n")
        #expect(MCPSwitches.connectorsOff(in: env) == true)
        try MCPSwitches.apply(try MCPSwitches.connectorsPlan(off: false, in: env), home: home)
        #expect(try text(settings) == "{\"model\": \"opus\"}\n")
        try write(".claude/settings.json", "{ broken")
        #expect(MCPSwitches.connectorsOff(in: env) == nil)
    }

    // MARK: - Pi

    @Test func piOffEverywhereAndInProject() throws {
        let original = "{\n  \"mcpServers\": {\n    \"search\": {\n      \"command\": \"search-mcp\",\n      \"env\": {\"KEY\": \"secret-value\"}\n    }\n  }\n}\n"
        try write(".pi/agent/mcp.json", original)
        let search = try server("search", file: ".pi/agent/mcp.json")
        #expect(MCPSwitches.options(for: search, harness: .pi, in: env)?.modes == [.everywhere, .project])

        let everywhere = try MCPSwitches.plan(search, harness: .pi, off: true, target: .everywhere, in: env)
        #expect(!everywhere.changes.flatMap(\.diff).map { "\($0)" }.joined().contains("secret-value"))
        try MCPSwitches.apply(everywhere, home: home)
        #expect(try json(home.appending(path: ".pi/agent/mcp.json")).value(at: ["mcpServers", "search", "enabled"]) == .bool(false))
        try MCPSwitches.apply(try MCPSwitches.plan(search, harness: .pi, off: false, target: .everywhere, in: env), home: home)
        #expect(try text(home.appending(path: ".pi/agent/mcp.json")) == original)

        // In a project: an override in each folder's .pi/mcp.json; the worktree's own file keeps its other servers.
        try write("trees/app-feature/.pi/mcp.json", "{\n  \"mcpServers\": {\n    \"mine\": {\"command\": \"m\"}\n  }\n}\n")
        try MCPSwitches.apply(try MCPSwitches.plan(search, harness: .pi, off: true, target: .projects([family]), in: env), home: home)
        #expect(try json(project.appending(path: ".pi/mcp.json")) == .object(["mcpServers": .object(["search": .object(["enabled": .bool(false)])])]))
        #expect(try json(worktree.appending(path: ".pi/mcp.json")).value(at: ["mcpServers", "mine"]) != nil)
        #expect(try json(worktree.appending(path: ".pi/mcp.json")).value(at: ["mcpServers", "search"]) == .object(["enabled": .bool(false)]))
        #expect(status(search, .pi)?.offIn.count == 2)
        try MCPSwitches.apply(try MCPSwitches.plan(search, harness: .pi, off: false, target: .projects([family]), in: env), home: home)
        #expect(try text(worktree.appending(path: ".pi/mcp.json")) == "{\n  \"mcpServers\": {\n    \"mine\": {\"command\": \"m\"}\n  }\n}\n")
    }

    @Test func piProjectServerIsTurnedOffInItsOwnEntry() throws {
        try write("Projects/app/.pi/mcp.json", #"{"mcpServers": {"lint": {"command": "lint-mcp"}}}"#)
        let lint = try server("lint", file: "Projects/app/.pi/mcp.json")
        #expect(MCPSwitches.options(for: lint, harness: .pi, in: env)?.modes == [.project])
        let plan = try MCPSwitches.plan(lint, harness: .pi, off: true, target: .projects([family]), in: env)
        // No override for the worktree: there is no user-level lint for it to override.
        #expect(plan.skipped == [worktree.standardizedFileURL.path])
        try MCPSwitches.apply(plan, home: home)
        #expect(try text(project.appending(path: ".pi/mcp.json")) == #"{"mcpServers": {"lint": {"command": "lint-mcp", "enabled": false}}}"#)
    }

    // MARK: - Later worktrees

    @Test func newWorktreesGetTheRememberedEntries() throws {
        try claudeState()
        let github = try server("github")
        try MCPSwitches.apply(try MCPSwitches.plan(github, harness: .claudeCode, off: true,
                                                   target: .projects([.init(main: project, worktrees: [])]), in: env), home: home)
        let later = home.appending(path: "trees/app-later", directoryHint: .isDirectory)
        let result = MCPSwitches.syncWorktrees([.init(main: project, worktrees: [later])], in: env)
        #expect(result.problems.isEmpty && result.added.count == 1)
        #expect(try json(state).value(at: ["projects", later.standardizedFileURL.path, "disabledMcpServers"]) == .array([.string("github")]))
        // Nothing left to add: a second sync writes nothing.
        let backups = (try? fm.contentsOfDirectory(atPath: home.appending(path: ".akit/backups").path).count) ?? 0
        #expect(MCPSwitches.syncWorktrees([.init(main: project, worktrees: [later])], in: env).added.isEmpty)
        #expect(((try? fm.contentsOfDirectory(atPath: home.appending(path: ".akit/backups").path).count) ?? 0) == backups)
    }
}
