import AKitCommandLine
import AKitFoundation
import Foundation
import Testing

/// `akit mcp state|set|connectors` and the worktree sync of remembered projects, in a temporary
/// fake home whose project is a git repository with a worktree.
struct MCPSwitchCLITests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-cli-mcp-\(UUID().uuidString)")
        try fm.createDirectory(at: home.appending(path: ".claude"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appending(path: ".pi/agent"), withIntermediateDirectories: true)
        try Data(#"{"mcpServers": {"github": {"type": "http", "url": "https://api.example.com/mcp"}}, "projects": {}}"#.utf8)
            .write(to: home.appending(path: ".claude.json"))
        try Data("{\n  \"model\": \"opus\"\n}\n".utf8).write(to: home.appending(path: ".claude/settings.json"))
    }

    var env: HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home, variables: [
            "HOME": home.path, "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
            "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
        ], executableSearchPaths: [URL(filePath: "/usr/bin")])
    }

    var project: URL { home.appending(path: "Projects/app") }

    func akit(_ arguments: String...) async -> (code: Int32, out: String, err: String) {
        var out: [String] = [], err: [String] = []
        let code = await AKitCLI.run(arguments, env: env, cwd: project, projectsRoot: home.appending(path: "Projects"),
                                     out: { out.append($0) }, err: { err.append($0) })
        return (code, out.joined(separator: "\n"), err.joined(separator: "\n"))
    }

    func git(_ args: String..., in folder: URL) async throws {
        let result = try #require(await ProcessRunner.run(URL(filePath: "/usr/bin/git"), arguments: args, directory: folder,
                                                           environment: env.variables, timeout: 20))
        #expect(result.succeeded, "git \(args.joined(separator: " ")): \(result.output)")
    }

    func claudeState() throws -> JSONValue { try JSONValue.parse(Data(contentsOf: home.appending(path: ".claude.json"))) }

    @Test func offInProjectReachesWorktreesNowAndLater() async throws {
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        try await git("init", "-q", "-b", "main", in: project)
        try await git("commit", "-q", "--allow-empty", "-m", "init", in: project)
        let first = home.appending(path: "trees/one")
        try await git("worktree", "add", "-q", first.path, "-b", "one", in: project)

        let preview = await akit("mcp", "set", "github", "--harness", "claude", "--off", "project", "--project", project.path)
        #expect(preview.code == 0, "\(preview.err)")
        #expect(preview.out.contains("Changes ~/.claude.json:") && preview.out.contains("Run again with --yes"))
        let done = await akit("mcp", "set", "github", "--harness", "claude", "--off", "project", "--project", project.path, "--yes")
        #expect(done.code == 0, "\(done.err)")
        let main = project.standardizedFileURL.path
        let state = try claudeState()
        #expect(state.value(at: ["projects", main, "disabledMcpServers"]) == .array([.string("github")]))
        let worktreeKeys = state.value(at: ["projects"])?.objectMembers?.keys.filter { $0.hasSuffix("/trees/one") } ?? []
        #expect(worktreeKeys.count == 1)

        // A worktree made later gets it on the next sync.
        let second = home.appending(path: "trees/two")
        try await git("worktree", "add", "-q", second.path, "-b", "two", in: project)
        let sync = await akit("worktrees", "sync", project.path)
        #expect(sync.out.contains("MCP: github off for Claude"), "\(sync.out) \(sync.err)")
        #expect(try claudeState().value(at: ["projects"])?.objectMembers?.keys.contains { $0.hasSuffix("/trees/two") } == true)

        let status = await akit("mcp", "state", "github")
        #expect(status.out.contains("Claude: Off in 3 folders"), "\(status.out)")

        let on = await akit("mcp", "set", "github", "--harness", "claude", "--on", "--yes")
        #expect(on.code == 0, "\(on.err)")
        #expect(await akit("mcp", "state", "github").out.contains("Claude: On"))
    }

    @Test func everywhereAndConnectors() async throws {
        let off = await akit("mcp", "set", "github", "--harness", "claude", "--off", "everywhere", "--yes")
        #expect(off.code == 0, "\(off.err)")
        let settings = try String(contentsOf: home.appending(path: ".claude/settings.json"), encoding: .utf8)
        #expect(settings.contains("\"mcp__github\""))
        #expect(await akit("mcp", "connectors", "off", "--yes").code == 0)
        #expect(await akit("mcp", "state").out.contains("claude.ai connectors (Claude Code): Off"))
        #expect(await akit("mcp", "set", "github", "--harness", "claude", "--on", "--yes").code == 0)
        #expect(await akit("mcp", "connectors", "on", "--yes").code == 0)
        #expect(try String(contentsOf: home.appending(path: ".claude/settings.json"), encoding: .utf8) == "{\n  \"model\": \"opus\"\n}\n")
    }

    @Test func refusals() async {
        #expect(await akit("mcp", "set", "github", "--harness", "claude", "--off", "project").err.contains("needs --project"))
        #expect(await akit("mcp", "set", "nope", "--harness", "claude", "--off", "everywhere").err.contains("No MCP server named nope"))
        #expect(await akit("mcp", "set", "github", "--harness", "claude", "--off", "somewhere").err.contains("--off is everywhere or project"))
        #expect(await akit("mcp", "connectors", "maybe").code != 0)
    }
}
