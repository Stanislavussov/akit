import Foundation
import SQLite3

// Readers of the token usage each harness records, for the daily usage table.
// They only read files, and only lines that can hold usage are decoded.

extension ClaudeSessions {
    /// `message.usage` of assistant entries in all sessions and subagent runs. One response
    /// is written as several lines with the same `message.id`, and resumed or forked
    /// sessions copy earlier lines, so responses are counted once per id.
    static func usage(configRoot: URL, since: Date) -> [UsageRecord] {
        let files = UsageScanner.files(in: [configRoot.appending(path: "projects")], since: since)
        let usageMarker = Data(#""usage""#.utf8)
        let assistantMarker = Data(#""type":"assistant""#.utf8)
        return UsageScanner.read(files) { file in
            guard let data = try? Data(contentsOf: file, options: .mappedIfSafe),
                  let entries = try? JSONLines.objects(in: data, where: {
                      JSONLines.contains($0, assistantMarker) && JSONLines.contains($0, usageMarker)
                  }) else { return [] }
            var byID: [String: Int] = [:]
            var result: [(key: String?, record: UsageRecord)] = []
            for entry in entries where entry["type"] as? String == "assistant" {
                guard let message = entry["message"] as? JSONLines.Object, let usage = message["usage"] as? JSONLines.Object,
                      let model = message["model"] as? String, model != "<synthetic>",
                      let time = JSONLines.date(entry["timestamp"]), time >= since else { continue }
                func count(_ key: String, in object: JSONLines.Object? = usage) -> Int { (object?[key] as? NSNumber)?.intValue ?? 0 }
                let tokens = TokenCounts(input: count("input_tokens"), output: count("output_tokens"),
                                         cacheRead: count("cache_read_input_tokens"),
                                         cacheWrite: count("cache_creation_input_tokens"),
                                         reasoning: count("thinking_tokens", in: usage["output_tokens_details"] as? JSONLines.Object))
                let record = UsageRecord(time: time, harness: .claudeCode, provider: "anthropic", model: model,
                                         tokens: tokens, cost: nil)
                let id = message["id"] as? String ?? entry["requestId"] as? String
                // The last line of a response carries its final usage.
                if let id, let index = byID[id] {
                    result[index] = (id, record)
                } else {
                    if let id { byID[id] = result.count }
                    result.append((id, record))
                }
            }
            return result
        }
    }
}

extension PiSessions {
    /// Every assistant message in the file, abandoned branches included: they were paid for.
    /// Pi records the provider and the cost of each response. A fork copies entries into
    /// a new file, so an entry id and time is counted once.
    static func usage(folder: URL, since: Date) -> [UsageRecord] {
        let files = UsageScanner.files(in: [folder], since: since)
        let usageMarker = Data(#""usage""#.utf8)
        return UsageScanner.read(files) { file in
            guard let data = try? Data(contentsOf: file, options: .mappedIfSafe),
                  let entries = try? JSONLines.objects(in: data, where: { JSONLines.contains($0, usageMarker) })
            else { return [] }
            return entries.compactMap { entry in
                guard entry["type"] as? String == "message", let message = entry["message"] as? JSONLines.Object,
                      message["role"] as? String == "assistant", let usage = message["usage"] as? JSONLines.Object,
                      let time = JSONLines.date(message["timestamp"]) ?? JSONLines.date(entry["timestamp"]),
                      time >= since else { return nil }
                func count(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
                let tokens = TokenCounts(input: count("input"), output: count("output"),
                                         cacheRead: count("cacheRead"), cacheWrite: count("cacheWrite"))
                let cost = ((usage["cost"] as? JSONLines.Object)?["total"] as? NSNumber)?.doubleValue
                let record = UsageRecord(time: time, harness: .pi, provider: message["provider"] as? String ?? "unknown",
                                         model: message["model"] as? String ?? "unknown", tokens: tokens, cost: cost)
                let key = (entry["id"] as? String).map { "\($0)|\(time.timeIntervalSince1970)" }
                return (key, record)
            }
        }
    }
}

/// Codex rollout files: `<codex home>/sessions/YYYY/MM/DD/rollout-*.jsonl` and
/// `archived_sessions/`. `token_count` events carry the running total of the session;
/// the growth between two events is what one response used. Codex records no cost.
enum CodexUsage {
    static func usage(codexHome: URL, since: Date) -> [UsageRecord] {
        let folders = [codexHome.appending(path: "sessions"), codexHome.appending(path: "archived_sessions")]
        let files = UsageScanner.files(in: folders, since: since)
        let markers = [#""token_count""#, #""turn_context""#, #""session_meta""#].map { Data($0.utf8) }
        return UsageScanner.read(files) { file in
            guard let data = try? Data(contentsOf: file, options: .mappedIfSafe),
                  let entries = try? JSONLines.objects(in: data, where: { line in markers.contains { JSONLines.contains(line, $0) } })
            else { return [] }
            var provider = "openai"
            var model = "unknown"
            var previous: TokenCounts?
            var result: [(key: String?, record: UsageRecord)] = []
            for entry in entries {
                let payload = entry["payload"] as? JSONLines.Object ?? [:]
                switch entry["type"] as? String {
                case "session_meta":
                    provider = payload["model_provider"] as? String ?? provider
                case "turn_context":
                    model = payload["model"] as? String ?? model
                case "event_msg" where payload["type"] as? String == "token_count":
                    guard let info = payload["info"] as? JSONLines.Object,
                          let total = (info["total_token_usage"] as? JSONLines.Object).map(tokens) else { continue }
                    // Codex repeats the last total (e.g. after an abort); only growth is new usage.
                    // The first event of a file counts its own response only, in case the
                    // total carries usage from before a resume.
                    let last = (info["last_token_usage"] as? JSONLines.Object).map(tokens)
                    let used = previous.map { difference(total, $0) } ?? last ?? total
                    previous = total
                    guard used.total > 0, let time = JSONLines.date(entry["timestamp"]), time >= since else { continue }
                    let record = UsageRecord(time: time, harness: .codex, provider: provider, model: model,
                                             tokens: used, cost: nil)
                    // A resumed session starts a new file that repeats earlier events.
                    let key = "\(time.timeIntervalSince1970)|\(total.total)"
                    result.append((key, record))
                default:
                    break
                }
            }
            return result
        }
    }

    /// OpenAI counts cached input inside `input_tokens` and reasoning inside `output_tokens`.
    static func tokens(_ usage: JSONLines.Object) -> TokenCounts {
        func count(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
        let cached = count("cached_input_tokens")
        return TokenCounts(input: max(count("input_tokens") - cached, 0), output: count("output_tokens"),
                           cacheRead: cached, reasoning: count("reasoning_output_tokens"))
    }

    /// `a - b`; a total that went down (a new count) is taken as it is.
    static func difference(_ a: TokenCounts, _ b: TokenCounts) -> TokenCounts {
        guard a.input >= b.input, a.output >= b.output, a.cacheRead >= b.cacheRead else { return a }
        return TokenCounts(input: a.input - b.input, output: a.output - b.output, cacheRead: a.cacheRead - b.cacheRead,
                           cacheWrite: max(a.cacheWrite - b.cacheWrite, 0), reasoning: max(a.reasoning - b.reasoning, 0))
    }
}

/// OpenCode keeps sessions in SQLite: `$XDG_DATA_HOME/opencode/opencode.db`
/// (default `~/.local/share/opencode`). Each assistant row of `message` has
/// `providerID`, `modelID`, `tokens` and the `cost` OpenCode computed.
enum OpenCodeUsage {
    static func database(in env: HarnessEnvironment) -> URL {
        let data = env.variables["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : env.expand($0) }
            ?? env.homeDirectory.appending(path: ".local/share")
        return data.appending(path: "opencode/opencode.db")
    }

    static func usage(database: URL, since: Date) -> [UsageRecord] {
        guard FileManager.default.fileExists(atPath: database.path) else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)
        var statement: OpaquePointer?
        let query = "SELECT data FROM message WHERE time_created >= ?"
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(since.timeIntervalSince1970 * 1000))

        var result: [UsageRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let bytes = sqlite3_column_blob(statement, 0) else { continue }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
            guard let message = JSONLines.decode(data), let record = record(message), record.time >= since else { continue }
            result.append(record)
        }
        return result
    }

    /// `input` excludes the cache; `output` includes `reasoning`.
    static func record(_ message: JSONLines.Object) -> UsageRecord? {
        guard message["role"] as? String == "assistant", let usage = message["tokens"] as? JSONLines.Object,
              let created = ((message["time"] as? JSONLines.Object)?["created"] as? NSNumber)?.doubleValue else { return nil }
        func count(_ key: String, in object: JSONLines.Object? = usage) -> Int { (object?[key] as? NSNumber)?.intValue ?? 0 }
        let cache = usage["cache"] as? JSONLines.Object
        let tokens = TokenCounts(input: count("input"), output: count("output"), cacheRead: count("read", in: cache),
                                 cacheWrite: count("write", in: cache), reasoning: count("reasoning"))
        guard tokens.total > 0 else { return nil }
        return UsageRecord(time: Date(timeIntervalSince1970: created / 1000), harness: .openCode,
                           provider: message["providerID"] as? String ?? "unknown",
                           model: message["modelID"] as? String ?? "unknown", tokens: tokens,
                           cost: (message["cost"] as? NSNumber)?.doubleValue)
    }
}
