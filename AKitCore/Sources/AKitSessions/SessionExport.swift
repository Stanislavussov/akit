import AKitModel
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
        if transcript.usage.hasTokens {
            lines += ["", "## Usage", ""] + usageLines(transcript.usage)
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

    /// Only the usage part of `markdown`: a table per model plus activity counts.
    public static func usageMarkdown(_ session: SessionSummary, _ transcript: SessionTranscript) -> String {
        var lines = ["# Usage: \(session.title)", ""]
        for (label, value) in facts(session, transcript) {
            lines.append("- \(label): \(value)")
        }
        lines += [""] + usageLines(transcript.usage)
        return lines.joined(separator: "\n") + "\n"
    }

    /// Plain numbers (no separators), so agents and scripts can read them.
    static func usageLines(_ usage: SessionUsage) -> [String] {
        var lines = [
            "| Model | Requests | Input | Output | Reasoning | Cache read | Cache write | Total | Cost, USD |",
            "|---|--:|--:|--:|--:|--:|--:|--:|--:|",
        ]
        func row(_ name: String, _ requests: Int, _ tokens: TokenCounts, _ cost: Double?) -> String {
            let values = [requests, tokens.input, tokens.output, tokens.reasoning, tokens.cacheRead, tokens.cacheWrite,
                          tokens.total].map(String.init)
            return "| \(name) | \(values.joined(separator: " | ")) | \(cost.map(money) ?? "–") |"
        }
        for model in usage.models {
            lines.append(row(model.id, model.requests, model.tokens, model.cost))
        }
        for model in usage.subagentModels {
            lines.append(row("Subagents: \(model.id)", model.requests, model.tokens, model.cost))
        }
        let all = usage.models + usage.subagentModels
        if all.count > 1 {
            lines.append(row("**Total**", all.reduce(0) { $0 + $1.requests }, usage.tokens + usage.subagentTokens, usage.cost))
        }
        lines.append("")
        lines.append("- Context: peak \(usage.peakContext), last \(usage.lastContext) tokens")
        if let active = usage.activeTime { lines.append("- Active time: \(Int(active.rounded())) s") }
        if let first = usage.firstActivity, let last = usage.lastActivity {
            lines.append("- Wall time: \(Int(last.timeIntervalSince(first).rounded())) s")
        }
        lines.append("- Prompts: \(usage.userPrompts), tool calls: \(usage.toolCalls) (\(usage.toolErrors) failed), "
                     + "compactions: \(usage.compactions), subagent runs: \(usage.subagentRuns)")
        if !usage.tools.isEmpty {
            lines.append("- Tools: " + usage.tools.map { "\($0.name) \($0.calls)" }.joined(separator: ", "))
        }
        return lines
    }

    private static func money(_ value: Double) -> String { String(format: "%.4f", value) }

    /// JSON for scripts and evals: session facts, `usage`, and `items` with a `type` per entry
    /// (`user`, `assistant`, `thinking`, `tool_call`, `tool_result`, `event`).
    public static func json(_ session: SessionSummary, _ transcript: SessionTranscript) -> String {
        let export = Export(
            harness: session.harness.displayName,
            harnessVersion: session.harnessVersion,
            title: session.title,
            project: session.project?.path,
            started: session.started.map(date),
            models: transcript.models,
            usage: Export.Usage(transcript.usage),
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
        let usage: Usage
        let items: [Item]

        struct Usage: Encodable {
            struct Tokens: Encodable {
                let input, output, reasoning, cacheRead, cacheWrite, total: Int
                init(_ tokens: TokenCounts) {
                    (input, output, reasoning) = (tokens.input, tokens.output, tokens.reasoning)
                    (cacheRead, cacheWrite, total) = (tokens.cacheRead, tokens.cacheWrite, tokens.total)
                }
            }
            struct Model: Encodable {
                let model: String
                let provider: String?
                let requests: Int
                let tokens: Tokens
                let costUSD: Double?
                init(_ usage: ModelUsage) {
                    (model, provider, requests) = (usage.model, usage.provider, usage.requests)
                    tokens = Tokens(usage.tokens)
                    costUSD = usage.cost
                }
            }
            let models: [Model]
            let subagentModels: [Model]
            let subagentRuns: Int
            let tokens: Tokens
            let subagentTokens: Tokens
            let costUSD: Double?
            let peakContext, lastContext: Int
            let activeSeconds: Int?
            let wallSeconds: Int?
            let prompts, toolCalls, toolErrors, compactions: Int
            let tools: [ToolCount]

            init(_ usage: SessionUsage) {
                models = usage.models.map(Model.init)
                subagentModels = usage.subagentModels.map(Model.init)
                subagentRuns = usage.subagentRuns
                tokens = Tokens(usage.tokens)
                subagentTokens = Tokens(usage.subagentTokens)
                costUSD = usage.cost
                (peakContext, lastContext) = (usage.peakContext, usage.lastContext)
                activeSeconds = usage.activeTime.map { Int($0.rounded()) }
                if let first = usage.firstActivity, let last = usage.lastActivity {
                    wallSeconds = Int(last.timeIntervalSince(first).rounded())
                } else {
                    wallSeconds = nil
                }
                (prompts, toolCalls, toolErrors, compactions) = (usage.userPrompts, usage.toolCalls, usage.toolErrors,
                                                                 usage.compactions)
                tools = usage.tools
            }
        }

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
