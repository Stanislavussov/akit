import Foundation

/// A window of whole local days, from the start of `first` to the end of `last` (`akit stats --from/--to`,
/// Insights → Date Range…). Unlike "the last N days", it can end in the past: calls after its last day don't count.
public struct DayRange: Hashable, Sendable {
    /// The start of the first day.
    public let first: Date
    /// The start of the last day; never before `first`.
    public let last: Date

    /// Any times within the two days; swapped when `last` is the earlier one.
    public init(first: Date, last: Date, calendar: Calendar = .current) {
        let a = calendar.startOfDay(for: first), b = calendar.startOfDay(for: last)
        self.first = min(a, b)
        self.last = max(a, b)
    }

    /// Days in the range, both ends included.
    public func days(calendar: Calendar = .current) -> Int {
        (calendar.dateComponents([.day], from: first, to: last).day ?? 0) + 1
    }

    /// From the start of the first day to the end of the last one, or to `now` when that is earlier.
    public func bounds(now: Date, calendar: Calendar = .current) -> (from: Date, to: Date) {
        let end = (calendar.date(byAdding: .day, value: 1, to: last) ?? last).addingTimeInterval(-0.001)
        return (first, min(end, max(now, first)))
    }

    /// The two days as `yyyy-MM-dd`, as the JSON and the text show them.
    public func label(calendar: Calendar = .current) -> StatsReport.Window.Days {
        .init(first: Self.day(first, calendar: calendar), last: Self.day(last, calendar: calendar))
    }

    /// `--from DAY [--to DAY]`: `to` is today when nil. Throws a message for a day that isn't `YYYY-MM-DD`,
    /// or a first day after today.
    public static func parse(from: String, to: String?, now: Date = Date(), calendar: Calendar = .current) throws -> DayRange {
        guard let start = date(from, calendar: calendar) else { throw ParseError(message: "--from is a day: YYYY-MM-DD.") }
        let end: Date
        if let to {
            guard let parsed = date(to, calendar: calendar) else { throw ParseError(message: "--to is a day: YYYY-MM-DD.") }
            end = parsed
        } else {
            end = now
        }
        guard start <= end else { throw ParseError(message: "--from is after \(to == nil ? "today" : "--to").") }
        return DayRange(first: start, last: end, calendar: calendar)
    }

    public struct ParseError: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    static func date(_ text: String, calendar: Calendar) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter.date(from: text.trimmingCharacters(in: .whitespaces))
    }

    static func day(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
