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

        public init(pi: String, arguments: [String], cwd: String, model: String, thinking: String, fork: String?, session: String?,
                    started: Date, ended: Date, exitStatus: Int32?, error: String?, usage: SendUsage, tools: ToolTimes?) {
            (self.pi, self.arguments, self.cwd, self.model, self.thinking, self.fork, self.session) = (pi, arguments, cwd, model, thinking, fork, session)
            (self.started, self.ended, self.exitStatus, self.error, self.usage, self.tools) = (started, ended, exitStatus, error, usage, tools)
        }

        public var prompt: String? { arguments.last }
        public var duration: TimeInterval { ended.timeIntervalSince(started) }
    }

    /// When each tool call started and ended: by `toolCallId`, and in order for calls without one.
    public struct ToolTimes: Codable, Sendable, Hashable {
        public var starts: [String: Date] = [:]
        public var ends: [String: Date] = [:]
        public var unnamedStarts: [Date] = []
        public var unnamedEnds: [Date] = []

        public init(starts: [String: Date] = [:], ends: [String: Date] = [:], unnamedStarts: [Date] = [], unnamedEnds: [Date] = []) {
            (self.starts, self.ends, self.unnamedStarts, self.unnamedEnds) = (starts, ends, unnamedStarts, unnamedEnds)
        }

        /// Reads what it can: a record of another shape gives no times rather than no call.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            starts = (try? container.decodeIfPresent([String: Date].self, forKey: .starts)) ?? [:]
            ends = (try? container.decodeIfPresent([String: Date].self, forKey: .ends)) ?? [:]
            unnamedStarts = (try? container.decodeIfPresent([Date].self, forKey: .unnamedStarts)) ?? []
            unnamedEnds = (try? container.decodeIfPresent([Date].self, forKey: .unnamedEnds)) ?? []
        }
    }

    /// Notes when tool calls start and end while Pi runs.
    public final class Times: @unchecked Sendable {
        private let lock = NSLock()
        private var times = ToolTimes()

        public init() {}

        func note(_ line: String, at date: Date = .now) {
            guard line.hasPrefix("{"), line.contains("\"tool_execution_start\"") || line.contains("\"tool_execution_end\""),
                  let event = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { return }
            let call = event["toolCallId"] as? String
            lock.withLock {
                switch event["type"] as? String {
                case "tool_execution_start":
                    if let call { times.starts[call] = date } else { times.unnamedStarts.append(date) }
                case "tool_execution_end":
                    if let call { times.ends[call] = date } else { times.unnamedEnds.append(date) }
                default: break
                }
            }
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
        /// The tool's arguments as pretty JSON, or the text or thinking; cut at the load's limit.
        public var detail: String
        public var detailCount: Int
        /// The tool's result, cut at the load's limit; nil while there is none.
        public var result: String?
        public var resultCount: Int
        public var isError: Bool
        public var started: Date?
        public var ended: Date?
        /// An end event with no start in the stream.
        public var orphan = false

        public var duration: TimeInterval? { started.flatMap { start in ended.map { $0.timeIntervalSince(start) } } }
    }

    /// Everything the log of one answer shows.
    public struct Answer: Sendable {
        public var entry: KnowledgeAsk.Entry
        public var call: Call?
        public var steps: [Step]
        public var stream: URL

        public init(entry: KnowledgeAsk.Entry, call: Call?, steps: [Step], stream: URL) {
            (self.entry, self.call, self.steps, self.stream) = (entry, call, steps, stream)
        }
    }

    /// How much of a result or an argument list the sheet keeps (the full log reads it all).
    public static let viewLimit = 200_000

    static func callFile(_ number: Int, in chat: KnowledgeAsk.Chat) -> URL {
        chat.folder.appending(path: "streams/q\(number).call.json")
    }

    static func save(_ call: Call, question number: Int, in chat: KnowledgeAsk.Chat) throws {
        try KnowledgeAsk.encoder.encode(call).write(to: callFile(number, in: chat), options: .atomic)
    }

    /// The log of one answer: its call file and its stream, whatever of them is there. Results
    /// are kept up to `limit` characters (nil: whole).
    public static func load(_ entry: KnowledgeAsk.Entry, in chat: KnowledgeAsk.Chat, limit: Int? = viewLimit) -> Answer {
        let number = Int(entry.id.dropFirst()) ?? 0
        let stream = chat.folder.appending(path: "streams/q\(number).jsonl")
        let call = (try? Data(contentsOf: callFile(number, in: chat))).flatMap { try? KnowledgeAsk.decoder.decode(Call.self, from: $0) }
        let data = (try? Data(contentsOf: stream, options: .mappedIfSafe)) ?? Data()
        return Answer(entry: entry, call: call, steps: steps(data: data, times: call?.tools, limit: limit), stream: stream)
    }

    /// The chat's system prompt as Pi got it (`system.md`).
    public static func systemPrompt(_ chat: KnowledgeAsk.Chat) -> String? {
        try? String(contentsOf: chat.folder.appending(path: "system.md"), encoding: .utf8)
    }

    /// `steps(data:)` of lines (tests, snapshots).
    public static func steps(_ lines: [String], times: ToolTimes? = nil, limit: Int? = viewLimit) -> [Step] {
        steps(data: Data(lines.joined(separator: "\n").utf8), times: times, limit: limit)
    }

    /// What Pi did, from its json stream, read line by line: each tool call (its end matched by
    /// `toolCallId`; without one, by tool name, else the oldest open call without one; an end
    /// with no start is a step of its own), the assistant's text and thinking, a model error.
    /// A secret file's content is hidden (`PiSecretFiles`, also for streams saved before) and the
    /// rest masked again. Lines that aren't whole JSON are skipped.
    public static func steps(data: Data, times: ToolTimes? = nil, limit: Int? = viewLimit) -> [Step] {
        let secrets = PiSecretFiles()
        var steps: [Step] = []
        var open: [(call: String?, index: Int)] = []
        var unnamedStarts = 0, unnamedEnds = 0
        func cut(_ text: String) -> String { limit.map { text.count > $0 ? String(text.prefix($0)) : text } ?? text }
        for slice in data.split(separator: 0x0A) where slice.first == UInt8(ascii: "{") {
            let line = secrets.line(String(decoding: slice, as: UTF8.self))
            guard let event = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            let call = event["toolCallId"] as? String
            switch event["type"] as? String {
            case "tool_execution_start":
                let name = event["toolName"] as? String ?? "tool"
                let args = event["args"] as? [String: Any] ?? [:]
                let started: Date?
                if let call { started = times?.starts[call] } else {
                    started = times.flatMap { unnamedStarts < $0.unnamedStarts.count ? $0.unnamedStarts[unnamedStarts] : nil }
                    unnamedStarts += 1
                }
                let detail = pretty(args)
                steps.append(Step(id: steps.count, kind: .tool, tool: name, summary: summary(args), detail: cut(detail), detailCount: detail.count,
                                  result: nil, resultCount: 0, isError: false, started: started, ended: nil))
                open.append((call, steps.count - 1))
            case "tool_execution_end":
                let name = event["toolName"] as? String
                let ended: Date?
                let place: Int?
                if let call {
                    ended = times?.ends[call]
                    place = open.firstIndex { $0.call == call }
                } else {
                    ended = times.flatMap { unnamedEnds < $0.unnamedEnds.count ? $0.unnamedEnds[unnamedEnds] : nil }
                    unnamedEnds += 1
                    place = open.firstIndex { $0.call == nil && name != nil && steps[$0.index].tool == name } ?? open.firstIndex { $0.call == nil }
                }
                let result = JSONMask.text(KnowledgeAsk.resultText(event["result"]))
                let index: Int
                if let place {
                    index = open.remove(at: place).index
                } else {
                    steps.append(Step(id: steps.count, kind: .tool, tool: name ?? "tool", summary: "result without start", detail: "", detailCount: 0,
                                      result: nil, resultCount: 0, isError: false, started: nil, ended: nil, orphan: true))
                    index = steps.count - 1
                }
                steps[index].result = cut(result)
                steps[index].resultCount = result.count
                steps[index].isError = event["isError"] as? Bool == true
                steps[index].ended = ended
            case "message_end":
                guard let message = event["message"] as? [String: Any], message["role"] as? String == "assistant" else { continue }
                if message["stopReason"] as? String == "error" {
                    let text = SecretFilter.masked(message["errorMessage"] as? String ?? "The model call failed.")
                    steps.append(Step(id: steps.count, kind: .error, tool: "", summary: oneLine(text), detail: text, detailCount: text.count,
                                      result: nil, resultCount: 0, isError: true))
                }
                for part in message["content"] as? [[String: Any]] ?? [] {
                    let (kind, text): (Step.Kind?, String?) = switch part["type"] as? String {
                    case "text": (.text, part["text"] as? String)
                    case "thinking": (.thinking, part["thinking"] as? String)
                    default: (nil, nil)
                    }
                    guard let kind, let text = text.map(JSONMask.text), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    steps.append(Step(id: steps.count, kind: kind, tool: "", summary: oneLine(text), detail: cut(text), detailCount: text.count,
                                      result: nil, resultCount: 0, isError: false))
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
        let answers = KnowledgeAsk.entries(chat).filter { only == nil || $0.id == only }.map { load($0, in: chat, limit: nil) }
        return fullLog(chat, system: systemPrompt(chat), answers: answers)
    }

    /// The log of answers already loaded (whole: `load(…, limit: nil)`) as plain text.
    public static func fullLog(_ chat: KnowledgeAsk.Chat?, system: String?, answers: [Answer]) -> String {
        var out: [String] = []
        if let chat {
            out += ["Ask Pi log: \(chat.note.id) (\(chat.note.path)) in the base \(chat.note.base) at \(chat.note.baseRoot)",
                    "Chat \(chat.id), started \(stamp(chat.created)), Pi runs in \(chat.cwd)"]
        }
        if let system { out += ["", "## System prompt (appended)", system.trimmingCharacters(in: .newlines)] }
        for answer in answers { out += ["", text(of: answer)] }
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
                out.append("- \(step.tool)\(step.isError ? " FAILED" : "")\(time): \(step.summary)" + (step.resultCount > (step.result?.count ?? 0) ? " (result cut)" : ""))
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

    static func stamp(_ date: Date) -> String { date.formatted(.iso8601) }

    // MARK: - Thinking per model

    /// The thinking level Ask Pi uses with `model` (K34): the one last used with it, when Pi still
    /// offers it; else `fallback` (Lab's default for Pi); else `medium`, else Pi's first level.
    public static func thinking(for model: String, remembered: [String: String], fallback: String, levels: [String]) -> String {
        if let level = remembered[model], levels.contains(level) { return level }
        if levels.contains(fallback) { return fallback }
        return levels.contains("medium") ? "medium" : levels.first ?? ""
    }
}
