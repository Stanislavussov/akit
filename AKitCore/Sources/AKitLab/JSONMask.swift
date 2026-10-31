import AKitFoundation
import Foundation

/// Masks secrets in JSON lines AKit keeps on disk (Pi's json streams, saved MCP answers, send
/// logs): JSON stays JSON (only string values change) and a multi-line text keeps its lines.
/// Masking masked text changes nothing. Moved down from `ReviewMask` (2026-10-31) so Ask Pi's
/// streams are masked the same way; Review calls it.
public enum JSONMask {
    /// One line of JSON (a saved answer, a log line, a Pi event) with its string values masked;
    /// a line that isn't JSON is masked as text.
    public static func jsonLine(_ line: String) -> String {
        guard line.contains(where: { $0 == "{" || $0 == "[" }) else { return text(line) }
        guard let value = try? JSONSerialization.jsonObject(with: Data(line.utf8), options: [.fragmentsAllowed]) else { return text(line) }
        let (masked, changed) = json(value)
        guard changed, let data = try? JSONSerialization.data(withJSONObject: masked, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
        else { return line }
        return String(decoding: data, as: UTF8.self)
    }

    /// A string value: JSON inside it (whole, or after a line of text, as MCP servers answer)
    /// is masked as JSON, the rest line by line.
    public static func string(_ value: String) -> String {
        if let start = value.firstIndex(where: { $0 == "{" || $0 == "[" }),
           let inner = try? JSONSerialization.jsonObject(with: Data(value[start...].utf8), options: []) {
            let (masked, changed) = json(inner)
            let prefix = text(String(value[..<start]))
            guard changed, let data = try? JSONSerialization.data(withJSONObject: masked, options: [.sortedKeys, .withoutEscapingSlashes])
            else { return prefix + value[start...] }
            return prefix + String(decoding: data, as: UTF8.self)
        }
        return text(value)
    }

    /// Text masked line by line, so the number of lines stays. A private key's lines are
    /// masked whole between its BEGIN and END lines (a diff line keeps its `+`, `-` or space).
    public static func text(_ value: String) -> String {
        // Most text holds no secret: one pass over the whole text, line by line only if it does.
        guard !value.isEmpty, value.contains("PRIVATE KEY") || SecretFilter.masked(value) != value else { return value }
        var inKey = false
        var changed = false
        let lines = value.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let line = String(line)
            if line.contains("PRIVATE KEY") && line.contains("-----BEGIN") { inKey = !line.contains("-----END") }
            else if inKey {
                if line.contains("-----END") && line.contains("PRIVATE KEY") { inKey = false }
                let marker = line.first.map { "+- ".contains($0) ? String($0) : "" } ?? ""
                changed = true
                return marker + SecretFilter.mask
            }
            let masked = SecretFilter.masked(line)
            if masked != line { changed = true }
            return masked
        }
        return changed ? lines.joined(separator: "\n") : value
    }

    /// A JSON value with every string masked, and whether any string changed.
    public static func json(_ value: Any) -> (Any, Bool) {
        switch value {
        case let string as String:
            let masked = Self.string(string)
            return (masked, masked != string)
        case let list as [Any]:
            var changed = false
            let masked = list.map { item -> Any in
                let (value, itemChanged) = json(item)
                changed = changed || itemChanged
                return value
            }
            return (masked, changed)
        case let object as [String: Any]:
            var changed = false
            var masked: [String: Any] = [:]
            for (key, item) in object {
                let (value, itemChanged) = json(item)
                changed = changed || itemChanged
                masked[key] = value
            }
            return (masked, changed)
        default:
            return (value, false)
        }
    }

}
