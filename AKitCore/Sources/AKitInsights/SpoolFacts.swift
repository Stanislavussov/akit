import AKitFoundation
import Foundation

/// Spool lines (see `Spool`) as index rows: `session_start` → `hook_events`, `apply` →
/// `applies`, `mark` → `marks`, `rating` → `ratings`. Written with the same upsert rule as session facts (see `FactWriter`).
enum SpoolFacts {
    /// 2: `mark` lines. Spool files still on disk from parser 1 are read again, so marks an
    /// older akit counted as unknown are picked up.
    /// 3: `head` of session starts. Spool files still on disk from parser 2 are read again, so
    /// heads an older importer dropped (a hook binary newer than the importer) are picked up.
    /// 4: `rating` lines (`akit rate`). Spool files still on disk from parser 3 are read again.
    static let parserVersion = 4

    /// What one line did.
    enum Outcome {
        case written
        /// A kind or line version this akit doesn't know: counted in `sources.unknown_lines`,
        /// so the file is kept for a newer akit.
        case unknown
        /// A known kind without the fields it needs.
        case malformed
    }

    static func write(_ entry: JSONLines.Object, kinds: Set<String> = Spool.kinds, database: IndexDatabase,
                      sourceID: Int64, parserVersion: Int) throws -> Outcome {
        let version = (entry["v"] as? NSNumber)?.intValue ?? 0
        guard let kind = entry["kind"] as? String, kinds.contains(kind), version >= 1, version <= Spool.lineVersion else {
            return .unknown
        }
        guard let ts = (entry["ts"] as? NSNumber)?.int64Value else { return .malformed }
        func text(_ key: String) -> String? { entry[key] as? String }
        switch kind {
        case "session_start":
            guard let harness = text("harness"), let session = text("session_id") else { return .malformed }
            try database.run(hookEventSQL, harness, session, ts, text("source"), text("cwd"), text("gitdir"), text("common_dir"),
                             text("remote_id"), text("branch"), text("transcript"), text("head"), sourceID, parserVersion)
        case "apply":
            guard let project = text("project") else { return .malformed }
            try database.run(applySQL, project, ts, json(entry["layers"] ?? []), json(entry["skills"] ?? [:]), sourceID, parserVersion)
        case "mark":
            guard let note = text("note"), !note.isEmpty else { return .malformed }
            try database.run(markSQL, ts, note, sourceID, parserVersion)
        case "rating":
            guard let harness = text("harness"), let session = text("session_id"), let rating = text("rating"),
                  RateRun.values.contains(rating) else { return .malformed }
            try database.run(ratingSQL, harness, session, ts, rating, text("text"), text("anchor"), text("transcript"), text("cwd"),
                             sourceID, parserVersion)
        default:
            return .unknown
        }
        return .written
    }

    private static func json(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static let hookEventSQL = FactWriter.upsert("hook_events", key: ["harness", "session_id", "ts"], identity: [],
                                                values: ["source", "cwd", "gitdir", "common_dir", "remote_id", "branch", "transcript", "head"])
    static let applySQL = FactWriter.upsert("applies", key: ["project_id", "ts"], identity: [], values: ["layers", "skills"])
    static let markSQL = FactWriter.upsert("marks", key: ["ts", "note"], identity: [], values: [])
    static let ratingSQL = FactWriter.upsert("ratings", key: ["harness", "session_id", "ts"], identity: [],
                                             values: ["rating", "text", "anchor", "transcript", "cwd"])
}
