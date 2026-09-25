import Foundation

/// A harness the user describes by hand (Add Harness… in the app).
/// Saved in `~/.akit/harnesses.json`. Paths may start with `~`, so the same file
/// works on every machine.
public struct CustomHarness: Codable, Hashable, Sendable, Identifiable {
    /// Stable id, e.g. "my-agent". Generated from the name.
    public var id: String
    public var name: String
    /// CLI command looked up in PATH, e.g. "goose". Empty = none.
    public var command: String
    /// Main config folder, e.g. "~/.config/goose".
    public var configRoot: String
    /// Main settings file. Empty = none.
    public var settingsFile: String
    /// Global skill folders (each has `<name>/SKILL.md` inside, any depth).
    public var skillFolders: [String]
    /// Skill folder inside every project, relative, e.g. ".goose/skills". Empty = none.
    public var projectSkillFolder: String
    public var agentsFolder: String
    public var mcpFile: String
    public var instructionsFile: String

    public init(id: String = "", name: String = "", command: String = "", configRoot: String = "",
                settingsFile: String = "", skillFolders: [String] = [], projectSkillFolder: String = "",
                agentsFolder: String = "", mcpFile: String = "", instructionsFile: String = "") {
        self.id = id
        self.name = name
        self.command = command
        self.configRoot = configRoot
        self.settingsFile = settingsFile
        self.skillFolders = skillFolders
        self.projectSkillFolder = projectSkillFolder
        self.agentsFolder = agentsFolder
        self.mcpFile = mcpFile
        self.instructionsFile = instructionsFile
    }

    // Missing keys become empty, so a short hand-written entry loads. A value of the
    // wrong type throws: the file is then reported as broken and never overwritten.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) throws -> String { try c.decodeIfPresent(String.self, forKey: key) ?? "" }
        name = try text(.name)
        id = try text(.id)
        command = try text(.command)
        configRoot = try text(.configRoot)
        settingsFile = try text(.settingsFile)
        skillFolders = try c.decodeIfPresent([String].self, forKey: .skillFolders) ?? []
        projectSkillFolder = try text(.projectSkillFolder)
        agentsFolder = try text(.agentsFolder)
        mcpFile = try text(.mcpFile)
        instructionsFile = try text(.instructionsFile)
        if id.isEmpty { id = Self.slug(name) }
    }

    public var harnessID: HarnessID { HarnessID("custom:\(id)", displayName: name) }

    /// Problems that block saving. Empty = OK.
    /// `isNew`: the id will be `slug(name)` and must not belong to another harness.
    public func validate(against others: [CustomHarness], reservedNames: [String], isNew: Bool) -> [String] {
        var problems: [String] = []
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let candidateID = isNew ? Self.slug(trimmed) : id
        if trimmed.isEmpty { problems.append("Name is required.") }
        if Self.slug(trimmed).isEmpty && !trimmed.isEmpty { problems.append("Name needs at least one letter or digit.") }
        let clash = others.contains { other in
            (isNew || other.id != id) && (other.id == candidateID || Self.slug(other.name) == Self.slug(trimmed))
        }
        if clash || reservedNames.contains(where: { Self.slug($0) == Self.slug(trimmed) }) {
            problems.append("A harness with this name already exists.")
        }
        let root = configRoot.trimmingCharacters(in: .whitespaces)
        if command.trimmingCharacters(in: .whitespaces).isEmpty && root.isEmpty {
            problems.append("Set a command or a config folder, so AKit can tell whether it is installed.")
        }
        if command.contains("/") && !command.hasPrefix("/") && !command.hasPrefix("~/") {
            problems.append("Command is a name like \"goose\" or a full path.")
        }
        if !root.isEmpty && Self.absolute(root) == nil {
            problems.append("Config folder must start with / or ~/.")
        }
        let paths = [settingsFile, agentsFolder, mcpFile, instructionsFile] + skillFolders
        for path in paths.map({ $0.trimmingCharacters(in: .whitespaces) }) where !path.isEmpty {
            if path.split(separator: "/").contains("..") {
                problems.append("Paths must not contain \"..\": \(path)")
            } else if Self.absolute(path) == nil && (root.isEmpty || Self.absolute(root) == nil) {
                problems.append("\(path) is relative, so it needs a config folder that starts with / or ~/.")
            }
        }
        let project = projectSkillFolder.trimmingCharacters(in: .whitespaces)
        if project.hasPrefix("/") || project.hasPrefix("~") {
            problems.append("Project skill folder is relative to the project, e.g. \".goose/skills\".")
        } else if !project.isEmpty && (project.split(separator: "/").allSatisfy { $0 == "." } || project.split(separator: "/").contains("..")) {
            problems.append("Project skill folder must be a subfolder, e.g. \".goose/skills\".")
        }
        return problems
    }

    /// `/x`, `~` or `~/x` → the path with `~` kept; anything else (relative, `$HOME/…`) → nil.
    static func absolute(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("/") || trimmed == "~" || trimmed.hasPrefix("~/") ? trimmed : nil
    }

    /// "My Agent 2" → "my-agent-2".
    public static func slug(_ name: String) -> String {
        let lowered = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(lowered).split(separator: "-").joined(separator: "-")
    }
}

/// Reads and writes `~/.akit/harnesses.json`.
public enum CustomHarnessStore {
    struct File: Codable {
        var version: Int? = 1
        var harnesses: [CustomHarness]
    }

    public enum Failure: LocalizedError {
        case duplicateID(String)
        public var errorDescription: String? {
            switch self {
            case .duplicateID(let id): "Two harnesses have the id \"\(id)\"."
            }
        }
    }

    public static func url(in env: HarnessEnvironment) -> URL {
        env.homeDirectory.appending(path: ".akit/harnesses.json")
    }

    /// Missing file = no custom harnesses. A broken file throws (and is never overwritten).
    public static func load(in env: HarnessEnvironment) throws -> [CustomHarness] {
        let url = url(in: env)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let list = try JSONDecoder().decode(File.self, from: Data(contentsOf: url)).harnesses
        var seen = Set<String>()
        for harness in list where !seen.insert(harness.id).inserted {
            throw Failure.duplicateID(harness.id)
        }
        return list
    }

    /// Re-reads the file right now, applies `change` and saves. If the file is broken
    /// (e.g. a hand edit in progress) nothing is written. Returns the saved list.
    @discardableResult
    public static func update(in env: HarnessEnvironment,
                              _ change: ([CustomHarness]) throws -> [CustomHarness]) throws -> [CustomHarness] {
        let list = try change(load(in: env))
        try save(list, in: env)
        return list
    }

    /// Writes the whole list. The previous version is copied to `~/.akit/backups/`
    /// (the newest 20 are kept). A symlinked file stays a symlink.
    static func save(_ harnesses: [CustomHarness], in env: HarnessEnvironment) throws {
        let url = url(in: env).resolvingSymlinksInPath()
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: url.path) {
            try backup(url, in: env)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(File(harnesses: harnesses)).write(to: url, options: .atomic)
    }

    static func backupFolder(in env: HarnessEnvironment) -> URL {
        env.homeDirectory.appending(path: ".akit/backups")
    }

    private static func backup(_ file: URL, in env: HarnessEnvironment) throws {
        let fm = FileManager.default
        let folder = backupFolder(in: env)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter.string(from: .now, timeZone: .current,
                                                formatOptions: [.withFullDate, .withTime, .withFractionalSeconds])
            .replacingOccurrences(of: ":", with: "")
        try fm.copyItem(at: file, to: folder.appending(path: "harnesses-\(stamp).json"))
        let old = (try? fm.contentsOfDirectory(atPath: folder.path))?
            .filter { $0.hasPrefix("harnesses-") }.sorted().dropLast(20) ?? []
        for name in old { try? fm.removeItem(at: folder.appending(path: name)) }
    }
}

/// Adapter built from a CustomHarness description.
public struct CustomHarnessAdapter: HarnessAdapter {
    public let definition: CustomHarness
    public var id: HarnessID { definition.harnessID }
    public var displayName: String { definition.name }

    public init(_ definition: CustomHarness) {
        self.definition = definition
    }

    /// The config folder; only absolute or `~/` paths count.
    func root(in env: HarnessEnvironment) -> URL? {
        CustomHarness.absolute(definition.configRoot).map(env.expand)
    }

    /// Absolute and `~/` paths as is; relative ones inside the config folder.
    /// Paths with `..` are ignored.
    func path(_ text: String, in env: HarnessEnvironment) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.split(separator: "/").contains("..") else { return nil }
        if let absolute = CustomHarness.absolute(trimmed) { return env.expand(absolute) }
        return root(in: env)?.appending(path: trimmed)
    }

    func executable(in env: HarnessEnvironment) -> URL? {
        let command = definition.command.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty else { return nil }
        if command.hasPrefix("/") || command.hasPrefix("~/") {
            let url = env.expand(command)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }
        return env.findExecutable(command)
    }

    public func detect(in env: HarnessEnvironment) -> HarnessInstallation? {
        let root = root(in: env)
        let exe = executable(in: env)
        guard exe != nil || root.map(FileProbe.exists) == true else { return nil }

        var locations: [ConfigLocation] = []
        if let url = path(definition.settingsFile, in: env) {
            locations.append(FileProbe.location("Settings", url, kind: .file, role: .settings))
        }
        for folder in definition.skillFolders {
            if let url = path(folder, in: env) {
                locations.append(FileProbe.location("Skills", url, kind: .directory, role: .skills))
            }
        }
        if let url = path(definition.agentsFolder, in: env) {
            locations.append(FileProbe.location("Agents", url, kind: .directory, role: .agents))
        }
        if let url = path(definition.mcpFile, in: env) {
            locations.append(FileProbe.location("MCP servers", url, kind: .file, role: .mcp))
        }
        if let url = path(definition.instructionsFile, in: env) {
            locations.append(FileProbe.location("Instructions", url, kind: .file, role: .context))
        }
        return HarnessInstallation(id: id, displayName: displayName, executableURL: exe,
                                   configRoot: root ?? exe?.deletingLastPathComponent() ?? env.homeDirectory,
                                   locations: locations, isCustom: true)
    }

    public func skillRoots(in env: HarnessEnvironment, projects: [URL]) -> [SkillRoot] {
        var roots = definition.skillFolders.compactMap { path($0, in: env) }.map {
            SkillRoot(url: $0, harness: id, scope: .global, layout: .recursive(rootMarkdown: false))
        }
        let relative = definition.projectSkillFolder.trimmingCharacters(in: .whitespaces)
        let parts = relative.split(separator: "/")
        if !relative.isEmpty, !relative.hasPrefix("/"), !relative.hasPrefix("~"),
           !parts.contains(".."), !parts.allSatisfy({ $0 == "." }) {
            roots += projects.map {
                SkillRoot(url: $0.appending(path: relative), harness: id, scope: .project($0),
                          layout: .recursive(rootMarkdown: false))
            }
        }
        return roots
    }
}
