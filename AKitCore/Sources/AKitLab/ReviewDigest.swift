import Foundation
import AKitSessions

/// A session cut down to fit one model call: numbered items, long texts shortened, thinking
/// left out. Tool results go first when it's still too long, then the middle of the session.
/// The items are already masked by the session readers.
enum ReviewDigest {
    /// Characters per kind of item; 0 leaves the kind out.
    struct Limits {
        var user: Int
        var assistant: Int
        var call: Int
        var result: Int
        var error: Int
        var event: Int
    }

    static let tiers = [
        Limits(user: 4000, assistant: 2000, call: 400, result: 300, error: 800, event: 400),
        Limits(user: 3000, assistant: 1000, call: 200, result: 120, error: 400, event: 200),
        Limits(user: 2000, assistant: 600, call: 120, result: 0, error: 240, event: 120),
    ]

    /// About 90K tokens: fits every current model with room for the answer.
    static let defaultBudget = 360_000

    static func text(_ transcript: SessionTranscript, budget: Int = defaultBudget) -> String {
        var lines: [String] = []
        for limits in tiers {
            lines = transcript.items.compactMap { line($0, limits) }
            if size(lines) <= budget { return lines.joined(separator: "\n") }
        }
        // Still too long: keep the start and the end, where the task and the outcome are.
        var used = 0
        var front = 0
        while front < lines.count, used + lines[front].count + 1 <= budget / 2 {
            used += lines[front].count + 1
            front += 1
        }
        var back = lines.count
        while back > front, used + lines[back - 1].count + 1 <= budget {
            used += lines[back - 1].count + 1
            back -= 1
        }
        return (lines[..<front] + ["[… \(back - front) items in the middle left out to fit …]"] + lines[back...])
            .joined(separator: "\n")
    }

    static func line(_ item: TranscriptItem, _ limits: Limits) -> String? {
        let (label, limit, keepEnd): (String, Int, Bool) = switch item.kind {
        case .user: ("user", limits.user, false)
        case .assistant: ("assistant", limits.assistant, false)
        case .thinking: ("thinking", 0, false)
        case .toolCall(let name): ("call \(name)", limits.call, false)
        case .toolResult(let name, let isError):
            ("\(isError ? "error" : "result")\(name.map { " \($0)" } ?? "")", isError ? limits.error : limits.result, true)
        case .event(let title): ("event \(title)", limits.event, false)
        }
        guard limit > 0 else { return nil }
        return "[#\(item.id) \(label)] \(cut(item.text, to: limit, keepEnd: keepEnd))"
    }

    /// The first `limit` characters, or for tool output its start and end (errors come last).
    static func cut(_ text: String, to limit: Int, keepEnd: Bool) -> String {
        guard text.count > limit else { return text }
        let more = text.count - limit
        guard keepEnd else { return "\(text.prefix(limit)) […\(more) chars]" }
        return "\(text.prefix(limit / 2)) […\(more) chars…] \(text.suffix(limit / 2))"
    }

    private static func size(_ lines: [String]) -> Int { lines.reduce(0) { $0 + $1.count + 1 } }
}
