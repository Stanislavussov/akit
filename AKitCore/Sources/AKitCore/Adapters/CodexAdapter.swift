import Foundation

/// OpenAI Codex CLI.
/// Paths verified against the Codex docs (config reference, skills) and a real machine (0.147.x).
public struct CodexAdapter: HarnessAdapter {
    public let id = HarnessID.codex
    public let displayName = "Codex"

    public init() {}

    /// `~/.codex`, or the folder from CODEX_HOME.
    public func configRoot(in env: HarnessEnvironment) -> URL {
        if let custom = env.variables["CODEX_HOME"], !custom.isEmpty {
            return env.expand(custom)
        }
        return env.homeDirectory.appending(path: ".codex")
    }

    public func detect(in env: HarnessEnvironment) -> HarnessInstallation? {
        let root = configRoot(in: env)
        let executable = env.findExecutable("codex")
        guard executable != nil || FileProbe.exists(root) else { return nil }

        let locations = [
            FileProbe.location("Settings & MCP", root.appending(path: "config.toml"), kind: .file, role: .settings,
                               note: "MCP servers are [mcp_servers.<name>] tables"),
            FileProbe.location("Shared skills", env.homeDirectory.appending(path: ".agents/skills"), kind: .directory, role: .skills,
                               note: "Codex reads your skills from here"),
            FileProbe.location("Built-in skills", root.appending(path: "skills/.system"), kind: .directory, role: .skills,
                               note: "Managed by Codex"),
            FileProbe.location("Hooks", root.appending(path: "hooks.json"), kind: .file, role: .extensions),
            FileProbe.location("Plugins", root.appending(path: "plugins"), kind: .directory, role: .extensions),
            FileProbe.location("Instructions", root.appending(path: "AGENTS.md"), kind: .file, role: .context),
        ]
        return HarnessInstallation(id: id, displayName: displayName, executableURL: executable,
                                   configRoot: root, locations: locations)
    }

    /// User skills: `~/.agents/skills`; project: `.agents/skills` from the project up to
    /// the repo root. Bundled skills sit in `~/.codex/skills/.system` (read-only).
    public func skillRoots(in env: HarnessEnvironment, projects: [URL]) -> [SkillRoot] {
        var roots = [
            SkillRoot(url: env.homeDirectory.appending(path: ".agents/skills"), harness: id, scope: .global,
                      layout: .recursive(rootMarkdown: false)),
            SkillRoot(url: configRoot(in: env).appending(path: "skills/.system"), harness: id, scope: .bundled(id),
                      layout: .recursive(rootMarkdown: false), isReadOnly: true, origin: "Codex"),
        ]
        for project in projects {
            for dir in PiAdapter.ancestorsToGitRoot(of: project, home: env.homeDirectory) {
                roots.append(SkillRoot(url: dir.appending(path: ".agents/skills"), harness: id, scope: .project(project),
                                       layout: .recursive(rootMarkdown: false)))
            }
        }
        return roots
    }
}
