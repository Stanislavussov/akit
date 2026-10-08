import AKitFoundation
import AKitModel
import AKitSessions
import Foundation

/// Metrics of one Claude Code session file, read in order (see `SessionMetrics`).
/// Pure: reads the transcript and its subagent files, runs nothing.
public enum SessionAnalyzer {
    typealias Object = JSONLines.Object

    public static func analyze(file: URL) throws -> SessionMetrics {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        var reader = Reader()
        for entry in try JSONLines.objects(in: data) {
            reader.read(entry)
        }
        var metrics = reader.result
        let subagents = subagentCalls(of: file, sidechain: reader.sidechainCalls)
        metrics.subagentCalls = subagents.count
        metrics.subagentFreshTokens = subagents.values.reduce(0) { $0 + $1 }
        return metrics
    }

    /// Fresh tokens per response id of subagents: side chains in the main file (older
    /// versions) and `<session>/subagents/agent-*.jsonl`.
    private static func subagentCalls(of file: URL, sidechain: [String: Int]) -> [String: Int] {
        var calls = sidechain
        let folder = file.deletingPathExtension().appending(path: "subagents")
        let usageLine = Data(#""usage""#.utf8)
        for agent in FileWalk.children(of: folder) where agent.pathExtension == "jsonl" {
            guard let data = try? Data(contentsOf: agent),
                  let entries = try? JSONLines.objects(in: data, where: { JSONLines.contains($0, usageLine) }) else { continue }
            for entry in entries {
                guard let call = Call(entry) else { continue }
                calls["\(agent.lastPathComponent)|\(call.id)"] = call.fresh
            }
        }
        return calls
    }

    /// One API response: the lines of an assistant entry with the same `message.id`.
    struct Call {
        let id: String
        let context: Int
        let fresh: Int

        init?(_ entry: Object) {
            guard entry["type"] as? String == "assistant", let message = entry["message"] as? Object,
                  let usage = message["usage"] as? Object, message["model"] as? String != "<synthetic>" else { return nil }
            let tokens = ClaudeLogFormat.tokens(fromClaudeUsage: usage)
            id = message["id"] as? String ?? entry["requestId"] as? String ?? UUID().uuidString
            context = tokens.context
            fresh = tokens.input + tokens.cacheWrite + tokens.output
        }
    }

    /// Characters that arrived between two calls, by kind.
    struct Chunk {
        var readCode = 0
        var ownOutput = 0
        var injections = 0
        var other = 0
        var total: Int { readCode + ownOutput + injections + other }
    }

    /// A call with the context growth since the previous call of its segment, split by kind.
    struct Growth {
        var context: Int
        var segment: Int
        var chunk: Chunk
    }

    struct Reader {
        private(set) var metrics = SessionMetrics()
        private(set) var sidechainCalls: [String: Int] = [:]

        private var callIndex: [String: Int] = [:]
        private var fresh: [Int] = []
        private var output: [Int] = []
        private var cacheRead: [Int] = []
        private var growth: [Growth] = []
        private var segment = 0
        /// Characters seen since the last call started.
        private var pending = Chunk()

        /// Tool use id → (name, input) of calls not answered yet.
        private var tools: [String: (name: String, input: Object)] = [:]
        /// `Read` keys (path, offset, limit) since the file was last edited.
        private var readKeys: [String: Set<String>] = [:]
        private var commitShas = Set<String>()
        /// Interrupts, rejections, tool errors and repeated calls: the rules the index uses too.
        private var signals = FailureSignals()
        private var first: Date?
        private var last: Date?
        private var turns: [DateInterval] = []

        mutating func read(_ entry: Object) {
            if ClaudeLogFormat.isSidechain(entry) {
                if let call = Call(entry) { sidechainCalls["sidechain|\(call.id)"] = call.fresh }
                return
            }
            let type = entry["type"] as? String
            let time = JSONLines.date(entry["timestamp"])
            if type == "user" || type == "assistant", let time {
                first = first ?? time
                last = time
            }
            switch type {
            case "assistant": assistant(entry)
            case "user": user(entry)
            case "attachment":
                guard let attachment = entry["attachment"] as? Object,
                      !Self.logOnly.contains(attachment["type"] as? String ?? "") else { return }
                pending.injections += Self.size(of: attachment)
            case "system":
                switch entry["subtype"] as? String {
                case "compact_boundary":
                    metrics.compactions += 1
                    segment += 1
                    pending = Chunk()
                case "turn_duration":
                    if let milliseconds = entry["durationMs"] as? NSNumber, let end = time {
                        turns.append(DateInterval(start: end.addingTimeInterval(-milliseconds.doubleValue / 1000), end: end))
                    }
                default: break
                }
            default: break
            }
        }

        /// Attachments written only to the log, never sent to the model.
        static let logOnly: Set<String> = ["hook_success", "prompt_snapshot"]

        private mutating func assistant(_ entry: Object) {
            guard let message = entry["message"] as? Object else { return }
            if let call = Call(entry) {
                if let index = callIndex[call.id] {
                    // Later lines of the same response: same input, final output count.
                    fresh[index] = call.fresh
                    output[index] = Self.tokens(entry).output
                } else {
                    callIndex[call.id] = fresh.count
                    fresh.append(call.fresh)
                    output.append(Self.tokens(entry).output)
                    cacheRead.append(Self.tokens(entry).cacheRead)
                    growth.append(Growth(context: call.context, segment: segment, chunk: pending))
                    pending = Chunk()
                    if let model = message["model"] as? String, !metrics.models.contains(model) { metrics.models.append(model) }
                }
            }
            for block in message["content"] as? [Object] ?? [] {
                switch block["type"] as? String {
                case "text": pending.ownOutput += (block["text"] as? String)?.count ?? 0
                case "thinking": pending.ownOutput += (block["thinking"] as? String)?.count ?? 0
                case "tool_use":
                    let input = block["input"] as? Object ?? [:]
                    pending.ownOutput += Self.size(of: input)
                    metrics.toolCalls += 1
                    if let id = block["id"] as? String { tools[id] = (block["name"] as? String ?? "", input) }
                    toolStarted(block["name"] as? String ?? "", input: input)
                    // A call with no input is not in the transcript either.
                    let inputText = FailureSignals.inputText(block["input"])
                    if !inputText.isEmpty { signals.toolCall(block["name"] as? String ?? "tool", input: inputText) }
                default: break
                }
            }
        }

        private static func tokens(_ entry: Object) -> TokenCounts {
            ClaudeLogFormat.tokens(fromClaudeUsage: (entry["message"] as? Object)?["usage"] as? Object ?? [:])
        }

        /// Re-reads and the edits that make a later read new again. A read counts as done
        /// when its result came back without an error (see `toolResult`). A shell command that
        /// may write (anything but plain reading) makes every file new again.
        private mutating func toolStarted(_ name: String, input: Object) {
            if name == "Bash", !ShellCommand.onlyReads(input["command"] as? String ?? "") {
                readKeys = [:]
                return
            }
            guard let path = input["file_path"] as? String ?? input["notebook_path"] as? String else { return }
            switch name {
            case "Read":
                if readKeys[path, default: []].contains(Self.readKey(input)) { metrics.rereads += 1 }
            case "Edit", "MultiEdit", "Write", "NotebookEdit":
                readKeys[path] = nil
            default: break
            }
        }

        static func readKey(_ input: Object) -> String {
            "\(input["offset"] ?? "")|\(input["limit"] ?? "")|\(input["pages"] ?? "")"
        }

        /// Meta lines and compaction summaries are not the user's messages: the signals skip them,
        /// as the transcript does.
        private mutating func user(_ entry: Object) {
            guard let message = entry["message"] as? Object else { return }
            let content = message["content"]
            let meta = entry["isMeta"] as? Bool == true
            let counted = !meta && entry["isCompactSummary"] as? Bool != true
            guard let blocks = content as? [Object] else {
                let text = content as? String ?? ""
                if counted { signals.userText(text) }
                if meta { pending.injections += text.count } else { pending.other += text.count }
                return
            }
            for block in blocks {
                switch block["type"] as? String {
                case "tool_result":
                    toolResult(block, counted: !meta)
                case "text":
                    let text = block["text"] as? String ?? ""
                    if meta { pending.injections += text.count } else { pending.other += text.count }
                default:
                    pending.other += Self.size(of: block)
                }
            }
            // One user message: its text blocks together, as the transcript joins them.
            if counted { signals.userText(JSONLines.text(of: blocks.filter { $0["type"] as? String != "tool_result" })) }
        }

        private mutating func toolResult(_ block: Object, counted: Bool) {
            let text = JSONLines.text(of: block["content"])
            let call = (block["tool_use_id"] as? String).flatMap { tools.removeValue(forKey: $0) }
            if let call, call.name == "Read", block["is_error"] as? Bool != true, let path = call.input["file_path"] as? String {
                readKeys[path, default: []].insert(Self.readKey(call.input))
            }
            if counted {
                let name = call?.name ?? ""
                signals.toolResult(name, ToolResultOutcome(tool: name, result: text, isError: block["is_error"] as? Bool == true))
            }
            if let call, Self.readsCode(call.name, input: call.input) {
                pending.readCode += text.count
            } else {
                pending.other += text.count
            }
            if call?.name == "Bash", let command = call?.input["command"] as? String, command.contains("git"), command.contains("commit") {
                for commit in Self.commits(in: text, command: command) where commitShas.insert(commit.sha).inserted {
                    // An amended commit replaces the one it rewrote.
                    if command.contains("--amend"), !metrics.commits.isEmpty {
                        metrics.commits[metrics.commits.count - 1] = commit
                    } else {
                        metrics.commits.append(commit)
                    }
                }
            }
        }

        /// The finished numbers.
        var result: SessionMetrics {
            var result = metrics
            result.interrupts = signals.interrupts
            result.rejected = signals.rejected
            result.toolErrors = signals.toolErrors
            result.repeatedCalls = signals.repeatedCalls
            result.calls = fresh.count
            result.freshTokens = fresh.reduce(0, +)
            result.outputTokens = output.reduce(0, +)
            result.cacheReadTokens = cacheRead.reduce(0, +)
            result.peakContext = growth.map(\.context).max() ?? 0
            result.baselineContext = growth.first?.context ?? 0
            result.contextRent = Self.rent(growth)
            if let first, let last { result.wallSeconds = Int(last.timeIntervalSince(first).rounded()) }
            result.activeSeconds = Self.union(turns).map { Int($0.rounded()) }
            return result
        }

        /// Context rent: each call's growth, split by characters, times the calls that
        /// send it again (itself and the later calls of its segment).
        static func rent(_ calls: [Growth]) -> ContextRent {
            var rent = ContextRent()
            var remaining: [Int: Int] = [:]
            for call in calls { remaining[call.segment, default: 0] += 1 }
            var previous: Growth?
            var explained = 0
            for call in calls {
                let repeats = remaining[call.segment] ?? 1
                remaining[call.segment] = repeats - 1
                guard let before = previous, before.segment == call.segment else {
                    rent.baseline += call.context * repeats
                    explained += call.context * repeats
                    previous = call
                    continue
                }
                previous = call
                let grown = call.context - before.context
                let chunk = call.chunk
                guard grown > 0, chunk.total > 0 else { continue }
                func part(_ characters: Int) -> Int { grown * characters / chunk.total * repeats }
                rent.readCode += part(chunk.readCode)
                rent.ownOutput += part(chunk.ownOutput)
                rent.injections += part(chunk.injections)
                rent.other += part(chunk.other)
            }
            explained += rent.readCode + rent.ownOutput + rent.injections + rent.other
            // The parts must add up to what was really sent. Growth without characters and
            // rounding leave some over: it goes to other. A context that shrank without a
            // compaction (cleared tool results) was counted too long: scale the parts down.
            let sent = calls.reduce(0) { $0 + $1.context }
            if explained > sent, explained > 0 {
                let scale = Double(sent) / Double(explained)
                func scaled(_ value: Int) -> Int { Int((Double(value) * scale).rounded(.down)) }
                rent = ContextRent(baseline: scaled(rent.baseline), readCode: scaled(rent.readCode), ownOutput: scaled(rent.ownOutput),
                                   injections: scaled(rent.injections), other: scaled(rent.other))
            }
            rent.other += max(0, sent - rent.total)
            return rent
        }

        static func union(_ turns: [DateInterval]) -> TimeInterval? {
            guard !turns.isEmpty else { return nil }
            var total: TimeInterval = 0
            var current: DateInterval?
            for turn in turns.sorted(by: { $0.start < $1.start }) {
                if let open = current, turn.start <= open.end {
                    current = DateInterval(start: open.start, end: max(open.end, turn.end))
                } else {
                    total += current?.duration ?? 0
                    current = turn
                }
            }
            return total + (current?.duration ?? 0)
        }

        static func size(of value: Any) -> Int {
            guard JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value) else { return 0 }
            return data.count
        }

        static func readsCode(_ tool: String, input: Object) -> Bool {
            switch tool {
            case "Read", "Grep", "Glob", "LS", "NotebookRead": return true
            case "Bash": return ShellCommand.onlyReads(input["command"] as? String ?? "")
            default: return false
            }
        }

        /// `[main 1a2b3c4] Subject`, `[main (root-commit) 1a2b3c4] Subject` and `[detached HEAD
        /// 1a2b3c4] Subject` lines. After
        /// `git commit -q`, a `git log --oneline` line counts only when its subject is in the
        /// command itself (the lines of older commits it prints are not).
        static func commits(in output: String, command: String = "") -> [LabCommit] {
            let lines = output.split(whereSeparator: \.isNewline)
            let printed = lines.compactMap { line -> LabCommit? in
                guard let match = line.wholeMatch(of: /\[(?:detached HEAD|[^\]\s]+)(?: \([^)]*\))? ([0-9a-f]{7,40})\] (.+)/) else { return nil }
                return LabCommit(sha: String(match.1), subject: String(match.2))
            }
            guard printed.isEmpty else { return printed }
            return lines.compactMap { line -> LabCommit? in
                guard let match = line.wholeMatch(of: /([0-9a-f]{7,40}) (.+)/),
                      command.contains(String(match.2)) else { return nil }
                return LabCommit(sha: String(match.1), subject: String(match.2))
            }
        }
    }
}

/// Shell commands that only look at files.
enum ShellCommand {
    static let readers: Set<String> = ["cat", "head", "tail", "grep", "egrep", "rg", "find", "ls", "wc", "nl", "less",
                                       "awk", "sort", "uniq", "cut", "tr", "jq", "file", "stat", "tree", "diff", "plutil"]
    static let neutral: Set<String> = ["cd", "echo", "pwd", "true"]
    static let gitReaders: Set<String> = ["show", "diff", "log", "grep", "blame", "status", "ls-files"]

    /// Every part of the command (split at `|`, `&&`, `||` and `;`) reads: `cat`, `sed -n`,
    /// `grep`, `git show`… A command that writes anything counts as other work.
    static func onlyReads(_ command: String) -> Bool {
        let parts = command.split(whereSeparator: { "|&;\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !command.contains(">"), !command.contains("<<") else { return false }
        var reads = false
        for part in parts {
            let words = part.split(separator: " ").map(String.init)
            guard let name = words.first.map({ URL(filePath: $0).lastPathComponent }) else { continue }
            if neutral.contains(name) { continue }
            if readers.contains(name) {
                reads = true
            } else if name == "sed", words.contains("-n"), !words.contains("-i") {
                reads = true
            } else if name == "git", gitReaders.contains(gitSubcommand(words.dropFirst())) {
                reads = true
            } else {
                return false
            }
        }
        return reads
    }

    /// `git -C dir -c k=v show x` → `show`.
    private static func gitSubcommand(_ words: ArraySlice<String>) -> String {
        var skipValue = false
        for word in words {
            if skipValue {
                skipValue = false
            } else if word == "-C" || word == "-c" {
                skipValue = true
            } else if !word.hasPrefix("-") {
                return word
            }
        }
        return ""
    }
}
