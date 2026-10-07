import AKitFoundation
import AKitModel
import Foundation

/// Reading single lines of Claude Code session files. Shared by the session list and
/// transcript (ClaudeSessions), token usage and the insights fact reader.
public enum ClaudeLogFormat {
    public typealias Object = JSONLines.Object

    /// Text the user typed, or nil for tool results, harness-injected and meta entries.
    public static func promptText(_ entry: Object) -> String? {
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

    public static func isSidechain(_ entry: Object) -> Bool { entry["isSidechain"] as? Bool == true }

    /// Claude's `message.usage`: input_tokens, output_tokens, cache_read_input_tokens,
    /// cache_creation_input_tokens, output_tokens_details.thinking_tokens.
    public static func tokens(fromClaudeUsage usage: Object) -> TokenCounts {
        func count(_ key: String, in object: Object? = usage) -> Int { (object?[key] as? NSNumber)?.intValue ?? 0 }
        return TokenCounts(input: count("input_tokens"), output: count("output_tokens"),
                           cacheRead: count("cache_read_input_tokens"),
                           cacheWrite: count("cache_creation_input_tokens"),
                           reasoning: count("thinking_tokens", in: usage["output_tokens_details"] as? Object))
    }

    /// The skills of a `skill_listing` attachment, one per name in `names`, with their `content`
    /// line `- <name>: …` (or `- <name>` alone; empty when there is none). Plugin skill names
    /// contain `:`, so lines are matched by name, longest first, never split on `:`.
    public static func listedSkills(_ attachment: Object) -> [(name: String, line: String)] {
        let lines = (attachment["content"] as? String ?? "").split(separator: "\n").map(String.init)
        var names = attachment["names"] as? [String] ?? []
        if names.isEmpty {
            // Older listings without `names`: a name ends at the first ": ".
            names = lines.filter { $0.hasPrefix("- ") }.map { line in
                let body = line.dropFirst(2)
                return String(body.range(of: ": ").map { body[..<$0.lowerBound] } ?? body)
            }
        }
        let longestFirst = names.sorted { $0.count > $1.count }
        var found: [String: String] = [:]
        for line in lines where line.hasPrefix("- ") {
            guard let name = longestFirst.first(where: { line == "- " + $0 || line.hasPrefix("- " + $0 + ":") }),
                  found[name] == nil else { continue }
            found[name] = line
        }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }.map { ($0, found[$0] ?? "") }
    }

    /// Trimmed text between `<name>` and `</name>`.
    public static func tag(_ name: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(name)>"), let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex)
        else { return nil }
        return String(text[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
