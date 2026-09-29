import Foundation
import Testing
import AKitFoundation
import AKitHarnesses
import AKitModel
@testable import AKitMCP

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

        let plan = try MCPWriter.plan(grafana, into: target, secretMode: .environment, keychain: MemorySecretStore(), home: home)
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
        let plan = try MCPWriter.plan(grafana, into: target, secretMode: .keychainLookup, keychain: MemorySecretStore(), home: home)
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
        let piEntry = try ConfigText.jsonObject(Data(try MCPWriter.plan(remote, into: pi, secretMode: .keychainLookup, keychain: MemorySecretStore(), home: home).entryCompact.utf8), jsonc: false)
        #expect((piEntry["headers"] as? [String: String])?["Authorization"]
                == "!/usr/bin/security find-generic-password -s 'AKit MCP' -a 'LINEAR_AUTHORIZATION' -w")

        let claude = try #require(all.first { $0.claudeScope == "user" })
        let plan = try MCPWriter.plan(remote, into: claude, secretMode: .keychainLookup, keychain: MemorySecretStore(), home: home)
        let entry = try ConfigText.jsonObject(Data(plan.entryCompact.utf8), jsonc: false)
        #expect(entry["headers"] == nil)
        #expect((entry["headersHelper"] as? String)?.hasPrefix(#"printf '{"Authorization":"%s"}' "$(/usr/bin/security"#) == true)
        #expect(plan.diff.isEmpty)
    }

    @Test func claudeStateIsChangedThroughCLI() async throws {
        try write(".claude/settings.json", "{}")
        try write(".claude.json", #"{"mcpServers": {"grafana": {"command": "old"}}}"#)
        let target = try #require(try targets().first { $0.claudeScope == "user" })
        #expect(throws: ConfigTextError.self) { try MCPWriter.plan(grafana, into: target, secretMode: .environment, keychain: MemorySecretStore(), home: home) }
        let plan = try MCPWriter.plan(grafana, into: target, secretMode: .environment, replacing: "grafana", keychain: MemorySecretStore(), home: home)
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
        let plan = try MCPWriter.plan(grafana, into: target, secretMode: .environment, keychain: MemorySecretStore(), home: home)
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
        let plan = try MCPWriter.plan(grafana, into: target, secretMode: .environment, keychain: MemorySecretStore(), home: home)
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

    @Test func editRoundTripKeepsHiddenValuesAndKeychainItems() throws {
        try write(".claude/settings.json", "{}")
        try write("Projects/app/.mcp.json", """
        {"mcpServers": {"grafana": {"command": "mcp-grafana", "cwd": "/tmp", "lifecycle": "lazy",
                             "env": {"URL": "https://g.example.com", "TOKEN": "glsa_literal_123"}}}}
        """)
        let target = try #require(try targets().first { $0.file.lastPathComponent == ".mcp.json" })
        let raw = try #require((try read("Projects/app/.mcp.json")["mcpServers"] as? [String: Any])?["grafana"] as? [String: Any])
        var draft = MCPDraft.editing(name: "grafana", entry: raw, dialect: .standard, keychain: MemorySecretStore())
        #expect(draft.environment.allSatisfy { $0.value.isEmpty && $0.hasHiddenValue })
        // The token looks secret, so the form offers the Keychain for it; the URL doesn't.
        #expect(draft.environment.map(\.isSecret) == [true, false])
        let index = try #require(draft.environment.firstIndex { $0.key == "TOKEN" })
        draft.environment[index].isSecret = false

        // Unchanged: literals stay as they were.
        var plan = try MCPWriter.plan(draft, into: target, secretMode: .environment, replacing: "grafana", keychain: MemorySecretStore(), home: home)
        #expect(plan.replaces)
        #expect(plan.diff.allSatisfy { if case .same = $0 { true } else { false } })

        // "Secret" on the token moves the existing literal into the Keychain.
        draft.environment[index].isSecret = true
        plan = try MCPWriter.plan(draft, into: target, secretMode: .keychainLookup, replacing: "grafana", keychain: MemorySecretStore(), home: home)
        #expect(plan.secretNames == ["GRAFANA_TOKEN"]) // namespaced: a lookup doesn't need the env name
        let entry = try ConfigText.jsonObject(Data(plan.entryCompact.utf8), jsonc: false)
        #expect(entry["command"] as? String == "/bin/sh")
        #expect(entry["env"] as? [String: String] == ["URL": "https://g.example.com"])
        #expect(entry["cwd"] as? String == "/tmp")
        #expect(entry["lifecycle"] as? String == "lazy")

        // Editing that entry again gives back the Keychain secret and the real command.
        let again = MCPDraft.editing(name: "grafana", entry: entry, dialect: .standard, keychain: MemorySecretStore())
        #expect(again.command == "mcp-grafana")
        #expect(again.arguments.isEmpty)
        let token = try #require(again.environment.first { $0.key == "TOKEN" })
        #expect(token.keychainAccount == "GRAFANA_TOKEN")
        #expect(token.isSecret)
        #expect(again.problems.isEmpty)
    }

    @Test func referencesToKeychainItemsBecomeSecretsWhenEditing() {
        let store = MemorySecretStore()
        try? store.save("x", for: "GRAFANA_TOKEN")
        let draft = MCPDraft.editing(name: "g", entry: ["command": "g", "env": ["GRAFANA_TOKEN": "${GRAFANA_TOKEN}", "OTHER": "${OTHER}"]],
                                     dialect: .standard, keychain: store)
        #expect(draft.environment.map(\.keychainAccount) == ["GRAFANA_TOKEN", nil])
        #expect(draft.environment.last?.value == "${OTHER}")
    }

    @Test func renameAndRemove() async throws {
        try write(".claude/settings.json", "{}")
        try write("Projects/app/.mcp.json", #"{"mcpServers": {"a": {"command": "a"}, "b": {"command": "b"}}}"#)
        let target = try #require(try targets().first { $0.file.lastPathComponent == ".mcp.json" })

        #expect(throws: ConfigTextError.self) {
            try MCPWriter.plan(MCPDraft(name: "b", command: "a"), into: target, secretMode: .environment, replacing: "a", keychain: MemorySecretStore(), home: home)
        }
        let rename = try MCPWriter.plan(MCPDraft(name: "c", command: "a"), into: target, secretMode: .environment,
                                        replacing: "a", keychain: MemorySecretStore(), home: home)
        _ = try await MCPWriter.apply(rename, secrets: MemorySecretStore(), home: home) { _, _ in }
        #expect((try read("Projects/app/.mcp.json")["mcpServers"] as? [String: Any]).map { Set($0.keys) } == ["b", "c"])

        let removal = try MCPWriter.removalPlan("b", from: target, home: home)
        #expect(removal.diff.contains { if case .removed = $0 { true } else { false } })
        _ = try await MCPWriter.apply(removal, secrets: MemorySecretStore(), home: home) { _, _ in }
        #expect((try read("Projects/app/.mcp.json")["mcpServers"] as? [String: Any]).map { Set($0.keys) } == ["c"])
    }

    @Test func claudeRemovalAndRenameGoThroughCLI() async throws {
        try write(".claude/settings.json", "{}")
        try write(".claude.json", #"{"mcpServers": {"a": {"command": "a"}}}"#)
        let target = try #require(try targets().first { $0.claudeScope == "user" })
        let calls = CallLog()
        let rename = try MCPWriter.plan(MCPDraft(name: "b", command: "a"), into: target, secretMode: .environment,
                                        replacing: "a", keychain: MemorySecretStore(), home: home)
        _ = try await MCPWriter.apply(rename, secrets: MemorySecretStore(), home: home) { args, _ in calls.add(args) }
        _ = try await MCPWriter.apply(try MCPWriter.removalPlan("a", from: target, home: home),
                                      secrets: MemorySecretStore(), home: home) { args, _ in calls.add(args) }
        #expect(calls.all.map { Array($0.prefix(2)) + [$0[4]] } == [["mcp", "add-json", "b"], ["mcp", "remove", "a"], ["mcp", "remove", "a"]]) // rename adds first
    }

    /// The real-CLI `apply` with a fake `claude` script: arguments, PATH, masked failure output.
    @Test func claudeCLIRunsWithEnvironmentAndMasksFailures() async throws {
        try write(".claude/settings.json", "{}")
        try write(".claude.json", #"{"mcpServers": {"a": {"command": "a"}}}"#)
        let target = try #require(try targets().first { $0.claudeScope == "user" })
        let script = home.appending(path: "bin/claude")
        func claude(_ body: String) throws -> HarnessInstallation {
            try write("bin/claude", "#!/bin/sh\n\(body)\n")
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            return HarnessInstallation(id: .claudeCode, displayName: "Claude Code", executableURL: script,
                                       configRoot: home.appending(path: ".claude"), locations: [])
        }
        let removal = try MCPWriter.removalPlan("a", from: target, home: home)
        let log = home.appending(path: "claude-args")
        _ = try await MCPWriter.apply(removal, claude: try claude(#"printf '%s\n' "$@" "$PATH" > "\#(log.path)""#),
                                      secrets: MemorySecretStore(), env: env)
        #expect(try String(contentsOf: log, encoding: .utf8)
                == "mcp\nremove\n--scope\nuser\na\n\(env.pathForChildProcesses)\n")

        let failing = try claude("echo 'GRAFANA_TOKEN=glsa_secret_value_123'; exit 1")
        let message = await #expect(throws: ConfigTextError.self) {
            try await MCPWriter.apply(removal, claude: failing, secrets: MemorySecretStore(), env: env)
        }?.localizedDescription ?? ""
        #expect(message.hasPrefix("claude mcp remove failed: GRAFANA_TOKEN="))
        #expect(!message.contains("glsa_secret_value_123"))

        let missing = await #expect(throws: ConfigTextError.self) {
            try await MCPWriter.apply(removal, claude: nil, secrets: MemorySecretStore(), env: env)
        }?.localizedDescription ?? ""
        #expect(missing.hasPrefix("The claude command was not found."))
    }

    @Test func wrapperAndHelperParsing() {
        let script = KeychainSecretStore.wrapperScript([("TOKEN", "GRAFANA_TOKEN")])
        #expect(KeychainSecretStore.wrapperAccounts(script)?.map { "\($0.key)=\($0.account)" } == ["TOKEN=GRAFANA_TOKEN"])
        #expect(KeychainSecretStore.wrapperAccounts("echo hi && exec \"$0\" \"$@\"") == nil)
        #expect(KeychainSecretStore.lookupAccount(inCommand: KeychainSecretStore.lookupCommand("A_B")) == "A_B")
        let helper = #"printf '{"Authorization":"%s"}' "$(/usr/bin/security find-generic-password -s 'AKit MCP' -a 'LINEAR_AUTHORIZATION' -w)""#
        #expect(KeychainSecretStore.helperHeaders(helper).map { "\($0.0)=\($0.1)" } == ["Authorization=LINEAR_AUTHORIZATION"])
    }

    @Test func storeSecretButton() throws {
        let store = MemorySecretStore()
        var notes = try MCPWriter.storeSecret("glsa_x", for: "GRAFANA_TOKEN", in: store, home: home)
        #expect(store.value("GRAFANA_TOKEN") == "glsa_x")
        #expect(notes.count == 1)
        try write(".zshrc", "source ~/.akit/env.sh\n")
        notes = try MCPWriter.storeSecret("y", for: "OTHER", in: store, home: home)
        #expect(notes.isEmpty)
        let script = try String(contentsOf: home.appending(path: ".akit/env.sh"), encoding: .utf8)
        #expect(script.contains("export GRAFANA_TOKEN=") && script.contains("export OTHER="))
        #expect(throws: ConfigTextError.self) { try MCPWriter.storeSecret("x", for: "bad name", in: store, home: home) }
    }

    // MARK: - Regressions from the write-path review

    @Test func shellInjectionThroughNamesIsRejected() throws {
        let env = try MCPDraft.parse(json: #"{"mcpServers":{"x":{"command":"npx","env":{"API_KEY;touch /tmp/pwned;X":"sk-abcdefghijklmnopqrstuvwxyz123456"}}}}"#)
        #expect(env.first?.problems.contains { $0.contains("Secret name") } == true)
        let header = try MCPDraft.parse(json: #"{"x":{"type":"http","url":"https://h.example/mcp","headers":{"X-Api-Key' ; touch /tmp/p ; echo '":"sk-abcdefghijklmnopqrstuvwxyz123456"}}}"#)
        #expect(header.first?.problems.contains { $0.contains("Secret header") } == true)
        #expect(throws: ConfigTextError.self) { try KeychainSecretStore.helperCommand([("A'b", "X")]) }
        #expect(!KeychainSecretStore.lookupCommand("A';touch x;'").contains(";"))
        #expect(!KeychainSecretStore.wrapperScript([("A;touch x", "B")]).contains(";"))
        #expect(KeychainSecretStore.lookupAccount(inCommand: "/usr/bin/security find-generic-password -s 'AKit MCP' -a 'A=$(touch /tmp/p)' -w") == nil)
        try MCPWriter.updateEnvFile(adding: ["A;touch /tmp/pwned2;B", "OK_NAME"], home: home)
        let script = try String(contentsOf: home.appending(path: ".akit/env.sh"), encoding: .utf8)
        #expect(!script.contains("pwned") && script.contains("export OK_NAME="))
    }

    @Test func claudeReplaceRestoresTheOldEntryWhenAddFails() async throws {
        try write(".claude/settings.json", "{}")
        try write(".claude.json", #"{"mcpServers": {"a": {"command": "old-a"}}}"#)
        let target = try #require(try targets().first { $0.claudeScope == "user" })
        let plan = try MCPWriter.plan(MCPDraft(name: "a", command: "new-a"), into: target, secretMode: .environment,
                                      replacing: "a", keychain: MemorySecretStore(), home: home)
        let calls = CallLog()
        await #expect(throws: ConfigTextError.self) {
            try await MCPWriter.apply(plan, secrets: MemorySecretStore(), home: home) { args, _ in
                calls.add(args)
                if args[1] == "add-json", args.last?.contains("new-a") == true { throw ConfigTextError("boom") }
            }
        }
        #expect(calls.all.map { $0[1] } == ["remove", "add-json", "add-json"])
        #expect(calls.all.last?.last?.contains("old-a") == true)
    }

    @Test func keychainCollisionIsWarned() throws {
        try write(".claude/settings.json", "{}")
        let target = try #require(try targets().first { $0.file.lastPathComponent == ".mcp.json" })
        let store = MemorySecretStore()
        try store.save("tokenA", for: "API_KEY")
        let draft = MCPDraft(name: "b", command: "b", environment: [.init(key: "API_KEY", value: "tokenB", isSecret: true)])
        let shared = try MCPWriter.plan(draft, into: target, secretMode: .environment, keychain: store, home: home)
        #expect(shared.warnings.first?.contains("API_KEY") == true)
        // A lookup doesn't need the env name, so it gets its own account instead.
        let lookup = try MCPWriter.plan(draft, into: target, secretMode: .keychainLookup, keychain: store, home: home)
        #expect(lookup.secretNames == ["B_API_KEY"])
        #expect(lookup.warnings.isEmpty)
    }

    @Test func editKeepsForeignHeadersHelperTypesAndEmptyArguments() throws {
        let raw: [String: Any] = ["type": "http", "url": "https://h.example/mcp", "headersHelper": "/Users/me/bin/token.sh", "timeout": 5]
        let draft = MCPDraft.editing(name: "h", entry: raw, dialect: .standard, keychain: MemorySecretStore())
        var notes: [String] = []
        let target = MCPWriteTarget(file: home.appending(path: "x.json"), keyPath: ["mcpServers"], dialect: .standard,
                                    scope: .global, layer: "User", harnesses: [.claudeCode], claudeScope: nil,
                                    isShared: false, blockedReason: nil, inactiveReason: nil)
        let built = try MCPWriter.entry(for: draft, target: target, mode: .keychainLookup, notes: &notes)
        #expect(built.entry["headersHelper"] as? String == "/Users/me/bin/token.sh")
        #expect(built.entry["timeout"] as? Int == 5)

        let stdio = MCPDraft.editing(name: "s", entry: ["command": "x", "args": ["--a", ""], "env": ["DEBUG": true, "PORT": 8080]],
                                     dialect: .standard, keychain: MemorySecretStore())
        let again = try MCPWriter.entry(for: stdio, target: target, mode: .environment, notes: &notes).entry
        #expect(again["args"] as? [String] == ["--a", ""])
        #expect((again["env"] as? [String: Any])?["DEBUG"] as? Bool == true)
        #expect((again["env"] as? [String: Any])?["PORT"] as? Int == 8080)
    }

    @Test func onlyTheChosenTransportsValuesAreUsed() throws {
        var draft = try #require(try MCPDraft.parse(json: #"{"x":{"command":"c","url":"https://h.example/mcp","env":{"API_KEY":"sk-abcdefghijklmnopqrstuvwxyz"},"headers":{"X-Id":"1"}}}"#).first)
        draft.transport = .http
        var notes: [String] = []
        let target = MCPWriteTarget(file: home.appending(path: "x.json"), keyPath: ["mcpServers"], dialect: .standard,
                                    scope: .global, layer: "User", harnesses: [.pi], claudeScope: nil,
                                    isShared: false, blockedReason: nil, inactiveReason: nil)
        let built = try MCPWriter.entry(for: draft, target: target, mode: .keychainLookup, notes: &notes)
        #expect(built.secrets.isEmpty)
        #expect(built.entry["env"] == nil)
    }

    @Test func keptKeychainItemSwitchedToReferenceIsExported() async throws {
        try write(".claude/settings.json", "{}")
        let target = try #require(try targets().first { $0.file.lastPathComponent == ".mcp.json" })
        let draft = MCPDraft(name: "g", command: "g", environment: [.init(key: "TOKEN", isSecret: true, keychainAccount: "G_TOKEN")])
        let plan = try MCPWriter.plan(draft, into: target, secretMode: .environment, keychain: MemorySecretStore(), home: home)
        #expect(plan.secretNames.isEmpty)
        _ = try await MCPWriter.apply(plan, secrets: MemorySecretStore(), home: home) { _, _ in }
        let script = try String(contentsOf: home.appending(path: ".akit/env.sh"), encoding: .utf8)
        #expect(script.contains("export G_TOKEN="))
    }

    @Test func writingThroughSymlinkKeepsLinkAndPermissions() throws {
        try write("dotfiles/mcp.json", "{}")
        let real = home.appending(path: "dotfiles/mcp.json")
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: real.path)
        let link = home.appending(path: "link.json")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        try MCPWriter.write("{\"a\": 1}\n", to: link)
        #expect((try fm.destinationOfSymbolicLink(atPath: link.path)) == real.path)
        #expect((try fm.attributesOfItem(atPath: real.path))[.posixPermissions] as? Int == 0o600)
        #expect(try String(contentsOf: real, encoding: .utf8).contains("\"a\""))
    }

    @Test func commentsAddedAfterTheScanBlockThePlan() throws {
        try write(".config/opencode/opencode.json", #"{"model": "x"}"#)
        let target = try #require(try targets().first { $0.dialect == .openCode && $0.scope == .global })
        try write(".config/opencode/opencode.json", "{\n  // mine\n  \"model\": \"x\"\n}")
        #expect(throws: ConfigTextError.self) {
            try MCPWriter.plan(grafana, into: target, secretMode: .environment, keychain: MemorySecretStore(), home: home)
        }
    }

    @Test func backupsNeverOverwriteEachOther() throws {
        try write("a.json", "one")
        let first = try #require(try MCPWriter.backUp(home.appending(path: "a.json"), home: home))
        try write("a.json", "two")
        let second = try #require(try MCPWriter.backUp(home.appending(path: "a.json"), home: home))
        #expect(first != second)
        #expect(try String(contentsOf: first, encoding: .utf8) == "one")
    }

    @Test func editRefusesWhenTheFileChangedSinceTheFormOpened() throws {
        try write(".claude/settings.json", "{}")
        try write("Projects/app/.mcp.json", #"{"mcpServers": {"a": {"command": "a"}}}"#)
        let target = try #require(try targets().first { $0.file.lastPathComponent == ".mcp.json" })
        let opened = try String(contentsOf: target.file, encoding: .utf8)
        try write("Projects/app/.mcp.json", #"{"mcpServers": {"a": {"command": "changed"}}}"#)
        #expect(throws: ConfigTextError.self) {
            try MCPWriter.plan(MCPDraft(name: "a", command: "a"), into: target, secretMode: .environment, replacing: "a",
                               openedText: opened, keychain: MemorySecretStore(), home: home)
        }
    }

    @Test func failedRestoreIsReportedHonestly() async throws {
        try write(".claude/settings.json", "{}")
        try write(".claude.json", #"{"mcpServers": {"a": {"command": "old-a"}}}"#)
        let target = try #require(try targets().first { $0.claudeScope == "user" })
        let plan = try MCPWriter.plan(MCPDraft(name: "a", command: "new-a"), into: target, secretMode: .environment,
                                      replacing: "a", keychain: MemorySecretStore(), home: home)
        do {
            _ = try await MCPWriter.apply(plan, secrets: MemorySecretStore(), home: home) { args, _ in
                if args[1] == "add-json" { throw ConfigTextError("boom") }
            }
            Issue.record("expected an error")
        } catch {
            #expect(error.localizedDescription.contains("failed too"))
            #expect(error.localizedDescription.contains("backup"))
        }
    }

    @Test func foreignHelperStaysWhenASecretHeaderIsAdded() throws {
        var draft = MCPDraft.editing(name: "h", entry: ["type": "http", "url": "https://h.example/mcp", "headersHelper": "/Users/me/bin/token.sh"],
                                     dialect: .standard, keychain: MemorySecretStore())
        draft.headers.append(.init(key: "X-Team", value: "secret-team-token", isSecret: true))
        var notes: [String] = []
        let target = MCPWriteTarget(file: home.appending(path: "x.json"), keyPath: ["mcpServers"], dialect: .standard,
                                    scope: .global, layer: "User", harnesses: [.claudeCode], claudeScope: nil,
                                    isShared: false, blockedReason: nil, inactiveReason: nil)
        let entry = try MCPWriter.entry(for: draft, target: target, mode: .keychainLookup, notes: &notes).entry
        #expect(entry["headersHelper"] as? String == "/Users/me/bin/token.sh")
        #expect((entry["headers"] as? [String: String])?["X-Team"] == "${H_X_TEAM}")
    }

    @Test func plainValuesMayHaveLooseNamesSecretsMayNot() {
        let plain = MCPDraft(name: "n", command: "npm", environment: [.init(key: "npm-config-x", value: "1")])
        #expect(plain.problems.isEmpty)
        let secret = MCPDraft(name: "n", command: "npm", environment: [.init(key: "npm-config-x", value: "1", isSecret: true)])
        #expect(secret.problems.contains { $0.contains("Secret name") })
    }

    @Test func tooLongOrMultilineKeychainValuesAreRefusedBeforeAnythingRuns() {
        // Rejected before /usr/bin/security is started, so this never touches the real Keychain.
        #expect(throws: ConfigTextError.self) { try KeychainSecretStore().save(String(repeating: "a", count: 2500), for: "AKIT_TEST") }
        #expect(throws: ConfigTextError.self) { try KeychainSecretStore().save("a\nb", for: "AKIT_TEST") }
        #expect(throws: ConfigTextError.self) { try KeychainSecretStore().save("x", for: "bad name") }
        #expect(throws: ConfigTextError.self) { try KeychainSecretStore().save("pässwort", for: "AKIT_TEST") }
        #expect(throws: ConfigTextError.self) { try KeychainSecretStore().save("a\tb", for: "AKIT_TEST") }
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
