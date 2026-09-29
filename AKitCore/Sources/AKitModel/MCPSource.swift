import Foundation

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
    public let precedence: Int
    public let isReadOnly: Bool
    /// Claude's answer for project servers; nil = no approval step.
    public var approval: MCPApproval?
    /// Set when the harness won't load this file right now.
    public var inactiveReason: String?
    /// Names switched off for this source (Claude's `/mcp` toggle: `disabledMcpServers`).
    public var turnedOff: Set<String> = []
    /// Claude's own state file (`~/.claude.json`): AKit changes its servers through the
    /// `claude mcp` CLI (user and local scopes) instead of editing the file.
    public var writesThroughClaudeCLI = false

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
public struct MCPApproval: Sendable {
    public var enabled: Set<String> = []
    public var disabled: Set<String> = []
    public var enableAll = false

    public init() {}
}
