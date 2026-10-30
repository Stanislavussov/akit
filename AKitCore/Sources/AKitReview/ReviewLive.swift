import AKitFoundation
import Foundation

/// A line of a review's live log with its details (a call's arguments, a tool's answer, the
/// model's thinking and text, the findings), joined by a record separator so it travels
/// through `ReviewPasses.Options.progress` as one string. The app opens the details under the
/// line; the terminal prints only the title.
public enum ReviewLive {
    static let separator: Character = "\u{1E}"
    /// Characters of details a line keeps: the live log holds up to 3000 lines.
    static let detailLimit = 8000

    public static func line(_ title: String, detail: String?) -> String {
        guard let detail, !detail.isEmpty else { return title }
        return title + String(separator) + detail
    }

    public static func split(_ line: String) -> (title: String, detail: String?) {
        guard let index = line.firstIndex(of: separator) else { return (line, nil) }
        let detail = String(line[line.index(after: index)...])
        return (String(line[..<index]), detail.isEmpty ? nil : detail)
    }

    /// Masked, trimmed, its head and tail kept when long; nil when empty.
    static func clip(_ text: String) -> String? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // A big answer (a whole file, an MCP page) is cut before the mask scans it; the mask
        // still runs on everything kept.
        let keep = 2 * detailLimit
        if trimmed.count > keep {
            trimmed = String(trimmed.prefix(detailLimit)) + "\n…\n" + String(trimmed.suffix(detailLimit))
        }
        return ReviewDebug.middleCut(SecretFilter.masked(trimmed), detailLimit)
    }

    /// Arguments as indented JSON, keys sorted.
    static func pretty(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return ReviewDebug.json(value) }
        return String(decoding: data, as: UTF8.self)
    }

    /// One pass's saved event stream (`passes/<name>.jsonl`) as live log lines, for Log… after
    /// the run: the same titles and details the live log showed.
    public static func events(stream: URL) -> [(title: String, detail: String?)] {
        guard let data = try? Data(contentsOf: stream) else { return [] }
        let update = Data(#"{"type":"message_update""#.utf8)
        return data.split(separator: 0x0A).compactMap { line in
            // Partial answers: frequent and large. Never decode them.
            if line.starts(with: update) { return nil }
            return ReviewPasses.liveEvent(String(decoding: line, as: UTF8.self))
        }
    }
}
