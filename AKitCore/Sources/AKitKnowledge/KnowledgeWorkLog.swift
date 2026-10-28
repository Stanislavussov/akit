import AKitFoundation
import Foundation

/// The work log of a base (docs/design/worklog.md): short lines of what the user did, each with the
/// time it was written and a kind, one Markdown file per day in `worklog/` beside `notebook/`
/// (W1, W2):
///
/// ```
/// - 09:14 #agent Review of COL-123 with Pi
/// - 09:40 #bug Login fails in Safari https://…
/// - 10:05 #break
/// ```
///
/// An entry may have a summary of a few sentences (Auto-Fill writes one; Edit… changes it) on the
/// next line, indented as a quote: `  > Found that the outbox wrote the event twice; …` (W9).
///
/// An entry lasts until the next one of its day; the last one of today lasts until now (W4). Other
/// lines (a note typed in Obsidian) are kept as they are. Search, lint and the agent card leave the
/// log out, as the notebook (NB9).
public struct KnowledgeWorkLog: Sendable {
    public typealias Failure = KnowledgeBase.Failure

    public static let folderName = "worklog"

    /// A preset kind (W3). Any other `#tag` works too; it shows with its tag as the title.
    public struct Kind: Sendable, Equatable, Identifiable, Hashable {
        public let id: String
        public let title: String
        /// An SF Symbol for the app.
        public let symbol: String
        /// false for a break: its time is not work.
        public let isWork: Bool

        public init(id: String, title: String, symbol: String, isWork: Bool = true) {
            (self.id, self.title, self.symbol, self.isWork) = (id, title, symbol, isWork)
        }
    }

    public static let presets: [Kind] = [
        Kind(id: "agent", title: "Agent", symbol: "sparkles"),
        Kind(id: "task", title: "Task", symbol: "checkmark.circle"),
        Kind(id: "bug", title: "Bug", symbol: "ladybug"),
        Kind(id: "research", title: "Research", symbol: "magnifyingglass"),
        Kind(id: "reply", title: "Reply", symbol: "arrowshape.turn.up.left"),
        Kind(id: "meeting", title: "Meeting", symbol: "person.2"),
        Kind(id: "review", title: "Review", symbol: "eye"),
        Kind(id: "break", title: "Break", symbol: "cup.and.saucer", isWork: false),
    ]

    /// The preset of a tag, or a plain kind named by the tag.
    public static func kind(_ id: String) -> Kind {
        presets.first { $0.id == id } ?? Kind(id: id, title: id, symbol: "tag")
    }

    /// One line of the log.
    public struct Entry: Sendable, Equatable, Hashable, Codable {
        /// The line's number in its day's file (0-based), to find it again for an edit.
        public var line: Int
        /// `HH:mm`, local time.
        public var time: String
        /// The tag without `#`, lowercased; nil for an entry without one.
        public var kind: String?
        public var text: String
        /// A few sentences of what was done, on the quoted line under the entry (W9).
        public var summary: String?

        public init(line: Int = 0, time: String, kind: String?, text: String, summary: String? = nil) {
            (self.line, self.time, self.kind, self.text, self.summary) = (line, time, kind, text, summary)
        }

        /// The entry's lines in the file: the entry, then its summary, one quoted line per line of
        /// it (an empty one as `  >`, so paragraphs typed in Obsidian or Edit… stay).
        public var markdownLines: [String] {
            [markdown] + (summary?.split(separator: "\n", omittingEmptySubsequences: false).map { $0.isEmpty ? "  >" : "  > \($0)" } ?? [])
        }

        /// The Markdown line: `- 09:14 #bug text`.
        public var markdown: String {
            (["- \(time)"] + [kind.map { "#\($0)" }, text.isEmpty ? nil : text].compactMap { $0 }).joined(separator: " ")
        }

        /// Minutes since midnight.
        public var minute: Int { KnowledgeWorkLog.minute(time) ?? 0 }
    }

    /// A day: its entries in time order, with how long each lasted (W4).
    public struct Day: Sendable, Equatable {
        public var date: String
        public var entries: [Entry]
        /// Per entry, in minutes; nil for the last entry of a past day (its end is unknown).
        public var minutes: [Int?]

        /// Minutes per kind ("" for entries without a kind), largest first; breaks included.
        public var totals: [(kind: String, minutes: Int)] {
            var sums: [String: Int] = [:]
            for (entry, minutes) in zip(entries, minutes) { sums[entry.kind ?? "", default: 0] += minutes ?? 0 }
            return sums.filter { $0.value > 0 }.map { ($0.key, $0.value) }
                .sorted { $0.minutes != $1.minutes ? $0.minutes > $1.minutes : $0.kind < $1.kind }
        }

        /// Minutes of work: every kind but a break.
        public var workMinutes: Int {
            zip(entries, minutes).reduce(0) { sum, pair in
                pair.0.kind.map { KnowledgeWorkLog.kind($0).isWork } == false ? sum : sum + (pair.1 ?? 0)
            }
        }

        public static func == (a: Day, b: Day) -> Bool { a.date == b.date && a.entries == b.entries && a.minutes == b.minutes }
    }

    public let base: KnowledgeBase

    public init(base: KnowledgeBase) { self.base = base }

    public var folder: URL { base.root.appending(path: Self.folderName, directoryHint: .isDirectory) }
    /// A day's file: `worklog/2026-10-28.md`.
    public func file(_ date: String) -> URL { folder.appending(path: date + ".md") }
    public func path(_ date: String) -> String { "\(Self.folderName)/\(date).md" }

    // MARK: - Reading

    /// The days with a file, newest first.
    public func days() -> [String] {
        FileWalk.children(of: folder)
            .filter { $0.pathExtension == "md" && FileWalk.isRegularFile($0) }
            .map { $0.deletingPathExtension().lastPathComponent }
            .filter(Self.isDate)
            .sorted(by: >)
    }

    /// A day's text; "" when the day has no file.
    public func text(_ date: String) throws(Failure) -> String {
        let file = file(date)
        guard FileWalk.isRegularFile(file) else { return "" }
        do { return String(decoding: try Data(contentsOf: file), as: UTF8.self) } catch {
            throw Failure(message: "Couldn't read \(path(date)): \(error.localizedDescription)")
        }
    }

    /// A day with its entries and their minutes. `now` ends the last entry when the day is today.
    public func day(_ date: String, now: Date = .now) throws(Failure) -> Day {
        Self.day(date, text: try text(date), now: now)
    }

    // MARK: - Writing

    /// Adds an entry at `date`'s time to its day, in time order. The text may start with `#tag` when
    /// `kind` is nil. Returns the entry, the base-relative path and the file's new hash. No commit:
    /// the app queues it (U2), `add(…env:)` commits at once.
    public func add(_ text: String, kind: String?, at date: Date) throws(Failure) -> (entry: Entry, path: String, hash: String) {
        let (day, time) = Self.stamp(date)
        return try add(text, kind: kind, day: day, time: time)
    }

    /// The same at a given day and `HH:mm`.
    public func add(_ text: String, kind: String?, day: String, time: String, summary: String? = nil) throws(Failure)
        -> (entry: Entry, path: String, hash: String) {
        guard Self.isDate(day) else { throw Failure(message: "“\(day)” is no day: use YYYY-MM-DD.") }
        guard let minute = Self.minute(time) else { throw Failure(message: "“\(time)” is no time: use HH:MM.") }
        var entry = try Self.checkedEntry(text, kind: kind, time: Self.time(minute), summary: summary)
        let old = try self.text(day)
        let (new, line) = Self.inserting(entry, into: old)
        entry.line = line
        let hash = try write(day, old: old, new: new)
        return (entry, path(day), hash)
    }

    /// `akit worklog add`: the entry, committed at once.
    @discardableResult
    public func add(_ text: String, kind: String?, at date: Date, env: HarnessEnvironment) async throws(Failure) -> (entry: Entry, path: String) {
        let added = try add(text, kind: kind, at: date)
        try await commit([added.path], "Work log: \(added.entry.time) \(added.entry.kind.map { "#\($0)" } ?? "")".trimmingCharacters(in: .whitespaces), env)
        return (added.entry, added.path)
    }

    /// Edit…: the entry `old` (its line must still read the same) gets a new time, kind or text and
    /// moves to its place in time order. Returns the path and the file's new hash.
    public func replace(_ old: Entry, on date: String, with new: Entry) throws(Failure) -> (path: String, hash: String) {
        guard let newMinute = Self.minute(new.time) else { throw Failure(message: "“\(new.time)” is no time: use HH:MM.") }
        let checked = try Self.checkedEntry(new.text, kind: new.kind, time: Self.time(newMinute), takeTag: false, summary: new.summary)
        let text = try self.text(date)
        let without = try Self.removing(old, from: text, path: path(date))
        let (result, _) = Self.inserting(checked, into: without)
        return (path(date), try write(date, old: text, new: result))
    }

    /// Delete: the entry's line leaves its day's file (git keeps it). The file stays, empty or not.
    public func remove(_ entry: Entry, on date: String) throws(Failure) -> (path: String, hash: String) {
        let text = try self.text(date)
        return (path(date), try write(date, old: text, new: try Self.removing(entry, from: text, path: path(date))))
    }

    private func write(_ date: String, old: String, new: String) throws(Failure) -> String {
        let file = file(date), bytes = Data(new.utf8)
        do {
            if FileWalk.isRegularFile(file) {
                let outcome = try KnowledgeWrite.saveChecked(bytes, to: file, expectedHash: KnowledgeWrite.hash(Data(old.utf8)))
                guard case .saved(let hash) = outcome else {
                    throw Failure(message: "\(path(date)) changed while AKit wrote it; nothing was written. Try again.")
                }
                return hash
            }
            guard old.isEmpty else { throw Failure(message: "\(path(date)) is gone; nothing was written.") }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try bytes.write(to: file, options: .withoutOverwriting)
            return KnowledgeWrite.hash(bytes)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure(message: "Couldn't write \(path(date)): \(error.localizedDescription)")
        }
    }

    private func commit(_ paths: [String], _ message: String, _ env: HarnessEnvironment) async throws(Failure) {
        do { try await KnowledgeGit(base: base.root, env: env).commit(paths: paths, message: message) } catch {
            throw Failure(message: "Saved, but not committed: \(error.message)")
        }
    }

    // MARK: - Pure

    /// The day and time of a moment, local: (`2026-10-28`, `09:14`).
    public static func stamp(_ date: Date, calendar: Calendar = .current) -> (day: String, time: String) {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return (String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0),
                String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0))
    }

    public static func isDate(_ text: String) -> Bool {
        text.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil && dayFormatter.date(from: text) != nil
    }

    /// `H:MM` or `HH:MM` → minutes since midnight.
    public static func minute(_ time: String) -> Int? {
        guard let match = time.wholeMatch(of: /(\d{1,2}):(\d{2})/), let hour = Int(match.1), let minute = Int(match.2),
              hour < 24, minute < 60 else { return nil }
        return hour * 60 + minute
    }

    /// Minutes since midnight → `HH:MM`.
    public static func time(_ minute: Int) -> String { String(format: "%02d:%02d", minute / 60, minute % 60) }

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }()

    /// A kind as typed (`Bug`, `#bug`) → `bug`; nil for an empty one; throws for one that can't be a tag.
    public static func checkedKind(_ kind: String?) throws(Failure) -> String? {
        guard var kind = kind?.trimmingCharacters(in: .whitespaces), !kind.isEmpty else { return nil }
        if kind.hasPrefix("#") { kind.removeFirst() }
        kind = kind.lowercased()
        guard kind.wholeMatch(of: /[\p{L}\p{N}][\p{L}\p{N}_-]{0,39}/) != nil else {
            throw Failure(message: "“\(kind)” can't be a kind: use letters, digits, - and _ (like bug or code-review).")
        }
        return kind
    }

    /// The text on one line, a leading `#tag` taken as the kind when none is given.
    /// `takeTag` false (Edit… with Kind None): a leading `#tag` stays text.
    static func checkedEntry(_ text: String, kind: String?, time: String, takeTag: Bool = true, summary: String? = nil) throws(Failure) -> Entry {
        var text = oneLine(text)
        var kind = try checkedKind(kind)
        if kind == nil, takeTag, let match = text.prefixMatch(of: /#([\p{L}\p{N}][\p{L}\p{N}_-]*)(\s+|$)/) {
            kind = try checkedKind(String(match.1))
            text = String(text[match.range.upperBound...])
        }
        guard !text.isEmpty || kind != nil else { throw Failure(message: "Write what you did, or choose a kind.") }
        let summary = summary.flatMap(checkedSummary)
        return Entry(time: time, kind: kind, text: text, summary: summary)
    }

    /// A summary as kept: its lines trimmed, blank lines at its ends dropped, at most `maxSummary`
    /// characters; nil when nothing is left.
    static func checkedSummary(_ text: String) -> String? {
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        while lines.first == "" { lines.removeFirst() }
        while lines.last == "" { lines.removeLast() }
        let joined = String(lines.joined(separator: "\n").prefix(maxSummary)).trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    /// A summary has at most this many characters.
    public static let maxSummary = 1200

    /// Every line break (CR, LF, U+2028…) becomes a space: an entry and its summary are one line each.
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    /// A summary line under an entry (`  > text`): its text, or nil.
    static func summaryLine(_ line: Substring) -> String? {
        guard let match = line.wholeMatch(of: /[ \t]+>\s?(.*)/) else { return nil }
        return String(match.1).trimmingCharacters(in: .whitespaces)
    }

    /// How many lines the entry on `line` takes: itself and its summary lines.
    static func span(_ line: Int, in lines: [Substring]) -> Int {
        var end = line + 1
        while end < lines.count, summaryLine(lines[end]) != nil { end += 1 }
        return end - line
    }

    /// The entry a line holds (`- 09:14 #bug text`, `*` too), or nil.
    public static func entry(_ line: Substring, number: Int) -> Entry? {
        guard let match = line.wholeMatch(of: /[-*]\s+(\d{1,2}:\d{2})(?:\s+#([\p{L}\p{N}][\p{L}\p{N}_-]*))?(?:\s+(.*))?\s*/),
              let minute = minute(String(match.1)) else { return nil }
        return Entry(line: number, time: time(minute), kind: match.2.map { $0.lowercased() },
                     text: match.3.map { $0.trimmingCharacters(in: .whitespaces) } ?? "")
    }

    /// The lines of a text; CRLF (one Character in Swift) and other line breaks split too. A
    /// write joins them with LF.
    static func lines(_ text: String) -> [Substring] {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    }

    public static func entries(in text: String) -> [Entry] {
        let lines = lines(text)
        return lines.enumerated().compactMap { number, line in
            guard var entry = entry(line, number: number) else { return nil }
            let parts = lines[(number + 1)..<(number + span(number, in: lines))].compactMap(summaryLine)
            entry.summary = checkedSummary(parts.joined(separator: "\n"))
            return entry
        }
    }

    /// A day from its file's text: entries in time order (the file's order for the same minute),
    /// each lasting until the next; the last one until `now` when the day is today and `now` is later.
    public static func day(_ date: String, text: String, now: Date = .now) -> Day {
        let entries = entries(in: text).enumerated().sorted { ($0.element.minute, $0.offset) < ($1.element.minute, $1.offset) }.map(\.element)
        let (today, nowTime) = stamp(now)
        var minutes: [Int?] = []
        for (index, entry) in entries.enumerated() {
            if index + 1 < entries.count {
                minutes.append(entries[index + 1].minute - entry.minute)
            } else if date == today, let now = minute(nowTime), now >= entry.minute {
                minutes.append(now - entry.minute)
            } else {
                minutes.append(nil)
            }
        }
        return Day(date: date, entries: entries, minutes: minutes)
    }

    /// The text with the entry after the last entry at or before its time (before the first entry
    /// otherwise, or at the end of a text without entries), and its line number.
    static func inserting(_ entry: Entry, into text: String) -> (text: String, line: Int) {
        var lines = Self.lines(text).map(String.init)
        if lines.last == "" { lines.removeLast() }
        let present = entries(in: text)
        let at: Int
        if let last = present.last(where: { $0.minute <= entry.minute }) {
            at = last.line + span(last.line, in: Self.lines(text))
        } else if let first = present.first {
            at = first.line
        } else {
            at = lines.count
        }
        lines.insert(contentsOf: entry.markdownLines, at: at)
        return (lines.joined(separator: "\n") + "\n", at)
    }

    /// The text without the entry's line; throws when that line no longer holds the entry.
    static func removing(_ entry: Entry, from text: String, path: String) throws(Failure) -> String {
        var lines = Self.lines(text)
        guard entry.line < lines.count, var found = Self.entries(in: text).first(where: { $0.line == entry.line }) else {
            throw Failure(message: "\(path) changed: the entry \(entry.time) isn't on its line any more. Look again.")
        }
        found.line = entry.line
        guard found == entry else { throw Failure(message: "\(path) changed: the entry \(entry.time) isn't on its line any more. Look again.") }
        lines.removeSubrange(entry.line..<(entry.line + span(entry.line, in: lines)))
        var result = lines.joined(separator: "\n")
        if !result.isEmpty, !result.hasSuffix("\n") { result += "\n" }
        return result == "\n" ? "" : result
    }

    /// `90` → `1 h 30 min`, `45` → `45 min`.
    public static func duration(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min" : minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }
}

extension KnowledgeWorkLog {
    /// A day as a date at its start, local; nil for no day.
    public static func date(_ day: String) -> Date? {
        guard isDate(day) else { return nil }
        return dayFormatter.date(from: day)
    }
}
