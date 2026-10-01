import AKitFoundation
import Darwin
import Foundation

/// What one model call cost, as the harness recorded it: tokens, and the cost when the
/// harness wrote one (Claude Code's `total_cost_usd`, Pi's `usage.cost.total`). AKit never
/// prices tokens itself.
public struct SendUsage: Codable, Hashable, Sendable {
    public var input: Int
    public var cached: Int
    public var output: Int
    /// US dollars, as recorded; nil when the harness recorded none.
    public var cost: Double?

    public init(input: Int = 0, cached: Int = 0, output: Int = 0, cost: Double? = nil) {
        self.input = input
        self.cached = cached
        self.output = output
        self.cost = cost
    }

    static func + (a: SendUsage, b: SendUsage) -> SendUsage {
        SendUsage(input: a.input + b.input, cached: a.cached + b.cached, output: a.output + b.output,
                  cost: a.cost.map { $0 + (b.cost ?? 0) } ?? b.cost)
    }
}

/// One line of `sends.jsonl`: one call that sent session data or code out.
public struct SendRecord: Codable, Hashable, Sendable {
    public var date: Date
    /// review, notes, verifier, matching, clustering, judge, pairing, replay, …
    public var purpose: String
    /// The session key or transcript path the data came from, when it came from one.
    public var session: String?
    public var runID: String?
    public var harness: LabHarness
    public var provider: String
    public var account: String
    public var org: String
    public var model: String
    /// Characters sent after scrubbing: the estimate of the next call scales with it.
    public var inputCharacters: Int
    public var usage: SendUsage
    public var scrubVersion: Int
    /// Scrubber matches per rule, so the log shows what was masked (never the values).
    public var scrubbed: [String: Int]?

    public init(date: Date = .now, purpose: String, session: String?, runID: String?, destination: SendDestination, model: String,
                inputCharacters: Int, usage: SendUsage, scrubVersion: Int = Scrubber.version, scrubbed: [String: Int]? = nil) {
        self.date = date
        self.purpose = purpose
        self.session = session
        self.runID = runID
        harness = destination.harness
        provider = destination.provider
        account = destination.account
        org = destination.org
        self.model = model
        self.inputCharacters = inputCharacters
        self.usage = usage
        self.scrubVersion = scrubVersion
        self.scrubbed = scrubbed
    }
}

/// `~/.akit/lab/analysis/sends.jsonl`: every send, appended under a lock, never rewritten.
public enum SendLog {
    public static func file(env: HarnessEnvironment) -> URL {
        LabPaths(env: env).folder.appending(path: "analysis/sends.jsonl")
    }

    /// One `write` on a file opened with O_APPEND: lines of parallel calls never interleave.
    public static func append(_ record: SendRecord, env: HarnessEnvironment) throws {
        let url = file(env: env)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var line = try lineEncoder.encode(record)
        line.append(0x0A)
        let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw LabStore.Failure(message: "Can't open \(url.path).") }
        defer { close(descriptor) }
        let written = line.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        guard written == line.count else { throw LabStore.Failure(message: "Couldn't write to \(url.path).") }
    }

    /// Every record, oldest first; unreadable lines are skipped.
    public static func records(env: HarnessEnvironment) -> [SendRecord] {
        guard let data = try? Data(contentsOf: file(env: env)) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? LabStore.decoder.decode(SendRecord.self, from: Data($0)) }
    }

    /// Recorded cost of the calendar month that holds `date`.
    public static func monthCost(_ records: [SendRecord], at date: Date = .now, calendar: Calendar = .current) -> Double {
        records.filter { calendar.isDate($0.date, equalTo: date, toGranularity: .month) }.compactMap(\.usage.cost).reduce(0, +)
    }

    /// "≈" cost of sending `characters` to `model` of `harness`: the recorded cost per input
    /// character of earlier calls to the same model. nil until one such call recorded a cost.
    public static func estimate(characters: Int, harness: LabHarness, model: String, records: [SendRecord]) -> Double? {
        let same = records.filter { $0.harness == harness && $0.model == model && $0.usage.cost != nil && $0.inputCharacters > 0 }
        guard !same.isEmpty else { return nil }
        let cost = same.compactMap(\.usage.cost).reduce(0, +)
        let sent = same.map(\.inputCharacters).reduce(0, +)
        return cost / Double(sent) * Double(characters)
    }

    /// Throws when the month's recorded cost plus `estimate` would pass the monthly limit.
    /// Without an estimate only the cost so far is checked.
    public static func checkLimit(estimate: Double?, settings: LabSettings, env: HarnessEnvironment, now: Date = .now) throws {
        guard let limit = settings.monthlyLimit else { return }
        let spent = monthCost(records(env: env), at: now)
        let next = estimate ?? 0
        guard spent + next <= limit else {
            throw SendAccounts.Failure(message: String(format: "Not sent: the monthly limit is $%.2f, $%.2f is recorded this month", limit, spent)
                                           + (estimate.map { String(format: " and this needs ≈ $%.2f", $0) } ?? "") + ". Raise it in Settings → Lab.")
        }
    }

    private static let lineEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date))
        }
        return encoder
    }()
}
