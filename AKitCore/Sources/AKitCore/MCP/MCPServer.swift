import Foundation

/// One MCP server entry in one config file. The same entry can be used by several
/// harnesses (a project `.mcp.json` is read by Claude and by Pi's MCP adapter), so it
/// is listed once with one `MCPUse` per harness.
///
/// Secrets never reach this model: env and header values are kept only as `${VAR}`
/// references or commands, everything else is `.hidden`; arguments and URLs are masked.
public struct MCPServer: Identifiable, Hashable, Sendable {
    /// File + place inside the file + name. Unique per entry.
    public var id: String { "\(file.path)|\(keyPath.joined(separator: "/"))|\(name)" }

    public let name: String
    public let file: URL
    /// Where the `name → server` table sits inside the file, e.g. `["projects", "/x", "mcpServers"]`.
    public let keyPath: [String]
    public let scope: SkillScope
    public let transport: MCPTransport
    /// Masked command and arguments (stdio servers).
    public let command: String?
    public let arguments: [String]
    /// Masked URL (remote servers).
    public let url: String?
    public let workingDirectory: String?
    public let environment: [MCPSetting]
    public let headers: [MCPSetting]
    /// Variables the harness must find in its environment when it starts the server
    /// (`${VAR}` without a default, Codex `bearer_token_env_var`, …). Sorted, no duplicates.
    public let variables: [String]
    public internal(set) var uses: [MCPUse]
    public let isReadOnly: Bool
    public internal(set) var warnings: [String]

    public var usedBy: [HarnessID] { uses.map(\.harness) }
}

public enum MCPTransport: Hashable, Sendable {
    case stdio, http, sse
    case other(String)

    public var title: String {
        switch self {
        case .stdio: "stdio"
        case .http: "HTTP"
        case .sse: "SSE"
        case .other(let name): name
        }
    }
}

/// An env variable or header of a server, safe to show.
public struct MCPSetting: Hashable, Sendable {
    public enum Value: Hashable, Sendable {
        /// Only references, e.g. `${GITHUB_TOKEN}` or `Bearer ${TOKEN}`: the secret itself lives elsewhere.
        case reference(String)
        /// A command the harness runs to get the value (pi-mcp-adapter's `!command`). Masked.
        case command(String)
        /// A value written into the file. Never shown: it may be a secret.
        case hidden
    }

    public let key: String
    public let value: Value
}

/// How one harness treats a server entry.
public struct MCPUse: Hashable, Sendable {
    public let harness: HarnessID
    /// Which of the harness's config layers this is, e.g. "User", "Local", "Project".
    public let layer: String
    /// Higher wins when two entries of one harness have the same name.
    let precedence: Int
    public internal(set) var state: MCPState
}

public enum MCPState: Hashable, Sendable {
    case active
    /// Turned off in the config (`disabled: true`, `enabled = false`).
    case disabled
    /// A project server Claude asks about before its first use.
    case needsApproval
    /// A project server the user rejected in Claude.
    case rejected
    /// Another entry with the same name wins (layer and file of that entry).
    case shadowed(by: String)
    /// The harness can't use it now (reason).
    case inactive(String)

    public var title: String {
        switch self {
        case .active: "Active"
        case .disabled: "Turned off"
        case .needsApproval: "Waiting for approval"
        case .rejected: "Rejected"
        case .shadowed(let other): "Overridden by \(other)"
        case .inactive(let reason): reason
        }
    }

    public var isActive: Bool { self == .active }
}

/// A file (or a part of one) a harness reads MCP servers from.
public struct MCPSource: Sendable {
    public enum Format: Sendable {
        /// JSON; `.jsonc` also allows comments and trailing commas.
        case json, jsonc, toml
    }

    /// How server entries are spelled.
    public enum Dialect: Sendable {
        /// `{command, args, env, cwd}` or `{type, url, headers}` — Claude, Pi, most tools.
        case standard
        /// OpenCode: `{type: local, command: [...], environment}` / `{type: remote, url, headers}`.
        case openCode
        /// Codex: `command, args, env, env_vars, url, bearer_token_env_var, http_headers, env_http_headers`.
        case codex
    }

    public let file: URL
    public let format: Format
    public let dialect: Dialect
    /// Path to the `name → server` table inside the file.
    public let keyPath: [String]
    public let harness: HarnessID
    public let scope: SkillScope
    public let layer: String
    let precedence: Int
    public let isReadOnly: Bool
    /// Claude's answer for project servers; nil = no approval step.
    var approval: MCPApproval?
    /// Set when the harness won't load this file right now.
    var inactiveReason: String?
    /// Names switched off for this source (Claude's `/mcp` toggle: `disabledMcpServers`).
    var turnedOff: Set<String> = []

    public init(file: URL, format: Format = .json, dialect: Dialect = .standard, keyPath: [String],
                harness: HarnessID, scope: SkillScope, layer: String, precedence: Int, isReadOnly: Bool = false) {
        self.file = file
        self.format = format
        self.dialect = dialect
        self.keyPath = keyPath
        self.harness = harness
        self.scope = scope
        self.layer = layer
        self.precedence = precedence
        self.isReadOnly = isReadOnly
    }
}

/// Claude's approval of project `.mcp.json` servers, collected from its settings.
struct MCPApproval: Sendable {
    var enabled: Set<String> = []
    var disabled: Set<String> = []
    var enableAll = false

    func state(of name: String) -> MCPState {
        if disabled.contains(name) { return .rejected }
        if enableAll || enabled.contains(name) { return .active }
        return .needsApproval
    }
}

/// Everything found, plus files that couldn't be read.
public struct MCPScanResult: Sendable {
    public var servers: [MCPServer] = []
    public var problems: [String] = []
}
