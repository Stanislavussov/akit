import AKitFoundation
import Foundation

/// The log of Ask Pi answers (K34): how Pi was called (`streams/qN.call.json`, masked, written
/// by `KnowledgeAsk.ask`) and what it did, read back from the saved json stream
/// (`streams/qN.jsonl`): tool calls in order with their arguments, result and timing, the
/// assistant's text and thinking. Chats saved before K34 have no call file: the log shows what
/// the entry and the stream hold.
public enum KnowledgeAskLog {
    /// How one question ran Pi. Everything in it is masked; the prompt is the one sent (scrubbed).
    public struct Call: Codable, Sendable, Hashable {
        public var pi: String
        /// The arguments as AKit ran them; the last one is the prompt.
        public var arguments: [String]
        public var cwd: String
        public var model: String
        public var thinking: String
        /// The session file the question forked; nil for a chat's first question.
        public var fork: String?
        /// The session file Pi saved this answer in.
        public var session: String?
        public var started: Date
        public var ended: Date
        public var exitStatus: Int32?
        public var error: String?
        public var usage: SendUsage
        /// When each tool call started and ended, in the order of the stream's events.
        public var tools: ToolTimes?

        public var prompt: String? { arguments.last }
        public var duration: TimeInterval { ended.timeIntervalSince(started) }
    }

    public struct ToolTimes: Codable, Sendable, Hashable {
        public var starts: [Date] = []
        public var ends: [Date] = []
    }

    /// Notes when tool calls start and end while Pi runs.
    public final class Times: @unchecked Sendable {
        private let lock = NSLock()
        private var times = ToolTimes()

        public init() {}

        func note(_ line: String, at date: Date = .now) {
            guard line.hasPrefix("{") else { return }
            if line.contains("\"tool_execution_start\"") { lock.withLock { times.starts.append(date) } }
            else if line.contains("\"tool_execution_end\"") { lock.withLock { times.ends.append(date) } }
        }

        var all: ToolTimes { lock.withLock { times } }
    }

    /// One thing Pi did.
    public struct Step: Sendable, Hashable, Identifiable {
        public enum Kind: String, Sendable { case tool, text, thinking, error }

        public var id: Int
        public var kind: Kind
        /// The tool's name (`bash`, `read`, `mcp__gitlab__get_issue`…); empty for text.
        public var tool: String
        /// One line: the bash command, the path, the query, else the arguments in short.
        public var summary: String
        /// The tool's arguments as pretty JSON, or the text or thinking.
        public var detail: String
        public var result: String?
        public var isError: Bool
        public var started: Date?
        public var ended: Date?

        public var duration: TimeInterval? { started.flatMap { start in ended.map { $0.timeIntervalSince(start) } } }
    }

    /// Everything the log of one answer shows.
    public struct Answer: Sendable {
        public var entry: KnowledgeAsk.Entry
        public var call: Call?
        public var steps: [Step]
        public var stream: URL
    }

    static func callFile(_ number: Int, in chat: KnowledgeAsk.Chat) -> URL {
        chat.folder.appending(path: "streams/q\(number).call.json")
    }

    static func save(_ call: Call, question number: Int, in chat: KnowledgeAsk.Chat) throws {
        try KnowledgeAsk.encoder.encode(call).write(to: callFile(number, in: chat), options: .atomic)
    }

    /// The log of one answer: its call file and its stream, whatever of them is there.
    public static func load(_ entry: KnowledgeAsk.Entry, in chat: KnowledgeAsk.Chat) -> Answer {
        let number = Int(entry.id.dropFirst()) ?? 0
        let stream = chat.folder.appending(path: "streams/q\(number).jsonl")
        let call = (try? Data(contentsOf: callFile(number, in: chat))).flatMap { try? KnowledgeAsk.decoder.decode(Call.self, from: $0) }
        let lines = ((try? String(contentsOf: stream, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        return Answer(entry: entry, call: call, steps: steps(lines, times: call?.tools), stream: stream)
    }

    /// The chat's system prompt as Pi got it (`system.md`).
    public static func systemPrompt(_ chat: KnowledgeAsk.Chat) -> String? {
        try? String(contentsOf: chat.folder.appending(path: "system.md"), encoding: .utf8)
    }

    /// What Pi did, from its json stream: each tool call (start and end matched by `toolCallId`,
    /// else by order), the assistant's text and thinking, a model error. Masked again (the stream
    /// is saved masked already).
    public static func steps(_ lines: [String], times: ToolTimes? = nil) -> [Step] {
        var steps: [Step] = []
        var open: [(call: String?, index: Int)] = []
        var starts = 0, ends = 0
        for line in lines where line.hasPrefix("{") {
            guard let event = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            switch event["type"] as? String {
            case "tool_execution_start":
                let name = event["toolName"] as? String ?? "tool"
                let args = event["args"] as? [String: Any] ?? [:]
                let started = times.flatMap { starts < $0.starts.count ? $0.starts[starts] : nil }
                starts += 1
                steps.append(Step(id: steps.count, kind: .tool, tool: name, summary: summary(args), detail: pretty(args),
                                  result: nil, isError: false, started: started, ended: nil))
                open.append((event["toolCallId"] as? String, steps.count - 1))
            case "tool_execution_end":
                let ended = times.flatMap { ends < $0.ends.count ? $0.ends[ends] : nil }
                ends += 1
                let call = event["toolCallId"] as? String
                let name = event["toolName"] as? String
                guard let place = open.firstIndex(where: { call != nil && $0.call == call })
                        ?? open.firstIndex(where: { name != nil && steps[$0.index].tool == name }) ?? open.indices.first else { continue }
                let index = open.remove(at: place).index
                steps[index].result = JSONMask.text(KnowledgeAsk.resultText(event["result"]))
                steps[index].isError = event["isError"] as? Bool == true
                steps[index].ended = ended
            case "message_end":
                guard let message = event["message"] as? [String: Any], message["role"] as? String == "assistant" else { continue }
                if message["stopReason"] as? String == "error" {
                    let text = SecretFilter.masked(message["errorMessage"] as? String ?? "The model call failed.")
                    steps.append(Step(id: steps.count, kind: .error, tool: "", summary: oneLine(text), detail: text, result: nil, isError: true))
                }
                for part in message["content"] as? [[String: Any]] ?? [] {
                    let (kind, text): (Step.Kind?, String?) = switch part["type"] as? String {
                    case "text": (.text, part["text"] as? String)
                    case "thinking": (.thinking, part["thinking"] as? String)
                    default: (nil, nil)
                    }
                    guard let kind, let text = text.map(JSONMask.text), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    steps.append(Step(id: steps.count, kind: kind, tool: "", summary: oneLine(text), detail: text, result: nil, isError: false))
                }
            default:
                break
            }
        }
        return steps
    }

    /// A tool call's arguments in one line: its command, path, query or pattern, else the JSON.
    static func summary(_ args: [String: Any]) -> String {
        for key in ["command", "path", "file_path", "query", "pattern", "url", "code"] {
            if let value = args[key] as? String, !value.isEmpty { return oneLine(SecretFilter.masked(value)) }
        }
        return oneLine(args.isEmpty ? "" : compact(args))
    }

    static func oneLine(_ text: String, limit: Int = 160) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }

    static func pretty(_ object: [String: Any]) -> String {
        guard !object.isEmpty, let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return "" }
        return JSONMask.text(String(decoding: data, as: UTF8.self))
    }

    static func compact(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "" }
        return JSONMask.text(String(decoding: data, as: UTF8.self))
    }

    /// "12.3 s", "2 min 5 s".
    public static func seconds(_ interval: TimeInterval) -> String {
        interval < 60 ? String(format: "%.1f s", interval) : "\(Int(interval) / 60) min \(Int(interval) % 60) s"
    }

    // MARK: - Full log

    /// The whole chat's log as plain text (Copy Full Log): masked, uncut.
    public static func fullLog(_ chat: KnowledgeAsk.Chat, only: String? = nil) -> String {
        var out = ["Ask Pi log: \(chat.note.id) (\(chat.note.path)) in the base \(chat.note.base) at \(chat.note.baseRoot)",
                   "Chat \(chat.id), started \(stamp(chat.created)), Pi runs in \(chat.cwd)"]
        if let system = systemPrompt(chat) { out += ["", "## System prompt (appended)", system.trimmingCharacters(in: .newlines)] }
        for entry in KnowledgeAsk.entries(chat) where only == nil || entry.id == only {
            out += ["", text(of: load(entry, in: chat))]
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// One answer's log as plain text.
    public static func text(of answer: Answer) -> String {
        let entry = answer.entry
        var out = ["## \(entry.id): \(entry.question)"]
        if let passage = entry.passage { out.append("Passage:\n" + passage) }
        if let call = answer.call {
            out += ["Pi: \(call.pi)", "Model: \(call.model.isEmpty ? "Pi's default" : call.model) · thinking \(call.thinking.isEmpty ? "Pi's default" : call.thinking)",
                    "Working folder: \(call.cwd)", "Fork: \(call.fork ?? "none (the chat's first question)")", "Session: \(call.session ?? "-")",
                    "Started \(stamp(call.started)), ended \(stamp(call.ended)), \(seconds(call.duration))"
                        + (call.exitStatus.map { ", exit status \($0)" } ?? ""),
                    "Tokens: \(call.usage.input) in, \(call.usage.cached) cached, \(call.usage.output) out" + (call.usage.cost.map { String(format: ", $%.4f", $0) } ?? ""),
                    "Arguments:"] + call.arguments.dropLast().map { "  " + $0 }
            if let prompt = call.prompt { out += ["Prompt sent:", prompt] }
        } else {
            out.append("(No call record: this answer was saved before AKit kept one. Model \(entry.model ?? "unknown").)")
        }
        out.append("Steps:")
        for step in answer.steps {
            let time = step.duration.map { " (\(seconds($0)))" } ?? ""
            switch step.kind {
            case .tool:
                out.append("- \(step.tool)\(step.isError ? " FAILED" : "")\(time): \(step.summary)")
                if !step.detail.isEmpty { out.append(indent(step.detail)) }
                out.append(step.result.map { "  Result:\n" + indent($0) } ?? "  No result (stopped?)")
            case .text: out.append("- Pi wrote:\n" + indent(step.detail))
            case .thinking: out.append("- Pi thought:\n" + indent(step.detail))
            case .error: out.append("- Model error: \(step.detail)")
            }
        }
        if answer.steps.isEmpty { out.append("  (none in the saved stream)") }
        if let answerText = entry.answer { out += ["Answer:", answerText] }
        if let error = entry.error { out.append("Error: \(error)") }
        if let proposals = entry.proposals { out.append("Proposals: " + proposals.map(\.id).joined(separator: ", ")) }
        return out.joined(separator: "\n")
    }

    static func indent(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }.joined(separator: "\n")
    }

    static func stamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    // MARK: - Thinking per model

    /// The thinking level Ask Pi uses with `model` (K34): the one last used with it, when Pi still
    /// offers it; else `fallback` (Lab's default for Pi); else `medium`, else Pi's first level.
    public static func thinking(for model: String, remembered: [String: String], fallback: String, levels: [String]) -> String {
        if let level = remembered[model], levels.contains(level) { return level }
        if levels.contains(fallback) { return fallback }
        return levels.contains("medium") ? "medium" : levels.first ?? ""
    }
}
