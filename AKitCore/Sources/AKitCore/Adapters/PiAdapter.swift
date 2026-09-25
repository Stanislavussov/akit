import Foundation

/// Pi coding agent (@earendil-works/pi-coding-agent).
/// Paths verified against the docs/ shipped in the installed package (0.84.x) and a real machine.
public struct PiAdapter: HarnessAdapter {
    public let id = HarnessID.pi
    public let displayName = "Pi"

    public init() {}

    /// `~/.pi/agent`, or the folder from PI_CODING_AGENT_DIR.
    public func configRoot(in env: HarnessEnvironment) -> URL {
        if let custom = env.variables["PI_CODING_AGENT_DIR"], !custom.isEmpty {
            return env.expand(custom)
        }
        return env.homeDirectory.appending(path: ".pi/agent")
    }

    public func detect(in env: HarnessEnvironment) -> HarnessInstallation? {
        let root = configRoot(in: env)
        let executable = env.findExecutable("pi")
        guard executable != nil || FileProbe.exists(root) else { return nil }

        let locations = [
            FileProbe.location("Settings", root.appending(path: "settings.json"), kind: .file, role: .settings),
            FileProbe.location("Models & providers", root.appending(path: "models.json"), kind: .file, role: .settings),
            FileProbe.location("Skills", root.appending(path: "skills"), kind: .directory, role: .skills),
            FileProbe.location("Shared skills", env.homeDirectory.appending(path: ".agents/skills"), kind: .directory, role: .skills,
                               note: "Pi reads this folder by default"),
            FileProbe.location("Subagents", root.appending(path: "agents"), kind: .directory, role: .agents,
                               note: "Only work with the pi-subagents package"),
            FileProbe.location("Prompt templates", root.appending(path: "prompts"), kind: .directory, role: .prompts),
            FileProbe.location("Extensions", root.appending(path: "extensions"), kind: .directory, role: .extensions),
            FileProbe.location("MCP servers", root.appending(path: "mcp.json"), kind: .file, role: .mcp,
                               note: "Only read by the pi-mcp-adapter extension"),
            FileProbe.location("Instructions", root.appending(path: "AGENTS.md"), kind: .file, role: .context),
        ]
        return HarnessInstallation(id: id, displayName: displayName, executableURL: executable,
                                   configRoot: root, locations: locations)
    }

    /// Pi has no MCP of its own; the pi-mcp-adapter package reads these files (later wins):
    /// `~/.config/mcp/mcp.json`, `~/.agents/mcp.json`, `~/.agents/mcp/mcp.json`,
    /// `<Pi dir>/mcp.json`, then per project `.mcp.json` and `.pi/mcp.json`.
    /// Without the package only Pi's own files are listed, marked as not loaded.
    public func mcpSources(in env: HarnessEnvironment, projects: [URL]) -> [MCPSource] {
        let root = configRoot(in: env)
        let home = env.homeDirectory
        let globalAdapter = Self.hasMCPAdapter(settings: root.appending(path: "settings.json"))
        func source(_ file: URL, _ scope: SkillScope, _ layer: String, _ precedence: Int, installed: Bool) -> MCPSource {
            var source = MCPSource(file: file, keyPath: ["mcpServers"], harness: id, scope: scope,
                                   layer: layer, precedence: precedence)
            if !installed { source.inactiveReason = "Needs the pi-mcp-adapter package" }
            return source
        }
        var sources: [MCPSource] = []
        if globalAdapter {
            sources += [
                source(home.appending(path: ".config/mcp/mcp.json"), .global, "Shared", 0, installed: true),
                source(home.appending(path: ".agents/mcp.json"), .global, "Shared", 1, installed: true),
                source(home.appending(path: ".agents/mcp/mcp.json"), .global, "Shared", 2, installed: true),
            ]
        }
        sources.append(source(root.appending(path: "mcp.json"), .global, "Pi global", 3, installed: globalAdapter))
        for project in projects {
            let installed = globalAdapter || Self.hasMCPAdapter(settings: project.appending(path: ".pi/settings.json"))
            if installed {
                sources.append(source(project.appending(path: ".mcp.json"), .project(project), "Project", 4, installed: true))
            }
            sources.append(source(project.appending(path: ".pi/mcp.json"), .project(project), "Pi project", 5,
                                  installed: installed))
        }
        return sources
    }

    /// Whether Pi settings list the pi-mcp-adapter package (`packages`, plain or `{source}` entries).
    static func hasMCPAdapter(settings: URL) -> Bool {
        guard let data = try? Data(contentsOf: settings),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let packages = json["packages"] as? [Any] else { return false }
        return packages.contains { entry in
            let text = entry as? String ?? (entry as? [String: Any])?["source"] as? String ?? ""
            return text.contains("pi-mcp-adapter")
        }
    }

    /// Mirrors Pi's loader (core/package-manager.js):
    /// global `~/.pi/agent/skills` and `~/.agents/skills`; per project `.pi/skills`
    /// and `.agents/skills` in the project and each parent up to the git root.
    public func skillRoots(in env: HarnessEnvironment, projects: [URL]) -> [SkillRoot] {
        var roots = [
            SkillRoot(url: configRoot(in: env).appending(path: "skills"), harness: id, scope: .global,
                      layout: .recursive(rootMarkdown: true)),
            SkillRoot(url: env.homeDirectory.appending(path: ".agents/skills"), harness: id, scope: .global,
                      layout: .recursive(rootMarkdown: false)),
        ]
        for project in projects {
            roots.append(SkillRoot(url: project.appending(path: ".pi/skills"), harness: id, scope: .project(project),
                                   layout: .recursive(rootMarkdown: true)))
            for dir in Self.ancestorsToGitRoot(of: project, home: env.homeDirectory) {
                roots.append(SkillRoot(url: dir.appending(path: ".agents/skills"), harness: id, scope: .project(project),
                                       layout: .recursive(rootMarkdown: false)))
            }
        }
        return roots
    }

    public func sessions(in env: HarnessEnvironment) -> [SessionSummary] {
        PiSessions.list(folder: PiSessions.folder(configRoot: configRoot(in: env), in: env))
    }

    public func transcript(of session: SessionSummary) throws -> SessionTranscript {
        try PiSessions.transcript(of: session.file)
    }

    public var systemPromptAccess: SystemPromptAccess { .captured }

    /// See PiPromptProbe. nil when the `pi` command isn't found.
    public func capturePrompt(in project: URL, env: HarnessEnvironment) async throws -> PromptSnapshot? {
        guard let executable = env.findExecutable("pi") else { return nil }
        return try await PiPromptProbe.capture(executable: executable, project: project, env: env)
    }

    /// The shared `.agents/skills` (Codex and OpenCode read it too), not `~/.pi/agent/skills`.
    public func skillInstallRoot(for scope: InstallScope, in env: HarnessEnvironment) -> URL? {
        switch scope {
        case .global: env.homeDirectory.appending(path: ".agents/skills")
        case .project(let project): project.appending(path: ".agents/skills")
        }
    }

    /// The folder itself and its parents up to the git root. Without a git root Pi
    /// walks to `/`; we stop at home, whose `.agents/skills` is already the global root.
    static func ancestorsToGitRoot(of start: URL, home: URL) -> [URL] {
        let fm = FileManager.default
        let homePath = home.standardizedFileURL.path
        var dirs: [URL] = []
        var dir = start.standardizedFileURL
        while true {
            if dir.path == homePath { break }
            dirs.append(dir)
            if fm.fileExists(atPath: dir.appending(path: ".git").path) { break }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return dirs
    }
}
