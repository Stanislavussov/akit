import Foundation
import Testing
import AKitFoundation
@testable import AKitDoctor

/// `akit doctor pi` in a temporary fake home; `pi` is a fake runner, never the real one.
struct PiDoctorTests {
    let home: URL
    let fm = FileManager.default
    let secret = "ghp_piDoctorEnvSECRET0123456789abcdef"

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-pidoctor-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var env: HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home, variables: ["HOME": home.path],
                           executableSearchPaths: [home.appending(path: "bin"), home.appending(path: "other")])
    }

    func write(_ path: String, _ text: String = "") throws {
        let url = home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func executable(_ path: String) throws {
        try write(path, "#!/bin/sh\n")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.appending(path: path).path)
    }

    /// A clean Pi: the command, settings, an MCP server whose command exists, an extension, a skill.
    func setUpClean() throws {
        try executable("bin/pi")
        try executable("bin/my-mcp")
        try write(".pi/agent/settings.json", #"{"defaultProvider": "anthropic", "defaultModel": "claude", "defaultThinkingLevel": "high", "compaction": {"enabled": true}, "lastChangelogVersion": "1.0.4"}"#)
        try write(".pi/agent/mcp.json", #"{"mcpServers": {"tools": {"command": "my-mcp", "env": {"TOKEN": "\#(secret)"}}}}"#)
        try write(".pi/agent/extensions/guard.ts", "export default function () {}")
        try write(".pi/agent/skills/pdf-tools/SKILL.md", "---\nname: pdf-tools\ndescription: Read PDFs.\n---\nBody")
        try write(".pi/agent/AGENTS.md", "Be brief.")
    }

    /// Records the arguments of every run; answers like Pi 1.0.4.
    final class FakePi: @unchecked Sendable {
        let lock = NSLock()
        var calls: [[String]] = []
        var mcpList = #"{"servers": [], "errors": []}"#
        var auth = #"{"status": "ready", "provider": "anthropic", "authType": "oauth"}"#

        var runner: PiDoctor.Runner {
            { _, arguments, _, _ in
                self.lock.withLock { self.calls.append(arguments) }
                switch arguments.first {
                case "--version": return .init(status: 0, output: "1.0.4\n")
                case "mcp": return .init(status: 0, output: self.mcpList)
                case "auth": return .init(status: 0, output: self.auth)
                default: return nil
                }
            }
        }
    }

    func check(live: Bool = false, projects: [URL] = [], pi: FakePi = FakePi()) async -> PiDoctor.Report {
        await PiDoctor.check(env: env, projects: projects, live: live, runner: pi.runner)
    }

    func lines(_ report: PiDoctor.Report, _ level: PiDoctor.Level) -> [String] {
        report.sections.flatMap(\.lines).filter { $0.level == level }.map(\.text)
    }

    @Test func aCleanSetupHasNoProblems() async throws {
        try setUpClean()
        let report = await check()
        #expect(lines(report, .problem).isEmpty)
        #expect(lines(report, .warning).isEmpty, "\(report.text)")
        #expect(report.text.hasSuffix("No problems found."))
        #expect(report.text.contains("pi: ~/bin/pi, version 1.0.4"))
        #expect(report.text.contains("default model: anthropic/claude"))
        #expect(report.text.contains("tools: stdio, my-mcp, env: TOKEN"))
        #expect(!report.text.contains(secret))
    }

    @Test func aBrokenSettingsFileIsAProblem() async throws {
        try setUpClean()
        try write(".pi/agent/settings.json", #"{"defaultModel": "#)
        let report = await check()
        #expect(lines(report, .problem).contains { $0.hasPrefix("~/.pi/agent/settings.json can't be read") })
        #expect(report.text.contains("1 problem found."))
    }

    @Test func unknownKeysWarnAndUnknownValuesAreProblems() async throws {
        try setUpClean()
        try write(".pi/agent/settings.json", #"{"defaultThinkingLevel": "huge", "themee": "dark", "compaction": {"enabld": true}, "quietStartup": "header", "outputPad": 2, "modelThinkingLevels": {"a/b": "lots"}}"#)
        let report = await check()
        #expect(Set(lines(report, .warning)) == ["~/.pi/agent/settings.json: unknown key compaction.enabld",
                                                 "~/.pi/agent/settings.json: unknown key themee"])
        #expect(Set(lines(report, .problem)) == ["~/.pi/agent/settings.json: defaultThinkingLevel has a value Pi doesn't know",
                                                 "~/.pi/agent/settings.json: outputPad has a value Pi doesn't know",
                                                 "~/.pi/agent/settings.json: modelThinkingLevels[\"a/b\"] is not a thinking level"])
    }

    @Test func aProjectMayNotSetGlobalOnlyKeys() async throws {
        try setUpClean()
        let project = home.appending(path: "Projects/app")
        try write("Projects/app/.pi/settings.json", #"{"httpProxy": "http://proxy"}"#)
        let report = await check(projects: [project])
        #expect(lines(report, .warning).contains { $0.contains("httpProxy works only in ~/.pi/agent/settings.json") })
    }

    @Test func mcpServersAreCheckedLikePiChecksThem() async throws {
        try setUpClean()
        try write(".pi/agent/mcp.json", #"""
            {"mcpServers": {
              "missing": {"command": "no-such-mcp", "env": {"KEY": "\#(secret)"}},
              "shell": {"command": "my-mcp --stdio"},
              "old": {"url": "https://example.com/sse", "type": "sse"},
              "empty": {},
              "bad name": {"command": "my-mcp"},
              "web": {"url": "https://example.com/mcp", "headers": {"Authorization": "Bearer \#(secret)"}, "exposure": "loud"},
              "off": {"command": "no-such-mcp", "enabled": false}
            }}
            """#)
        let report = await check()
        let problems = lines(report, .problem)
        #expect(problems.contains("~/.pi/agent/mcp.json: server \"missing\" runs no-such-mcp, which isn't found"))
        #expect(problems.contains { $0.hasPrefix("~/.pi/agent/mcp.json: server \"shell\" runs my-mcp, which isn't found (command is one program") })
        #expect(problems.contains("~/.pi/agent/mcp.json: server \"old\" uses the SSE transport, which Pi doesn't support"))
        #expect(problems.contains("~/.pi/agent/mcp.json: server \"empty\" needs either command (stdio) or url (streamable HTTP)"))
        #expect(problems.contains("~/.pi/agent/mcp.json: server \"bad name\" has an invalid name"))
        #expect(problems.contains("~/.pi/agent/mcp.json: server \"web\" has an unknown exposure"))
        #expect(problems.count == 6)
        #expect(lines(report, .ok).contains("off: stdio, no-such-mcp, off"))
        #expect(!report.text.contains(secret))
    }

    @Test func aProjectOverrideNeedsAGlobalServer() async throws {
        try setUpClean()
        let project = home.appending(path: "Projects/app")
        try write("Projects/app/.pi/mcp.json", #"{"mcpServers": {"tools": {"enabled": false}, "ghost": {"enabled": false}, "wide": {"enabled": false, "env": {}}}}"#)
        try write(".pi/agent/mcp.json", #"{"mcpServers": {"tools": {"command": "my-mcp"}, "wide": {"command": "my-mcp"}}}"#)
        let problems = lines(await check(projects: [project]), .problem)
        #expect(problems.count == 2)
        #expect(problems.contains { $0.contains("\"ghost\" has no command or url") })
        #expect(problems.contains { $0.contains("\"wide\" changes a global server but also sets env") })
    }

    @Test func aMissingPackageAndAnEmptyExtensionFolder() async throws {
        try setUpClean()
        try write(".pi/agent/settings.json", #"{"packages": ["npm:pi-missing", "npm:pi-here"], "extensions": ["./gone.ts", "-builtin:mcp"]}"#)
        try write(".pi/agent/npm/node_modules/pi-here/package.json", #"{"name": "pi-here", "version": "2.0.0"}"#)
        try write(".pi/agent/extensions/settings-only/config.json", "{}")
        try write(".pi/agent/extensions/tool/index.ts", "export default function () {}")
        let report = await check()
        #expect(lines(report, .problem).contains("npm:pi-missing isn't installed"))
        let missing = report.sections.flatMap(\.lines).first { $0.text == "npm:pi-missing isn't installed" }
        #expect(missing?.command == "akit pi packages install npm:pi-missing")
        #expect(missing?.action == .installPackage(source: "npm:pi-missing", project: nil))
        #expect(lines(report, .problem).contains { $0.hasPrefix("extensions entry ./gone.ts:") })
        #expect(lines(report, .ok).contains("npm:pi-here: pi-here 2.0.0"))
        #expect(lines(report, .warning).contains { $0.hasPrefix("extensions/settings-only/ has no index.ts") })
        #expect(lines(report, .ok).contains("~/.pi/agent/extensions: 2 extensions Pi loads"))
    }

    @Test func skillProblemsComeFromTheSkillScanner() async throws {
        try setUpClean()
        try write(".pi/agent/skills/no-description/SKILL.md", "---\nname: no-description\n---\nBody")
        try write(".pi/agent/skills/Bad_Name/SKILL.md", "---\nname: Bad_Name\ndescription: Bad.\n---\nBody")
        try write(".pi/agent/skills/folder/SKILL.md", "---\nname: other-name\ndescription: Elsewhere.\n---\nBody")
        let report = await check()
        #expect(lines(report, .problem).contains { $0.hasPrefix("no-description") && $0.contains("Pi ignores this skill") })
        #expect(lines(report, .warning).contains { $0.hasPrefix("Bad_Name") && $0.contains("a-z, 0-9 and hyphens") })
        #expect(lines(report, .warning).contains { $0.hasPrefix("other-name") && $0.contains("differs from its folder folder") })
    }

    @Test func largeInstructionsWarn() async throws {
        try setUpClean()
        try write(".pi/agent/AGENTS.md", String(repeating: "x", count: 40_001))
        #expect(lines(await check(), .warning) == ["~/.pi/agent/AGENTS.md: 40001 characters, over 40000"])
    }

    @Test func keybindingsAndEnvironmentValues() async throws {
        try setUpClean()
        try write(".pi/agent/keybindings.json", #"{"app.session.new": "ctrl+shift+n", "app.tree": ["ctrl++", "hyper+k"], "app.x": 5}"#)
        var env = env
        env.variables["PI_IMAGE_PROTOCOL"] = "sixel"
        env.variables["PI_TELEMETRY"] = "0"
        let report = await PiDoctor.check(env: env, projects: [], runner: FakePi().runner)
        #expect(Set(lines(report, .problem)) == ["~/.pi/agent/keybindings.json: app.x must be a key or a list of keys",
                                                 "PI_IMAGE_PROTOCOL has a value Pi doesn't know"])
        #expect(lines(report, .warning) == ["~/.pi/agent/keybindings.json: app.tree: hyper+k isn't a key Pi knows"])
        #expect(lines(report, .ok).contains("PI_TELEMETRY=0"))
    }

    @Test func twoInstallationsWarnAndNoPiIsAProblem() async throws {
        try setUpClean()
        try executable("other/pi")
        #expect(lines(await check(), .warning).contains { $0.hasPrefix("2 different Pi installations") })
        try fm.removeItem(at: home.appending(path: "bin/pi"))
        try fm.removeItem(at: home.appending(path: "other/pi"))
        #expect(lines(await check(), .problem) == ["pi isn't on PATH"])
    }

    @Test func theLiveCheckReadsPiMCPListAndAuthCheckWithoutCredentials() async throws {
        try setUpClean()
        let pi = FakePi()
        pi.mcpList = #"""
            warning on stderr
            {"servers": [
              {"name": "tools", "scope": "global", "enabled": true, "state": "connected", "tools": ["a", "b"]},
              {"name": "sentry", "scope": "global", "enabled": true, "state": "needs-auth", "tools": []},
              {"name": "broken", "scope": "project", "enabled": true, "state": "failed", "tools": [], "error": "spawn ENOENT\nmore"}
            ], "errors": ["\#(home.path)/.pi/agent/mcp.json: server \"x\" must be an object"]}
            """#
        pi.auth = #"{"status": "not_ready", "provider": "anthropic"}"#
        let report = await check(live: true, pi: pi)
        #expect(report.live)
        #expect(lines(report, .ok).contains("tools: connected, 2 tools"))
        #expect(Set(lines(report, .problem)) == ["sentry: needs sign-in", "broken (project): failed: spawn ENOENT",
                                                 "~/.pi/agent/mcp.json: server \"x\" must be an object",
                                                 "sign-in for anthropic: no usable credentials"])
        let signIn = report.sections.flatMap(\.lines).first { $0.text == "sentry: needs sign-in" }
        #expect(signIn?.command == "akit mcp login sentry --harness pi" && signIn?.action == .mcpLogin(server: "sentry"))
        // Every fix is an akit command or a hand edit; none sends the user to pi.
        let fixes = report.sections.flatMap(\.lines).compactMap(\.fix)
        #expect(!fixes.contains { $0.contains("Run pi") || $0.contains("in a terminal") }, "\(fixes)")
        let calls = pi.lock.withLock { pi.calls }
        #expect(calls.contains(["auth", "check", "--provider", "anthropic", "--json", "--no-refresh"]))
        #expect(!calls.joined().contains("--credentials"))
    }

    @Test func offlineByDefault() async throws {
        try setUpClean()
        let pi = FakePi()
        _ = await check(pi: pi)
        #expect(pi.lock.withLock { pi.calls } == [["--version"]])
    }
}
