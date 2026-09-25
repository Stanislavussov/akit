import Foundation
import Testing
@testable import AKitCore

/// MCP discovery in a temporary fake home. Never touches the real one.
struct MCPTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-mcp-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var env: HarnessEnvironment { HarnessEnvironment(homeDirectory: home) }
    var project: URL { home.appending(path: "Projects/app", directoryHint: .isDirectory) }

    func write(_ path: String, _ text: String) throws {
        let url = home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func scan() -> MCPScanResult {
        try? fm.createDirectory(at: project, withIntermediateDirectories: true)
        return MCPScanner.scan(installations: HarnessCatalog.detectAll(in: env), projects: [project], in: env)
    }

    @Test func claudeLayersApprovalAndOverride() throws {
        let key = project.standardizedFileURL.path
        try write(".claude/settings.json", "{}")
        try write(".claude.json", """
        {"mcpServers": {"github": {"type": "http", "url": "https://api.example.com/mcp",
                                   "headers": {"Authorization": "Bearer ${GITHUB_TOKEN}"}}},
         "projects": {"\(key)": {"mcpServers": {"grafana": {"command": "mcp-grafana",
                                                             "env": {"GRAFANA_SERVICE_ACCOUNT_TOKEN": "glsa_realsecretvalue123"}}},
                                 "disabledMcpjsonServers": ["db"]}}}
        """)
        try write("Projects/app/.mcp.json", """
        {"mcpServers": {"grafana": {"command": "/opt/homebrew/bin/mcp-grafana", "args": ["-t", "stdio"],
                                    "env": {"GRAFANA_URL": "https://grafana.example.com",
                                            "GRAFANA_SERVICE_ACCOUNT_TOKEN": "${GRAFANA_SERVICE_ACCOUNT_TOKEN}"}},
                        "db": {"command": "db-mcp"}, "docs": {"command": "docs-mcp"}}}
        """)
        try write("Projects/app/.claude/settings.local.json", #"{"enabledMcpjsonServers": ["grafana"]}"#)

        let servers = scan().servers
        let github = try #require(servers.first { $0.name == "github" })
        #expect(github.scope == .global)
        #expect(github.transport == .http)
        #expect(github.headers == [MCPSetting(key: "Authorization", value: .reference("Bearer ${GITHUB_TOKEN}"))])
        #expect(github.variables == ["GITHUB_TOKEN"])
        #expect(github.uses.map(\.layer) == ["User"])

        let local = try #require(servers.first { $0.name == "grafana" && $0.keyPath.first == "projects" })
        #expect(local.uses.first?.state == .active)
        #expect(local.environment == [MCPSetting(key: "GRAFANA_SERVICE_ACCOUNT_TOKEN", value: .hidden)])
        #expect(local.variables.isEmpty)

        let shared = try #require(servers.first { $0.name == "grafana" && $0.file.lastPathComponent == ".mcp.json" })
        #expect(shared.uses.first?.state == .shadowed(by: "Local (~/.claude.json)"))
        #expect(shared.arguments == ["-t", "stdio"])
        #expect(shared.environment.map(\.value) == [.reference("${GRAFANA_SERVICE_ACCOUNT_TOKEN}"), .hidden])
        #expect(shared.variables == ["GRAFANA_SERVICE_ACCOUNT_TOKEN"])

        #expect(servers.first { $0.name == "db" }?.uses.first?.state == .rejected)
        #expect(servers.first { $0.name == "docs" }?.uses.first?.state == .needsApproval)
    }

    @Test func sharedProjectFileIsOneEntryForClaudeAndPi() throws {
        try write(".claude/settings.json", "{}")
        try write(".pi/agent/settings.json", #"{"packages": ["npm:pi-mcp-adapter"]}"#)
        try write("Projects/app/.mcp.json", #"{"mcpServers": {"figma": {"url": "https://mcp.figma.com/mcp"}}}"#)

        let servers = scan().servers.filter { $0.name == "figma" }
        #expect(servers.count == 1)
        #expect(servers.first?.usedBy == [.claudeCode, .pi])
    }

    @Test func piWithoutAdapterListsOnlyItsOwnFilesAsNotLoaded() throws {
        try write(".pi/agent/settings.json", #"{"packages": ["npm:pi-subagents"]}"#)
        try write(".pi/agent/mcp.json", """
        {"mcpServers": {"figma": {"url": "https://mcp.figma.com/mcp", "lifecycle": "lazy",
                                  "env": {"TOKEN": "!security find-generic-password -s figma -w"}}}}
        """)
        try write("Projects/app/.mcp.json", #"{"mcpServers": {"x": {"command": "x"}}}"#)

        let servers = scan().servers
        let figma = try #require(servers.first { $0.name == "figma" })
        #expect(figma.uses.first?.state == .inactive("Needs the pi-mcp-adapter package"))
        #expect(figma.environment.first?.value == .command("security find-generic-password -s figma -w"))
        #expect(servers.first { $0.name == "x" } == nil) // Claude isn't installed, Pi doesn't read it
    }

    @Test func codexTomlServersAndTrust() throws {
        let key = project.standardizedFileURL.path
        try write(".codex/config.toml", """
        model = "gpt-5" # comment
        [projects."\(key)"]
        trust_level = "trusted"

        [[skills.config]]
        path = "/x"
        enabled = false

        [mcp_servers.docs]
        command = "npx"
        args = [
          "-y", # the package
          "docs-mcp",
        ]
        env = { API_KEY = "sk-live-abcdefghijklmnop", MODE = 'fast' }
        enabled = false

        [mcp_servers.linear]
        url = "https://mcp.linear.app/mcp"
        bearer_token_env_var = "LINEAR_TOKEN"
        """)
        try write("Projects/app/.codex/config.toml", """
        [mcp_servers.local]
        command = "local-mcp"
        """)

        let servers = scan().servers
        let docs = try #require(servers.first { $0.name == "docs" })
        #expect(docs.command == "npx")
        #expect(docs.arguments == ["-y", "docs-mcp"])
        #expect(docs.environment.map(\.value) == [.hidden, .hidden])
        #expect(docs.uses.first?.state == .disabled)
        let linear = try #require(servers.first { $0.name == "linear" })
        #expect(linear.variables == ["LINEAR_TOKEN"])
        #expect(linear.headers == [MCPSetting(key: "Authorization", value: .reference("Bearer ${LINEAR_TOKEN}"))])
        #expect(servers.first { $0.name == "local" }?.uses.first?.state == .active)
    }

    @Test func untrustedCodexProjectIsNotLoaded() throws {
        try write(".codex/config.toml", "")
        try write("Projects/app/.codex/config.toml", "[mcp_servers.local]\ncommand = \"local-mcp\"\n")
        let local = try #require(scan().servers.first { $0.name == "local" })
        #expect(local.uses.first?.state == .inactive("Codex reads it only in trusted projects"))
    }

    @Test func openCodeJSONCWithComments() throws {
        try write(".config/opencode/opencode.jsonc", """
        {
          // servers
          "mcp": {
            "jira": {"type": "remote", "url": "https://jira.example.com/mcp?api_key=abc123secret&project=X",
                     "headers": {"Authorization": "Bearer {env:JIRA_TOKEN}"}, /* note */ },
            "fs": {"type": "local", "command": ["npx", "fs-mcp", "--token", "tok_1234567890"], "enabled": false,},
          },
        }
        """)
        let servers = scan().servers
        let jira = try #require(servers.first { $0.name == "jira" })
        #expect(jira.url == "https://jira.example.com/mcp?api_key=hidden&project=X")
        #expect(jira.variables == ["JIRA_TOKEN"])
        let fs = try #require(servers.first { $0.name == "fs" })
        #expect(fs.command == "npx")
        #expect(fs.arguments == ["fs-mcp", "--token", SecretFilter.mask])
        #expect(fs.uses.first?.state == .disabled)
    }

    @Test func brokenFileIsReportedNotFatal() throws {
        try write(".claude.json", "{ not json")
        try write(".claude/settings.json", "{}")
        let result = scan()
        #expect(result.servers.isEmpty)
        #expect(result.problems.count == 1)
        #expect(result.problems.first?.hasPrefix("~/.claude.json") == true)
    }

    @Test func masking() {
        #expect(MCPValues.maskedArguments(["--api-key=abcdef123456", "--token", "${TOKEN}", "--port", "8080"])
                == ["--api-key=\(SecretFilter.mask)", "--token", "${TOKEN}", "--port", "8080"])
        #expect(MCPValues.maskedURL("https://user:pw@host/x?token=${T}&q=1") == "https://hidden@host/x?token=${T}&q=1")
        #expect(MCPValues.maskedURL("https://host/x?sig=abcdef&page=2") == "https://host/x?sig=hidden&page=2")
        #expect(MCPValues.setting("A", "Bearer ${X}", commandPrefix: false).value == .reference("Bearer ${X}"))
        #expect(MCPValues.setting("A", "prefix-long-literal-${X}", commandPrefix: false).value == .hidden)
        #expect(MCPValues.setting("A", 42, commandPrefix: false).value == .hidden)
        #expect(MCPValues.requiredVariables(in: "${A} ${B:-x} $env:C {env:D} ${CLAUDE_PLUGIN_ROOT}") == ["A", "C", "D"])
    }

    @Test func miniTOMLValues() throws {
        let doc = try MiniTOML.parse("""
        a.b = "x\\ty"
        c = '''
        raw'''
        [t]
        n = 1_000
        list = [1, [2, 3], { k = true }]
        """)
        #expect((doc["a"] as? [String: Any])?["b"] as? String == "x\ty")
        #expect(doc["c"] as? String == "raw")
        let t = try #require(doc["t"] as? [String: Any])
        #expect(t["n"] as? Int == 1000)
        #expect((t["list"] as? [Any])?.count == 3)
        #expect(throws: ConfigTextError.self) { try MiniTOML.parse("x = \"open") }
    }

    @Test func jsoncStripping() throws {
        let text = #"{"a": "http://x//y", /* c */ "b": [1, 2,], // end"# + "\n}"
        let object = try ConfigText.jsonObject(Data(text.utf8), jsonc: true)
        #expect(object["a"] as? String == "http://x//y")
        #expect((object["b"] as? [Any])?.count == 2)
    }

    // MARK: - Regressions from review

    @Test func argumentSecretsAreMasked() {
        let secrets = ["S3cretPw", "abc123def456", "abc123def456xyz", "0123456789abcdef0123456789abcdef01234567",
                       "9f8e7d6c5b4a39281706", "hunter22", "abcdefghijkl123", "abcdef0123456789", "pub"]
        let args = [
            "postgresql://admin:S3cretPw@db.internal:5432/prod",
            "https://mcp.example.com/sse?api_key=abc123def456",
            "--header", "Authorization: Bearer abc123def456xyz",
            "--header", "Authorization: token 0123456789abcdef0123456789abcdef01234567",
            "-H", "X-API-Key: 9f8e7d6c5b4a39281706",
            "-e", "DATABASE_URL=postgres://u:hunter22@h/db",
            "-e", "OPENAI_API_KEY_PROD=abcdefghijkl123",
            "--pat", "abcdef0123456789",
            "--dsn", "https://pub@sentry.io/1",
            "--connection-string", "Server=x;Password=hunter22",
            "mcp-server --api-key abcdef0123456789",
            "Server=y;Password=hunter22;Database=z",
        ]
        let shown = MCPValues.maskedArguments(args).joined(separator: " ")
        for secret in secrets { #expect(!shown.contains(secret), "leaked \(secret) in \(shown)") }
        #expect(MCPValues.maskedArguments(["-H", "Authorization: Bearer ${TOKEN}"]) == ["-H", "Authorization: Bearer ${TOKEN}"])
        #expect(MCPValues.maskedArguments(["-y", "@modelcontextprotocol/server-postgres", "--port", "8080"])
                == ["-y", "@modelcontextprotocol/server-postgres", "--port", "8080"])
    }

    @Test func defaultsInReferencesAreHidden() {
        #expect(MCPValues.setting("A", "Bearer ${TOKEN:-sk-live-abc123def456ghi789}", commandPrefix: false).value
                == .reference("Bearer ${TOKEN:-…}"))
        #expect(MCPValues.maskedURL("https://x/?token=${T:-realtokenvalue}") == "https://x/?token=${T:-…}")
        let args = MCPValues.maskedArguments(["--api-key=${K:-sk-ant-api03-abcdefghijklmnopqrstuv}", "--token", "${K:-plainsecretvalue}"])
        #expect(!args.joined().contains("abcdefghij"))
        #expect(!args.joined().contains("plainsecretvalue"))
        #expect(MCPValues.setting("X", "${USER}:secretpw", commandPrefix: false).value == .hidden)
        #expect(MCPValues.setting("Y", "{env:A}abcdefghijk", commandPrefix: false).value == .hidden)
    }

    @Test func urlTokensAreMasked() {
        for url in ["https://mcp.pipedream.net/6f1c2b9e-1234-4d5e-9abc-0123456789ab/github",
                    "https://mcp.zapier.com/api/mcp/s/NmQ4ZjY3YTAtYmUxYi00/sse",
                    "https://abcdef0123456789@mcp.example.com/mcp", "redis://:hunter2@host:6379",
                    "https://u:p@ss@host"] {
            let shown = MCPValues.maskedURL(url)
            for secret in ["6f1c2b9e", "NmQ4ZjY3", "abcdef0123456789", "hunter2", "pa/ss", "p@ss"] {
                #expect(!shown.contains(secret), "leaked in \(shown)")
            }
        }
        #expect(MCPValues.maskedURL("https://mcp.linear.app/mcp") == "https://mcp.linear.app/mcp")
        #expect(MCPValues.setting("T", "!echo mysecretvalue123", commandPrefix: true).value == .command("echo …"))
        #expect(MCPValues.setting("T", "!security find-generic-password -s grafana -w", commandPrefix: true).value
                == .command("security find-generic-password -s grafana -w"))
    }

    @Test func deepTOMLThrowsInsteadOfCrashing() {
        #expect(throws: ConfigTextError.self) { try MiniTOML.parse("a = " + String(repeating: "[", count: 3000)) }
        #expect(throws: ConfigTextError.self) { try MiniTOML.parse("a = " + String(repeating: "{b=", count: 3000)) }
        #expect(throws: ConfigTextError.self) { try MiniTOML.parse(Array(repeating: "a", count: 1000).joined(separator: ".") + " = 1") }
    }

    @Test func crlfAndBOMFiles() throws {
        let toml = try MiniTOML.parse("\u{FEFF}# c\r\n[mcp_servers.a]\r\ncommand = \"x\"\r\n")
        #expect(((toml["mcp_servers"] as? [String: Any])?["a"] as? [String: Any])?["command"] as? String == "x")
        let json = try ConfigText.jsonObject(Data("{\r\n // c\r\n \"a\": 1\r\n}".utf8), jsonc: true)
        #expect(json["a"] as? Int == 1)
    }

    @Test func pendingOrRejectedProjectEntryDoesNotOverrideUser() throws {
        let key = project.standardizedFileURL.path
        try write(".claude/settings.json", "{}")
        try write(".claude.json", """
        {"mcpServers": {"github": {"command": "gh-mcp"}},
         "projects": {"\(key)": {"disabledMcpjsonServers": ["github"], "disabledMcpServers": ["neon"],
                                 "mcpServers": {"neon": {"url": "https://mcp.neon.tech/mcp"}}}}}
        """)
        try write("Projects/app/.mcp.json", #"{"mcpServers": {"github": {"command": "other"}}}"#)
        let servers = scan().servers
        let user = try #require(servers.first { $0.name == "github" && $0.scope == .global })
        #expect(user.warnings.allSatisfy { !$0.contains("instead") })
        #expect(user.uses.first?.state == .active)
        #expect(servers.first { $0.name == "neon" }?.uses.first?.state == .disabled)
    }

    @Test func customBareObjectListsOnlyServers() throws {
        try write(".akit/harnesses.json", #"{"harnesses": [{"name": "Goose", "configRoot": "~/.goose", "mcpFile": "mcp.json"}]}"#)
        try write(".goose/mcp.json", #"{"hooks": {"a": 1}, "fs": {"command": "fs-mcp"}}"#)
        let custom = try CustomHarnessStore.load(in: env)
        let adapters = HarnessCatalog.allAdapters(custom: custom)
        let result = MCPScanner.scan(installations: HarnessCatalog.detectAll(in: env, adapters: adapters), projects: [],
                                     adapters: adapters, in: env)
        #expect(result.servers.map(\.name) == ["fs"])
    }
}
