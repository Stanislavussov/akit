import Foundation
import SQLite3
import Testing
@testable import AKitCore

/// Daily usage from session files in a temporary fake home. Never touches the real one.
struct UsageTests {
    let home: URL
    let fm = FileManager.default
    let since = JSONLines.date("2026-09-01T00:00:00.000Z")!

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-usage-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var env: HarnessEnvironment { HarnessEnvironment(homeDirectory: home) }

    /// The harness at its usual place in the fake home, whether it is detected or not.
    func installation(_ harness: HarnessID) -> HarnessInstallation {
        HarnessInstallation(id: harness, displayName: harness.displayName, executableURL: nil,
                            configRoot: HarnessCatalog.configRoot(of: harness, in: env)!, locations: [])
    }

    /// Usage of one harness as `UsageScanner` reads it.
    func usage(_ harness: HarnessID) -> [UsageRecord] {
        UsageScanner.scan(installations: [installation(harness)], since: since, in: env)
    }

    func write(_ path: String, lines: [[String: Any]]) throws {
        let url = home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = try lines.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
            .joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: url)
    }

    func claudeAnswer(id: String, time: String, model: String = "claude-opus-5", input: Int, output: Int) -> [String: Any] {
        ["type": "assistant", "timestamp": time,
         "message": ["id": id, "role": "assistant", "model": model, "content": [["type": "text", "text": "ok"]],
                     "usage": ["input_tokens": input, "output_tokens": output, "cache_read_input_tokens": 100,
                               "cache_creation_input_tokens": 10]]]
    }

    // MARK: Claude Code

    @Test func claudeCountsEachResponseOnceAcrossLinesAndFiles() throws {
        let first = claudeAnswer(id: "msg_1", time: "2026-09-20T10:00:00.000Z", input: 5, output: 50)
        try write(".claude/projects/-work-app/a.jsonl", lines: [
            first,
            claudeAnswer(id: "msg_1", time: "2026-09-20T10:00:01.000Z", input: 5, output: 70), // same response, final usage
            claudeAnswer(id: "msg_2", time: "2026-09-21T10:00:00.000Z", model: "<synthetic>", input: 1, output: 1),
            claudeAnswer(id: "msg_old", time: "2026-08-20T10:00:00.000Z", input: 1, output: 1), // before `since`
        ])
        // A resumed session repeats msg_1; a subagent has its own response.
        try write(".claude/projects/-work-app/b.jsonl", lines: [first])
        try write(".claude/projects/-work-app/a/subagents/agent-1.jsonl", lines: [
            claudeAnswer(id: "msg_3", time: "2026-09-21T11:00:00.000Z", model: "claude-haiku-4-5", input: 2, output: 3),
        ])

        let records = usage(.claudeCode).sorted { $0.time < $1.time }
        #expect(records.count == 2)
        #expect(records.map(\.model) == ["claude-opus-5", "claude-haiku-4-5"])
        #expect(records.allSatisfy { $0.provider == "anthropic" && $0.cost == nil && $0.harness == .claudeCode })
        let opus = try #require(records.first)
        #expect(opus.tokens == TokenCounts(input: 5, output: 70, cacheRead: 100, cacheWrite: 10))
    }

    @Test func claudeSessionCostIsSpreadOverItsResponses() throws {
        try write(".claude/projects/-work-app/s.jsonl", lines: [
            claudeAnswer(id: "m1", time: "2026-09-20T22:00:00.000Z", model: "claude-opus-5[1m]", input: 100, output: 0),
            claudeAnswer(id: "m2", time: "2026-09-21T09:00:00.000Z", model: "claude-opus-5[1m]", input: 300, output: 0),
            ["type": "cost-state", "sessionId": "s", "totalCostUSD": 1.0,
             "modelUsage": ["claude-opus-5[1m]": ["costUSD": 0.2], "claude-haiku-4-5-20251001": ["costUSD": 0.3]]],
            // The same process saves again later with its total so far.
            ["type": "cost-state", "sessionId": "s", "totalCostUSD": 1.2,
             "modelUsage": ["claude-opus-5[1m]": ["costUSD": 0.8], "claude-haiku-4-5-20251001": ["costUSD": 0.3]]],
        ])
        // A subagent answered with a model the cost-state lists too.
        try write(".claude/projects/-work-app/s/subagents/agent-1.jsonl", lines: [
            claudeAnswer(id: "m3", time: "2026-09-21T10:00:00.000Z", model: "claude-haiku-4-5-20251001", input: 5, output: 5),
        ])
        try write(".claude/projects/-work-app/no-cost.jsonl", lines: [
            claudeAnswer(id: "m4", time: "2026-09-21T11:00:00.000Z", input: 1, output: 1),
        ])

        let records = usage(.claudeCode).sorted { $0.time < $1.time }
        #expect(records.map(\.model) == ["claude-opus-5[1m]", "claude-opus-5[1m]", "claude-haiku-4-5-20251001", "claude-opus-5"])
        let costs = records.map { $0.cost.map { ($0 * 1000).rounded() / 1000 } }
        // Opus: 210 and 410 tokens (with the cache) share $0.80; haiku gets its $0.30; the
        // $0.10 no model accounts for goes to all 740 tokens. The other session's 112
        // tokens are estimated at the rate learned here: opus's $0.884 per 620 tokens.
        #expect(costs == [0.299, 0.584, 0.316, 0.16])
        #expect(records.map(\.costIsEstimated) == [false, false, false, true])
        #expect(abs(records.prefix(3).reduce(0) { $0 + ($1.cost ?? 0) } - 1.2) < 0.0001)
    }

    func costState(total: Double, start: String, minutes: Double, opus: Double? = nil) -> [String: Any] {
        ["type": "cost-state", "totalCostUSD": total,
         "startTime": JSONLines.date(start)!.timeIntervalSince1970 * 1000, "totalDuration": minutes * 60_000,
         "modelUsage": ["claude-opus-5[1m]": ["costUSD": opus ?? total]]]
    }

    @Test func claudeSavedCostCoversOnlyItsOwnProcess() throws {
        try write(".claude/projects/-work-app/resumed.jsonl", lines: [
            // First run, killed: saved nothing.
            claudeAnswer(id: "r1", time: "2026-09-20T10:00:00.000Z", input: 0, output: 890),
            // Second run (a resume) saved $2 for its own responses.
            claudeAnswer(id: "r2", time: "2026-09-21T10:00:00.000Z", input: 0, output: 890),
            costState(total: 2, start: "2026-09-21T09:59:00.000Z", minutes: 30),
            // Third run saved $0 although it answered; fourth never saved.
            claudeAnswer(id: "r3", time: "2026-09-22T10:00:00.000Z", input: 0, output: 890),
            costState(total: 0, start: "2026-09-22T09:59:00.000Z", minutes: 30),
            claudeAnswer(id: "r4", time: "2026-09-23T10:00:00.000Z", input: 0, output: 890),
        ])
        try write(".claude/projects/-work-app/resumed/subagents/agent-1.jsonl", lines: [
            claudeAnswer(id: "r5", time: "2026-09-21T10:05:00.000Z", input: 0, output: 890), // in the second run
        ])

        let records = usage(.claudeCode).sorted { $0.time < $1.time }
        #expect(records.map { $0.cost.map { ($0 * 1000).rounded() / 1000 } } == [1, 1, 1, 1, 1])
        // Only the second run and its subagent carry the recorded $2.
        #expect(records.map(\.costIsEstimated) == [true, false, false, true, true])
    }

    @Test func claudeIdleProcessKeepsItsFirstEqualSaveAndForksKeepTheRecordedCost() throws {
        try write(".claude/projects/-work-app/b-original.jsonl", lines: [
            claudeAnswer(id: "f1", time: "2026-09-21T10:00:00.000Z", input: 0, output: 890),
            costState(total: 2, start: "2026-09-21T09:59:00.000Z", minutes: 30),
            // The same process saved the same total again after idling for days.
            costState(total: 2, start: "2026-09-21T09:59:00.000Z", minutes: 60 * 24 * 5),
            // A later run inside that long window saved nothing: it is estimated.
            claudeAnswer(id: "f2", time: "2026-09-23T10:00:00.000Z", input: 0, output: 890),
        ])
        // A fork sorted first copies f1; its copy has no saved cost of its own.
        try write(".claude/projects/-work-app/a-fork.jsonl", lines: [
            claudeAnswer(id: "f1", time: "2026-09-21T10:00:00.000Z", input: 0, output: 890),
        ])

        let records = usage(.claudeCode).sorted { $0.time < $1.time }
        #expect(records.map(\.cost) == [2, 2])
        #expect(records.map(\.costIsEstimated) == [false, true])
    }

    @Test func claudeEstimateCountsCallsTheTranscriptLeavesOut() throws {
        // Claude Code saved $3 for a run whose transcript shows 1M tokens: the cost-state
        // also counts calls it didn't write down, so the rate is $3 per transcript million.
        try write(".claude/projects/-work-old/old.jsonl", lines: [
            ["type": "assistant", "timestamp": "2026-08-01T10:00:00.000Z",
             "message": ["id": "o1", "role": "assistant", "model": "claude-opus-5", "content": [],
                         "usage": ["input_tokens": 0, "output_tokens": 0, "cache_read_input_tokens": 1_000_000,
                                   "cache_creation_input_tokens": 0]]],
            costState(total: 3, start: "2026-08-01T09:00:00.000Z", minutes: 120),
        ])
        try fm.setAttributes([.modificationDate: JSONLines.date("2026-08-01T12:00:00.000Z")!],
                             ofItemAtPath: home.appending(path: ".claude/projects/-work-old/old.jsonl").path)
        // This session was killed: no cost-state.
        try write(".claude/projects/-work-app/killed.jsonl", lines: [
            ["type": "assistant", "timestamp": "2026-09-21T10:00:00.000Z",
             "message": ["id": "k1", "role": "assistant", "model": "claude-opus-5[1m]", "content": [],
                         "usage": ["input_tokens": 0, "output_tokens": 10_000, "cache_read_input_tokens": 240_000,
                                   "cache_creation_input_tokens": 0]]],
            // No saved cost for haiku anywhere: it stays unknown.
            claudeAnswer(id: "k2", time: "2026-09-21T10:01:00.000Z", model: "claude-haiku-4-5", input: 1, output: 1),
        ])

        let records = usage(.claudeCode).sorted { $0.time < $1.time }
        #expect(records.count == 2)
        let opus = try #require(records.first)
        #expect(opus.costIsEstimated)
        #expect(abs((opus.cost ?? 0) - 0.75) < 0.0001)
        #expect(records.last?.cost == nil)
        #expect(records.last?.costIsEstimated == false)

        let report = DailyUsageReport(records: records, from: since, to: JSONLines.date("2026-09-22T00:00:00.000Z")!)
        #expect(abs(report.grandTotal.estimatedCost - 0.75) < 0.0001)
        #expect(report.grandTotal.unpricedRequests == 1)
    }

    @Test func oldFilesAreNotRead() throws {
        try write(".claude/projects/-work-app/a.jsonl", lines: [
            claudeAnswer(id: "msg_1", time: "2026-09-20T10:00:00.000Z", input: 5, output: 50),
        ])
        try fm.setAttributes([.modificationDate: JSONLines.date("2026-08-01T00:00:00.000Z")!],
                             ofItemAtPath: home.appending(path: ".claude/projects/-work-app/a.jsonl").path)
        #expect(usage(.claudeCode).isEmpty)
    }

    // MARK: Pi

    func piAnswer(id: String, ms: Double, provider: String, model: String, cost: Double) -> [String: Any] {
        ["type": "message", "id": id, "parentId": "p", "timestamp": "2026-09-20T10:00:00.000Z",
         "message": ["role": "assistant", "provider": provider, "model": model, "timestamp": ms,
                     "content": [["type": "text", "text": "ok"]],
                     "usage": ["input": 10, "output": 20, "cacheRead": 30, "cacheWrite": 0, "totalTokens": 60,
                               "cost": ["total": cost]]]]
    }

    @Test func piRecordsProviderAndCostAndSkipsForkedCopies() throws {
        let ms = JSONLines.date("2026-09-22T08:00:00.000Z")!.timeIntervalSince1970 * 1000
        let shared = piAnswer(id: "a1", ms: ms, provider: "anthropic", model: "claude-opus-4-6", cost: 0.25)
        try write(".pi/agent/sessions/--work-app--/1_x.jsonl", lines: [
            ["type": "session", "id": "s1", "cwd": "/work/app", "timestamp": "2026-09-22T08:00:00.000Z"],
            shared,
            piAnswer(id: "a2", ms: ms + 1000, provider: "minimax", model: "MiniMax-M2.7", cost: 0.01),
        ])
        var failed = piAnswer(id: "a3", ms: ms + 2000, provider: "minimax", model: "MiniMax-M2.7", cost: 0)
        var message = failed["message"] as! [String: Any]
        message["usage"] = ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "cost": ["total": 0]]
        failed["message"] = message
        try write(".pi/agent/sessions/--work-app--/2_y.jsonl", lines: [shared, failed]) // a fork copies the entry

        let records = usage(.pi).sorted { $0.time < $1.time }
        #expect(records.count == 2)
        #expect(records.map(\.provider) == ["anthropic", "minimax"])
        #expect(records.map(\.cost) == [0.25, 0.01])
        #expect(records.first?.time == JSONLines.date("2026-09-22T08:00:00.000Z"))
        #expect(records.first?.tokens == TokenCounts(input: 10, output: 20, cacheRead: 30))
    }

    // MARK: Codex

    func tokenCount(_ time: String, input: Int, cached: Int, output: Int, reasoning: Int,
                    last: [String: Any]? = nil) -> [String: Any] {
        let total: [String: Any] = ["input_tokens": input, "cached_input_tokens": cached, "output_tokens": output,
                                    "reasoning_output_tokens": reasoning, "total_tokens": input + output]
        return ["type": "event_msg", "timestamp": time,
                "payload": ["type": "token_count", "info": ["total_token_usage": total, "last_token_usage": last ?? total]]]
    }

    @Test func codexResumedFileCountsOnlyItsOwnResponses() throws {
        // The first total carries 10 000 tokens from before the resume; only the last response is new.
        let last: [String: Any] = ["input_tokens": 300, "cached_input_tokens": 200, "output_tokens": 30,
                                   "reasoning_output_tokens": 0, "total_tokens": 330]
        try write(".codex/sessions/2026/09/24/rollout-2.jsonl", lines: [
            ["type": "turn_context", "timestamp": "2026-09-24T09:00:00.000Z", "payload": ["model": "gpt-5.5"]],
            tokenCount("2026-09-24T09:00:01.000Z", input: 10_000, cached: 9000, output: 330, reasoning: 0, last: last),
            tokenCount("2026-09-24T09:00:02.000Z", input: 10_500, cached: 9400, output: 360, reasoning: 0),
        ])
        let records = usage(.codex).sorted { $0.time < $1.time }
        #expect(records.map(\.tokens) == [
            TokenCounts(input: 100, output: 30, cacheRead: 200),
            TokenCounts(input: 100, output: 30, cacheRead: 400),
        ])
    }

    @Test func codexCountsGrowthOfTheRunningTotal() throws {
        try write(".codex/sessions/2026/09/23/rollout-1.jsonl", lines: [
            ["type": "session_meta", "timestamp": "2026-09-23T09:00:00.000Z", "payload": ["model_provider": "openai"]],
            ["type": "turn_context", "timestamp": "2026-09-23T09:00:00.000Z", "payload": ["model": "gpt-5.5"]],
            tokenCount("2026-09-23T09:00:01.000Z", input: 1000, cached: 800, output: 50, reasoning: 10),
            tokenCount("2026-09-23T09:00:02.000Z", input: 2500, cached: 2000, output: 80, reasoning: 30),
            tokenCount("2026-09-23T09:00:03.000Z", input: 2500, cached: 2000, output: 80, reasoning: 30), // repeated
            ["type": "turn_context", "timestamp": "2026-09-23T09:01:00.000Z", "payload": ["model": "gpt-5.4-mini"]],
            tokenCount("2026-09-23T09:01:01.000Z", input: 3000, cached: 2400, output: 100, reasoning: 30),
        ])

        let records = usage(.codex).sorted { $0.time < $1.time }
        #expect(records.map(\.model) == ["gpt-5.5", "gpt-5.5", "gpt-5.4-mini"])
        #expect(records.map(\.tokens) == [
            TokenCounts(input: 200, output: 50, cacheRead: 800, reasoning: 10),
            TokenCounts(input: 300, output: 30, cacheRead: 1200, reasoning: 20),
            TokenCounts(input: 100, output: 20, cacheRead: 400),
        ])
        #expect(records.allSatisfy { $0.provider == "openai" && $0.cost == nil })
    }

    func limitEvent(_ time: String, fiveHour: Double, weekly: Double, limit: String = "codex") -> [String: Any] {
        ["type": "event_msg", "timestamp": time,
         "payload": ["type": "token_count", "info": NSNull(),
                     "rate_limits": ["limit_id": limit, "plan_type": "plus",
                                     "primary": ["used_percent": fiveHour, "window_minutes": 300, "resets_at": 1_790_000_000],
                                     "secondary": ["used_percent": weekly, "window_minutes": 10_080, "resets_at": 1_790_500_000]]]]
    }

    @Test func codexLimitsGivePeaksPerDayAndTheLatestState() throws {
        try write(".codex/sessions/2026/09/23/rollout-3.jsonl", lines: [
            ["type": "session_meta", "timestamp": "2026-09-23T09:00:00.000Z", "payload": ["model_provider": "openai"]],
            limitEvent("2026-09-23T09:00:01.000Z", fiveHour: 10, weekly: 3),
            limitEvent("2026-09-23T12:00:00.000Z", fiveHour: 80, weekly: 9),
            limitEvent("2026-09-23T12:00:01.000Z", fiveHour: 99, weekly: 99, limit: "premium"), // another limit: ignored
            limitEvent("2026-09-24T08:00:00.000Z", fiveHour: 5, weekly: 11),
        ])
        let samples = UsageScanner.scanLimits(installations: [installation(.codex)], since: since, in: env)
        #expect(samples.count == 6)
        #expect(samples.first?.planName == "ChatGPT Plus")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let report = SubscriptionLimitReport(samples: samples, from: since, to: JSONLines.date("2026-09-25T00:00:00.000Z")!,
                                             calendar: calendar)
        let openAI = Subscription(provider: "openai")
        let day = calendar.startOfDay(for: JSONLines.date("2026-09-23T09:00:00.000Z")!)
        #expect(report.peaks(day, openAI).map(\.usedPercent) == [80, 9])
        #expect(report.peaks(day, openAI).map(\.windowName) == ["5-hour", "weekly"])
        #expect(report.latest(of: openAI).map(\.usedPercent) == [5, 11])
    }

    // MARK: OpenCode

    @Test func openCodeReadsAssistantRowsFromTheDatabase() throws {
        let url = home.appending(path: ".local/share/opencode/opencode.db")
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let created = JSONLines.date("2026-09-24T12:00:00.000Z")!.timeIntervalSince1970 * 1000
        func row(_ id: String, _ time: Double, _ data: [String: Any]) throws -> String {
            let json = String(decoding: try JSONSerialization.data(withJSONObject: data), as: UTF8.self)
            return "INSERT INTO message VALUES ('\(id)', 's', \(Int64(time)), \(Int64(time)), '\(json)');"
        }
        let assistant: [String: Any] = [
            "role": "assistant", "providerID": "opencode-go", "modelID": "kimi-k2.6", "cost": 0.5,
            "time": ["created": created], "tokens": ["input": 10, "output": 40, "reasoning": 15, "cache": ["read": 100, "write": 5]],
        ]
        let sql = try [
            "CREATE TABLE message (id text PRIMARY KEY, session_id text, time_created integer, time_updated integer, data text);",
            row("m1", created, assistant),
            row("m2", created, ["role": "user", "time": ["created": created]]),
            row("m3", created - 40 * 86_400_000, assistant), // before `since`
        ].joined()
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)

        let records = usage(.openCode)
        #expect(records.count == 1)
        let record = try #require(records.first)
        #expect(record.provider == "opencode-go")
        #expect(record.cost == 0.5)
        #expect(record.tokens == TokenCounts(input: 10, output: 40, cacheRead: 100, cacheWrite: 5, reasoning: 15))
    }

    // MARK: Daily report

    @Test func reportGroupsByDayAndSubscription() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Prague")!
        func record(_ time: String, _ harness: HarnessID, _ provider: String, output: Int, cost: Double?) -> UsageRecord {
            UsageRecord(time: JSONLines.date(time)!, harness: harness, provider: provider, model: "m",
                        tokens: TokenCounts(output: output), cost: cost)
        }
        let records = [
            record("2026-09-20T10:00:00.000Z", .claudeCode, "anthropic", output: 100, cost: nil),
            record("2026-09-20T11:00:00.000Z", .pi, "anthropic", output: 50, cost: 1.5),
            // 23:30 UTC is already the next day in Prague.
            record("2026-09-20T23:30:00.000Z", .codex, "openai", output: 10, cost: nil),
            record("2026-09-22T09:00:00.000Z", .pi, "openai-codex", output: 20, cost: 0.5),
            record("2026-08-01T09:00:00.000Z", .pi, "minimax", output: 999, cost: 9), // outside the range
        ]
        let report = DailyUsageReport(records: records, from: JSONLines.date("2026-09-20T08:00:00.000Z")!,
                                      to: JSONLines.date("2026-09-22T20:00:00.000Z")!, calendar: calendar)

        #expect(report.days.count == 3) // Sept 22, 21, 20 — the empty day stays in the table
        #expect(report.subscriptions.map(\.name) == ["Anthropic", "OpenAI"])
        let sept20 = report.days[2], sept21 = report.days[1]
        let anthropic = report.subscriptions[0], openAI = report.subscriptions[1]

        let cell = try #require(report.cell(sept20, anthropic))
        #expect(cell.requests == 2)
        #expect(cell.tokens.output == 150)
        #expect(cell.cost == 1.5)
        #expect(cell.unpricedRequests == 1)
        #expect(cell.parts.map(\.harness) == [.claudeCode, .pi])

        #expect(report.cell(sept21, openAI)?.tokens.output == 10)
        #expect(report.cell(sept21, openAI)?.cost == nil)
        #expect(report.total(of: openAI)?.cost == 0.5)
        #expect(report.grandTotal.requests == 4)
        #expect(report.grandTotal.cost == 2.0)
    }
}
