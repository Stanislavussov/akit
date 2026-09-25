import Foundation

/// Usage added up for one day, one subscription or everything.
public struct UsageTotal: Sendable, Hashable {
    public var requests = 0
    public var tokens = TokenCounts()
    /// Sum of the recorded costs; nil when no response here has one.
    public var cost: Double?
    /// Responses without a recorded cost (their harness doesn't write it).
    public var unpricedRequests = 0
    /// By harness and model, most tokens first.
    public var parts: [UsagePart] = []

    public init() {}

    mutating func add(_ record: UsageRecord) {
        requests += 1
        tokens = tokens + record.tokens
        if let recorded = record.cost {
            cost = (cost ?? 0) + recorded
        } else {
            unpricedRequests += 1
        }
        if let index = parts.firstIndex(where: { $0.harness == record.harness && $0.model == record.model }) {
            parts[index].add(record)
        } else {
            var part = UsagePart(harness: record.harness, model: record.model)
            part.add(record)
            parts.append(part)
        }
    }

    mutating func sortParts() {
        parts.sort { ($0.tokens.total, $1.model) > ($1.tokens.total, $0.model) }
    }
}

public struct UsagePart: Sendable, Hashable, Identifiable {
    public var id: String { "\(harness.rawValue)|\(model)" }
    public let harness: HarnessID
    public let model: String
    public var requests = 0
    public var tokens = TokenCounts()
    public var cost: Double?

    mutating func add(_ record: UsageRecord) {
        requests += 1
        tokens = tokens + record.tokens
        if let recorded = record.cost { cost = (cost ?? 0) + recorded }
    }
}

/// Usage per calendar day and subscription: rows are days, columns subscriptions.
public struct DailyUsageReport: Sendable {
    /// Every day from the first to the last requested one, newest first.
    public let days: [Date]
    /// Columns, most tokens first.
    public let subscriptions: [Subscription]
    public let grandTotal: UsageTotal

    private let cells: [Date: [String: UsageTotal]]
    private let dayTotals: [Date: UsageTotal]
    private let subscriptionTotals: [String: UsageTotal]

    /// Days run from the day of `from` to the day of `to` in `calendar`'s time zone.
    /// Records outside that range are left out.
    public init(records: [UsageRecord], from: Date, to: Date, calendar: Calendar = .current) {
        let first = calendar.startOfDay(for: from)
        let last = calendar.startOfDay(for: to)
        var cells: [Date: [String: UsageTotal]] = [:]
        var dayTotals: [Date: UsageTotal] = [:]
        var subscriptionTotals: [String: UsageTotal] = [:]
        var subscriptions: [String: Subscription] = [:]
        var grand = UsageTotal()
        for record in records {
            let day = calendar.startOfDay(for: record.time)
            guard day >= first, day <= last else { continue }
            let subscription = record.subscription
            subscriptions[subscription.id] = subscription
            cells[day, default: [:]][subscription.id, default: UsageTotal()].add(record)
            dayTotals[day, default: UsageTotal()].add(record)
            subscriptionTotals[subscription.id, default: UsageTotal()].add(record)
            grand.add(record)
        }
        for day in cells.keys {
            for id in cells[day]!.keys { cells[day]![id]!.sortParts() }
            dayTotals[day]!.sortParts()
        }
        for id in subscriptionTotals.keys { subscriptionTotals[id]!.sortParts() }
        grand.sortParts()

        var days: [Date] = []
        var day = last
        while day >= first {
            days.append(day)
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        self.days = days
        self.cells = cells
        self.dayTotals = dayTotals
        self.subscriptionTotals = subscriptionTotals
        self.grandTotal = grand
        self.subscriptions = subscriptions.values.sorted {
            let a = subscriptionTotals[$0.id]?.tokens.total ?? 0, b = subscriptionTotals[$1.id]?.tokens.total ?? 0
            return a != b ? a > b : $0 < $1
        }
    }

    public func cell(_ day: Date, _ subscription: Subscription) -> UsageTotal? { cells[day]?[subscription.id] }
    public func total(ofDay day: Date) -> UsageTotal? { dayTotals[day] }
    public func total(of subscription: Subscription) -> UsageTotal? { subscriptionTotals[subscription.id] }
    public var isEmpty: Bool { grandTotal.requests == 0 }
}
