import Foundation

/// OpenCode (opencode.ai).
/// Paths verified against opencode.ai/docs (config, skills, agents, rules) and a real machine (1.18.x).
public struct OpenCodeAdapter: HarnessAdapter {
    public let id = HarnessID.openCode
    public let displayName = "OpenCode"

    public init() {}

    /// `$XDG_CONFIG_HOME/opencode`, default `~/.config/opencode`.
    public func configRoot(in env: HarnessEnvironment) -> URL {
        if let xdg = env.variables["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return env.expand(xdg).appending(path: "opencode")
        }
        return env.homeDirectory.appending(path: ".config/opencode")
    }

    /// OPENCODE_CONFIG_DIR: an extra folder loaded like `.opencode` (skills, agents, …).
    /// Only visible when AKit itself was started with it (e.g. from a terminal).
    func extraConfigDir(in env: HarnessEnvironment) -> URL? {
        guard let dir = env.variables["OPENCODE_CONFIG_DIR"], !dir.isEmpty else { return nil }
        return env.expand(dir)
    }

    public func detect(in env: HarnessEnvironment) -> HarnessInstallation? {
        let root = configRoot(in: env)
        let executable = env.findExecutable("opencode")
        guard executable != nil || FileProbe.exists(root) else { return nil }

        // opencode.jsonc is accepted too; show whichever exists.
        let jsonc = root.appending(path: "opencode.jsonc")
        let settings = FileProbe.exists(jsonc) ? jsonc : root.appending(path: "opencode.json")
        var locations = [
            FileProbe.location("Settings & MCP", settings, kind: .file, role: .settings,
                               note: "MCP servers live under the \"mcp\" key"),
            FileProbe.location("Skills", root.appending(path: "skills"), kind: .directory, role: .skills),
            FileProbe.location("Shared skills", env.homeDirectory.appending(path: ".agents/skills"), kind: .directory, role: .skills,
                               note: "OpenCode also reads ~/.claude/skills"),
            FileProbe.location("Agents", root.appending(path: "agents"), kind: .directory, role: .agents),
            FileProbe.location("Commands", root.appending(path: "commands"), kind: .directory, role: .prompts),
            FileProbe.location("Plugins", root.appending(path: "plugins"), kind: .directory, role: .extensions),
            FileProbe.location("Instructions", root.appending(path: "AGENTS.md"), kind: .file, role: .context),
        ]
        if let extra = extraConfigDir(in: env) {
            locations.append(FileProbe.location("Extra config folder", extra, kind: .directory, role: .settings,
                                                note: "From OPENCODE_CONFIG_DIR"))
        }
        return HarnessInstallation(id: id, displayName: displayName, executableURL: executable,
                                   configRoot: root, locations: locations)
    }

    /// The `mcp` key of `opencode.json(c)`: global, in OPENCODE_CONFIG_DIR, and in the project root.
    public func mcpSources(in env: HarnessEnvironment, projects: [URL]) -> [MCPSource] {
        func config(in dir: URL) -> URL {
            let jsonc = dir.appending(path: "opencode.jsonc")
            return FileProbe.exists(jsonc) ? jsonc : dir.appending(path: "opencode.json")
        }
        func source(_ dir: URL, _ scope: SkillScope, _ layer: String, _ precedence: Int) -> MCPSource {
            MCPSource(file: config(in: dir), format: .jsonc, dialect: .openCode, keyPath: ["mcp"], harness: id,
                      scope: scope, layer: layer, precedence: precedence)
        }
        var sources = [source(configRoot(in: env), .global, "User", 0)]
        if let extra = extraConfigDir(in: env) { sources.append(source(extra, .global, "OPENCODE_CONFIG_DIR", 1)) }
        sources += projects.map { source($0, .project($0), "Project", 2) }
        return sources
    }

    /// The binary (1.18) globs `{skill,skills}/**/SKILL.md` in its own config folders and
    /// `skills/**/SKILL.md` in `.claude` / `.agents` (the docs say one level; the code recurses).
    /// Project folders are looked up from the project up to the git root.
    public func skillRoots(in env: HarnessEnvironment, projects: [URL]) -> [SkillRoot] {
        let configDirs = [configRoot(in: env)] + [extraConfigDir(in: env)].compactMap { $0 }
        let global = configDirs.flatMap { [$0.appending(path: "skill"), $0.appending(path: "skills")] } + [
            env.homeDirectory.appending(path: ".claude/skills"),
            env.homeDirectory.appending(path: ".agents/skills"),
        ]
        var roots = global.map { SkillRoot(url: $0, harness: id, scope: .global, layout: .recursive(rootMarkdown: false)) }
        for project in projects {
            for dir in PiAdapter.ancestorsToGitRoot(of: project, home: env.homeDirectory) {
                for sub in [".opencode/skill", ".opencode/skills", ".claude/skills", ".agents/skills"] {
                    roots.append(SkillRoot(url: dir.appending(path: sub), harness: id, scope: .project(project),
                                           layout: .recursive(rootMarkdown: false)))
                }
            }
        }
        return roots
    }

    /// The shared `.agents/skills`, so one copy also serves Pi and Codex.
    public func skillInstallRoot(for scope: InstallScope, in env: HarnessEnvironment) -> URL? {
        switch scope {
        case .global: env.homeDirectory.appending(path: ".agents/skills")
        case .project(let project): project.appending(path: ".agents/skills")
        }
    }
}
