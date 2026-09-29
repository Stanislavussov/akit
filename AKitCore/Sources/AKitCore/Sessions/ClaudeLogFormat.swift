import Foundation

/// Reading single lines of Claude Code session files. Shared by the session list and
/// transcript (ClaudeSessions), token usage and the insights fact reader.
enum ClaudeLogFormat {
    typealias Object = JSONLines.Object

    /// Text the user typed, or nil for tool results, harness-injected and meta entries.
    static func promptText(_ entry: Object) -> String? {
        guard entry["type"] as? String == "user", !isSidechain(entry),
              entry["isMeta"] as? Bool != true, entry["isCompactSummary"] as? Bool != true,
              let message = entry["message"] as? Object else { return nil }
        if let blocks = message["content"] as? [Object], blocks.contains(where: { $0["type"] as? String == "tool_result" }) {
            return nil
        }
        let text = JSONLines.text(of: message["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
        // Slash commands and their output are wrapped in tags like <command-name>.
        if text.isEmpty || text.hasPrefix("<") || text.hasPrefix("[Request interrupted") { return nil }
        return text
    }

    static func isSidechain(_ entry: Object) -> Bool { entry["isSidechain"] as? Bool == true }

    /// Claude's `message.usage`: input_tokens, output_tokens, cache_read_input_tokens,
    /// cache_creation_input_tokens, output_tokens_details.thinking_tokens.
    static func tokens(fromClaudeUsage usage: Object) -> TokenCounts {
        func count(_ key: String, in object: Object? = usage) -> Int { (object?[key] as? NSNumber)?.intValue ?? 0 }
        return TokenCounts(input: count("input_tokens"), output: count("output_tokens"),
                           cacheRead: count("cache_read_input_tokens"),
                           cacheWrite: count("cache_creation_input_tokens"),
                           reasoning: count("thinking_tokens", in: usage["output_tokens_details"] as? Object))
    }

    /// Trimmed text between `<name>` and `</name>`.
    static func tag(_ name: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(name)>"), let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex)
        else { return nil }
        return String(text[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
