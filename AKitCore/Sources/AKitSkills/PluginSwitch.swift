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
        public let change: SettingsFile.Change
    }

    /// Turning `plugin` (the name before `@`) off. `installed`: the scanned skills, for the list.
    public static func plan(plugin: String, installed: [Skill], in env: HarnessEnvironment) throws(Failure) -> Plan {
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
        return Plan(plugin: plugin, keys: keys, skills: Array(Set(skills)).sorted(), change: change)
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
