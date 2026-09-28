import Foundation
import SQLite3

// Readers of the token usage each harness records, for the daily usage table.
// They only read files, and only lines that can hold usage are decoded.

extension ClaudeSessions {
    /// `message.usage` of assistant entries in all sessions and their subagent runs. One
    /// response is written as several lines with the same `message.id`, and resumed or
    /// forked sessions copy earlier lines, so responses are counted once per id.
    ///
    /// Claude Code records no cost per response, but when a session ends normally it saves
    /// a `cost-state` line: the session's total (what `/cost` shows) and each model's part.
    /// Each model's part is spread over that model's responses by their share of its
    /// tokens, so a session that ran over several days lands on each of them.
    /// Sessions that never saved one (the process was killed, or still runs) get an
    /// estimate from the rates in the saved ones (`ClaudeCostRates`), marked as such.
    static func usage(configRoot: URL, since: Date) -> [UsageRecord] {
        let projects = configRoot.appending(path: "projects")
        func isSession(_ url: URL) -> Bool {
            url.pathExtension == "jsonl" && url.deletingLastPathComponent().lastPathComponent != "subagents"
        }
        let rates = ClaudeCostRates(costStates: costStates(in: UsageScanner.files(in: [projects], since: .distantPast, where: isSession)))
        let sessions = UsageScanner.files(in: [projects], since: since, where: isSession)
        return UsageScanner.read(sessions) { session in
            var (responses, cost) = sessionUsage(in: session)
            let subagents = session.deletingPathExtension().appending(path: "subagents")
            for agent in SkillScanner.children(of: subagents) where agent.pathExtension == "jsonl" {
                responses += sessionUsage(in: agent).responses
            }
            if let cost {
                responses = spread(cost, over: responses, estimated: false)
            } else if let estimate = rates.estimate(for: responses.map(\.record)) {
                responses = spread(estimate, over: responses, estimated: true)
            }
            return responses.filter { $0.record.time >= since }
        }
    }

    /// Cost Claude Code saved for a session, in US dollars.
    struct CostState: Sendable {
        struct Part: Sendable {
            var tokens: TokenCounts
            var cost: Double
        }
        var total: Double
        /// By model id without a context suffix such as `[1m]`.
        var byModel: [String: Part]
    }

    /// The last (largest) cost-state of every session file that has one.
    static func costStates(in files: [URL]) -> [CostState] {
        let marker = Data(#""cost-state""#.utf8)
        let box = CostStateBox(count: files.count)
        DispatchQueue.concurrentPerform(iterations: files.count) { index in
            // Most files have none: look for the marker before splitting into lines.
            guard let data = try? Data(contentsOf: files[index], options: .mappedIfSafe), data.range(of: marker) != nil,
                  let entries = try? JSONLines.objects(in: data, where: { JSONLines.contains($0, marker) }) else { return }
            var best: CostState?
            for entry in entries {
                if let state = costState(entry), state.total >= (best?.total ?? 0) { best = state }
            }
            box.set(index, best)
        }
        return box.values.compactMap(\.self)
    }

    static func costState(_ entry: JSONLines.Object) -> CostState? {
        guard entry["type"] as? String == "cost-state",
              let total = (entry["totalCostUSD"] as? NSNumber)?.doubleValue else { return nil }
        var byModel: [String: CostState.Part] = [:]
        for (model, usage) in entry["modelUsage"] as? JSONLines.Object ?? [:] {
            guard let usage = usage as? JSONLines.Object, let dollars = (usage["costUSD"] as? NSNumber)?.doubleValue else { continue }
            func count(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
            let tokens = TokenCounts(input: count("inputTokens"), output: count("outputTokens"),
                                     cacheRead: count("cacheReadInputTokens"), cacheWrite: count("cacheCreationInputTokens"))
            var part = byModel[baseModel(model)] ?? CostState.Part(tokens: TokenCounts(), cost: 0)
            part.tokens = part.tokens + tokens
            part.cost += dollars
            byModel[baseModel(model)] = part
        }
        return CostState(total: total, byModel: byModel)
    }

    static func sessionUsage(in file: URL) -> (responses: [(key: String?, record: UsageRecord)], cost: CostState?) {
        let usageMarker = Data(#""usage""#.utf8)
        let assistantMarker = Data(#""type":"assistant""#.utf8)
        let costMarker = Data(#""cost-state""#.utf8)
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe),
              let entries = try? JSONLines.objects(in: data, where: {
                  (JSONLines.contains($0, assistantMarker) && JSONLines.contains($0, usageMarker)) || JSONLines.contains($0, costMarker)
              }) else { return ([], nil) }
        var byID: [String: Int] = [:]
        var result: [(key: String?, record: UsageRecord)] = []
        var cost: CostState?
        for entry in entries {
            // A resumed session saves it again with the total so far: the largest wins.
            if let state = costState(entry) {
                if state.total >= (cost?.total ?? 0) { cost = state }
                continue
            }
            guard entry["type"] as? String == "assistant",
                  let message = entry["message"] as? JSONLines.Object, let usage = message["usage"] as? JSONLines.Object,
                  let model = message["model"] as? String, model != "<synthetic>",
                  let time = JSONLines.date(entry["timestamp"]) else { continue }
            let record = UsageRecord(time: time, harness: .claudeCode, provider: "anthropic", model: model,
                                     tokens: tokens(fromClaudeUsage: usage), cost: nil)
            let id = message["id"] as? String ?? entry["requestId"] as? String
            // The last line of a response carries its final usage.
            if let id, let index = byID[id] {
                result[index] = (id, record)
            } else {
                if let id { byID[id] = result.count }
                result.append((id, record))
            }
        }
        return (result, cost)
    }

    /// `claude-opus-5[1m]` → `claude-opus-5`
    static func baseModel(_ model: String) -> String {
        model.firstIndex(of: "[").map { String(model[..<$0]) } ?? model
    }

    /// Gives each response its share of the session cost. With a saved cost, a model the
    /// cost-state doesn't list shares what is left of the total with the other unlisted
    /// ones; with an estimate, unlisted models stay without a cost.
    static func spread(_ cost: CostState, over responses: [(key: String?, record: UsageRecord)], estimated: Bool)
        -> [(key: String?, record: UsageRecord)] {
        var groups: [String: [Int]] = [:]
        for (index, item) in responses.enumerated() { groups[baseModel(item.record.model), default: []].append(index) }
        let listed = groups.keys.filter { cost.byModel[$0] != nil }
        let unlisted = groups.keys.filter { cost.byModel[$0] == nil }
        let leftover = max(cost.total - listed.reduce(0) { $0 + cost.byModel[$1]!.cost }, 0)

        var result = responses
        func give(_ dollars: Double, to indices: [Int]) {
            let tokens = indices.reduce(0) { $0 + responses[$1].record.tokens.total }
            for index in indices {
                let share = tokens > 0 ? Double(responses[index].record.tokens.total) / Double(tokens) : 1 / Double(indices.count)
                let record = responses[index].record
                result[index].record = UsageRecord(time: record.time, harness: record.harness, provider: record.provider,
                                                   model: record.model, tokens: record.tokens, cost: dollars * share,
                                                   costIsEstimated: estimated)
            }
        }
        for model in listed { give(cost.byModel[model]!.cost, to: groups[model]!) }
        if !estimated, !unlisted.isEmpty { give(leftover, to: unlisted.flatMap { groups[$0]! }) }
        return result
    }
}

private final class CostStateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var slots: [ClaudeSessions.CostState?]

    init(count: Int) { slots = Array(repeating: nil, count: count) }

    func set(_ index: Int, _ value: ClaudeSessions.CostState?) {
        lock.withLock { slots[index] = value }
    }

    var values: [ClaudeSessions.CostState?] { lock.withLock { slots } }
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
                let tokens = tokens(fromPiUsage: usage), cost = cost(fromPiUsage: usage)
                // Failed requests are saved with all counts at zero.
                guard tokens.total > 0 || (cost ?? 0) > 0 else { return nil }
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
