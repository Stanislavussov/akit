import Foundation

/// One model response as a harness recorded it: when, through which provider, how many
/// tokens and, if the harness writes it down, what it cost. The only estimate is Claude Code
/// cost for sessions that saved none, worked out from Claude Code's own saved costs.
public struct UsageRecord: Sendable, Hashable {
    public let time: Date
    public let harness: HarnessID
    /// Provider id as the harness wrote it: `anthropic`, `openai`, `opencode-go`…
    public let provider: String
    public let model: String
    public let tokens: TokenCounts
    /// US dollars recorded by the harness (Pi and OpenCode per response, Claude Code per
    /// session), or estimated when `costIsEstimated`. nil = unknown (Codex never records it).
    public let cost: Double?
    /// `cost` was worked out, not recorded: see `ClaudeCostRates`.
    public let costIsEstimated: Bool

    public init(time: Date, harness: HarnessID, provider: String, model: String, tokens: TokenCounts, cost: Double?,
                costIsEstimated: Bool = false) {
        self.time = time
        self.harness = harness
        self.provider = provider
        self.model = model
        self.tokens = tokens
        self.cost = cost
        self.costIsEstimated = cost != nil && costIsEstimated
    }

    public var subscription: Subscription { Subscription(provider: provider) }
}

/// Where the tokens were paid: the provider account or plan behind a harness.
/// The same provider used from several harnesses is one subscription
/// (Claude Code and Pi on `anthropic`, Codex on `openai` and Pi on `openai-codex`).
public struct Subscription: Sendable, Hashable, Identifiable, Comparable {
    public let id: String
    public let name: String

    public init(provider: String) {
        let key = provider.lowercased()
        let known = Self.names.first { $0.providers.contains(key) }
        id = known?.id ?? key
        name = known?.name ?? provider
    }

    public static func < (a: Subscription, b: Subscription) -> Bool { a.name.localizedStandardCompare(b.name) == .orderedAscending }

    private static let names: [(id: String, name: String, providers: Set<String>)] = [
        ("anthropic", "Anthropic", ["anthropic"]),
        ("openai", "OpenAI", ["openai", "openai-codex"]),
        ("github-copilot", "GitHub Copilot", ["github-copilot"]),
        ("google-antigravity", "Antigravity", ["google-antigravity"]),
        ("google", "Google Gemini", ["google", "google-gemini-cli"]),
        ("minimax", "MiniMax", ["minimax"]),
        ("opencode-go", "OpenCode Go", ["opencode-go"]),
        ("opencode", "OpenCode Zen", ["opencode"]),
        ("openrouter", "OpenRouter", ["openrouter"]),
    ]
}

/// Usage records of all installed harnesses.
public enum UsageScanner {
    /// Responses from `since` on, in no particular order. Harnesses that record none or
    /// that AKit can't read (custom ones too) add none.
    public static func scan(installations: [HarnessInstallation], since: Date, in env: HarnessEnvironment) -> [UsageRecord] {
        installations.flatMap { usage(of: $0, since: since, in: env) }
    }

    /// Token usage of every model response one harness recorded at or after `since`.
    static func usage(of installation: HarnessInstallation, since: Date, in env: HarnessEnvironment) -> [UsageRecord] {
        switch installation.id {
        case .claudeCode:
            ClaudeUsage.usage(configRoot: installation.configRoot, since: since)
        case .pi:
            PiUsage.usage(folder: PiLogFormat.folder(configRoot: installation.configRoot, in: env), since: since)
        case .codex:
            // Token counts from the rollout files. Codex records no cost.
            CodexUsage.usage(codexHome: installation.configRoot, since: since)
        case .openCode:
            // Token counts and cost from OpenCode's session database.
            OpenCodeUsage.usage(database: OpenCodeUsage.database(in: env), since: since)
        default:
            []
        }
    }

    /// Session files changed at or after `since`: older ones can't hold newer responses.
    static func files(in folders: [URL], since: Date, where keep: (URL) -> Bool = { $0.pathExtension == "jsonl" }) -> [URL] {
        let fm = FileManager.default
        var result: [URL] = []
        for folder in folders {
            guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])
            else { continue }
            for case let url as URL in walker where keep(url) {
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                guard values?.isRegularFile == true, (values?.contentModificationDate ?? .distantPast) >= since else { continue }
                result.append(url)
            }
        }
        return result.sorted { $0.path < $1.path }
    }

    /// Reads files in parallel and keeps one record per key: harnesses copy earlier
    /// responses into a new file when a session is resumed or forked. A copy may have
    /// been taken while the response was still streaming, so the largest one wins; of
    /// equal ones a recorded cost beats an estimated or missing one.
    static func read(_ files: [URL], _ read: @Sendable (URL) -> [(key: String?, record: UsageRecord)]) -> [UsageRecord] {
        let box = RecordBox(count: files.count)
        DispatchQueue.concurrentPerform(iterations: files.count) { index in
            box.set(index, read(files[index]))
        }
        var unkeyed: [UsageRecord] = []
        var byKey: [String: UsageRecord] = [:]
        for item in box.values.flatMap(\.self) {
            guard let key = item.key else {
                unkeyed.append(item.record)
                continue
            }
            if let kept = byKey[key], (kept.tokens.total, rank(kept)) >= (item.record.tokens.total, rank(item.record)) { continue }
            byKey[key] = item.record
        }
        return unkeyed + byKey.values
    }

    private static func rank(_ record: UsageRecord) -> Int {
        record.cost == nil ? 0 : record.costIsEstimated ? 1 : 2
    }
}

private final class RecordBox: @unchecked Sendable {
    private let lock = NSLock()
    private var slots: [[(key: String?, record: UsageRecord)]]

    init(count: Int) { slots = Array(repeating: [], count: count) }

    func set(_ index: Int, _ value: [(key: String?, record: UsageRecord)]) {
        lock.withLock { slots[index] = value }
    }

    var values: [[(key: String?, record: UsageRecord)]] { lock.withLock { slots } }
}
