import Foundation

/// The cost report (M21): what OpenRouter charged, by day, week or month, in a date range,
/// optionally for one model. Each meeting counts in the period of its start, with the cost it
/// stores (the sum of what OpenRouter reported for its calls); each question (M24) in the period
/// it was asked.
public enum CostReport {
    public enum Grouping: String, CaseIterable, Sendable, Identifiable {
        case day, week, month
        public var id: Self { self }
        public var title: String { rawValue.capitalized }
        var component: Calendar.Component {
            switch self {
            case .day: .day
            case .week: .weekOfYear
            case .month: .month
            }
        }
    }

    public struct Row: Identifiable, Equatable, Sendable {
        /// The period's first moment.
        public var start: Date
        public var meetings: Int
        public var seconds: TimeInterval
        public var cost: Double
        /// M24: questions asked in the period; their cost is in `cost`.
        public var questions: Int = 0
        public var id: Date { start }

        /// USD per recorded hour; nil without recorded time.
        public var costPerHour: Double? { seconds > 0 ? cost / (seconds / 3600) : nil }
    }

    public struct Totals: Equatable, Sendable {
        public var meetings: Int
        public var questions: Int = 0
        public var seconds: TimeInterval
        public var cost: Double
        /// Calendar days in the range, for the average per day.
        public var days: Int
        public var costPerHour: Double? { seconds > 0 ? cost / (seconds / 3600) : nil }
        public var costPerDay: Double { days > 0 ? cost / Double(days) : 0 }
    }

    /// One row per period from the period of `from` to the period of `to`, empty periods
    /// included (zero), oldest first. `model` nil is every model.
    public static func rows(_ meetings: [Meeting], asks: [AskLog.Entry] = [], grouping: Grouping, from: Date, to: Date, model: String? = nil,
                            calendar: Calendar = .current) -> [Row] {
        let start = calendar.startOfDay(for: min(from, to))
        let end = calendar.startOfDay(for: max(from, to))
        guard let first = calendar.dateInterval(of: grouping.component, for: start)?.start else { return [] }
        var rows: [Row] = []
        var index: [Date: Int] = [:]
        var period = first
        while period <= end {
            index[period] = rows.count
            rows.append(Row(start: period, meetings: 0, seconds: 0, cost: 0))
            guard let next = calendar.date(byAdding: grouping.component, value: 1, to: period), rows.count < 5_000 else { break }
            period = next
        }
        for meeting in filtered(meetings, from: start, to: end, model: model, calendar: calendar) {
            guard let key = calendar.dateInterval(of: grouping.component, for: meeting.started)?.start, let i = index[key] else { continue }
            rows[i].meetings += 1
            rows[i].seconds += meeting.duration
            rows[i].cost += meeting.costUSD
        }
        for ask in filtered(asks, from: start, to: end, model: model, calendar: calendar) {
            guard let key = calendar.dateInterval(of: grouping.component, for: ask.date)?.start, let i = index[key] else { continue }
            rows[i].questions += 1
            rows[i].cost += ask.costUSD
        }
        return rows
    }

    public static func filtered(_ asks: [AskLog.Entry], from: Date, to: Date, model: String? = nil, calendar: Calendar = .current) -> [AskLog.Entry] {
        let start = calendar.startOfDay(for: min(from, to))
        guard let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: max(from, to))) else { return [] }
        return asks.filter { $0.date >= start && $0.date < end && (model == nil || $0.model == model) }
    }

    /// The meetings that started from the day of `from` through the day of `to`.
    public static func filtered(_ meetings: [Meeting], from: Date, to: Date, model: String? = nil, calendar: Calendar = .current) -> [Meeting] {
        let start = calendar.startOfDay(for: min(from, to))
        guard let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: max(from, to))) else { return [] }
        return meetings.filter { $0.started >= start && $0.started < end && (model == nil || $0.model == model) }
    }

    public static func totals(_ meetings: [Meeting], asks: [AskLog.Entry] = [], from: Date, to: Date, model: String? = nil, calendar: Calendar = .current) -> Totals {
        let chosen = filtered(meetings, from: from, to: to, model: model, calendar: calendar)
        let questions = filtered(asks, from: from, to: to, model: model, calendar: calendar)
        let days = (calendar.dateComponents([.day], from: calendar.startOfDay(for: min(from, to)), to: calendar.startOfDay(for: max(from, to))).day ?? 0) + 1
        return Totals(meetings: chosen.count, questions: questions.count, seconds: chosen.reduce(0) { $0 + $1.duration },
                      cost: chosen.reduce(0) { $0 + $1.costUSD } + questions.reduce(0) { $0 + $1.costUSD }, days: days)
    }

    /// The models that wrote a transcript or answered a question, for the filter.
    public static func models(_ meetings: [Meeting], asks: [AskLog.Entry] = []) -> [String] {
        Array(Set(meetings.compactMap(\.model) + asks.map(\.model))).sorted()
    }

    /// A period's label: `Mon 3. 11.`, `Week of 3. 11.`, `November 2026`.
    public static func label(_ row: Row, grouping: Grouping) -> String {
        switch grouping {
        case .day: row.start.formatted(.dateTime.weekday(.abbreviated).day().month(.defaultDigits))
        case .week: "Week of " + row.start.formatted(.dateTime.day().month(.defaultDigits))
        case .month: row.start.formatted(.dateTime.month(.wide).year())
        }
    }

    /// The rows as CSV, for a spreadsheet: period start (ISO day), meetings, hours, USD, USD/hour,
    /// questions.
    public static func csv(_ rows: [Row], calendar: Calendar = .current) -> String {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.calendar = calendar
        day.dateFormat = "yyyy-MM-dd"
        var lines = ["period,meetings,hours,usd,usd_per_hour,questions"]
        for row in rows {
            lines.append([day.string(from: row.start), "\(row.meetings)", String(format: "%.2f", row.seconds / 3600),
                          String(format: "%.4f", row.cost), row.costPerHour.map { String(format: "%.4f", $0) } ?? "", "\(row.questions)"].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
