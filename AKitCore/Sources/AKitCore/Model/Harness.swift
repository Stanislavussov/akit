import Foundation

/// Which harness this is. Built-in harnesses have static ids; harnesses the user
/// describes in `~/.akit/harnesses.json` get theirs from that file.
/// Equality uses `rawValue` only.
public struct HarnessID: Sendable, Hashable, Codable, Comparable, CustomStringConvertible {
    public let rawValue: String
    /// Short name for badges and messages ("Claude", "Pi").
    public let displayName: String

    public init(_ rawValue: String, displayName: String) {
        self.rawValue = rawValue
        self.displayName = displayName
    }

    public static let claudeCode = HarnessID("claude-code", displayName: "Claude")
    public static let pi = HarnessID("pi", displayName: "Pi")
    public static let openCode = HarnessID("opencode", displayName: "OpenCode")
    public static let codex = HarnessID("codex", displayName: "Codex")

    public static func == (a: HarnessID, b: HarnessID) -> Bool { a.rawValue == b.rawValue }
    public static func < (a: HarnessID, b: HarnessID) -> Bool { a.rawValue < b.rawValue }
    public func hash(into hasher: inout Hasher) { hasher.combine(rawValue) }
    public var description: String { rawValue }

    public static let builtIn: [HarnessID] = [.claudeCode, .pi, .openCode, .codex]

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self.builtIn.first { $0.rawValue == raw } ?? HarnessID(raw, displayName: raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Result of detecting a harness on this machine.
public struct HarnessInstallation: Sendable, Identifiable, Hashable {
    public var id: HarnessID
    public var displayName: String
    /// Path to the CLI (`claude`, `pi`), if found.
    public var executableURL: URL?
    /// Main config folder (`~/.claude`, `~/.pi/agent`).
    public var configRoot: URL
    /// Known config locations — both existing and not yet created.
    public var locations: [ConfigLocation]
    /// Described by the user in `~/.akit/harnesses.json`, not built into AKit.
    public var isCustom: Bool

    public init(id: HarnessID, displayName: String, executableURL: URL?, configRoot: URL, locations: [ConfigLocation],
                isCustom: Bool = false) {
        self.id = id
        self.isCustom = isCustom
        self.displayName = displayName
        self.executableURL = executableURL
        self.configRoot = configRoot
        self.locations = locations
    }
}

/// One place on disk where a harness keeps something of its own.
public struct ConfigLocation: Sendable, Identifiable, Hashable {
    public enum Kind: String, Sendable { case file, directory }
    public enum Role: String, Sendable, CaseIterable {
        case settings, skills, agents, mcp, context, prompts, extensions
    }

    public var id: String { url.path }
    public var title: String
    public var note: String?
    public var role: Role
    public var kind: Kind
    public var url: URL
    public var exists: Bool
    /// If this is a symlink — where it points (relative targets already resolved).
    public var symlinkDestination: URL?

    public init(title: String, note: String? = nil, role: Role, kind: Kind, url: URL, exists: Bool, symlinkDestination: URL? = nil) {
        self.title = title
        self.note = note
        self.role = role
        self.kind = kind
        self.url = url
        self.exists = exists
        self.symlinkDestination = symlinkDestination
    }
}
