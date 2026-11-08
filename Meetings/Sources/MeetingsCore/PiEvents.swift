import Foundation

/// Pi's `--mode json` stream (one JSON event a line): short steps for the meeting screen while
/// Pi works, and the answer's text at the end. Steps never hold the meeting's words, only what
/// Pi does (a tool, its first search word, a retry).
public enum PiEvents {
    /// Tokens (and the cost when the provider reports one) of Pi's model calls, as Pi recorded them.
    public struct Usage: Codable, Equatable, Sendable {
        public var input = 0
        public var output = 0
        public var cacheRead = 0
        public var cost = 0.0
        public var calls = 0

        public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cost: Double = 0, calls: Int = 0) {
            self.input = input
            self.output = output
            self.cacheRead = cacheRead
            self.cost = cost
            self.calls = calls
        }

        public var tokens: Int { input + output + cacheRead }
        public var isEmpty: Bool { calls == 0 }

        public static func + (a: Usage, b: Usage) -> Usage {
            Usage(input: a.input + b.input, output: a.output + b.output, cacheRead: a.cacheRead + b.cacheRead,
                  cost: a.cost + b.cost, calls: a.calls + b.calls)
        }

        /// `12.4k in · 1.1k out · 3 calls`, with the cost when Pi recorded one.
        public var text: String {
            var parts = ["\(Self.short(input + cacheRead)) in", "\(Self.short(output)) out", "\(calls) call\(calls == 1 ? "" : "s")"]
            if cost > 0 { parts.append(String(format: "$%.3f", cost)) }
            return parts.joined(separator: " · ")
        }

        public static func short(_ n: Int) -> String { n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)" }
    }

    /// The usage of one finished model call (an assistant `message_end`), nil for other lines.
    public static func usage(_ line: String) -> Usage? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              object["type"] as? String == "message_end", let message = object["message"] as? [String: Any],
              message["role"] as? String == "assistant", let usage = message["usage"] as? [String: Any] else { return nil }
        func int(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
        let cost = ((usage["cost"] as? [String: Any])?["total"] as? NSNumber)?.doubleValue ?? 0
        return Usage(input: int("input"), output: int("output"), cacheRead: int("cacheRead"), cost: cost, calls: 1)
    }

    /// The sum of a whole run's model calls.
    public static func totalUsage(_ output: Data) -> Usage {
        String(decoding: output, as: UTF8.self).split(separator: "\n").compactMap { usage(String($0)) }.reduce(Usage(), +)
    }

    /// The step one event line stands for, or nil for the many lines that are not one.
    public static func step(_ line: String) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        switch type {
        case "tool_execution_start":
            let tool = object["toolName"] as? String ?? "tool"
            let args = object["args"] as? [String: Any] ?? [:]
            switch tool {
            case "tool_search":
                return "Looks for tools: " + short(args["query"] as? String ?? "")
            case "codemode":
                let calls = codemodeCalls(args["code"] as? String ?? "")
                return calls.isEmpty ? "Runs a script" : "Calls " + calls.prefix(4).joined(separator: ", ") + (calls.count > 4 ? " …" : "")
            default:
                return "Calls " + toolTitle(tool)
            }
        case "tool_execution_end":
            guard object["isError"] as? Bool == true else { return nil }
            return "Failed: " + toolTitle(object["toolName"] as? String ?? "tool")
        case "auto_retry_start":
            let attempt = (object["attempt"] as? NSNumber)?.intValue ?? 0, most = (object["maxAttempts"] as? NSNumber)?.intValue ?? 0
            return "Retry \(attempt) of \(most): " + short(object["errorMessage"] as? String ?? "")
        case "message_end":
            guard let message = object["message"] as? [String: Any], message["role"] as? String == "assistant",
                  message["stopReason"] as? String == "error" else { return nil }
            return "Model error: " + short(message["errorMessage"] as? String ?? "")
        case "compaction_start":
            return "Makes room in its context"
        case "message_update":
            switch (object["assistantMessageEvent"] as? [String: Any])?["type"] as? String {
            case "thinking_start": return "Thinks"
            case "text_start": return "Writes the answer"
            default: return nil
            }
        default:
            return nil
        }
    }

    /// The text of the last assistant message. Output that is not an event stream (an older Pi,
    /// a test's fake) is the answer as it is.
    public static func answer(_ output: Data) -> String {
        let raw = String(decoding: output, as: UTF8.self)
        var last: String?
        var sawEvent = false
        for line in raw.split(separator: "\n") {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let type = object["type"] as? String else { continue }
            sawEvent = true
            guard type == "message_end", let message = object["message"] as? [String: Any],
                  message["role"] as? String == "assistant", let content = message["content"] as? [[String: Any]] else { continue }
            let text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
            if !text.isEmpty { last = text }
        }
        return sawEvent ? (last ?? "") : raw
    }

    /// The model's own error when Pi's last assistant message ended with one (an expired key, a
    /// provider outage): its text, for a clear reason instead of an empty answer.
    public static func failure(_ output: Data) -> String? {
        var error: String?
        for line in String(decoding: output, as: UTF8.self).split(separator: "\n") {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  object["type"] as? String == "message_end", let message = object["message"] as? [String: Any],
                  message["role"] as? String == "assistant" else { continue }
            error = message["stopReason"] as? String == "error" ? (message["errorMessage"] as? String ?? "the model failed") : nil
        }
        return error
    }

    /// `mcp__azure_devops__search_work_items` → `azure_devops: search_work_items`.
    static func toolTitle(_ name: String) -> String {
        guard name.hasPrefix("mcp__") else { return name }
        let parts = name.dropFirst(5).components(separatedBy: "__")
        return parts.count >= 2 ? "\(parts[0]): \(parts.dropFirst().joined(separator: "__"))" : name
    }

    /// The tools a codemode script calls (`tools.mcp__x__y({ query: "login" })`), with the first
    /// string argument when there is one.
    static func codemodeCalls(_ code: String) -> [String] {
        guard let pattern = try? NSRegularExpression(pattern: #"tools\.([A-Za-z0-9_]+)\s*\(\s*(?:\{[^"'}]*["']([^"']{1,60})["'])?"#) else { return [] }
        var seen: [String] = []
        for match in pattern.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
            guard let name = Range(match.range(at: 1), in: code).map({ String(code[$0]) }) else { continue }
            var call = toolTitle(name)
            if let word = Range(match.range(at: 2), in: code).map({ String(code[$0]) }) { call += " “\(word)”" }
            if !seen.contains(call) { seen.append(call) }
        }
        return seen
    }

    static func short(_ text: String) -> String {
        let line = text.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return line.count > 80 ? String(line.prefix(80)) + "…" : line
    }
}
