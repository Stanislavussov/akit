import AKitFoundation
import AKitLab
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
    /// a line that isn't JSON is masked as text (`JSONMask`).
    public static func jsonLine(_ line: String) -> String { JSONMask.jsonLine(line) }

    static func string(_ value: String) -> String { JSONMask.string(value) }

    static func text(_ value: String) -> String { JSONMask.text(value) }

    static func json(_ value: Any) -> (Any, Bool) { JSONMask.json(value) }

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
