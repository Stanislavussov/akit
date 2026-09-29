import AKitFoundation
import AKitModel
import Foundation

/// Reading Pi's session folder and single lines of its session files. Shared by the
/// session list and transcript (PiSessions), token usage and the insights fact reader.
public enum PiLogFormat {
    public typealias Object = JSONLines.Object

    /// `PI_CODING_AGENT_SESSION_DIR`, then `sessionDir` from the global settings, then `<config>/sessions`.
    /// A relative `sessionDir` points inside each project and is not followed.
    public static func folder(configRoot: URL, in env: HarnessEnvironment) -> URL {
        if let custom = env.variables["PI_CODING_AGENT_SESSION_DIR"], !custom.isEmpty {
            return env.expand(custom)
        }
        if let data = try? Data(contentsOf: configRoot.appending(path: "settings.json")),
           let settings = try? JSONSerialization.jsonObject(with: data) as? Object,
           let dir = settings["sessionDir"] as? String, dir.hasPrefix("/") || dir.hasPrefix("~") {
            return env.expand(dir)
        }
        return configRoot.appending(path: "sessions")
    }

    /// A prompt that starts with an expanded skill (`<skill name="tdd" …>`) is titled by what follows it.
    public static func promptTitle(_ text: String) -> String {
        guard text.hasPrefix("<skill "), let end = text.range(of: "</skill>") else { return text }
        let rest = text[end.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? text : rest
    }

    /// `x` for a prompt that starts with an expanded skill `<skill name="x" …>`.
    public static func skillPrefixName(_ text: String) -> String? {
        let start = "<skill name=\""
        guard text.hasPrefix(start) else { return nil }
        let rest = text.dropFirst(start.count)
        guard let quote = rest.firstIndex(of: "\""), quote > rest.startIndex else { return nil }
        return String(rest[..<quote])
    }

    /// Pi's `message.usage`: input, output, cacheRead, cacheWrite.
    public static func tokens(fromPiUsage usage: Object) -> TokenCounts {
        func count(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
        return TokenCounts(input: count("input"), output: count("output"),
                           cacheRead: count("cacheRead"), cacheWrite: count("cacheWrite"))
    }

    /// `usage.cost.total` in US dollars, when Pi recorded it.
    public static func cost(fromPiUsage usage: Object) -> Double? {
        ((usage["cost"] as? Object)?["total"] as? NSNumber)?.doubleValue
    }
}
