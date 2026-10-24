import Foundation
import Testing
import AKitFoundation
import AKitHarnesses
import AKitModel
@testable import AKitMCP

/// The connection check: the harnesses' answers as Claude Code 2.1.310 and Pi 1.0.4 print
/// them, and a whole run with a fake login shell, `claude` and `pi` in a temporary home.
struct MCPCheckTests {
    let home: URL
    let fm = FileManager.default
    let date = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-mcp-check-\(UUID().uuidString)")
        try fm.createDirectory(at: home.appending(path: "bin"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appending(path: ".claude"), withIntermediateDirectories: true)
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
    }

    var project: URL { home.appending(path: "Projects/app", directoryHint: .isDirectory) }

    // MARK: Claude Code

    @Test func claudeGetConnected() {
        let output = """
        kosik:
          Scope: User config (available in all your projects)
          Status: ✔ Connected
          Type: http
          URL: https://mcp.kosik.cz/mcp/

        To remove this server, run: claude mcp remove kosik -s user
        """
        let result = MCPCheck.parseClaudeGet(output, name: "kosik", folder: "/x", checkedAt: date)
        #expect(result.state == .connected)
        #expect(result.detail == nil)
    }

    @Test func claudeGetFailedReadsOnlyStatusAndIssue() {
        let output = """
        needvar:
          Scope: User config (available in all your projects)
          Status: ✘ Failed to connect
          Issue: CONNECTION_CLOSED: Connection closed
          Type: stdio
          Command: /bin/sh
          Args: -c exit 1
          Environment:
            TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123456789

        To remove this server, run: claude mcp remove needvar -s user
        """
        let result = MCPCheck.parseClaudeGet(output, name: "needvar", folder: "/x", checkedAt: date)
        #expect(result.state == .failed)
        #expect(result.detail == "Failed to connect: CONNECTION_CLOSED: Connection closed")
        #expect(result.detail?.contains("ghp_") == false)
    }

    @Test func claudeGetOtherStates() {
        func state(_ status: String) -> MCPCheckResult.State {
            MCPCheck.parseClaudeGet("x:\n  Status: \(status)\n", name: "x", folder: "/x", checkedAt: date).state
        }
        #expect(state("⏸ Pending approval (run `claude` to approve)") == .pendingApproval)
        #expect(state("! Needs authentication") == .needsSignIn)
        #expect(state("! Connected · tools fetch failed") == .failed)
        #expect(state("- Not configured") == .failed)
        #expect(MCPCheck.parseClaudeGet("No MCP server named \"x\". Configured servers: a", name: "x", folder: "/x",
                                        checkedAt: date).state == .notFound)
    }

    @Test func claudeListLines() {
        let output = """
        Checking MCP server health…

        claude.ai Canva: https://mcp.canva.com/mcp - ! Needs authentication
        broken: /bin/sh -c echo boom >&2; exit 3 - ✘ Failed to connect — CONNECTION_CLOSED: Connection closed
        dash-in-args: npx -y tool - x - ✔ Connected
        shared: /bin/true  - ⏸ Pending approval (run `claude` to approve)
        kosik: https://mcp.kosik.cz/mcp/ (HTTP) - ✔ Connected
        """
        let results = MCPCheck.parseClaudeList(output, names: ["broken", "dash-in-args", "shared", "kosik", "absent"],
                                               folder: "/x", checkedAt: date)
        let byName = Dictionary(uniqueKeysWithValues: results.map { ($0.name, $0) })
        #expect(byName["broken"]?.state == .failed)
        #expect(byName["broken"]?.detail == "Failed to connect: CONNECTION_CLOSED: Connection closed")
        #expect(byName["dash-in-args"]?.state == .connected)
        #expect(byName["shared"]?.state == .pendingApproval)
        #expect(byName["kosik"]?.state == .connected)
        #expect(byName["absent"] == nil)
    }

    // MARK: Pi

    @Test func piListJSON() throws {
        let output = """
        {
          "servers": [
            {"name": "broken", "scope": "global", "enabled": true, "exposure": "codemode", "transport": "/bin/sh",
             "state": "failed", "tools": [], "error": "MCP connection closed\\nboom"},
            {"name": "needvar", "enabled": true, "state": "failed", "tools": [],
             "error": "Failed to resolve MCP server \\"needvar\\" env \\"TOKEN\\" from environment variable: MISSING_TOKEN_X"},
            {"name": "off", "enabled": false, "exposure": "codemode", "state": "disabled", "tools": []},
            {"name": "docs", "enabled": true, "exposure": "codemode", "state": "connected", "tools": ["search", "read"],
             "toolExposure": {"read": "direct"}},
            {"name": "oauth", "enabled": true, "state": "needs-auth", "tools": []}
          ],
          "errors": []
        }
        """
        let results = try #require(MCPCheck.parsePiList(output, folder: "/x", checkedAt: date))
        let byName = Dictionary(uniqueKeysWithValues: results.map { ($0.name, $0) })
        #expect(byName["broken"]?.state == .failed)
        #expect(byName["broken"]?.detail == "MCP connection closed\nboom")
        #expect(byName["off"]?.state == .off)
        #expect(byName["docs"]?.state == .connected)
        #expect(byName["docs"]?.tools == ["search", "read"])
        #expect(byName["docs"]?.exposure == "codemode")
        #expect(byName["docs"]?.toolExposure == ["read": "direct"])
        #expect(byName["oauth"]?.state == .needsSignIn)
        #expect(MCPCheck.parsePiList("zsh: no job control\nnot json", folder: "/x", checkedAt: date) == nil)
    }

    // MARK: Review fixes

    @Test func issueTextThatLooksLikeAStatusDoesntHideTheStatus() {
        let line = "x: cmd - ✘ Failed to connect — error - ! foo"
        #expect(MCPCheck.claudeStatusPart(line) == "✘ Failed to connect — error - ! foo")
        let results = MCPCheck.parseClaudeList(line, names: ["x"], folder: "/x", checkedAt: date)
        #expect(results.first?.state == .failed)
    }

    @Test func piJSONAfterAnotherJSONLine() throws {
        let output = "{\"warning\": \"old config\"}\n{\"servers\": [{\"name\": \"p\", \"enabled\": true, \"state\": \"connected\", \"tools\": []}]}"
        let results = try #require(MCPCheck.parsePiList(output, folder: "/x", checkedAt: date))
        #expect(results.map(\.state) == [.connected])
    }

    @Test func missingVariablesKeepAStateWithItsOwnFix() async throws {
        let env = try fakeTools(claude: "x:\n  Status: ⏸ Pending approval (run `claude` to approve)", pi: "")
        let results = await MCPCheck.run([MCPCheck.Request(harness: .claudeCode, folder: home, names: ["x"], variables: ["x": ["NOWHERE_TOKEN"]])], in: env, shellTimeout: 120)
        #expect(results.first?.state == .pendingApproval)
        #expect(results.first?.missingVariables == ["NOWHERE_TOKEN"])
    }

    // MARK: Requests

    @Test func requestsGroupByHarnessAndFolder() throws {
        try write(".claude.json", #"{"mcpServers":{"g":{"command":"g-server","env":{"T":"${G_TOKEN}"}}}}"#)
        try write(".pi/agent/mcp.json", #"{"mcpServers":{"g":{"command":"g-server"}}}"#)
        try write("Projects/app/.pi/mcp.json", #"{"mcpServers":{"p":{"command":"p-server"}}}"#)
        let servers = scan()
        let requests = MCPCheck.requests(for: servers, context: nil, home: home)
        let claudeHome = try #require(requests.first { $0.harness == .claudeCode })
        #expect(claudeHome.folder.path == home.path)
        #expect(claudeHome.names == ["g"])
        #expect(claudeHome.variables["g"] == ["G_TOKEN"])
        let piProject = try #require(requests.first { $0.harness == .pi && $0.folder.standardizedFileURL == project.standardizedFileURL })
        #expect(piProject.names == ["p"])
        // A chosen project: global servers are checked there too.
        let inProject = MCPCheck.requests(for: servers, harness: .pi, context: project, home: home)
        #expect(inProject.count == 1)
        #expect(Set(inProject[0].names) == ["g", "p"])
    }

    // MARK: A whole run

    /// A login shell that prints noise first and exports one variable; `claude` and `pi`
    /// that write the folder they ran in and answer like the real ones.
    func fakeTools(claude: String, pi: String) throws -> HarnessEnvironment {
        try script("bin/fake-shell", """
        #!/bin/sh
        echo "Welcome to zsh"
        export SHELL_ONLY_TOKEN=from-shell
        shift 3
        exec /bin/sh -c "$1"
        """)
        try script("bin/claude", "#!/bin/sh\npwd -P > \"$HOME/claude-cwd\"\necho \"$*\" > \"$HOME/claude-args\"\ncat <<'EOF'\n\(claude)\nEOF\n")
        try script("bin/pi", "#!/bin/sh\npwd -P > \"$HOME/pi-cwd\"\ncat <<'EOF'\n\(pi)\nEOF\nexit 1\n")
        return HarnessEnvironment(homeDirectory: home, variables: ["SHELL": home.appending(path: "bin/fake-shell").path],
                                  executableSearchPaths: [home.appending(path: "bin")])
    }

    @Test func runUsesTheShellEnvironmentAndTheServersFolder() async throws {
        let env = try fakeTools(claude: "x:\n  Status: ✘ Failed to connect\n  Issue: CONNECTION_CLOSED: Connection closed",
                                pi: #"{"servers":[{"name":"p","enabled":true,"state":"connected","tools":["a"]}],"errors":[]}"#)
        let requests = [
            MCPCheck.Request(harness: .claudeCode, folder: home, names: ["x"], variables: ["x": ["SHELL_ONLY_TOKEN", "NOWHERE_TOKEN"]]),
            MCPCheck.Request(harness: .pi, folder: project, names: ["p"]),
        ]
        let results = await MCPCheck.run(requests, in: env, shellTimeout: 120, now: { Date(timeIntervalSince1970: 1_800_000_000) })
        let claude = try #require(results.first { $0.harness == HarnessID.claudeCode.rawValue })
        #expect(claude.state == .missingVariables)
        #expect(claude.missingVariables == ["NOWHERE_TOKEN"])
        #expect(try String(contentsOf: home.appending(path: "claude-args"), encoding: .utf8) == "mcp get x\n")
        #expect(try String(contentsOf: home.appending(path: "claude-cwd"), encoding: .utf8) == (FileWalk.realPath(home) ?? home.path) + "\n")
        let pi = try #require(results.first { $0.harness == HarnessID.pi.rawValue })
        #expect(pi.state == .connected)
        #expect(pi.tools == ["a"])
        #expect(try String(contentsOf: home.appending(path: "pi-cwd"), encoding: .utf8) == (FileWalk.realPath(project) ?? project.path) + "\n")

        try MCPCheckStore.save(results, home: home)
        let loaded = MCPCheckStore.load(home: home)
        #expect(loaded[claude.id]?.state == .missingVariables)
        #expect(loaded[pi.id]?.checkedAt == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func piUntrustedProjectIsNotAFailure() async throws {
        let env = try fakeTools(claude: "", pi: #"{"servers":[],"errors":[],"note":"/x/.pi/mcp.json is ignored because the project is not trusted."}"#)
        let results = await MCPCheck.run([MCPCheck.Request(harness: .pi, folder: project, names: ["p"])], in: env, shellTimeout: 120)
        #expect(results.map(\.state) == [.untrustedProject])
    }

    @Test func missingCommandSaysSo() async throws {
        let env = HarnessEnvironment(homeDirectory: home, variables: ["SHELL": "/nonexistent/shell"], executableSearchPaths: [])
        let results = await MCPCheck.run([MCPCheck.Request(harness: .pi, folder: home, names: ["p"])], in: env)
        #expect(results.first?.state == .failed)
        #expect(results.first?.detail?.contains("can't find the pi command") == true)
        #expect(results.first?.detail?.contains("login shell") == true)
    }

    // MARK: Helpers

    func write(_ path: String, _ text: String) throws {
        let url = home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func script(_ path: String, _ text: String) throws {
        try write(path, text)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.appending(path: path).path)
    }

    func scan() -> [MCPServer] {
        let env = HarnessEnvironment(homeDirectory: home)
        return MCPScanner.scan(installations: HarnessCatalog.detectAll(in: env), projects: [project], in: env).servers
    }
}

/// Approve…: one key of `.claude/settings.local.json`, never the rest of the file.
struct MCPApproveTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-mcp-approve-\(UUID().uuidString)")
        try fm.createDirectory(at: project.appending(path: ".claude"), withIntermediateDirectories: true)
    }

    var project: URL { home.appending(path: "Projects/app", directoryHint: .isDirectory) }
    var env: HarnessEnvironment { HarnessEnvironment(homeDirectory: home, executableSearchPaths: [URL(filePath: "/usr/bin")]) }

    @Test func addsTheNameAndShowsOnlyThatKey() throws {
        let file = MCPApprove.file(in: project)
        try Data(#"{"env": {"API_TOKEN": "sk-live-abcdefghijklmnopqrstuvwxyz012345"}, "enabledMcpjsonServers": ["other"]}"#.utf8).write(to: file)
        let plan = try MCPApprove.plan("shared", project: project, env: env)
        let shown = plan.change.diff.map { "\($0)" }.joined(separator: "\n")
        #expect(shown.contains("shared"))
        #expect(!shown.contains("sk-live"))
        #expect(!shown.contains("API_TOKEN"))
        _ = try MCPApprove.apply(plan, home: home)
        let saved = try JSONValue.parse(Data(contentsOf: file))
        #expect(saved.value(at: ["enabledMcpjsonServers"]) == .array([.string("other"), .string("shared")]))
        #expect(saved.value(at: ["env", "API_TOKEN"]) == .string("sk-live-abcdefghijklmnopqrstuvwxyz012345"))
        #expect(throws: SettingsFile.Failure.self) { try MCPApprove.plan("shared", project: project, env: env) }
    }

    @Test func aKeyThatIsNoListIsRefused() throws {
        try Data(#"{"enabledMcpjsonServers": "shared"}"#.utf8).write(to: MCPApprove.file(in: project))
        #expect(throws: SettingsFile.Failure.self) { try MCPApprove.plan("other", project: project, env: env) }
    }

    @Test func createsTheFileWhenMissing() throws {
        let plan = try MCPApprove.plan("shared", project: project, env: env)
        #expect(plan.change.creates)
        _ = try MCPApprove.apply(plan, home: home)
        #expect(try JSONValue.parse(Data(contentsOf: MCPApprove.file(in: project))).value(at: ["enabledMcpjsonServers"]) == .array([.string("shared")]))
    }

    @Test func aTrackedFileIsNamed() throws {
        let git = URL(filePath: "/usr/bin/git")
        for args in [["init", "-q"], ["add", "-f", ".claude/settings.local.json"]] {
            if args[0] == "add" { try Data("{}".utf8).write(to: MCPApprove.file(in: project)) }
            #expect(ProcessRunner.runAndWait(git, arguments: args, directory: project, environment: env.gitVariables, timeout: 30)?.succeeded == true)
        }
        let plan = try MCPApprove.plan("shared", project: project, env: env)
        #expect(plan.notes.first?.contains("Git tracks this file") == true)
        #expect(plan.notes.contains { $0.contains("doesn't trust this folder") })
    }

    @Test func aTrustedFolderGetsNoTrustNote() throws {
        let key = MCPSwitches.claudeProjectKey(project)
        try Data(#"{"projects": {"\#(key)": {"hasTrustDialogAccepted": true}}}"#.utf8).write(to: home.appending(path: ".claude.json"))
        let plan = try MCPApprove.plan("shared", project: project, env: env)
        #expect(!plan.notes.contains { $0.contains("doesn't trust") })
    }
}
