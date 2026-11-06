import AKitFoundation
import Foundation

/// The work norm and the hours report (docs/design/worklog.md, W12, W13): how many hours a work
/// day should have (7.5 by default, set for the base in `worklog/settings.yaml`, for one day by a
/// `norm: 8 h` line in its file), and per day of a week or a month how much is filled and how much
/// is missing, per kind and per ticket, as a table, CSV or JSON.
extension KnowledgeWorkLog {
    /// The base's work log settings: `worklog/settings.yaml`.
    public static let settingsName = "settings.yaml"
    /// Hours of a work day when the base sets none.
    public static let defaultHours = 7.5

    public var settingsFile: URL { folder.appending(path: Self.settingsName) }
    public var settingsPath: String { "\(Self.folderName)/\(Self.settingsName)" }

    /// The norm of a work day (Monday to Friday), in hours: `hours: 7.5` in the settings file.
    public func hours() -> Double {
        guard let data = try? Data(contentsOf: settingsFile) else { return Self.defaultHours }
        for line in Self.lines(String(decoding: data, as: UTF8.self)) {
            if let match = line.wholeMatch(of: /\s*hours:\s*(\d{1,2}(?:[.,]\d{1,2})?)\s*/),
               let hours = Double(match.1.replacingOccurrences(of: ",", with: ".")), hours <= 24 {
                return hours
            }
        }
        return Self.defaultHours
    }

    /// Sets the norm of a work day; returns the path to commit. Other lines of the file stay.
    @discardableResult
    public func setHours(_ hours: Double) throws(Failure) -> String {
        guard hours >= 0, hours <= 24 else { throw Failure(message: "A work day has 0 to 24 hours.") }
        let old = (try? Data(contentsOf: settingsFile)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        var lines = Self.lines(old).map(String.init).filter { $0.wholeMatch(of: /\s*hours:.*/) == nil }
        if lines.last == "" { lines.removeLast() }
        lines.insert("hours: \(Self.hoursText(hours))", at: 0)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: settingsFile, options: .atomic)
        } catch {
            throw Failure(message: "Couldn't write \(settingsPath): \(error.localizedDescription)")
        }
        return settingsPath
    }

    /// One day's own norm (`norm: 8 h` at the top of its file; nil removes it, back to the
    /// default). Returns the path and the file's new hash.
    public func setNorm(_ hours: Double?, on date: String) throws(Failure) -> (path: String, hash: String) {
        guard Self.isDate(date) else { throw Failure(message: "“\(date)” is no day: use YYYY-MM-DD.") }
        if let hours, !(0...24).contains(hours) { throw Failure(message: "A work day has 0 to 24 hours.") }
        let old = try text(date)
        var lines = Self.lines(old).map(String.init).filter { Self.norm(in: $0) == nil }
        if lines.last == "" { lines.removeLast() }
        if let hours { lines.insert("norm: \(Self.hoursText(hours)) h", at: 0) }
        let new = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        return (path(date), try write(date, old: old, new: new))
    }

    /// `7.5` → `7.5`, `8` → `8`.
    public static func hoursText(_ hours: Double) -> String {
        hours == hours.rounded() ? String(Int(hours)) : String(format: "%g", (hours * 100).rounded() / 100)
    }

    /// The norm of a day in minutes: its own line, else the base's hours on Monday to Friday and
    /// nothing on a weekend.
    public static func norm(of day: Day, hours: Double, calendar: Calendar = .current) -> Int {
        if let norm = day.norm { return norm }
        guard let date = date(day.date) else { return 0 }
        return calendar.isDateInWeekend(date) ? 0 : Int((hours * 60).rounded())
    }

    // MARK: - Report

    public struct Report: Sendable, Equatable {
        public struct Row: Sendable, Equatable {
            public var date: String
            public var norm: Int
            public var work: Int
            /// Minutes of breaks (not work).
            public var pause: Int
            /// Minutes per kind ("" for entries without one), breaks included.
            public var kinds: [String: Int]
            /// Minutes per ticket ("" for work without one); breaks left out.
            public var tickets: [String: Int]
            /// The last plain entry of a past day: its length is unknown, so it isn't counted.
            public var open: Bool
            public var missing: Int { max(0, norm - work) }
        }

        public var from: String
        public var to: String
        public var hours: Double
        public var rows: [Row]

        public var norm: Int { rows.reduce(0) { $0 + $1.norm } }
        public var work: Int { rows.reduce(0) { $0 + $1.work } }
        public var missing: Int { rows.reduce(0) { $0 + $1.missing } }
        public var kinds: [(kind: String, minutes: Int)] { Self.sorted(rows.map(\.kinds)) }
        public var tickets: [(ticket: String, minutes: Int)] { Self.sorted(rows.map(\.tickets)).map { ($0.kind, $0.minutes) } }

        static func sorted(_ parts: [[String: Int]]) -> [(kind: String, minutes: Int)] {
            var sums: [String: Int] = [:]
            for part in parts { for (key, value) in part { sums[key, default: 0] += value } }
            return sums.filter { $0.value > 0 }.map { ($0.key, $0.value) }
                .sorted { $0.minutes != $1.minutes ? $0.minutes > $1.minutes : $0.kind < $1.kind }
        }

        /// A day of the table: `Row` from a parsed day.
        public static func row(_ day: Day, hours: Double, calendar: Calendar = .current) -> Row {
            var kinds: [String: Int] = [:], tickets: [String: Int] = [:]
            var work = 0, pause = 0, open = false
            for (entry, minutes) in zip(day.entries, day.minutes) {
                guard let minutes else { open = true; continue }
                kinds[entry.kind ?? "", default: 0] += minutes
                if entry.kind.map({ KnowledgeWorkLog.kind($0).isWork }) == false {
                    pause += minutes
                } else {
                    work += minutes
                    tickets[entry.ticket ?? "", default: 0] += minutes
                }
            }
            return Row(date: day.date, norm: KnowledgeWorkLog.norm(of: day, hours: hours, calendar: calendar), work: work,
                       pause: pause, kinds: kinds.filter { $0.value > 0 }, tickets: tickets.filter { $0.value > 0 }, open: open)
        }

        /// The days as CSV, one row per day and a total: hours with two decimals.
        public var daysCSV: String {
            let kindIDs = kinds.map(\.kind)
            var lines = [(["date", "weekday", "norm_h", "work_h", "missing_h", "break_h"]
                          + kindIDs.map { "kind_" + ($0.isEmpty ? "none" : $0) + "_h" }).joined(separator: ",")]
            for row in rows {
                let weekday = KnowledgeWorkLog.date(row.date).map { Self.weekday($0) } ?? ""
                lines.append(([row.date, weekday, Self.h(row.norm), Self.h(row.work), Self.h(row.missing), Self.h(row.pause)]
                              + kindIDs.map { Self.h(row.kinds[$0] ?? 0) }).joined(separator: ","))
            }
            lines.append((["total", "", Self.h(norm), Self.h(work), Self.h(missing), Self.h(rows.reduce(0) { $0 + $1.pause })]
                          + kinds.map { Self.h($0.minutes) }).joined(separator: ","))
            return lines.joined(separator: "\n") + "\n"
        }

        /// Minutes → hours with two decimals: `90` → `1.50`.
        public static func h(_ minutes: Int) -> String { String(format: "%.2f", Double(minutes) / 60) }

        static func weekday(_ date: Date) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEE"
            return formatter.string(from: date)
        }
    }

    /// The report of the days `from`…`to` (both included): every day of the range, with a file
    /// or not, so a missing work day shows.
    public func report(from: String, to: String, now: Date = .now, calendar: Calendar = .current) throws(Failure) -> Report {
        guard let start = Self.date(from), let end = Self.date(to) else { throw Failure(message: "Use days as YYYY-MM-DD.") }
        guard start <= end else { throw Failure(message: "The report's first day \(from) is after its last day \(to).") }
        let hours = hours()
        var rows: [Report.Row] = []
        var day = start
        while day <= end, rows.count < 400 {
            let date = Self.stamp(day, calendar: calendar).day
            rows.append(Report.row(try self.day(date, now: now), hours: hours, calendar: calendar))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return Report(from: from, to: to, hours: hours, rows: rows)
    }

    /// The days of the week (Monday first) or month that holds `date`.
    public static func range(_ period: Period, containing date: Date, calendar: Calendar = .current) -> (from: String, to: String) {
        var calendar = calendar
        calendar.firstWeekday = 2
        let component: Calendar.Component = period == .week ? .weekOfYear : .month
        guard let interval = calendar.dateInterval(of: component, for: date),
              let last = calendar.date(byAdding: .day, value: -1, to: interval.end) else {
            let day = stamp(date, calendar: calendar).day
            return (day, day)
        }
        return (stamp(interval.start, calendar: calendar).day, stamp(last, calendar: calendar).day)
    }

    public enum Period: String, Sendable, CaseIterable { case week = "Week", month = "Month" }
}
