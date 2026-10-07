import AKitFoundation
import Foundation

/// The files where a part of Claude Code's setup is defined, so it can be opened and edited:
/// a skill's SKILL.md, a subagent's .md, the settings or plugin hooks file of a hook, a plugin's
/// `.mcp.json`. Only existing files are returned; `settings.local.json` never is (it may hold
/// secrets). Plugins are the user-scope ones switched on in `settings.json`, and the ones
/// claude.ai syncs into `plugins/synced/<account>/<plugin>~<suffix>`.
public enum ClaudeSetupFiles {
    public enum Kind: Sendable {
        case skill, subagent, hook, mcpServer, settings
    }

    /// `name` as the session lists it: `ralph` or `oh-my-claudecode:ralph` for a skill or a
    /// subagent, `SessionStart:startup` for a hook, the server name for MCP.
    public static func files(_ kind: Kind, name: String, home: URL, project: URL?) -> [URL] {
        let root = home.appending(path: ".claude")
        let local = project?.appending(path: ".claude")
        let plugins = ClaudeCodeAdapter().enabledPlugins(configRoot: root) + syncedPlugins(configRoot: root)
        let parts = name.split(separator: ":", maxSplits: 1).map(String.init)
        let plugin = parts.count == 2 ? plugins.first { $0.name == parts[0] } : nil
        let base = parts.last ?? name
        var candidates: [URL] = []

        switch kind {
        case .skill:
            if let plugin {
                candidates = plugin.skillFolders.map { $0.appending(path: "\(base)/SKILL.md") }
            } else {
                candidates = [local, root].compactMap { $0?.appending(path: "skills/\(base)/SKILL.md") }
            }
        case .subagent:
            if let plugin {
                candidates = [plugin.folder.appending(path: "agents/\(base).md")]
            } else {
                candidates = [local, root].compactMap { $0?.appending(path: "agents/\(base).md") }
            }
        case .hook:
            let event = String(name.split(separator: ":").first ?? Substring(name))
            candidates = ([local?.appending(path: "settings.json"), root.appending(path: "settings.json")].compactMap { $0 }
                + plugins.map { $0.folder.appending(path: "hooks/hooks.json") })
                .filter { (try? String(contentsOf: $0, encoding: .utf8))?.contains("\"\(event)\"") == true }
        case .mcpServer:
            // Plugin servers are named `plugin_<plugin>_<server>`.
            candidates = plugins.filter { name.hasPrefix("plugin_\($0.name)_") }.flatMap {
                [$0.folder.appending(path: ".mcp.json"), $0.folder.appending(path: ".claude-plugin/plugin.json")]
            }
            if let file = project?.appending(path: ".mcp.json"),
               (try? String(contentsOf: file, encoding: .utf8))?.contains("\"\(name)\"") == true {
                candidates.append(file)
            }
        case .settings:
            candidates = [root.appending(path: "settings.json")] + [local?.appending(path: "settings.json")].compactMap { $0 }
        }
        var seen = Set<String>()
        return candidates.filter { url in
            url.lastPathComponent != "settings.local.json" && FileManager.default.fileExists(atPath: url.path)
                && seen.insert(url.standardizedFileURL.path).inserted
        }
    }

    /// Plugins claude.ai syncs for the account: `plugins/synced/<account>/<plugin>~<suffix>/`.
    static func syncedPlugins(configRoot root: URL) -> [ClaudeCodeAdapter.InstalledPlugin] {
        FileWalk.children(of: root.appending(path: "plugins/synced")).flatMap { account in
            FileWalk.children(of: account).filter(FileWalk.isDirectory).map { folder in
                let name = String(folder.lastPathComponent.split(separator: "~").first ?? "")
                return ClaudeCodeAdapter.InstalledPlugin(name: name, version: nil, folder: folder,
                                                         skillFolders: [folder.appending(path: "skills")])
            }
        }
    }
}
