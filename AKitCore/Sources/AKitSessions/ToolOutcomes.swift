import AKitFoundation
import Foundation

/// How the tool calls of a session ended, per tool. The kind of a failure comes from the
/// result text, so it is a best guess; `ok` and the counts are exact.
public struct ToolOutcomes: Codable, Sendable, Hashable {
    public enum Outcome: String, Codable, CaseIterable, Sendable, CodingKeyRepresentable {
        case ok
        /// The user, a permission rule, a hook or the auto mode classifier said no.
        case rejected
        /// The user stopped it.
        case interrupted
        /// The input was wrong: a validation error, a missing file, an edit string that isn't
        /// there or isn't unique, a file not read first.
        case inputMistake
        /// A shell command ran and failed (non-zero exit).
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
    public static func outcome(tool: String, result: String, isError: Bool) -> Outcome {
        let text = result.lowercased()
        if text.hasPrefix("[request interrupted by user") { return .interrupted }
        guard isError else { return .ok }
        if isRejection(result) { return .rejected }
        if transientMarkers.contains(where: text.contains) { return .transient }
        if inputMarkers.contains(where: text.contains) { return .inputMistake }
        if tool == "Bash" || text.contains("exit code") { return .commandFailed }
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
