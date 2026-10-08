import AKitFoundation
import Foundation

/// How the tool calls of a session ended, per tool. The kind of a failure comes from the
/// result text, so it is a best guess; `ok` and the counts are exact.
public struct ToolOutcomes: Codable, Sendable, Hashable {
    public enum Outcome: String, Codable, CaseIterable, Sendable, CodingKeyRepresentable {
        case ok
        /// The user (saying what to do instead), a permission rule, the auto mode classifier or
        /// (Pi) an extension said no.
        case rejected
        /// The user stopped it (Esc or "No" at its permission prompt without saying what to do instead;
        /// Pi: "Command aborted").
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
    /// A shell command that ran and failed is `commandFailed` whatever its output says (a test
    /// log may mention a timeout or a missing file): Claude Code starts its result with
    /// `Exit code N`, Pi ends it with `Command exited with code N`. Other failures are read from
    /// the first lines only: the tool's own error message, not the text it returned.
    public static func outcome(tool: String, result: String, isError: Bool) -> Outcome {
        guard isError else { return .ok }
        let lines = result.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        // Pi ends a shell result with how the command ended.
        let last = lines.last ?? ""
        // Claude Code: "[Request interrupted by user…"; Pi: "Command aborted".
        if result.hasPrefix("[Request interrupted by user") || last == "Command aborted" { return .interrupted }
        if last.hasPrefix("Command timed out") { return .transient }
        if last.hasPrefix("Command exited with code") { return .commandFailed }
        let head = lines.prefix(2).joined(separator: " ")
        // Pi extensions that refuse a call answer "Blocked write: …", "Blocked edit: …".
        if isRejection(head) || head.wholeMatch(of: /Blocked [a-z_]+: .*/) != nil { return .rejected }
        // The command ran: whatever its output says (a test log may mention a timeout).
        if result.hasPrefix("Exit code") { return .commandFailed }
        // Before the shell rule: the auto mode classifier timing out means the command never ran.
        let lowered = head.lowercased()
        if transientMarkers.contains(where: lowered.contains) { return .transient }
        if tool.lowercased() == "bash" { return .commandFailed }
        if inputMarkers.contains(where: lowered.contains) { return .inputMistake }
        return .otherError
    }

    /// The user said no, or a permission rule, a hook or the auto mode classifier refused.
    public static func isRejection(_ text: String) -> Bool {
        rejectionMarkers.contains { text.localizedCaseInsensitiveContains($0) }
    }

    /// The user's own refusal. Claude Code writes it also when the user presses Esc at the
    /// permission prompt, then follows it with `[Request interrupted by user for tool use]`.
    public static let userRefusalMarker = "doesn't want to proceed with this tool use"

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
        "transient failure",
    ]

    static let inputMarkers = [
        "inputvalidationerror", "invalid input", "does not exist", "no such file", "not found", "has not been read yet",
        "modified since read", "matches of the string to replace", "must be unique", "is not a valid", "is a directory",
        "not a directory", "enoent", "eisdir", "exceeds maximum allowed tokens", "unknown skill", "cannot be empty",
        "could not find the exact text",
    ]
}

/// How one tool result ended, read from its real text: a transcript hides the text of a call
/// that touched a secrets file, so the outcome is taken before that and kept with the item.
public struct ToolResultOutcome: Sendable, Hashable {
    public let outcome: ToolOutcomes.Outcome
    /// A refusal in the user's own words, the only one Esc at the permission prompt also writes.
    public let userRefusal: Bool

    public init(tool: String, result: String, isError: Bool) {
        outcome = ToolOutcomes.outcome(tool: tool, result: result, isError: isError)
        let head = result.split(whereSeparator: \.isNewline).prefix(2).joined(separator: " ")
        userRefusal = outcome == .rejected && head.localizedCaseInsensitiveContains(ToolOutcomes.userRefusalMarker)
    }
}
