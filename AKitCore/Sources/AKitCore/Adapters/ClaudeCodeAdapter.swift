import Foundation

/// Claude Code.
/// Paths verified against code.claude.com/docs and a real machine (2.1.x).
public struct ClaudeCodeAdapter: HarnessAdapter {
    public let id = HarnessID.claudeCode
    public let displayName = "Claude Code"

    public init() {}

    /// `~/.claude`, or the folder from CLAUDE_CONFIG_DIR.
    public func configRoot(in env: HarnessEnvironment) -> URL {
        if let custom = env.variables["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
            return env.expand(custom)
        }
        return env.homeDirectory.appending(path: ".claude")
    }

    /// `~/.claude.json`; with CLAUDE_CONFIG_DIR set, Claude keeps it inside that folder.
    public func stateFile(in env: HarnessEnvironment) -> URL {
        if let custom = env.variables["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
            return env.expand(custom).appending(path: ".claude.json")
        }
        return env.homeDirectory.appending(path: ".claude.json")
    }

    public func detect(in env: HarnessEnvironment) -> HarnessInstallation? {
        let root = configRoot(in: env)
        let executable = env.findExecutable("claude")
        // Installed if either the CLI or the config folder exists.
        guard executable != nil || FileProbe.exists(root) else { return nil }

        let locations = [
            FileProbe.location("Settings", root.appending(path: "settings.json"), kind: .file, role: .settings),
            FileProbe.location("Local settings", root.appending(path: "settings.local.json"), kind: .file, role: .settings,
                               note: "May contain secrets"),
            FileProbe.location("MCP servers & state", stateFile(in: env), kind: .file, role: .mcp,
                               note: "Claude rewrites this file on its own"),
            FileProbe.location("Skills", root.appending(path: "skills"), kind: .directory, role: .skills),
            FileProbe.location("Subagents", root.appending(path: "agents"), kind: .directory, role: .agents),
            FileProbe.location("Commands (legacy)", root.appending(path: "commands"), kind: .directory, role: .prompts),
            FileProbe.location("Instructions", root.appending(path: "CLAUDE.md"), kind: .file, role: .context),
        ]
        return HarnessInstallation(id: id, displayName: displayName, executableURL: executable,
                                   configRoot: root, locations: locations)
    }

    /// Keys of `projects` in `~/.claude.json`: every folder Claude was started in.
    public func knownProjects(in env: HarnessEnvironment) -> [URL] {
        let url = stateFile(in: env)
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = json["projects"] as? [String: Any] else { return [] }
        return projects.keys.sorted().map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    public func skillRoots(in env: HarnessEnvironment, projects: [URL]) -> [SkillRoot] {
        let root = configRoot(in: env)
        let skills = root.appending(path: "skills")
        var roots = [SkillRoot(url: skills, harness: id, scope: .global, layout: .flat(),
                               syncedFolder: skills.appending(path: "synced"))]
        roots += projects.map {
            SkillRoot(url: $0.appending(path: ".claude/skills"), harness: id, scope: .project($0), layout: .flat())
        }
        roots += enabledPlugins(configRoot: root).flatMap { plugin in
            plugin.skillFolders.map {
                SkillRoot(url: $0, harness: id, scope: .plugin(name: plugin.name), layout: .flat(rootMayBeSkill: true),
                          isReadOnly: true, origin: [plugin.name, plugin.version].compactMap { $0 }.joined(separator: " "))
            }
        }
        return roots
    }

    /// `<config>/projects/*/<session id>.jsonl`.
    public func sessions(in env: HarnessEnvironment) -> [SessionSummary] {
        ClaudeSessions.list(configRoot: configRoot(in: env))
    }

    public func transcript(of session: SessionSummary) throws -> SessionTranscript {
        try ClaudeSessions.transcript(of: session.file)
    }

    struct InstalledPlugin {
        let name: String
        let version: String?
        let skillFolders: [URL]
    }

    /// User-scope plugins from `plugins/installed_plugins.json` that are switched on in
    /// `settings.json` (`enabledPlugins`). Only the installed version is used, not older
    /// copies in the cache. Project-scope plugins are not listed yet.
    func enabledPlugins(configRoot root: URL) -> [InstalledPlugin] {
        func json(_ url: URL) -> [String: Any]? {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        let enabled = (json(root.appending(path: "settings.json"))?["enabledPlugins"] as? [String: Any]) ?? [:]
        let installed = (json(root.appending(path: "plugins/installed_plugins.json"))?["plugins"] as? [String: Any]) ?? [:]

        var result: [InstalledPlugin] = []
        for key in installed.keys.sorted() where (enabled[key] as? Bool) == true {
            let name = String(key.split(separator: "@").first ?? Substring(key))
            for entry in (installed[key] as? [[String: Any]]) ?? [] where (entry["scope"] as? String ?? "user") == "user" {
                guard let path = entry["installPath"] as? String else { continue }
                let base = URL(filePath: path, directoryHint: .isDirectory)
                var folders = [base.appending(path: "skills")]
                // plugin.json may list skill folders explicitly.
                let listed = json(base.appending(path: ".claude-plugin/plugin.json"))?["skills"]
                let paths = (listed as? [String]) ?? (listed as? String).map { [$0] } ?? []
                folders += paths.map { base.appending(path: $0) }
                result.append(InstalledPlugin(name: name, version: entry["version"] as? String, skillFolders: folders))
            }
        }
        return result
    }
}
