import Foundation

/// A whole session as text to paste into another agent or an eval set.
/// Built from the transcript AKit shows, so secrets are already masked or hidden
/// (see SecretFilter) and nothing else is read from the session file.
public enum SessionExport {
    /// Readable Markdown: a header with the session facts, then every item in order.
    /// Thinking, tool calls, results and events are fenced blocks, so tool output
    /// can't break the structure.
    public static func markdown(_ session: SessionSummary, _ transcript: SessionTranscript) -> String {
        var lines = ["# \(session.title)", ""]
        for (label, value) in facts(session, transcript) {
            lines.append("- \(label): \(value)")
        }
        for item in transcript.items {
            lines.append("")
            switch item.kind {
            case .user:
                lines += ["## User", "", item.text]
            case .assistant:
                lines += ["## Assistant", "", item.text]
            case .thinking:
                lines += ["### Thinking", ""] + fenced(item.text)
            case .toolCall(let name):
                lines += ["### Tool call: \(name)", ""] + fenced(item.text)
            case .toolResult(let name, let isError):
                lines += ["### Tool \(isError ? "error" : "result")\(name.map { ": \($0)" } ?? "")", ""] + fenced(item.text)
            case .event(let title):
                lines += ["### Event: \(title)", ""] + fenced(item.text)
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// JSON for scripts and evals: session facts plus `items` with a `type` per entry
    /// (`user`, `assistant`, `thinking`, `tool_call`, `tool_result`, `event`).
    public static func json(_ session: SessionSummary, _ transcript: SessionTranscript) -> String {
        let export = Export(
            harness: session.harness.displayName,
            harnessVersion: session.harnessVersion,
            title: session.title,
            project: session.project?.path,
            started: session.started.map(date),
            models: transcript.models,
            items: transcript.items.map(Export.Item.init)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // Encoding plain strings and arrays can't fail.
        return String(decoding: (try? encoder.encode(export)) ?? Data(), as: UTF8.self)
    }

    private static func facts(_ session: SessionSummary, _ transcript: SessionTranscript) -> [(String, String)] {
        var facts = [("Harness", [session.harness.displayName, session.harnessVersion].compactMap(\.self).joined(separator: " "))]
        if let project = session.project { facts.append(("Project", project.path)) }
        if let started = session.started { facts.append(("Started", date(started))) }
        if !transcript.models.isEmpty { facts.append(("Models", transcript.models.joined(separator: ", "))) }
        facts.append(("Messages", "\(transcript.items.count) items"))
        return facts
    }

    /// A fence longer than any backtick run in the text.
    static func fenced(_ text: String) -> [String] {
        var longest = 0, run = 0
        for character in text {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return [fence, text, fence]
    }

    private static func date(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    private struct Export: Encodable {
        let harness: String
        let harnessVersion: String?
        let title: String
        let project: String?
        let started: String?
        let models: [String]
        let items: [Item]

        struct Item: Encodable {
            let type: String
            let name: String?
            let isError: Bool?
            let text: String
            let timestamp: String?

            init(_ item: TranscriptItem) {
                var name: String?
                var isError: Bool?
                switch item.kind {
                case .user: type = "user"
                case .assistant: type = "assistant"
                case .thinking: type = "thinking"
                case .toolCall(let tool):
                    type = "tool_call"
                    name = tool
                case .toolResult(let tool, let failed):
                    type = "tool_result"
                    name = tool
                    isError = failed
                case .event(let title):
                    type = "event"
                    name = title
                }
                self.name = name
                self.isError = isError
                text = item.text
                timestamp = item.timestamp.map(SessionExport.date)
            }
        }
    }
}
