import AKitFoundation
import Foundation

/// How the tool calls of a session ended, per tool. The kind of a failure comes from the
/// result text, so it is a best guess; `ok` and the counts are exact.
public struct ToolOutcomes: Codable, Sendable, Hashable {
    public enum Outcome: String, Codable, CaseIterable, Sendable, CodingKeyRepresentable {
        case ok
        /// The user (saying what to do instead), a permission rule or the auto mode classifier said no.
        case rejected
        /// The user stopped it (Esc or "No" at its permission prompt without saying what to do instead).
        case interrupted
        /// The input was wrong: a validation error, a missing file, an edit string that isn't
        /// there or isn't unique, a file not read first.
        case inputMistake
        /// A shell command failed (non-zero exit or not run).
        case commandFailed
        /// A timeout, the network, a rate limit or an overloaded service.
        case transient
        case otherError
        /// No result was recorded (the session ended or was cut before it came back).
        case noResult

        public var title: String {
            switch self {
            case .ok: "Succeeded"
            case .rejected: "Rejected"
            case .interrupted: "Interrupted"
            case .inputMistake: "Wrong input"
            case .commandFailed: "Command failed"
            case .transient: "Transient"
            case .otherError: "Other error"
            case .noResult: "No result"
            }
        }

        public var isFailure: Bool { [.inputMistake, .commandFailed, .transient, .otherError].contains(self) }

        /// The same call would fail the same way again; a transient failure may pass on a retry.
        public var isDeterministic: Bool { [.inputMistake, .commandFailed].contains(self) }
    }

    public struct Tool: Codable, Sendable, Hashable, Identifiable {
        public var name: String
        public var counts: [Outcome: Int] = [:]
        /// The first line of the first result of each failed outcome (secrets masked).
        public var examples: [Outcome: String] = [:]

        public var id: String { name }
        public var calls: Int { counts.values.reduce(0, +) }
        public var failed: Int { counts.filter { $0.key.isFailure }.values.reduce(0, +) }
        public func count(_ outcome: Outcome) -> Int { counts[outcome] ?? 0 }

        /// `mcp__claude-in-chrome__navigate` → `claude-in-chrome: navigate`.
        public var displayName: String {
            guard let server = MCPServers.server(ofTool: name) else { return name }
            return "\(server): \(name.dropFirst(5 + server.count + 2))"
        }
    }

    /// Most calls first.
    public var tools: [Tool]

    public init(tools: [Tool]) {
        self.tools = tools.sorted { ($0.calls, $1.name) > ($1.calls, $0.name) }
    }

    public var calls: Int { tools.reduce(0) { $0 + $1.calls } }
    public func count(_ outcome: Outcome) -> Int { tools.reduce(0) { $0 + $1.count(outcome) } }
    public var failed: Int { tools.reduce(0) { $0 + $1.failed } }
    public var deterministicFailures: Int { Outcome.allCases.filter(\.isDeterministic).reduce(0) { $0 + count($1) } }

    /// Part of all calls, 0…1.
    public func share(_ count: Int) -> Double { calls > 0 ? Double(count) / Double(calls) : 0 }

    /// The outcome of one tool result.
    /// A failed shell command is `commandFailed` whatever its output says (a test log may
    /// mention a timeout or a missing file). Other failures are read from the first lines only:
    /// the tool's own error message, not the text it returned.
    public static func outcome(tool: String, result: String, isError: Bool) -> Outcome {
        guard isError else { return .ok }
        if result.hasPrefix("[Request interrupted by user") { return .interrupted }
        if isRejection(result) { return .rejected }
        if tool == "Bash" || result.hasPrefix("Exit code") { return .commandFailed }
        let head = result.split(whereSeparator: \.isNewline).prefix(2).joined(separator: " ").lowercased()
        if transientMarkers.contains(where: head.contains) { return .transient }
        if inputMarkers.contains(where: head.contains) { return .inputMistake }
        return .otherError
    }

    /// The user said no, or a permission rule, a hook or the auto mode classifier refused.
    public static func isRejection(_ text: String) -> Bool {
        rejectionMarkers.contains { text.localizedCaseInsensitiveContains($0) }
    }

    public static let rejectionMarkers = [
        "doesn't want to proceed with this tool use",
        "Permission for this action was denied",
        "Permission for this tool use was denied",
        "Permission to use",
        "permission prompts are disabled",
        "requires approval",
    ]

    static let transientMarkers = [
        "timed out", "timeout", "econnreset", "etimedout", "econnrefused", "rate limit", "rate_limit", "overloaded",
        "temporarily unavailable", "socket hang up", "network error", "503 service", "502 bad gateway",
    ]

    static let inputMarkers = [
        "inputvalidationerror", "invalid input", "does not exist", "no such file", "not found", "has not been read yet",
        "modified since read", "matches of the string to replace", "must be unique", "is not a valid", "is a directory",
        "not a directory", "enoent", "eisdir", "exceeds maximum allowed tokens", "unknown skill", "cannot be empty",
    ]
}
