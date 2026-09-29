import Foundation

/// How much of a subscription's usage limit was used, as the harness saw it after a
/// response. Codex records this for ChatGPT plans: a 5-hour and a weekly window.
public struct LimitSample: Sendable, Hashable {
    public let time: Date
    public let harness: HarnessID
    public let provider: String
    /// `plus`, `pro`… as the harness wrote it.
    public let plan: String?
    public let windowMinutes: Int
    public let usedPercent: Double
    public let resetsAt: Date?

    public init(time: Date, harness: HarnessID, provider: String, plan: String?, windowMinutes: Int, usedPercent: Double,
                resetsAt: Date?) {
        self.time = time
        self.harness = harness
        self.provider = provider
        self.plan = plan
        self.windowMinutes = windowMinutes
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }

    public var subscription: Subscription { Subscription(provider: provider) }

    /// "5-hour", "weekly"
    public var windowName: String {
        switch windowMinutes {
        case 10_080: "weekly"
        case 1440: "daily"
        case let minutes where minutes % 60 == 0: "\(minutes / 60)-hour"
        case let minutes: "\(minutes)-minute"
        }
    }

    /// "ChatGPT Plus"
    public var planName: String? {
        guard let plan, !plan.isEmpty else { return nil }
        let name = plan.prefix(1).uppercased() + plan.dropFirst()
        return provider.lowercased().hasPrefix("openai") ? "ChatGPT \(name)" : name
    }
}

/// Limit samples per day and subscription: the highest share used in each window.
public struct SubscriptionLimitReport: Sendable {
    public struct Peak: Sendable, Hashable {
        public let windowMinutes: Int
        public let windowName: String
        public let usedPercent: Double
    }

    private var peaks: [Date: [String: [Int: Peak]]] = [:]
    private var latest: [String: [Int: LimitSample]] = [:]

    public init(samples: [LimitSample], from: Date, to: Date, calendar: Calendar = .current) {
        let first = calendar.startOfDay(for: from)
        let last = calendar.startOfDay(for: to)
        for sample in samples {
            let day = calendar.startOfDay(for: sample.time)
            guard day >= first, day <= last else { continue }
            let id = sample.subscription.id
            let old = peaks[day]?[id]?[sample.windowMinutes]?.usedPercent ?? -1
            if sample.usedPercent > old {
                peaks[day, default: [:]][id, default: [:]][sample.windowMinutes] =
                    Peak(windowMinutes: sample.windowMinutes, windowName: sample.windowName, usedPercent: sample.usedPercent)
            }
            if sample.time >= latest[id]?[sample.windowMinutes]?.time ?? .distantPast {
                latest[id, default: [:]][sample.windowMinutes] = sample
            }
        }
    }

    /// Highest use per window that day, shortest window first.
    public func peaks(_ day: Date, _ subscription: Subscription) -> [Peak] {
        (peaks[day]?[subscription.id] ?? [:]).values.sorted { $0.windowMinutes < $1.windowMinutes }
    }

    /// The last sample of each window, shortest window first.
    public func latest(of subscription: Subscription) -> [LimitSample] {
        (latest[subscription.id] ?? [:]).values.sorted { $0.windowMinutes < $1.windowMinutes }
    }

    public var subscriptionIDs: Set<String> { Set(latest.keys) }
    public var isEmpty: Bool { latest.isEmpty }
}

extension UsageScanner {
    /// Limit samples of all installed harnesses from `since` on. Only Codex records them
    /// (ChatGPT plan windows it saw after each response).
    public static func scanLimits(installations: [HarnessInstallation], since: Date, in env: HarnessEnvironment) -> [LimitSample] {
        installations.flatMap { installation -> [LimitSample] in
            switch installation.id {
            case .codex: CodexUsage.limits(codexHome: installation.configRoot, since: since)
            default: []
            }
        }
    }
}

extension CodexUsage {
    /// `rate_limits` of `token_count` events: plan type and the used share of the primary
    /// (5-hour) and secondary (weekly) windows. Only the `codex` limit is read.
    static func limits(codexHome: URL, since: Date) -> [LimitSample] {
        let folders = [codexHome.appending(path: "sessions"), codexHome.appending(path: "archived_sessions")]
        let files = UsageScanner.files(in: folders, since: since)
        let markers = [#""rate_limits""#, #""session_meta""#].map { Data($0.utf8) }
        let box = LimitBox(count: files.count)
        DispatchQueue.concurrentPerform(iterations: files.count) { index in
            guard let data = try? Data(contentsOf: files[index], options: .mappedIfSafe),
                  let entries = try? JSONLines.objects(in: data, where: { line in markers.contains { JSONLines.contains(line, $0) } })
            else { return }
            var provider = "openai"
            var samples: [LimitSample] = []
            for entry in entries {
                let payload = entry["payload"] as? JSONLines.Object ?? [:]
                if entry["type"] as? String == "session_meta" {
                    provider = payload["model_provider"] as? String ?? provider
                    continue
                }
                guard payload["type"] as? String == "token_count", let limits = payload["rate_limits"] as? JSONLines.Object,
                      (limits["limit_id"] as? String ?? "codex") == "codex",
                      let time = JSONLines.date(entry["timestamp"]), time >= since else { continue }
                for key in ["primary", "secondary"] {
                    guard let window = limits[key] as? JSONLines.Object,
                          let minutes = (window["window_minutes"] as? NSNumber)?.intValue,
                          let used = (window["used_percent"] as? NSNumber)?.doubleValue else { continue }
                    let resets = (window["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                    samples.append(LimitSample(time: time, harness: .codex, provider: provider, plan: limits["plan_type"] as? String,
                                               windowMinutes: minutes, usedPercent: used, resetsAt: resets))
                }
            }
            box.set(index, samples)
        }
        return box.values.flatMap(\.self)
    }
}

private final class LimitBox: @unchecked Sendable {
    private let lock = NSLock()
    private var slots: [[LimitSample]]

    init(count: Int) { slots = Array(repeating: [], count: count) }

    func set(_ index: Int, _ value: [LimitSample]) {
        lock.withLock { slots[index] = value }
    }

    var values: [[LimitSample]] { lock.withLock { slots } }
}
