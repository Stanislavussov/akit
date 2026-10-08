import AKitFoundation
import Foundation

/// The failure signals Lab and the session index both count, with one definition of each
/// (`docs/design/definitions.md`, "Failure signals"). Fed the main conversation in order:
/// subagents are left out. Lab feeds it from the log lines, the index from transcript items.
public struct FailureSignals: Sendable, Hashable {
    /// User text that starts with `[Request interrupted by user` (Esc).
    public private(set) var interrupts = 0
    /// Tool calls that the user, a permission rule, a hook, the auto mode classifier or a Pi
    /// extension refused. Esc at the permission prompt is not one (see `PromptEscapes`).
    public private(set) var rejected = 0
    /// Tool calls that failed, without rejected and interrupted ones.
    public private(set) var toolErrors = 0
    /// Runs of 3 or more calls of the same tool with the same input in a row (no other tool call
    /// between them); each run counts once, however long it is.
    public private(set) var repeatedCalls = 0

    /// The tool and input of the last call, and how many calls in a row had them.
    private var lastCall: String?
    private var run = 0
    private var escapes = PromptEscapes()

    public static let interruptMarker = "[Request interrupted by user"
    /// The rule of `repeatedCalls`.
    public static let repeatRun = 3

    public init() {}

    /// The signals of a transcript's items (`.user`, `.toolCall` and `.toolResult` count). A
    /// result's outcome comes from the item when it has one: its text may be hidden.
    public init(_ items: [TranscriptItem]) {
        for item in items {
            switch item.kind {
            case .user: userText(item.text)
            case .toolCall(let name): toolCall(name, input: item.text)
            case .toolResult(let name, let isError):
                toolResult(name ?? "", item.outcome ?? ToolResultOutcome(tool: name ?? "", result: item.text, isError: isError))
            default: break
            }
        }
    }

    /// An interrupt is user text that starts with the marker; the marker inside other text is not one.
    public static func isInterrupt(_ text: String) -> Bool {
        text.drop(while: \.isWhitespace).hasPrefix(interruptMarker)
    }

    /// The input text of a tool call as a transcript item holds it: sorted JSON, secrets masked.
    /// Two calls are the same when their tool and this text are the same. A call whose input is
    /// empty is not in the transcript, so it is not fed either.
    public static func inputText(_ input: Any?) -> String {
        SecretFilter.masked(JSONLines.pretty(SecretFilter.redactedInput(input)).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// A user message of the main conversation (not a tool result, not a meta line).
    public mutating func userText(_ text: String) {
        guard Self.isInterrupt(text) else { return }
        interrupts += 1
        rejected -= escapes.userText(text).count
    }

    /// `input`: the call's input text (see `inputText`).
    public mutating func toolCall(_ name: String, input: String) {
        escapes.toolCall()
        let key = name + "\u{1}" + input
        if key == lastCall {
            run += 1
            if run == Self.repeatRun { repeatedCalls += 1 }
        } else {
            lastCall = key
            run = 1
        }
    }

    /// A tool result, read from its real text.
    public mutating func toolResult(_ tool: String, _ result: ToolResultOutcome) {
        escapes.result(tool: tool, result)
        if result.outcome == .rejected {
            rejected += 1
        } else if result.outcome.isFailure {
            toolErrors += 1
        }
    }
}

/// Esc at the permission prompt: Claude Code writes the user's refusal ("doesn't want to
/// proceed…") as the call's result, then `[Request interrupted by user for tool use]` before
/// the next tool call. Those refusals were interruptions. A permission rule's or hook's denial
/// in the same batch stays a refusal. Used by `FailureSignals` and the Overview tab.
public struct PromptEscapes: Sendable, Hashable {
    /// Tools whose results were the user's refusal since the last tool call.
    private var open: [String] = []

    public init() {}

    public mutating func toolCall() { open = [] }

    public mutating func result(tool: String, _ result: ToolResultOutcome) {
        if result.userRefusal { open.append(tool) }
    }

    /// The tools whose refusals this user text shows to be Esc at the prompt, one per refusal.
    public mutating func userText(_ text: String) -> [String] {
        guard text.drop(while: \.isWhitespace).hasPrefix("\(FailureSignals.interruptMarker) for tool use]") else { return [] }
        defer { open = [] }
        return open
    }
}
