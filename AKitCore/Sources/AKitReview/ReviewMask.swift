import AKitFoundation
import Foundation

/// Masks secrets in what a run keeps on disk from MCP servers: the saved answers
/// (`mcp/calls/`), the send log (`send/log.jsonl`) and the pass streams (`passes/*.jsonl`).
/// A merge request, a thread or a work item can quote a token; AKit keeps the answer, not the
/// token. JSON stays JSON (only string values change) and a multi-line text keeps its lines, so
/// diffs keep their line numbers. Masking masked text changes nothing.
public enum ReviewMask {
    /// Masks the saved answers and the send log of a run, in place: after each pass, and when
    /// AKit opens a run (Discuss in Pi… saves answers while AKit doesn't watch). Only files
    /// changed since the last time are read again. Files that hold no secret stay byte for byte.
    public static func saved(in folder: URL) {
        let marker = folder.appending(path: "mcp/masked")
        let since = modified(marker)?.addingTimeInterval(-2)
        let started = Date.now
        var files = FileWalk.children(of: folder.appending(path: "mcp/calls")).filter { $0.pathExtension == "json" }
        files.append(folder.appending(path: "send/log.jsonl"))
        var seen = false
        for file in files {
            guard let date = modified(file) else { continue }
            seen = true
            guard since.map({ date >= $0 }) ?? true else { continue }
            rewrite(file) { text in
                text.split(separator: "\n", omittingEmptySubsequences: false).map { jsonLine(String($0)) }.joined(separator: "\n")
            }
        }
        guard seen else { return }
        try? FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data().write(to: marker)
        try? FileManager.default.setAttributes([.modificationDate: started], ofItemAtPath: marker.path)
    }

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
    static func string(_ value: String) -> String {
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
    static func text(_ value: String) -> String {
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
    static func json(_ value: Any) -> (Any, Bool) {
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

    private static func modified(_ file: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
    }

    private static func rewrite(_ file: URL, _ mask: (String) -> String) {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        let masked = mask(text)
        guard masked != text else { return }
        try? Data(masked.utf8).write(to: file, options: .atomic)
    }
}
