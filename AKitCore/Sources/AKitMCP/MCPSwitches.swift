import AKitFoundation
import AKitHarnesses
import AKitModel
import Foundation

/// Turning an MCP server off without deleting it (docs/design/harness-support.md, "MCP
/// switches"), in each harness's own setting:
///
/// - Claude Code, Off Everywhere: `mcp__<server>` in `permissions.deny` of `~/.claude/settings.json`
///   (the tools leave the context; the server still starts).
/// - Claude Code, Off in Project: the server's name in `disabledMcpServers` of the project's entry
///   in `~/.claude.json` (what `/mcp` → Disable writes). Claude Code keys that entry by the
///   canonical git root (a linked worktree's main checkout), so one entry covers every worktree.
/// - Pi, Off Everywhere: `enabled: false` on the server in `~/.pi/agent/mcp.json`.
/// - Pi, Off in Project: `enabled: false` in each folder's `.pi/mcp.json` (main checkout and every
///   worktree): on the project's own entry, or a `{ "enabled": false }` override of a user server.
/// - All claude.ai connectors: `disableClaudeAiConnectors: true` in `~/.claude/settings.json`.
///
/// AKit records which entries it added (`~/.akit/mcp-off.json`); On removes only those, and an
/// entry made outside AKit only when asked. Every write goes through `SettingsFile`. Keeping a
/// Pi project file out of git is `MCPProjectSwitch`'s part (AKitProjectSetup).
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

    /// A project's main checkout and its other git worktrees. Pi keys its project file by the
    /// folder it starts in, so each one needs the entry; Claude Code uses only `main`'s root.
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
        /// Folders (paths) where it is off: canonical git roots for Claude Code, folders for Pi.
        public var offIn: [String] = []
        /// Deny rules for some of its tools (`mcp__x__tool`, `mcp__x__*`), which AKit never writes.
        public var partlyDenied: [String] = []
        /// Entries that turn it off but that AKit didn't write (by `/mcp` or by hand).
        public var outsideAKit: [String] = []
        /// Why the state can't be read (a settings file that isn't valid JSON).
        public var unknown: String?

        public init() {}

        public var isOn: Bool { !offEverywhere && offIn.isEmpty && unknown == nil }

        public var title: String {
            if unknown != nil { return "Unknown" }
            var parts: [String] = []
            if offEverywhere { parts.append("Off Everywhere") }
            if !offIn.isEmpty { parts.append("Off in \(offIn.count) \(offIn.count == 1 ? "Folder" : "Folders")") }
            if parts.isEmpty { parts.append("On") }
            if !partlyDenied.isEmpty { parts.append("Partly Denied") }
            return parts.joined(separator: ", ")
        }
    }

    // MARK: - Files

    static func claudeSettings(_ env: HarnessEnvironment) -> URL? {
        HarnessCatalog.configRoot(of: .claudeCode, in: env)?.appending(path: "settings.json")
    }

    static func piGlobal(_ env: HarnessEnvironment) -> URL? {
        HarnessCatalog.configRoot(of: .pi, in: env)?.appending(path: "mcp.json")
    }

    public static func piProject(_ folder: URL) -> URL { folder.appending(path: ".pi/mcp.json") }

    /// `~/.claude.json` can hold megabytes of history.
    static let stateLimit = 64 << 20

    /// The lock directory Claude Code takes to write `~/.claude.json`.
    static func claudeLock(_ env: HarnessEnvironment) -> URL {
        let state = HarnessCatalog.claudeStateFile(in: env)
        return state.deletingLastPathComponent().appending(path: state.lastPathComponent + ".lock")
    }

    /// The permission rule for all of a server's tools. Claude Code names tools
    /// `mcp__<server>__<tool>` with every character other than letters, digits, `_` and `-` as `_`.
    public static func denyRule(_ server: String) -> String {
        "mcp__" + String(server.unicodeScalars.map { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-") ? Character(scalar) : "_"
        })
    }

    /// The key of a folder's entry in `~/.claude.json`, as Claude Code 2.1.296 computes it
    /// (`getProjectPathForConfig` → `findCanonicalGitRoot`), NFC-normalized like its `On`:
    ///
    /// - `findGitRoot` (`Vn`): from the physical folder (Claude Code starts from `getcwd`) up to the
    ///   first folder whose `.git` is a folder or a file (lstat; a `.git` link counts only when it
    ///   leads to a readable text file, as `Ue` reads it); outside git, the folder itself.
    /// - `findCanonicalGitRoot` (`gt`/`Xn`): a `.git` file whose `gitdir:` folder sits in
    ///   `<commondir>/worktrees` and whose `gitdir` file points back to this checkout's `.git`
    ///   (real paths) is a linked worktree: the key is the main checkout's top (`<commondir>/..`),
    ///   or for a common dir not named `.git` (a bare repository) that folder unless it holds a
    ///   `.git` itself. Anything else (a submodule, a moved worktree, a `.git` file without
    ///   `gitdir:`, a link where a file should be) keeps the checkout's own top.
    public static func claudeProjectKey(_ folder: URL) -> String {
        let start = FileWalk.realPath(folder) ?? folder.standardizedFileURL.path
        guard let root = gitRoot(from: start) else { return nfc(start) }
        return nfc(canonicalRoot(root))
    }

    static func nfc(_ path: String) -> String { path.precomposedStringWithCanonicalMapping }

    /// `Vn`: the nearest folder at or above `start` holding a usable `.git`.
    static func gitRoot(from start: String) -> String? {
        var path = start
        for _ in 0..<256 {
            if hasGitEntry(in: path) { return path }
            let parent = (path as NSString).deletingLastPathComponent
            guard !parent.isEmpty, parent != path else { return nil }
            path = parent
        }
        return nil
    }

    /// `Ue`: `.git` is a folder or file; a link only when it leads to a file readable as UTF-8 text.
    static func hasGitEntry(in folder: String) -> Bool {
        let git = (folder as NSString).appendingPathComponent(".git")
        var info = stat()
        guard lstat(git, &info) == 0 else { return false }
        switch info.st_mode & S_IFMT {
        case S_IFDIR, S_IFREG: return true
        case S_IFLNK:
            guard let data = FileWalk.head(of: URL(filePath: git), limit: 1 << 20), !data.contains(0),
                  String(data: data, encoding: .utf8) != nil else { return false }
            return true
        default: return false
        }
    }

    /// `Xn`: the main checkout's top for a verified linked worktree, else `root`.
    static func canonicalRoot(_ root: String) -> String {
        func text(_ path: String, plainFileOnly: Bool) -> String? {
            var info = stat()
            if plainFileOnly { guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil } }
            guard let data = FileWalk.head(of: URL(filePath: path), limit: 1 << 20), !data.contains(0) else { return nil }
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func resolve(_ path: String, against base: String) -> String {
            let joined = path.hasPrefix("/") ? path : base + "/" + path
            var parts: [Substring] = []
            for part in joined.split(separator: "/") {
                if part == "." { continue }
                if part == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
                parts.append(part)
            }
            return "/" + parts.joined(separator: "/")
        }
        guard let content = text(root + "/.git", plainFileOnly: false), content.hasPrefix("gitdir:") else { return root }
        let gitdir = resolve(String(content.dropFirst("gitdir:".count)).trimmingCharacters(in: .whitespaces), against: root)
        guard let commonText = text(gitdir + "/commondir", plainFileOnly: true) else { return root }
        let common = resolve(commonText, against: gitdir)
        guard (gitdir as NSString).deletingLastPathComponent == common + "/worktrees" else { return root }
        guard let back = text(gitdir + "/gitdir", plainFileOnly: true),
              let backReal = FileWalk.realPath(URL(filePath: resolve(back, against: gitdir))),
              let rootReal = FileWalk.realPath(URL(filePath: root)), backReal == rootReal + "/.git" else { return root }
        if (common as NSString).lastPathComponent != ".git" {
            return hasGitEntry(in: common) ? root : common
        }
        return (common as NSString).deletingLastPathComponent
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
            let projectHelp = "Adds \(server.name) to disabledMcpServers of the project's entry in \(FileWalk.tilde(state, home: home)) (what /mcp → Disable writes). Claude Code keys the entry by the project's git root, so it covers every git worktree of the project."
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
            let projectHelp = "Sets enabled: false on \(server.name) in .pi/mcp.json of the project and of each of its git worktrees (an override of a user-level server), and keeps that file out of git. Pi reads it only in a trusted project, started in that folder."
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
        let owned: [Owned]
        let storeProblem: String?
        do {
            owned = try Store.load(home: home).owned
            storeProblem = nil
        } catch {
            owned = []
            storeProblem = error.message
        }
        var cache: [URL: Result<JSONValue, SettingsFile.Failure>] = [:]
        func json(_ url: URL, limit: Int = 4 << 20) -> Result<JSONValue, SettingsFile.Failure> {
            if let cached = cache[url] { return cached }
            let result: Result<JSONValue, SettingsFile.Failure>
            do { result = .success(try SettingsFile.read(url, home: home, limit: limit)?.value ?? .object([:])) } catch { result = .failure(error) }
            cache[url] = result
            return result
        }
        var keyCache: [String: Bool] = [:]
        func isCanonical(_ key: String) -> Bool {
            if let known = keyCache[key] { return known }
            let url = URL(filePath: key, directoryHint: .isDirectory)
            // A folder that is gone keeps its key; one inside a checkout counts only as its root.
            let canonical = !FileWalk.isDirectory(url) || claudeProjectKey(url) == key
            keyCache[key] = canonical
            return canonical
        }
        var statuses: [MCPServer.ID: [HarnessID: Status]] = [:]
        for server in servers {
            for harness in harnesses {
                guard let options = options(for: server, harness: harness, in: env), options.unavailable == nil else { continue }
                var status = Status()
                let name = server.name
                switch harness {
                case .claudeCode:
                    let stateFile = HarnessCatalog.claudeStateFile(in: env)
                    if let settings = claudeSettings(env) {
                        switch json(settings) {
                        case .success(let value):
                            let rules = denyList(value)
                            let rule = denyRule(name)
                            if options.modes.contains(.everywhere), rules.contains(rule) {
                                status.offEverywhere = true
                                if !owned.contains(.init(harness: harness.rawValue, server: name, file: settings.path, folder: nil)) {
                                    status.outsideAKit.append("\(rule) in permissions.deny")
                                }
                            }
                            status.partlyDenied = rules.filter { $0.hasPrefix(rule + "__") }
                        case .failure(let error): status.unknown = error.message
                        }
                    }
                    switch json(stateFile, limit: stateLimit) {
                    case .success(let value):
                        let own = options.ownProject.map { claudeProjectKey($0) }
                        status.offIn = claudeOffFolders(name, in: value).filter { key in own.map { $0 == key } ?? isCanonical(key) }
                        for key in status.offIn where !owned.contains(.init(harness: harness.rawValue, server: name, file: stateFile.path, folder: key)) {
                            status.outsideAKit.append("disabledMcpServers of \(FileWalk.tilde(URL(filePath: key), home: home))")
                        }
                    case .failure(let error): status.unknown = error.message
                    }
                default:
                    if options.modes.contains(.everywhere), let global = piGlobal(env) {
                        switch json(global) {
                        case .success(let value):
                            status.offEverywhere = value.value(at: ["mcpServers", name, "enabled"]) == .bool(false)
                            if status.offEverywhere, !owned.contains(.init(harness: harness.rawValue, server: name, file: global.path, folder: nil)) {
                                status.outsideAKit.append("enabled: false in \(FileWalk.tilde(global, home: home))")
                            }
                        case .failure(let error): status.unknown = error.message
                        }
                    }
                    var folders = projects
                    if let own = options.ownProject, !folders.contains(where: { $0.standardizedFileURL == own.standardizedFileURL }) { folders.append(own) }
                    for folder in folders {
                        if let own = options.ownProject, !belongs(folder, to: own) { continue }
                        guard case .success(let value) = json(piProject(folder)) else { continue }
                        guard value.value(at: ["mcpServers", name, "enabled"]) == .bool(false) else { continue }
                        status.offIn.append(folder.standardizedFileURL.path)
                        if !owned.contains(.init(harness: harness.rawValue, server: name, file: piProject(folder).path, folder: nil)) {
                            status.outsideAKit.append("enabled: false in \(FileWalk.tilde(piProject(folder), home: home))")
                        }
                    }
                    status.offIn = Array(Set(status.offIn)).sorted()
                }
                if let storeProblem { status.unknown = storeProblem }
                statuses[server.id, default: [:]][harness] = status
            }
        }
        // A record whose entry is gone (turned on by hand or by /mcp) is no longer AKit's: a later
        // /mcp Disable of the same server is the user's. Only records of files read just now.
        let evaluated = Set(servers.map(\.name))
        let stale = owned.filter { record in
            guard evaluated.contains(record.server), case .success(let value)? = cache[URL(filePath: record.file)] else { return false }
            return !isPresent(record, in: value, env: env)
        }
        if !stale.isEmpty, storeProblem == nil { try? Store.update(StoreEdit(removeOwned: stale), home: home) }
        return statuses
    }

    /// Whether the entry a record names is in the file's JSON.
    static func isPresent(_ record: Owned, in value: JSONValue, env: HarnessEnvironment) -> Bool {
        if record.harness == HarnessID.claudeCode.rawValue {
            if let folder = record.folder { return claudeOffFolders(record.server, in: value).contains(folder) }
            return denyList(value).contains(denyRule(record.server))
        }
        return value.value(at: ["mcpServers", record.server, "enabled"]) == .bool(false)
    }

    /// The folder is the project or one of its worktrees.
    static func belongs(_ folder: URL, to project: URL) -> Bool {
        if folder.standardizedFileURL == project.standardizedFileURL { return true }
        guard let main = GitCheckout.containing(folder)?.mainFolder, let own = GitCheckout.containing(project)?.mainFolder else { return false }
        return main.standardizedFileURL == own.standardizedFileURL
    }

    static func denyList(_ settings: JSONValue) -> [String] {
        guard case .array(let items)? = settings.value(at: ["permissions", "deny"]) else { return [] }
        return items.compactMap { if case .string(let text) = $0 { text } else { nil } }
    }

    /// Keys of `~/.claude.json` whose `disabledMcpServers` names the server.
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
        public var notes: [String]
        /// Folders whose entry is skipped (nothing to override there).
        public let skipped: [String]
        /// Entries made outside AKit that On leaves alone unless asked (`includeUnmanaged`).
        public let unmanaged: [String]
        /// Pi project folders whose `.pi/mcp.json` this plan writes.
        public let piFolders: [URL]
        /// Exclude files and the lines AKit adds before writing (`MCPProjectSwitch`).
        public var excludes: [URL: [String]] = [:]
        let store: StoreEdit
        public var changesNothing: Bool { changes.isEmpty && store.isEmpty && excludes.isEmpty }
    }

    /// Where a change applies: Off Everywhere, in some projects (each with its worktrees), or for
    /// On, `.all`: everywhere and every folder where it is off, plus `extra` projects (remembered
    /// ones and the worktrees of off folders, for Pi).
    public enum Target: Sendable {
        case everywhere
        case projects([Family])
        case all(extra: [Family])
    }

    /// `known`: project folders whose Pi files `.all` looks at. `includeUnmanaged`: On also removes
    /// entries made outside AKit (by `/mcp` or by hand).
    public static func plan(_ server: MCPServer, harness: HarnessID, off: Bool, target: Target, includeUnmanaged: Bool = false,
                            known: [URL] = [], in env: HarnessEnvironment) throws(Failure) -> Plan {
        guard let options = options(for: server, harness: harness, in: env) else {
            throw Failure("\(harness.displayName) doesn't use \(server.name).")
        }
        if let reason = options.unavailable { throw Failure(reason) }
        let home = env.homeDirectory
        let name = server.name
        var everywhere = false
        var families: [Family] = []
        var claudeKeys: [String] = []
        switch target {
        case .everywhere:
            guard options.modes.contains(.everywhere) else { throw Failure("\(harness.displayName) has no Off Everywhere for \(name): it is a project's own server.") }
            everywhere = true
        case .projects(let chosen):
            guard !chosen.isEmpty else { throw Failure("Choose at least one project.") }
            if let own = options.ownProject, chosen.contains(where: { !belongs($0.main, to: own) }) {
                throw Failure("\(name) is \(own.lastPathComponent)'s own server: it can only be off in that project.")
            }
            families = chosen
            claudeKeys = chosen.map { claudeProjectKey($0.main) }
        case .all(let extra):
            guard !off else { throw Failure("Off needs a place: everywhere or a project.") }
            everywhere = options.modes.contains(.everywhere)
            let status = statuses(of: [server], projects: known + extra.flatMap(\.folders), in: env)[server.id]?[harness] ?? Status()
            if let unknown = status.unknown { throw Failure(unknown) }
            claudeKeys = status.offIn
            families = status.offIn.map { Family(main: URL(filePath: $0, directoryHint: .isDirectory), worktrees: []) } + extra
            if let own = options.ownProject { families = families.filter { belongs($0.main, to: own) } }
        }

        let store: Store
        do { store = try Store.load(home: home) } catch { throw Failure(error.message) }
        var edit = StoreEdit()
        var changes: [SettingsFile.Change] = []
        var skipped: [String] = []
        var unmanaged: [String] = []
        var notes: [String] = []
        var piFolders: [URL] = []
        /// Off: the entry is added and recorded. On: an entry AKit recorded goes; another only when asked.
        func decide(_ entry: Owned, present: Bool, describe: String) -> Bool {
            if off {
                guard !present else { return false }
                edit.addOwned.append(entry)
                return true
            }
            guard present else { return false }
            if store.owned.contains(entry) {
                edit.removeOwned.append(entry)
                return true
            }
            if includeUnmanaged { return true }
            unmanaged.append(describe)
            return false
        }
        do {
            switch harness {
            case .claudeCode:
                if everywhere, let settings = claudeSettings(env) {
                    let value = try SettingsFile.read(settings, home: home)?.value ?? .object([:])
                    let rule = denyRule(name)
                    let present = denyList(value).contains(rule)
                    if decide(.init(harness: harness.rawValue, server: name, file: settings.path, folder: nil), present: present,
                              describe: "\(rule) in permissions.deny of \(FileWalk.tilde(settings, home: home))") {
                        let edits = try denyEdits(rule: rule, off: off, settings: value)
                        if !edits.isEmpty { changes.append(try SettingsFile.change(settings, edits: edits, home: home)) }
                    }
                }
                // Physical paths, compared as written (standardizing would turn /private/tmp into /tmp).
                var seenKeys = Set<String>()
                let keys = claudeKeys.filter { seenKeys.insert($0).inserted }
                if !keys.isEmpty {
                    let stateFile = HarnessCatalog.claudeStateFile(in: env)
                    let state = try SettingsFile.read(stateFile, home: home, limit: stateLimit)?.value ?? .object([:])
                    let offNow = claudeOffFolders(name, in: state)
                    var edits: [SettingsFile.Edit] = []
                    for key in keys {
                        guard decide(.init(harness: harness.rawValue, server: name, file: stateFile.path, folder: key), present: offNow.contains(key),
                                     describe: "\(name) in disabledMcpServers of \(FileWalk.tilde(URL(filePath: key), home: home)) in \(FileWalk.tilde(stateFile, home: home))"),
                              let folderEdit = try claudeFolderEdit(name, folder: key, off: off, state: state) else { continue }
                        if case .set(let path, _) = folderEdit, path.count == 2 {
                            notes.append("Claude Code has no entry for \(FileWalk.tilde(URL(filePath: key), home: home)) yet: AKit creates Claude Code's default entry (\(claudeProjectDefaults.keys.sorted().joined(separator: ", "))) with disabledMcpServers.")
                        }
                        edits.append(folderEdit)
                    }
                    if !edits.isEmpty {
                        changes.append(try SettingsFile.change(stateFile, edits: edits, home: home, limit: stateLimit, lock: claudeLock(env)))
                    }
                }
            default:
                if everywhere, let global = piGlobal(env) {
                    let value = try SettingsFile.read(global, home: home)?.value ?? .object([:])
                    let present = value.value(at: ["mcpServers", name, "enabled"]) == .bool(false)
                    if decide(.init(harness: harness.rawValue, server: name, file: global.path, folder: nil), present: present,
                              describe: "enabled: false in \(FileWalk.tilde(global, home: home))"),
                       let piEdit = piEnabledEdit(name, off: off, file: value, mayOverride: false) {
                        changes.append(try SettingsFile.change(global, edits: [piEdit], home: home))
                    }
                }
                let globalDefines = piGlobal(env).flatMap { try? SettingsFile.read($0, home: home)?.value.value(at: ["mcpServers", name]) } != nil
                for folder in uniquePaths(families.flatMap(\.folders)) {
                    let url = URL(filePath: folder, directoryHint: .isDirectory)
                    let file = piProject(url)
                    let value = try SettingsFile.read(file, home: home)?.value ?? .object([:])
                    let present = value.value(at: ["mcpServers", name, "enabled"]) == .bool(false)
                    guard let piEdit = piEnabledEdit(name, off: off, file: value, mayOverride: globalDefines) else {
                        if off, value.value(at: ["mcpServers", name]) == nil { skipped.append(folder) }
                        continue
                    }
                    guard decide(.init(harness: harness.rawValue, server: name, file: file.path, folder: nil), present: present,
                                 describe: "enabled: false in \(FileWalk.tilde(file, home: home))") else { continue }
                    changes.append(try SettingsFile.change(file, edits: [piEdit], home: home))
                    piFolders.append(url)
                }
                // Off in a project is remembered, so worktrees made later get it too.
                let entries = families.map { Intent(harness: harness.rawValue, server: name, project: $0.main.path) }
                if off {
                    edit.addIntents = entries.filter { !store.projects.contains($0) }
                } else if case .all = target {
                    edit.removeIntents = store.projects.filter { $0.harness == harness.rawValue && $0.server == name }
                } else {
                    edit.removeIntents = store.projects.filter { entries.contains($0) }
                }
            }
        } catch let error as SettingsFile.Failure {
            throw Failure(error.message)
        } catch let error as Failure {
            throw error
        } catch {
            throw Failure(error.localizedDescription)
        }

        if off, !families.isEmpty, harness == .pi {
            notes.append("Git worktrees made later get the same entry when AKit refreshes or syncs worktrees (akit worktrees sync).")
        }
        if harness == .claudeCode, off, everywhere {
            notes.append("The deny rule removes the server's tools from the context; Claude Code still starts the server.")
        }
        if !skipped.isEmpty {
            notes.append("Skipped (no \(name) server there or in ~/.pi/agent/mcp.json to override): \(skipped.map { FileWalk.tilde(URL(filePath: $0), home: home) }.joined(separator: ", ")).")
        }
        if !unmanaged.isEmpty {
            notes.append("Turned off outside AKit (by /mcp or by hand), so left as it is: \(unmanaged.joined(separator: "; ")). Choose to remove those too to turn it on there.")
        }
        notes.append("Only these entries change; the rest of each file stays as it is. The preview shows only the changed entries.")
        let place: String = switch target {
        case .everywhere: "Everywhere"
        case .projects(let chosen): "in \(chosen.map(\.main.lastPathComponent).joined(separator: ", "))"
        case .all: "Everywhere and in Every Project"
        }
        let title = "Turn \(name) \(off ? "Off" : "On") \(place) in \(harness.displayName)"
        return Plan(title: title, changes: changes, notes: notes, skipped: skipped, unmanaged: unmanaged, piFolders: piFolders, store: edit)
    }

    /// `disableClaudeAiConnectors: true` (off) or the key removed (on) in `~/.claude/settings.json`.
    public static func connectorsPlan(off: Bool, in env: HarnessEnvironment) throws(Failure) -> Plan {
        guard let settings = claudeSettings(env) else { throw Failure("Claude Code's settings folder is unknown.") }
        do {
            let value = try SettingsFile.read(settings, home: env.homeDirectory)?.value ?? .object([:])
            let now = value.value(at: ["disableClaudeAiConnectors"])
            var changes: [SettingsFile.Change] = []
            if off, now != .bool(true) {
                changes.append(try SettingsFile.change(settings, edits: [.set(["disableClaudeAiConnectors"], .bool(true))], home: env.homeDirectory))
            } else if !off, now != nil {
                changes.append(try SettingsFile.change(settings, edits: [.remove(["disableClaudeAiConnectors"])], home: env.homeDirectory))
            }
            return Plan(title: "Turn claude.ai Connectors \(off ? "Off" : "On") in Claude Code", changes: changes,
                        notes: [off ? "Claude Code stops fetching and connecting every claude.ai connector, in every session."
                                    : "Claude Code fetches and connects your claude.ai connectors again.",
                                "Only this key changes; the rest of the file stays as it is."],
                        skipped: [], unmanaged: [], piFolders: [], store: StoreEdit())
        } catch {
            throw Failure(error.message)
        }
    }

    /// Writes every file of the plan (each refused on its own if it changed), then records what
    /// AKit added. Exclude lines are `MCPProjectSwitch`'s. Returns the backups.
    @discardableResult
    public static func apply(_ plan: Plan, home: URL) throws(Failure) -> [URL] {
        var backups: [URL] = []
        var written: [String] = []
        for change in plan.changes {
            do {
                if let backup = try SettingsFile.apply(change, home: home) { backups.append(backup) }
                written.append(change.file.path)
            } catch {
                // Replaced, but the check after it failed: what AKit wrote is still AKit's.
                if error.written { written.append(change.file.path) }
                let done = backups.isEmpty ? "" : " Files written before it: backups in \(backups.map { FileWalk.tilde($0, home: home) }.joined(separator: ", "))."
                // What was written is AKit's: record it even when a later file failed.
                try? Store.update(plan.store.limited(to: written), home: home)
                throw Failure(error.message + done)
            }
        }
        if !plan.store.isEmpty {
            do { try Store.update(plan.store, home: home) } catch {
                throw Failure("The settings were written, but AKit couldn't record them in ~/.akit/mcp-off.json: \(error.localizedDescription)")
            }
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
    /// On: the override goes; else `enabled: false` goes (Pi's default is on).
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

    // MARK: - What AKit wrote, and projects remembered for later worktrees

    /// "Off in Project" for one Pi server, so later worktrees get it.
    public struct Intent: Codable, Hashable, Sendable {
        public let harness: String
        public let server: String
        /// The project's main checkout.
        public let project: String
    }

    /// An entry AKit added: the deny rule (Claude settings), the name in a folder's
    /// `disabledMcpServers` (`~/.claude.json`, `folder` = its key), or `enabled: false` (a Pi file).
    public struct Owned: Codable, Hashable, Sendable {
        public let harness: String
        public let server: String
        public let file: String
        public let folder: String?
    }

    struct StoreEdit: Sendable {
        var addIntents: [Intent] = []
        var removeIntents: [Intent] = []
        var addOwned: [Owned] = []
        var removeOwned: [Owned] = []
        var isEmpty: Bool { addIntents.isEmpty && removeIntents.isEmpty && addOwned.isEmpty && removeOwned.isEmpty }

        /// Only the records of entries in these files (the files actually written).
        func limited(to files: [String]) -> StoreEdit {
            StoreEdit(addIntents: [], removeIntents: [], addOwned: addOwned.filter { files.contains($0.file) },
                      removeOwned: removeOwned.filter { files.contains($0.file) })
        }
    }

    /// `~/.akit/mcp-off.json`.
    struct Store: Codable {
        var projects: [Intent] = []
        var owned: [Owned] = []

        static func file(_ home: URL) -> URL { home.appending(path: ".akit/mcp-off.json") }

        /// Empty when there is no file; a file that can't be read is refused, never replaced.
        static func load(home: URL) throws(Failure) -> Store {
            let url = file(home)
            guard FileManager.default.fileExists(atPath: url.path) else { return Store() }
            struct Saved: Codable { let projects: [Intent]?; let owned: [Owned]? }
            guard let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Saved.self, from: data) else {
                throw Failure("\(FileWalk.tilde(url, home: home)) can't be read; AKit won't change MCP switches until it is fixed or removed (it lists the entries AKit added).")
            }
            return Store(projects: saved.projects ?? [], owned: saved.owned ?? [])
        }

        static func update(_ edit: StoreEdit, home: URL) throws {
            var store = try load(home: home)
            store.projects.removeAll { edit.removeIntents.contains($0) }
            store.projects += edit.addIntents.filter { !store.projects.contains($0) }
            store.owned.removeAll { edit.removeOwned.contains($0) }
            store.owned += edit.addOwned.filter { !store.owned.contains($0) }
            store.projects.sort { ($0.project, $0.harness, $0.server) < ($1.project, $1.harness, $1.server) }
            store.owned.sort { ($0.file, $0.server, $0.folder ?? "") < ($1.file, $1.server, $1.folder ?? "") }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let url = file(home)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(store).write(to: url, options: .atomic)
        }
    }

    /// The remembered "Off in Project" entries (Pi).
    public static func intents(home: URL) throws(Failure) -> [Intent] { try Store.load(home: home).projects }

    /// The Pi entries a remembered server lacks in these worktrees; by name, without a scanned server.
    public static func worktreePlan(_ name: String, worktrees: [URL], in env: HarnessEnvironment) throws(Failure) -> Plan {
        let home = env.homeDirectory
        var changes: [SettingsFile.Change] = []
        var folders: [URL] = []
        var owned: [Owned] = []
        do {
            let globalDefines = piGlobal(env).flatMap { try? SettingsFile.read($0, home: home)?.value.value(at: ["mcpServers", name]) } != nil
            for folder in uniquePaths(worktrees) {
                let url = URL(filePath: folder, directoryHint: .isDirectory)
                let file = piProject(url)
                let value = try SettingsFile.read(file, home: home)?.value ?? .object([:])
                if let edit = piEnabledEdit(name, off: true, file: value, mayOverride: globalDefines) {
                    changes.append(try SettingsFile.change(file, edits: [edit], home: home))
                    folders.append(url)
                    owned.append(Owned(harness: HarnessID.pi.rawValue, server: name, file: file.path, folder: nil))
                }
            }
        } catch {
            throw Failure(error.message)
        }
        return Plan(title: "", changes: changes, notes: [], skipped: [], unmanaged: [], piFolders: folders, store: StoreEdit(addOwned: owned))
    }
}
