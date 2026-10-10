import AKitFoundation
import AKitHarnesses
import AKitModel
import Foundation

/// Turning an MCP server off without deleting it (docs/design/harness-support.md, "MCP
/// switches"), in each harness's own setting:
///
/// - Claude Code, Off Everywhere: `mcp__<server>` in `permissions.deny` of `~/.claude/settings.json`
///   (the tools leave the context; the server still starts).
/// - Claude Code, Off in Project: the server's name in `disabledMcpServers` of the folder's entry
///   in `~/.claude.json` (`projects["<path>"]`, what `/mcp` → Disable writes), for the main checkout
///   and every git worktree.
/// - Pi, Off Everywhere: `enabled: false` on the server in `~/.pi/agent/mcp.json`.
/// - Pi, Off in Project: `enabled: false` in the folder's `.pi/mcp.json`: on the project's own entry,
///   or a `{ "enabled": false }` override of a user-level server.
/// - All claude.ai connectors: `disableClaudeAiConnectors: true` in `~/.claude/settings.json`.
///
/// On removes exactly these entries. Every write goes through `SettingsFile` (fresh read, refused
/// when the touched values changed, backup, in-place text edit checked as a tree edit).
public enum MCPSwitches {
    public static let harnesses: [HarnessID] = [.claudeCode, .pi]

    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
        public init(_ message: String) { self.message = message }
    }

    public enum Mode: String, CaseIterable, Sendable {
        case everywhere, project
    }

    /// A project's main checkout and its other git worktrees: Claude Code and Pi key their
    /// per-folder settings by the exact folder, so each one needs the entry.
    public struct Family: Hashable, Sendable {
        public let main: URL
        public let worktrees: [URL]
        public init(main: URL, worktrees: [URL]) {
            self.main = main.standardizedFileURL
            self.worktrees = worktrees.map(\.standardizedFileURL)
        }
        public var folders: [URL] { [main] + worktrees }
    }

    /// What a harness offers for one server entry.
    public struct Options: Hashable, Sendable {
        public let harness: HarnessID
        /// Empty when `unavailable`.
        public let modes: [Mode]
        /// A project's own server can only be off in that project.
        public let ownProject: URL?
        /// For tooltips: which file and key each mode writes.
        public let everywhereHelp: String?
        public let projectHelp: String
        public let unavailable: String?
    }

    /// The state of one server in one harness.
    public struct Status: Hashable, Sendable {
        public var offEverywhere = false
        /// Folders (paths) where it is off.
        public var offIn: [String] = []
        /// Why the state can't be read (a settings file that isn't valid JSON).
        public var unknown: String?

        public init() {}

        public var isOn: Bool { !offEverywhere && offIn.isEmpty && unknown == nil }

        public var title: String {
            if unknown != nil { return "Unknown" }
            if offEverywhere { return offIn.isEmpty ? "Off Everywhere" : "Off Everywhere, and in \(offIn.count) folder\(offIn.count == 1 ? "" : "s")" }
            if !offIn.isEmpty { return "Off in \(offIn.count) folder\(offIn.count == 1 ? "" : "s")" }
            return "On"
        }
    }

    // MARK: - Files

    static func claudeSettings(_ env: HarnessEnvironment) -> URL? {
        HarnessCatalog.configRoot(of: .claudeCode, in: env)?.appending(path: "settings.json")
    }

    static func piGlobal(_ env: HarnessEnvironment) -> URL? {
        HarnessCatalog.configRoot(of: .pi, in: env)?.appending(path: "mcp.json")
    }

    static func piProject(_ folder: URL) -> URL { folder.appending(path: ".pi/mcp.json") }

    /// `~/.claude.json` can hold megabytes of history.
    static let stateLimit = 64 << 20

    /// The permission rule for all of a server's tools. Claude Code names tools
    /// `mcp__<server>__<tool>` with every character other than letters, digits, `_` and `-` as `_`.
    public static func denyRule(_ server: String) -> String {
        "mcp__" + String(server.unicodeScalars.map { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-") ? Character(scalar) : "_"
        })
    }

    /// What Claude Code writes for a folder it hasn't seen yet (its own defaults, 2.1.296).
    static let claudeProjectDefaults: [String: JSONValue] = [
        "allowedTools": .array([]), "mcpContextUris": .array([]), "mcpServers": .object([:]),
        "enabledMcpjsonServers": .array([]), "disabledMcpjsonServers": .array([]), "hasTrustDialogAccepted": .bool(false),
        "hasClaudeMdExternalIncludesApproved": .bool(false), "hasClaudeMdExternalIncludesWarningShown": .bool(false),
    ]

    // MARK: - Options

    public static func options(for server: MCPServer, harness: HarnessID, in env: HarnessEnvironment) -> Options? {
        guard server.usedBy.contains(harness) else { return nil }
        let home = env.homeDirectory
        switch harness {
        case .claudeCode:
            let state = HarnessCatalog.claudeStateFile(in: env)
            let projectHelp = "Adds \(server.name) to disabledMcpServers of the folder's entry in \(FileWalk.tilde(state, home: home)), for the project and each of its git worktrees (what /mcp → Disable writes; Claude Code keys it by the exact folder)."
            switch server.scope {
            case .plugin:
                return Options(harness: harness, modes: [], ownProject: nil, everywhereHelp: nil, projectHelp: projectHelp,
                               unavailable: "A plugin's server is named after its plugin and marketplace, so AKit doesn't switch it alone; turn the plugin off with /plugin.")
            case .project(let project):
                return Options(harness: harness, modes: [.project], ownProject: project, everywhereHelp: nil, projectHelp: projectHelp, unavailable: nil)
            case .global where server.keyPath == ["mcpServers"] && server.file.standardizedFileURL == state.standardizedFileURL:
                let settings = claudeSettings(env).map { FileWalk.tilde($0, home: home) } ?? "settings.json"
                return Options(harness: harness, modes: [.everywhere, .project], ownProject: nil,
                               everywhereHelp: "Adds \(denyRule(server.name)) to permissions.deny in \(settings): its tools leave the context in every session; the server still starts.",
                               projectHelp: projectHelp, unavailable: nil)
            default:
                return Options(harness: harness, modes: [], ownProject: nil, everywhereHelp: nil, projectHelp: projectHelp,
                               unavailable: "AKit switches Claude Code's user, local and project servers only.")
            }
        case .pi:
            let unsupported = "AKit switches only servers in Pi's own mcp.json files (~/.pi/agent/mcp.json, .pi/mcp.json)."
            let projectHelp = "Sets enabled: false on \(server.name) in the folder's .pi/mcp.json (an override of a user-level server), for the project and each of its git worktrees. Pi reads it only in a trusted project, started in that folder."
            if let global = piGlobal(env), server.file.standardizedFileURL == global.standardizedFileURL {
                return Options(harness: harness, modes: [.everywhere, .project], ownProject: nil,
                               everywhereHelp: "Sets enabled: false on \(server.name) in \(FileWalk.tilde(global, home: home)): Pi keeps the entry and doesn't connect it.",
                               projectHelp: projectHelp, unavailable: nil)
            }
            if case .project(let project) = server.scope,
               server.file.standardizedFileURL == piProject(project).standardizedFileURL {
                return Options(harness: harness, modes: [.project], ownProject: project, everywhereHelp: nil, projectHelp: projectHelp, unavailable: nil)
            }
            return Options(harness: harness, modes: [], ownProject: nil, everywhereHelp: nil, projectHelp: projectHelp, unavailable: unsupported)
        default:
            return nil
        }
    }

    // MARK: - Reading

    /// Each server's state per harness that has a switch for it. `projects`: the folders whose
    /// Pi project files are read (Claude Code's entries are all in `~/.claude.json`).
    public static func statuses(of servers: [MCPServer], projects: [URL], in env: HarnessEnvironment) -> [MCPServer.ID: [HarnessID: Status]] {
        let home = env.homeDirectory
        var cache: [URL: Result<JSONValue, SettingsFile.Failure>] = [:]
        func json(_ url: URL, limit: Int = 4 << 20) -> Result<JSONValue, SettingsFile.Failure> {
            if let cached = cache[url] { return cached }
            let result: Result<JSONValue, SettingsFile.Failure>
            do { result = .success(try SettingsFile.read(url, home: home, limit: limit)?.value ?? .object([:])) } catch { result = .failure(error) }
            cache[url] = result
            return result
        }
        var statuses: [MCPServer.ID: [HarnessID: Status]] = [:]
        for server in servers {
            for harness in harnesses {
                guard let options = options(for: server, harness: harness, in: env), options.unavailable == nil else { continue }
                var status = Status()
                switch harness {
                case .claudeCode:
                    if options.modes.contains(.everywhere), let settings = claudeSettings(env) {
                        switch json(settings) {
                        case .success(let value): status.offEverywhere = denyList(value).contains(denyRule(server.name))
                        case .failure(let error): status.unknown = error.message
                        }
                    }
                    switch json(HarnessCatalog.claudeStateFile(in: env), limit: stateLimit) {
                    case .success(let value): status.offIn = claudeOffFolders(server.name, in: value)
                    case .failure(let error): status.unknown = error.message
                    }
                default:
                    if options.modes.contains(.everywhere), let global = piGlobal(env) {
                        switch json(global) {
                        case .success(let value): status.offEverywhere = value.value(at: ["mcpServers", server.name, "enabled"]) == .bool(false)
                        case .failure(let error): status.unknown = error.message
                        }
                    }
                    var folders = projects
                    if let own = options.ownProject, !folders.contains(where: { $0.standardizedFileURL == own.standardizedFileURL }) { folders.append(own) }
                    for folder in folders {
                        guard case .success(let value) = json(piProject(folder)) else { continue }
                        if value.value(at: ["mcpServers", server.name, "enabled"]) == .bool(false) { status.offIn.append(folder.standardizedFileURL.path) }
                    }
                    status.offIn.sort()
                }
                statuses[server.id, default: [:]][harness] = status
            }
        }
        return statuses
    }

    static func denyList(_ settings: JSONValue) -> [String] {
        guard case .array(let items)? = settings.value(at: ["permissions", "deny"]) else { return [] }
        return items.compactMap { if case .string(let text) = $0 { text } else { nil } }
    }

    /// Folders of `~/.claude.json` whose `disabledMcpServers` names the server.
    static func claudeOffFolders(_ name: String, in state: JSONValue) -> [String] {
        guard let projects = state.value(at: ["projects"])?.objectMembers else { return [] }
        return projects.compactMap { key, entry in
            guard case .array(let items)? = entry.objectMembers?["disabledMcpServers"], items.contains(.string(name)) else { return nil }
            return key
        }.sorted()
    }

    /// Whether all claude.ai connectors are off (`disableClaudeAiConnectors: true`); nil when the
    /// settings can't be read.
    public static func connectorsOff(in env: HarnessEnvironment) -> Bool? {
        guard let settings = claudeSettings(env) else { return false }
        do {
            return try SettingsFile.read(settings, home: env.homeDirectory)?.value.value(at: ["disableClaudeAiConnectors"]) == .bool(true)
        } catch {
            return nil
        }
    }

    // MARK: - Plans

    /// One change, ready to show and apply: one file change per file it touches.
    public struct Plan: Sendable {
        public let title: String
        public let changes: [SettingsFile.Change]
        public let notes: [String]
        /// Folders whose entry is skipped (nothing to override there), for messages.
        public let skipped: [String]
        let intents: IntentEdit?
        public var changesNothing: Bool { changes.isEmpty && intents == nil }
    }

    /// Where a change applies: Off Everywhere, in some projects (each with its worktrees), or for
    /// On, `.all`: everywhere and every folder where it is off.
    public enum Target: Sendable {
        case everywhere
        case projects([Family])
        case all
    }

    /// `known`: project folders whose Pi files `.all` looks at (Claude Code's are all in `~/.claude.json`).
    public static func plan(_ server: MCPServer, harness: HarnessID, off: Bool, target: Target, known: [URL] = [],
                            in env: HarnessEnvironment) throws(Failure) -> Plan {
        guard let options = options(for: server, harness: harness, in: env) else {
            throw Failure("\(harness.displayName) doesn't use \(server.name).")
        }
        if let reason = options.unavailable { throw Failure(reason) }
        let home = env.homeDirectory
        let name = server.name
        var everywhere = false
        var families: [Family] = []
        switch target {
        case .everywhere:
            guard options.modes.contains(.everywhere) else { throw Failure("\(harness.displayName) has no Off Everywhere for \(name): it is a project's own server.") }
            everywhere = true
        case .projects(let chosen):
            guard !chosen.isEmpty else { throw Failure("Choose at least one project.") }
            if let own = options.ownProject, chosen.contains(where: { $0.main != own.standardizedFileURL }) {
                throw Failure("\(name) is \(own.lastPathComponent)'s own server: it can only be off in that project.")
            }
            families = chosen
        case .all:
            guard !off else { throw Failure("Off needs a place: everywhere or a project.") }
            everywhere = options.modes.contains(.everywhere)
            let status = statuses(of: [server], projects: known, in: env)[server.id]?[harness] ?? Status()
            if let unknown = status.unknown { throw Failure(unknown) }
            families = status.offIn.map { Family(main: URL(filePath: $0, directoryHint: .isDirectory), worktrees: []) }
        }

        var changes: [SettingsFile.Change] = []
        var skipped: [String] = []
        do {
            switch harness {
            case .claudeCode:
                if everywhere, let settings = claudeSettings(env) {
                    let value = try SettingsFile.read(settings, home: home)?.value ?? .object([:])
                    let edits = try denyEdits(rule: denyRule(name), off: off, settings: value)
                    if !edits.isEmpty { changes.append(try SettingsFile.change(settings, edits: edits, preview: [["permissions", "deny"]], home: home)) }
                }
                let folders = families.flatMap(\.folders)
                if !folders.isEmpty {
                    let stateFile = HarnessCatalog.claudeStateFile(in: env)
                    let state = try SettingsFile.read(stateFile, home: home, limit: stateLimit)?.value ?? .object([:])
                    var edits: [SettingsFile.Edit] = []
                    for folder in uniquePaths(folders) {
                        if let edit = try claudeFolderEdit(name, folder: folder, off: off, state: state) { edits.append(edit) }
                    }
                    if !edits.isEmpty {
                        changes.append(try SettingsFile.change(stateFile, edits: edits, preview: edits.map { Array($0.path.prefix(2)) + ["disabledMcpServers"] },
                                                               home: home, limit: stateLimit))
                    }
                }
            default:
                if everywhere, let global = piGlobal(env) {
                    let value = try SettingsFile.read(global, home: home)?.value ?? .object([:])
                    if let edit = piEnabledEdit(name, off: off, file: value, mayOverride: false) {
                        changes.append(try SettingsFile.change(global, edits: [edit], preview: [["mcpServers", name]], home: home))
                    }
                }
                let globalDefines = piGlobal(env).flatMap { try? SettingsFile.read($0, home: home)?.value.value(at: ["mcpServers", name]) } != nil
                for folder in uniquePaths(families.flatMap(\.folders)) {
                    let file = piProject(URL(filePath: folder, directoryHint: .isDirectory))
                    let value = try SettingsFile.read(file, home: home)?.value ?? .object([:])
                    guard let edit = piEnabledEdit(name, off: off, file: value, mayOverride: globalDefines) else {
                        if off, value.value(at: ["mcpServers", name]) == nil { skipped.append(folder) }
                        continue
                    }
                    changes.append(try SettingsFile.change(file, edits: [edit], preview: [["mcpServers", name]], home: home))
                }
            }
        } catch let error as SettingsFile.Failure {
            throw Failure(error.message)
        } catch let error as Failure {
            throw error
        } catch {
            throw Failure(error.localizedDescription)
        }

        // Off in a project is remembered, so worktrees made later get it too (`syncWorktrees`).
        var intents: IntentEdit?
        if !families.isEmpty {
            let entries = families.map { Intent(harness: harness.rawValue, server: name, project: $0.main.path) }
            let saved = (try? Intents.load(home: home)) ?? []
            let changed = off ? entries.filter { !saved.contains($0) } : saved.filter { entry in entries.contains(entry) }
            if !changed.isEmpty { intents = IntentEdit(add: off, entries: changed) }
            if case .all = target {
                let all = saved.filter { $0.harness == harness.rawValue && $0.server == name }
                if !all.isEmpty { intents = IntentEdit(add: false, entries: all) }
            }
        }

        var notes: [String] = []
        if off, !families.isEmpty {
            notes.append("Git worktrees made later get the same entry when AKit refreshes or syncs worktrees (akit worktrees sync).")
        }
        if harness == .claudeCode, off, everywhere {
            notes.append("The deny rule removes the server's tools from the context; Claude Code still starts the server.")
        }
        if !skipped.isEmpty {
            notes.append("Skipped (no \(name) server there or in ~/.pi/agent/mcp.json to override): \(skipped.map { FileWalk.tilde(URL(filePath: $0), home: home) }.joined(separator: ", ")).")
        }
        notes.append("Only these entries change; the rest of each file stays as it is. The preview shows only the changed entries.")
        let place: String = switch target {
        case .everywhere: "Everywhere"
        case .projects(let chosen): "in \(chosen.map(\.main.lastPathComponent).joined(separator: ", "))"
        case .all: "Everywhere and in Every Project"
        }
        let title = "Turn \(name) \(off ? "Off" : "On") \(place) in \(harness.displayName)"
        return Plan(title: title, changes: changes, notes: notes, skipped: skipped, intents: intents)
    }

    /// `disableClaudeAiConnectors: true` (off) or the key removed (on) in `~/.claude/settings.json`.
    public static func connectorsPlan(off: Bool, in env: HarnessEnvironment) throws(Failure) -> Plan {
        guard let settings = claudeSettings(env) else { throw Failure("Claude Code's settings folder is unknown.") }
        do {
            let value = try SettingsFile.read(settings, home: env.homeDirectory)?.value ?? .object([:])
            let now = value.value(at: ["disableClaudeAiConnectors"])
            var changes: [SettingsFile.Change] = []
            if off, now != .bool(true) {
                changes.append(try SettingsFile.change(settings, edits: [.set(["disableClaudeAiConnectors"], .bool(true))],
                                                       preview: [["disableClaudeAiConnectors"]], home: env.homeDirectory))
            } else if !off, now != nil {
                changes.append(try SettingsFile.change(settings, edits: [.remove(["disableClaudeAiConnectors"])],
                                                       preview: [["disableClaudeAiConnectors"]], home: env.homeDirectory))
            }
            return Plan(title: "Turn claude.ai Connectors \(off ? "Off" : "On") in Claude Code", changes: changes,
                        notes: [off ? "Claude Code stops fetching and connecting every claude.ai connector, in every session."
                                    : "Claude Code fetches and connects your claude.ai connectors again.",
                                "Only this key changes; the rest of the file stays as it is."],
                        skipped: [], intents: nil)
        } catch {
            throw Failure(error.message)
        }
    }

    /// Writes every file of the plan (each refused on its own if it changed), then the remembered
    /// projects. Returns the backups.
    @discardableResult
    public static func apply(_ plan: Plan, home: URL) throws(Failure) -> [URL] {
        var backups: [URL] = []
        for change in plan.changes {
            do {
                if let backup = try SettingsFile.apply(change, home: home) { backups.append(backup) }
            } catch {
                let done = backups.isEmpty ? "" : " Files written before it: backups in \(backups.map { FileWalk.tilde($0, home: home) }.joined(separator: ", "))."
                throw Failure(error.message + done)
            }
        }
        if let intents = plan.intents {
            do { try Intents.update(intents, home: home) } catch { throw Failure("The settings were written, but AKit couldn't remember the project for later worktrees: \(error.localizedDescription)") }
        }
        return backups
    }

    // MARK: - Edits

    static func denyEdits(rule: String, off: Bool, settings: JSONValue) throws(Failure) -> [SettingsFile.Edit] {
        let permissions = settings.value(at: ["permissions"])
        if let permissions, permissions.objectMembers == nil { throw Failure("permissions in Claude Code's settings is not an object.") }
        var items: [JSONValue] = []
        switch permissions?.objectMembers?["deny"] {
        case nil: break
        case .array(let list)?: items = list
        default: throw Failure("permissions.deny in Claude Code's settings is not a list.")
        }
        if off {
            guard !items.contains(.string(rule)) else { return [] }
            items.append(.string(rule))
            return [.set(["permissions", "deny"], .array(items))]
        }
        guard items.contains(.string(rule)) else { return [] }
        items.removeAll { $0 == .string(rule) }
        if !items.isEmpty { return [.set(["permissions", "deny"], .array(items))] }
        // The list AKit emptied goes, and `permissions` with it when nothing else is left.
        return permissions?.objectMembers?.count == 1 ? [.remove(["permissions"])] : [.remove(["permissions", "deny"])]
    }

    static func claudeFolderEdit(_ name: String, folder: String, off: Bool, state: JSONValue) throws(Failure) -> SettingsFile.Edit? {
        if let projects = state.value(at: ["projects"]), projects.objectMembers == nil { throw Failure("projects in ~/.claude.json is not an object.") }
        guard let entry = state.value(at: ["projects", folder]) else {
            guard off else { return nil }
            var fresh = claudeProjectDefaults
            fresh["disabledMcpServers"] = .array([.string(name)])
            return .set(["projects", folder], .object(fresh))
        }
        guard let members = entry.objectMembers else { throw Failure("The entry of \(folder) in ~/.claude.json is not an object.") }
        var items: [JSONValue] = []
        switch members["disabledMcpServers"] {
        case nil: break
        case .array(let list)?: items = list
        default: throw Failure("disabledMcpServers of \(folder) in ~/.claude.json is not a list.")
        }
        if off {
            guard !items.contains(.string(name)) else { return nil }
            return .set(["projects", folder, "disabledMcpServers"], .array(items + [.string(name)]))
        }
        guard items.contains(.string(name)) else { return nil }
        // Claude Code's own toggle leaves an empty list too.
        return .set(["projects", folder, "disabledMcpServers"], .array(items.filter { $0 != .string(name) }))
    }

    /// Off: `enabled: false` on the entry, or a `{ "enabled": false }` override when `mayOverride`.
    /// On: the override AKit wrote goes; else `enabled: false` goes (Pi's default is on).
    static func piEnabledEdit(_ name: String, off: Bool, file: JSONValue, mayOverride: Bool) -> SettingsFile.Edit? {
        let entry = file.value(at: ["mcpServers", name])
        if off {
            guard let entry else { return mayOverride ? .set(["mcpServers", name], .object(["enabled": .bool(false)])) : nil }
            guard entry.objectMembers != nil, entry.objectMembers?["enabled"] != .bool(false) else { return nil }
            return .set(["mcpServers", name, "enabled"], .bool(false))
        }
        guard let members = entry?.objectMembers, members["enabled"] == .bool(false) else { return nil }
        return members.count == 1 ? .remove(["mcpServers", name]) : .remove(["mcpServers", name, "enabled"])
    }

    static func uniquePaths(_ folders: [URL]) -> [String] {
        var seen = Set<String>()
        return folders.map(\.standardizedFileURL.path).filter { seen.insert($0).inserted }
    }

    // MARK: - Projects remembered for later worktrees

    /// "Off in Project" for one server, kept in `~/.akit/mcp-off.json`.
    public struct Intent: Codable, Hashable, Sendable {
        public let harness: String
        public let server: String
        /// The project's main checkout.
        public let project: String
    }

    struct IntentEdit: Sendable {
        let add: Bool
        let entries: [Intent]
    }

    enum Intents {
        static func file(_ home: URL) -> URL { home.appending(path: ".akit/mcp-off.json") }

        static func load(home: URL) throws -> [Intent] {
            let url = file(home)
            guard FileManager.default.fileExists(atPath: url.path) else { return [] }
            struct Saved: Codable { let projects: [Intent] }
            return try JSONDecoder().decode(Saved.self, from: Data(contentsOf: url)).projects
        }

        static func update(_ edit: IntentEdit, home: URL) throws {
            var all = try load(home: home)
            if edit.add {
                all += edit.entries.filter { !all.contains($0) }
            } else {
                all.removeAll { edit.entries.contains($0) }
            }
            struct Saved: Codable { let projects: [Intent] }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let url = file(home)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(Saved(projects: all.sorted { ($0.project, $0.harness, $0.server) < ($1.project, $1.harness, $1.server) }))
                .write(to: url, options: .atomic)
        }
    }

    /// The remembered "Off in Project" entries.
    public static func intents(home: URL) -> [Intent] { (try? Intents.load(home: home)) ?? [] }

    /// Gives every worktree of a remembered project the entry it lacks (`families`: the remembered
    /// projects' current worktrees, from `ProjectWorktrees.family`). Writes only missing entries,
    /// each through `SettingsFile`; a file that changed meanwhile is left for the next sync.
    /// Returns what it did and what failed, for messages.
    public static func syncWorktrees(_ families: [Family], in env: HarnessEnvironment) -> (added: [String], problems: [String]) {
        let saved = intents(home: env.homeDirectory)
        var added: [String] = [], problems: [String] = []
        for family in families where !family.worktrees.isEmpty {
            for intent in saved where intent.project == family.main.path {
                guard let harness = harnesses.first(where: { $0.rawValue == intent.harness }) else { continue }
                do {
                    let plan = try worktreePlan(intent.server, harness: harness, worktrees: family.worktrees, in: env)
                    guard !plan.changesNothing else { continue }
                    try apply(plan, home: env.homeDirectory)
                    added.append("\(intent.server) off for \(harness.displayName) in the worktrees of \(family.main.lastPathComponent)")
                } catch {
                    problems.append("\(intent.server) (\(harness.displayName)) in the worktrees of \(family.main.lastPathComponent): \(error.message)")
                }
            }
        }
        return (added, problems)
    }

    /// The entries a remembered server lacks in new worktrees; by name, without a scanned server.
    static func worktreePlan(_ name: String, harness: HarnessID, worktrees: [URL], in env: HarnessEnvironment) throws(Failure) -> Plan {
        let home = env.homeDirectory
        var changes: [SettingsFile.Change] = []
        do {
            if harness == .claudeCode {
                let stateFile = HarnessCatalog.claudeStateFile(in: env)
                let state = try SettingsFile.read(stateFile, home: home, limit: stateLimit)?.value ?? .object([:])
                var edits: [SettingsFile.Edit] = []
                for folder in uniquePaths(worktrees) {
                    if let edit = try claudeFolderEdit(name, folder: folder, off: true, state: state) { edits.append(edit) }
                }
                if !edits.isEmpty { changes.append(try SettingsFile.change(stateFile, edits: edits, preview: [], home: home, limit: stateLimit)) }
            } else {
                let globalDefines = piGlobal(env).flatMap { try? SettingsFile.read($0, home: home)?.value.value(at: ["mcpServers", name]) } != nil
                for folder in uniquePaths(worktrees) {
                    let file = piProject(URL(filePath: folder, directoryHint: .isDirectory))
                    let value = try SettingsFile.read(file, home: home)?.value ?? .object([:])
                    if let edit = piEnabledEdit(name, off: true, file: value, mayOverride: globalDefines) {
                        changes.append(try SettingsFile.change(file, edits: [edit], preview: [], home: home))
                    }
                }
            }
        } catch let error as SettingsFile.Failure {
            throw Failure(error.message)
        } catch let error as Failure {
            throw error
        } catch {
            throw Failure(error.localizedDescription)
        }
        return Plan(title: "", changes: changes, notes: [], skipped: [], intents: nil)
    }
}
