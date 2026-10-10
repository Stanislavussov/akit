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
    /// The project's key in `~/.claude.json`: its physical path.
    var key: String { FileWalk.realPath(project) ?? project.path }
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

    /// A git checkout made of files (no git run): `project` is the main checkout, `worktree` a
    /// linked worktree of it, as `git worktree add` leaves them.
    func makeRepository() throws {
        try fm.createDirectory(at: project.appending(path: ".git/worktrees/app-feature"), withIntermediateDirectories: true)
        try write("Projects/app/.git/worktrees/app-feature/commondir", "../..\n")
        // Physical paths, as `git worktree add` writes them.
        try write("Projects/app/.git/worktrees/app-feature/gitdir", FileWalk.realPath(worktree)! + "/.git\n")
        try write("trees/app-feature/.git", "gitdir: \(FileWalk.realPath(project.appending(path: ".git/worktrees/app-feature"))!)\n")
        try fm.createDirectory(at: project.appending(path: "Sources/Deep"), withIntermediateDirectories: true)
    }

    @Test func claudeKeysByTheCanonicalGitRoot() throws {
        try makeRepository()
        let main = key
        #expect(MCPSwitches.claudeProjectKey(project) == main)
        #expect(MCPSwitches.claudeProjectKey(worktree) == main)
        #expect(MCPSwitches.claudeProjectKey(project.appending(path: "Sources/Deep")) == main)
        let outside = home.appending(path: "Notes", directoryHint: .isDirectory)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        #expect(MCPSwitches.claudeProjectKey(outside) == FileWalk.realPath(outside))
    }

    /// A linked worktree at `tree` of the git folder `common` (named `<name>` under worktrees).
    func linkWorktree(_ tree: URL, common: URL, name: String, backLink: URL? = nil) throws {
        let record = common.appending(path: "worktrees/\(name)")
        try fm.createDirectory(at: record, withIntermediateDirectories: true)
        try fm.createDirectory(at: tree, withIntermediateDirectories: true)
        try Data("../..\n".utf8).write(to: record.appending(path: "commondir"))
        // Physical paths, as `git worktree add` writes them.
        let back = backLink.map { $0.appending(path: ".git").path } ?? FileWalk.realPath(tree)! + "/.git"
        try Data((back + "\n").utf8).write(to: record.appending(path: "gitdir"))
        try Data("gitdir: \(FileWalk.realPath(record)!)\n".utf8).write(to: tree.appending(path: ".git"))
    }

    @Test func claudeKeyEdgesLikeClaudeCode() throws {
        // A bare repository's worktree: the bare folder (it holds no .git of its own).
        let bare = home.appending(path: "bare/repo.git", directoryHint: .isDirectory)
        try fm.createDirectory(at: bare, withIntermediateDirectories: true)
        let bareTree = home.appending(path: "bare/tree", directoryHint: .isDirectory)
        try linkWorktree(bareTree, common: bare, name: "tree")
        #expect(MCPSwitches.claudeProjectKey(bareTree) == FileWalk.realPath(bare))

        // A submodule: its gitdir is under .git/modules, not worktrees: its own top.
        try fm.createDirectory(at: project.appending(path: ".git/modules/sub"), withIntermediateDirectories: true)
        try write("Projects/app/sub/.git", "gitdir: ../.git/modules/sub\n")
        #expect(MCPSwitches.claudeProjectKey(project.appending(path: "sub")) == FileWalk.realPath(project.appending(path: "sub")))

        // A worktree moved without `git worktree repair`: its record points elsewhere: its own top.
        let moved = home.appending(path: "trees/moved", directoryHint: .isDirectory)
        try linkWorktree(moved, common: project.appending(path: ".git"), name: "moved", backLink: home.appending(path: "trees/old"))
        #expect(MCPSwitches.claudeProjectKey(moved) == FileWalk.realPath(moved))
        let fine = home.appending(path: "trees/fine", directoryHint: .isDirectory)
        try linkWorktree(fine, common: project.appending(path: ".git"), name: "fine")
        #expect(MCPSwitches.claudeProjectKey(fine) == key)

        // A .git file without gitdir: still the checkout's top.
        try write("Odd/.git", "not a pointer\n")
        try fm.createDirectory(at: home.appending(path: "Odd/inner"), withIntermediateDirectories: true)
        #expect(MCPSwitches.claudeProjectKey(home.appending(path: "Odd/inner")) == FileWalk.realPath(home.appending(path: "Odd")))

        // A decomposed folder name gives a precomposed (NFC) key.
        let decomposed = home.appending(path: "cafe\u{301}", directoryHint: .isDirectory)
        try fm.createDirectory(at: decomposed, withIntermediateDirectories: true)
        let nfc = MCPSwitches.claudeProjectKey(decomposed)
        #expect(nfc.hasSuffix("/caf\u{e9}") && nfc.unicodeScalars.contains("\u{e9}"))

        // /tmp is a link: Claude Code's key is the physical /private/tmp.
        let temporary = URL(filePath: "/tmp/akit-key-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }
        #expect(MCPSwitches.claudeProjectKey(temporary) == "/private" + temporary.path)
    }

    @Test func aRecordWhoseEntryIsGoneIsDroppedAndACorruptStoreIsRefused() throws {
        try claudeState()
        let github = try server("github")
        try MCPSwitches.apply(try MCPSwitches.plan(github, harness: .claudeCode, off: true, target: .projects([family]), in: env), home: home)
        // Turned on by hand, then off again with /mcp: the second entry is the user's.
        var value = try json(state)
        value.set(.array([.string("other")]), at: ["projects", key, "disabledMcpServers"])
        try Data(value.pretty.utf8).write(to: state)
        _ = status(github, .claudeCode)
        value.set(.array([.string("other"), .string("github")]), at: ["projects", key, "disabledMcpServers"])
        try Data(value.pretty.utf8).write(to: state)
        #expect(status(github, .claudeCode)?.outsideAKit.count == 1)
        let on = try MCPSwitches.plan(github, harness: .claudeCode, off: false, target: .projects([family]), in: env)
        #expect(on.changes.isEmpty && on.unmanaged.count == 1)

        try write(".akit/mcp-off.json", "{ broken")
        #expect(status(github, .claudeCode)?.unknown?.contains("mcp-off.json") == true)
        #expect(throws: MCPSwitches.Failure.self) { try MCPSwitches.plan(github, harness: .claudeCode, off: true, target: .everywhere, in: env) }
        #expect(try text(home.appending(path: ".akit/mcp-off.json")) == "{ broken")
    }

    @Test func claudeOffInProjectWritesOneEntryForTheRootAndOnRemovesIt() throws {
        try claudeState()
        try makeRepository()
        let original = try text(state)
        let github = try server("github")
        let options = try #require(MCPSwitches.options(for: github, harness: .claudeCode, in: env))
        #expect(options.modes == [.everywhere, .project])
        #expect(options.projectHelp.contains("git root"))

        // A subfolder AKit knows as a project stands for its repository's root.
        let sub = MCPSwitches.Family(main: project.appending(path: "Sources/Deep"), worktrees: [worktree])
        let plan = try MCPSwitches.plan(github, harness: .claudeCode, off: true, target: .projects([sub]), in: env)
        #expect(plan.changes.count == 1)
        // The preview shows only the changed list, never the other projects' servers or history.
        let shown = plan.changes.flatMap(\.diff).map { "\($0)" }.joined(separator: "\n")
        #expect(!shown.contains("hunter2") && !shown.contains("history") && !shown.contains("local-db"))
        try MCPSwitches.apply(plan, home: home)

        let after = try json(state)
        #expect(after.value(at: ["projects", key, "disabledMcpServers"]) == .array([.string("other"), .string("github")]))
        #expect(after.value(at: ["projects"])?.objectMembers?.count == 2)
        #expect(after.value(at: ["projects", "/somewhere/else"]) == (try JSONValue.parse(Data(original.utf8))).value(at: ["projects", "/somewhere/else"]))
        #expect(after.value(at: ["numStartups"]) == .number("42"))
        #expect(status(github, .claudeCode)?.offIn == [key])
        #expect(status(github, .claudeCode)?.outsideAKit.isEmpty == true)
        // Nothing remembered for Claude Code: its entry already covers later worktrees.
        #expect(try MCPSwitches.intents(home: home).isEmpty)
        #expect(!fm.fileExists(atPath: home.appending(path: ".claude.json.lock").path))

        let on = try MCPSwitches.plan(github, harness: .claudeCode, off: false, target: .projects([family]), in: env)
        try MCPSwitches.apply(on, home: home)
        #expect(try json(state).value(at: ["projects", key, "disabledMcpServers"]) == .array([.string("other")]))
        #expect(status(github, .claudeCode)?.isOn == true)
    }

    @Test func aWorktreeKeyClaudeCodeNeverUsesIsNotCounted() throws {
        try makeRepository()
        try write(".claude.json", """
        {"mcpServers": {"github": {"type": "http", "url": "https://x"}},
         "projects": {"\(FileWalk.realPath(worktree)!)": {"disabledMcpServers": ["github"]}}}
        """)
        #expect(status(try server("github"), .claudeCode)?.offIn == [])
    }

    @Test func newClaudeEntryIsShownWhole() throws {
        try claudeState()
        let github = try server("github")
        let fresh = MCPSwitches.Family(main: home.appending(path: "Projects/new"), worktrees: [])
        try fm.createDirectory(at: fresh.main, withIntermediateDirectories: true)
        let plan = try MCPSwitches.plan(github, harness: .claudeCode, off: true, target: .projects([fresh]), in: env)
        let shown = plan.changes.flatMap(\.diff).map { "\($0)" }.joined(separator: "\n")
        #expect(shown.contains("hasTrustDialogAccepted") && shown.contains("disabledMcpServers"))
        #expect(plan.notes.contains { $0.contains("creates Claude Code's default entry") })
    }

    @Test func entriesMadeOutsideAKitStayUnlessAsked() throws {
        try claudeState()
        let github = try server("github")
        // Turned off with /mcp: Off is a no-op and records nothing; On leaves it and says why.
        var value = try json(state)
        value.set(.array([.string("other"), .string("github")]), at: ["projects", key, "disabledMcpServers"])
        try Data(value.pretty.utf8).write(to: state)
        #expect(status(github, .claudeCode)?.outsideAKit.count == 1)
        let off = try MCPSwitches.plan(github, harness: .claudeCode, off: true, target: .projects([family]), in: env)
        #expect(off.changesNothing)
        let on = try MCPSwitches.plan(github, harness: .claudeCode, off: false, target: .all(extra: []), in: env)
        #expect(on.changes.isEmpty && on.unmanaged.count == 1)
        #expect(on.notes.contains { $0.contains("outside AKit") })
        let forced = try MCPSwitches.plan(github, harness: .claudeCode, off: false, target: .all(extra: []), includeUnmanaged: true, in: env)
        try MCPSwitches.apply(forced, home: home)
        #expect(try json(state).value(at: ["projects", key, "disabledMcpServers"]) == .array([.string("other")]))
    }

    @Test func toolDenyRulesShowAsPartlyDenied() throws {
        try claudeState()
        try write(".claude/settings.json", #"{"permissions": {"deny": ["mcp__github__create_issue"]}}"#)
        let status = try #require(status(try server("github"), .claudeCode))
        #expect(status.partlyDenied == ["mcp__github__create_issue"] && status.isOn && status.title == "On, Partly Denied")
    }

    @Test func aProjectsOwnServerCountsOnlyItsProject() throws {
        try claudeState()
        try write("Projects/app/.mcp.json", #"{"mcpServers": {"docs": {"command": "docs-mcp"}}}"#)
        // Another project turned a server of the same name off: not this one's state, and On leaves it.
        var value = try json(state)
        value.set(.array([.string("docs")]), at: ["projects", "/somewhere/else", "disabledMcpServers"])
        try Data(value.pretty.utf8).write(to: state)
        let docs = try server("docs", file: ".mcp.json")
        #expect(status(docs, .claudeCode)?.offIn == [])
        let on = try MCPSwitches.plan(docs, harness: .claudeCode, off: false, target: .all(extra: []), includeUnmanaged: true, in: env)
        #expect(on.changes.isEmpty)
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
        changed.set(.array([.string("x")]), at: ["projects", key, "disabledMcpServers"])
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
        try MCPSwitches.apply(try MCPSwitches.plan(github, harness: .claudeCode, off: false, target: .all(extra: []), in: env), home: home)
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

}
