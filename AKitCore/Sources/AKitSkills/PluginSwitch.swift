import AKitFoundation
import AKitHarnesses
import AKitModel
import Foundation

/// Disable Plugin…: a Claude Code plugin is on or off as a whole (`skillOverrides` doesn't reach
/// its skills), so a plugin skill leaves the context only with its plugin. Sets
/// `enabledPlugins["<plugin>@<marketplace>"]` to false in `~/.claude/settings.json` through
/// `SettingsFile` (backup, refused when the entry changed since the preview). Never automatic:
/// the preview names every skill that goes with it.
public enum PluginSwitch {
    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    public struct Plan: Sendable {
        public let plugin: String
        /// The `enabledPlugins` keys turned off.
        public let keys: [String]
        /// The plugin's skills that leave with it, as the scan found them.
        public let skills: [String]
        /// Its MCP servers, which stop too.
        public let servers: [String]
        /// Projects whose `.claude/settings.json` sets one of the keys to true: the plugin stays on there.
        public let keptOnIn: [String]
        public let change: SettingsFile.Change
        /// The settings file, as shown (`~/.claude/settings.json`).
        public let shownFile: String

        /// What the confirmation says: the keys, what goes with them, and where it stays on.
        public var summary: String {
            var lines = ["enabledPlugins in \(shownFile): " + keys.map { "\"\($0)\": true → false" }.joined(separator: ", ") + "."]
            lines.append(skills.isEmpty ? "No skills of it are installed here." : "Skills that go with it: \(skills.joined(separator: ", ")).")
            if !servers.isEmpty { lines.append("MCP servers that stop: \(servers.joined(separator: ", ")).") }
            lines.append("Its commands, agents and hooks go too.")
            if !keptOnIn.isEmpty { lines.append("It stays on in \(keptOnIn.joined(separator: ", ")): their .claude/settings.json turns it on.") }
            return lines.joined(separator: "\n")
        }
    }

    /// Turning `plugin` (the name before `@`) off. `installed`: the scanned skills, for the list.
    /// Turning `plugin` off. `servers`: the plugin's MCP server names (the app's scan); `projects`:
    /// project folders whose `.claude/settings.json` may turn it on again (`settings.local.json` is never read).
    public static func plan(plugin: String, installed: [Skill], servers: [String] = [], projects: [URL] = [],
                            in env: HarnessEnvironment) throws(Failure) -> Plan {
        guard let file = HarnessCatalog.configRoot(of: .claudeCode, in: env)?.appending(path: "settings.json") else {
            throw Failure(message: "Claude Code is not installed on this Mac.")
        }
        let home = env.homeDirectory
        let current: (data: Data, value: JSONValue)?
        do {
            current = try SettingsFile.read(file, home: home)
        } catch {
            throw Failure(message: error.message)
        }
        guard case .object(let enabled)? = current?.value.value(at: ["enabledPlugins"]) else {
            throw Failure(message: "\(FileWalk.tilde(file, home: home)) has no enabledPlugins entry for \(plugin).")
        }
        let keys = enabled.keys.filter { $0.split(separator: "@").first.map(String.init) == plugin && enabled[$0] == .bool(true) }.sorted()
        guard !keys.isEmpty else { throw Failure(message: "\(plugin) is not enabled in \(FileWalk.tilde(file, home: home)).") }
        let change: SettingsFile.Change
        do {
            change = try SettingsFile.change(file, edits: keys.map { .set(["enabledPlugins", $0], .bool(false)) }, home: home)
        } catch {
            throw Failure(message: error.message)
        }
        let skills = installed.filter { if case .plugin(let name) = $0.scope { name == plugin } else { false } }.map(\.name)
        var keptOn: [String] = []
        for project in projects {
            let file = project.appending(path: ".claude/settings.json")
            guard let read = try? SettingsFile.read(file, home: home),
                  case .object(let entries)? = read.value.value(at: ["enabledPlugins"]),
                  keys.contains(where: { entries[$0] == .bool(true) }) else { continue }
            keptOn.append(FileWalk.tilde(project, home: home))
        }
        return Plan(plugin: plugin, keys: keys, skills: Array(Set(skills)).sorted(), servers: Array(Set(servers)).sorted(),
                    keptOnIn: keptOn.sorted(), change: change, shownFile: FileWalk.tilde(file, home: home))
    }

    /// Writes it (backup first); returns the backup.
    @discardableResult
    public static func apply(_ plan: Plan, home: URL) throws(Failure) -> URL? {
        do {
            return try SettingsFile.apply(plan.change, home: home)
        } catch {
            throw Failure(message: error.message)
        }
    }
}
