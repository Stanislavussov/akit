import AKitFoundation
import AKitHarnesses
import AKitKnowledge
import AKitLab
import AKitModel
import AKitSessions
import Foundation

/// `akit worklog`: the work log of the knowledge base (docs/design/worklog.md), what the Work Log
/// screen shows. Agents run `show` and `kinds`, and `add` only when the user asked in the session.
extension AKitCLI {
    static let worklogUsage = """
    akit worklog: what you did, one short line at a time (docs/design/worklog.md). Each entry gets
    the day and time it was added; one Markdown file per day in the base's worklog/ folder, the Work
    Log screen in AKit. An entry lasts until the next one; Break ends work.

      akit worklog add TEXT [--kind KIND] [--at HH:MM] [--json] [--base PATH|WORLD]
                                        Only when the user asked. One entry, today, now (--at: an
                                        earlier time today). TEXT may start with #KIND. Committed at
                                        once. --json: {base, day, path, entry: {time, end, kind, text}}
      akit worklog add TEXT --at HH:MM --to HH:MM [--day DAY] [--kind KIND] [--json]
                                        Only when the user asked. A calendar block (a meeting, lunch):
                                        it holds its own time, any day (default today). Written as
                                        "- 09:00-09:30 #meeting Standup".
      akit worklog report [week|month|last-week|last-month|DAY|DAY..DAY] [--csv] [--json]
                                        Hours per day of the week (default) or month: norm, work,
                                        missing, break, per kind and per ticket (COL-123). The last
                                        entry of a past day without a block after it has no length
                                        and isn't counted. --csv: one row per day and a total.
                                        --json: {from, to, hours, norm_minutes, work_minutes,
                                        missing_minutes, days: [{date, norm_minutes, work_minutes,
                                        missing_minutes, break_minutes, kinds, tickets, open}],
                                        kinds, tickets}
      akit worklog hours [HOURS] [--day DAY [HOURS|default]] [--json]
                                        The norm of a work day (default 7.5 h, Monday to Friday; in
                                        worklog/settings.yaml). HOURS sets it (only when the user
                                        asked). --day: one day's own norm ("norm: 4 h" in its file;
                                        0 for a day off, default removes it). Committed at once.
      akit worklog show [DAY|today|yesterday] [--days N] [--json] [--base PATH|WORLD]
                                        The entries of a day (default today), with how long each
                                        lasted and the minutes per kind. --days N: the last N days
                                        with entries. --json: {base, days: [{date, path, entries:
                                        [{time, end, kind, text, minutes, summary}], totals: {KIND: minutes},
                                        work_minutes, norm_minutes}]}
      akit worklog fill [DAY|today|yesterday] [--slot 15|30] [--language cs] [--thinking LEVEL] [--harness claude|pi|all] [--model M] [--add] [--json]
                                        Auto-Fill: the user's prompts of that day in the harness's
                                        sessions (default all), in slots of --slot minutes (default
                                        30) with the project, git branch and ticket (COL-123) of
                                        each, go to a Pi model (default GPT-6 Luna,
                                        --model from pi --list-models) under the sending policy and
                                        the send log (worklog-fill); prints the proposed entries.
                                        --language: the entries' language (default cs, Czech).
                                        --thinking: Pi's thinking level (off, minimal, low, medium,
                                        high, xhigh, max; default low). Each entry gets a summary of
                                        2-3 sentences, kept as "  > …" under it.
                                        --add (only when the user asked) adds them, one commit.
                                        --json: {day, model, prompts, entries: [{time, kind, text, summary}]}
      akit worklog kinds [--json]       The preset kinds: agent, task, bug, research, reply,
                                        meeting, review, break. Any other #tag works too.

    Which base: as for akit kb (akit kb --help).
    """

    struct WorkLogEntryAnswer: Encodable {
        let time: String
        var end: String? = nil
        let kind: String?
        let text: String
        let minutes: Int?
        var summary: String? = nil
    }

    struct WorkLogDayAnswer: Encodable {
        let date: String
        let path: String
        let entries: [WorkLogEntryAnswer]
        let totals: [String: Int]
        let work_minutes: Int
        let norm_minutes: Int
    }

    struct WorkLogReportDayAnswer: Encodable {
        let date: String
        let norm_minutes: Int
        let work_minutes: Int
        let missing_minutes: Int
        let break_minutes: Int
        let kinds: [String: Int]
        let tickets: [String: Int]
        let open: Bool
    }

    struct WorkLogReportAnswer: Encodable {
        let from: String
        let to: String
        let hours: Double
        let norm_minutes: Int
        let work_minutes: Int
        let missing_minutes: Int
        let days: [WorkLogReportDayAnswer]
        let kinds: [String: Int]
        let tickets: [String: Int]
    }

    struct WorkLogHoursAnswer: Encodable {
        let hours: Double
        var day: String? = nil
        var day_norm_minutes: Int? = nil
    }

    struct WorkLogShowAnswer: Encodable {
        let base: String
        let days: [WorkLogDayAnswer]
    }

    struct WorkLogAddAnswer: Encodable {
        let base: String
        let day: String
        let path: String
        let entry: WorkLogEntryAnswer
    }

    struct WorkLogFillAnswer: Encodable {
        let day: String
        let model: String
        let prompts: Int
        let added: Bool
        let entries: [WorkLogEntryAnswer]
    }

    struct WorkLogKindAnswer: Encodable {
        let id: String
        let title: String
        let work: Bool
    }

    static func worklog(_ arguments: [String], env: HarnessEnvironment, cwd: URL, projectsRoot: URL,
                        out: (String) -> Void, now: Date = .now) async throws -> Int32 {
        var args = Arguments(arguments)
        if args.flag("--help") || args.flag("-h") || args.isEmpty {
            out(worklogUsage)
            return 0
        }
        let json = args.flag("--json")
        let baseOption = args.value("--base")
        let command = args.positional()
        func chosen() async throws -> KnowledgeBase? {
            do {
                return try await KnowledgeBase.choose(option: baseOption, folder: cwd, env: env, projectsRoot: projectsRoot, forReading: true)
            } catch {
                throw Failure(message: error.message)
            }
        }
        do {
            switch command {
            case "kinds":
                try args.finish()
                let kinds = KnowledgeWorkLog.presets
                out(json ? encode(kinds.map { WorkLogKindAnswer(id: $0.id, title: $0.title, work: $0.isWork) })
                         : kinds.map { "#\($0.id)  \($0.title)" + ($0.isWork ? "" : "  (not work)") }.joined(separator: "\n"))
            case "add":
                let kind = args.value("--kind"), at = args.value("--at"), to = args.value("--to"), dayOption = args.value("--day")
                guard let text = args.positional() else {
                    throw Failure(message: "Use: akit worklog add TEXT [--kind KIND] [--at HH:MM [--to HH:MM [--day DAY]]] [--json] [--base PATH|WORLD]")
                }
                try args.finish()
                guard to != nil || dayOption == nil else { throw Failure(message: "--day is for a block: give --at and --to too.") }
                guard to == nil || at != nil else { throw Failure(message: "A block needs its start: --at HH:MM --to HH:MM.") }
                let base = try await writable(chosen)
                let log = KnowledgeWorkLog(base: base)
                var today = KnowledgeWorkLog.stamp(now)
                let entry: KnowledgeWorkLog.Entry, path: String
                if let at, let to {
                    today.day = try day(dayOption ?? "today", now: now)
                    let added = try log.add(text, kind: kind, day: today.day, time: at, end: to)
                    do { try await KnowledgeGit(base: base.root, env: env).commit(paths: [added.path], message: "Work log: \(today.day) \(added.entry.time)-\(to)") } catch {
                        throw Failure(message: "Saved, but not committed: \(error.message)")
                    }
                    (entry, path) = (added.entry, added.path)
                } else if let at {
                    guard let minute = KnowledgeWorkLog.minute(at), let nowMinute = KnowledgeWorkLog.minute(today.time), minute <= nowMinute else {
                        throw Failure(message: "--at takes a time of today up to now, as HH:MM.")
                    }
                    let added = try log.add(text, kind: kind, day: today.day, time: at)
                    do { try await KnowledgeGit(base: base.root, env: env).commit(paths: [added.path], message: "Work log: \(added.entry.time)") } catch {
                        throw Failure(message: "Saved, but not committed: \(error.message)")
                    }
                    (entry, path) = (added.entry, added.path)
                } else {
                    (entry, path) = try await log.add(text, kind: kind, at: now, env: env)
                }
                if json {
                    out(encode(WorkLogAddAnswer(base: base.root.path, day: today.day, path: path,
                                                entry: WorkLogEntryAnswer(time: entry.time, end: entry.end, kind: entry.kind, text: entry.text, minutes: nil))))
                } else {
                    out("Added to \(path): \(entry.markdown), committed.")
                }
            case "fill":
                let thinking = args.value("--thinking") ?? WorkLogFill.defaultThinking
                guard LabHarness.pi.efforts.contains(thinking) else {
                    throw Failure(message: "--thinking takes one of \(LabHarness.pi.efforts.joined(separator: ", ")).")
                }
                let languageCode = args.value("--language") ?? LabLanguage.czech.rawValue
                guard let language = LabLanguage(rawValue: languageCode) else {
                    throw Failure(message: "--language takes one of \(LabLanguage.codes).")
                }
                let slot = Int(args.value("--slot") ?? "30") ?? 0
                guard [15, 30].contains(slot) else { throw Failure(message: "--slot takes 15 or 30.") }
                let harnessOption = args.value("--harness") ?? "all", model = args.value("--model") ?? "", add = args.flag("--add")
                let which = args.positional()
                try args.finish()
                let harnesses: Set<HarnessID>
                switch harnessOption {
                case "claude": harnesses = [.claudeCode]
                case "pi": harnesses = [.pi]
                case "all": harnesses = [.claudeCode, .pi]
                default: throw Failure(message: "--harness takes claude, pi or all.")
                }
                let date = try day(which ?? "today", now: now)
                let base: KnowledgeBase? = add ? try await writable(chosen) : try await chosen()
                let existing = try base.map { try KnowledgeWorkLog(base: $0).day(date, now: now).entries } ?? []
                let sessions = WorkLogFill.sessions(SessionScanner.scan(installations: HarnessCatalog.detectAll(in: env), in: env),
                                                    day: date, harnesses: harnesses)
                let proposal: (entries: [KnowledgeWorkLog.Entry], prompts: Int, model: String)
                do { proposal = try await WorkLogFill.propose(day: date, sessions: sessions, existing: existing, model: model, slotMinutes: slot, language: language, thinking: thinking, env: env) } catch {
                    throw Failure(message: error.message)
                }
                if add, let base {
                    let log = KnowledgeWorkLog(base: base)
                    var paths: Set<String> = []
                    for (index, entry) in proposal.entries.enumerated() {
                        do { paths.insert(try log.add(entry.text, kind: entry.kind, day: date, time: entry.time, summary: entry.summary).path) } catch {
                            throw Failure(message: "\(index) of \(proposal.entries.count) entries were written to worklog/\(date).md but not committed; then: \(error.message)")
                        }
                    }
                    if !paths.isEmpty {
                        do { try await KnowledgeGit(base: base.root, env: env).commit(paths: Array(paths), message: "Work log: auto-fill \(date)") } catch {
                            throw Failure(message: "Saved, but not committed: \(error.message)")
                        }
                    }
                }
                if json {
                    out(encode(WorkLogFillAnswer(day: date, model: proposal.model, prompts: proposal.prompts, added: add,
                                                 entries: proposal.entries.map { WorkLogEntryAnswer(time: $0.time, kind: $0.kind, text: $0.text, minutes: nil, summary: $0.summary) })))
                } else {
                    out((["\(proposal.entries.count) entries from \(proposal.prompts) prompts on \(date) (\(proposal.model))"
                          + (add ? ", added and committed:" : ":")] + proposal.entries.flatMap(\.markdownLines)).joined(separator: "\n"))
                }
            case "show":
                let daysOption = args.value("--days")
                let which = args.positional()
                try args.finish()
                guard let base = try await chosen() else { return noBase(json: json, out: out) }
                let log = KnowledgeWorkLog(base: base)
                var dates: [String]
                if let daysOption {
                    guard which == nil, let n = Int(daysOption), n > 0 else { throw Failure(message: "--days takes a number above 0, and no DAY.") }
                    dates = Array(log.days().prefix(n))
                } else {
                    dates = [try day(which ?? "today", now: now)]
                }
                let days = try dates.map { try log.day($0, now: now) }
                if json {
                    out(encode(WorkLogShowAnswer(base: base.root.path, days: days.map { day in
                        WorkLogDayAnswer(date: day.date, path: log.path(day.date),
                                         entries: zip(day.entries, day.minutes).map {
                                             WorkLogEntryAnswer(time: $0.time, end: $0.end, kind: $0.kind, text: $0.text, minutes: $1, summary: $0.summary)
                                         },
                                         totals: Dictionary(day.totals.map { ($0.kind.isEmpty ? "none" : $0.kind, $0.minutes) }, uniquingKeysWith: +),
                                         work_minutes: day.workMinutes, norm_minutes: KnowledgeWorkLog.norm(of: day, hours: log.hours()))
                    })))
                } else if days.allSatisfy({ $0.entries.isEmpty }) {
                    out(daysOption == nil ? "No entries on \(dates.first ?? "")." : "No entries yet.")
                } else {
                    out(days.filter { !$0.entries.isEmpty }.map(describe).joined(separator: "\n\n"))
                }
            case "report":
                let csv = args.flag("--csv")
                let which = args.positional() ?? "week"
                try args.finish()
                guard let base = try await chosen() else { return noBase(json: json, out: out) }
                let log = KnowledgeWorkLog(base: base)
                let range = try reportRange(which, now: now)
                let report = try log.report(from: range.from, to: range.to, now: now)
                func named(_ parts: [String: Int]) -> [String: Int] {
                    Dictionary(parts.map { ($0.key.isEmpty ? "none" : $0.key, $0.value) }, uniquingKeysWith: +)
                }
                if json {
                    out(encode(WorkLogReportAnswer(
                        from: report.from, to: report.to, hours: report.hours, norm_minutes: report.norm, work_minutes: report.work,
                        missing_minutes: report.missing,
                        days: report.rows.map { row in
                            WorkLogReportDayAnswer(date: row.date, norm_minutes: row.norm, work_minutes: row.work, missing_minutes: row.missing,
                                                   break_minutes: row.pause, kinds: named(row.kinds), tickets: named(row.tickets), open: row.open)
                        },
                        kinds: named(Dictionary(report.kinds.map { ($0.kind, $0.minutes) }, uniquingKeysWith: +)),
                        tickets: named(Dictionary(report.tickets.map { ($0.ticket, $0.minutes) }, uniquingKeysWith: +)))))
                } else if csv {
                    out(report.daysCSV.trimmingCharacters(in: .newlines))
                } else {
                    out(describe(report))
                }
            case "hours":
                let dayOption = args.value("--day")
                let value = args.positional()
                try args.finish()
                func parsed(_ text: String) throws -> Double {
                    guard let hours = Double(text.replacingOccurrences(of: ",", with: ".")), (0...24).contains(hours) else {
                        throw Failure(message: "“\(text)” is no number of hours: use 0 to 24, like 7.5.")
                    }
                    return hours
                }
                if let value {
                    let base = try await writable(chosen)
                    let log = KnowledgeWorkLog(base: base)
                    let path: String, message: String
                    if let dayOption {
                        let date = try day(dayOption, now: now)
                        path = try log.setNorm(value == "default" ? nil : try parsed(value), on: date).path
                        message = "Work log: norm of \(date)"
                    } else {
                        path = try log.setHours(try parsed(value))
                        message = "Work log: \(value) h a day"
                    }
                    do { try await KnowledgeGit(base: base.root, env: env).commit(paths: [path], message: message) } catch {
                        throw Failure(message: "Saved, but not committed: \(error.message)")
                    }
                }
                guard let base = try await chosen() else { return noBase(json: json, out: out) }
                let log = KnowledgeWorkLog(base: base)
                let hours = log.hours()
                let done = value != nil ? ", committed." : "."
                if let dayOption {
                    let date = try day(dayOption, now: now)
                    let norm = KnowledgeWorkLog.norm(of: try log.day(date, now: now), hours: hours)
                    out(json ? encode(WorkLogHoursAnswer(hours: hours, day: date, day_norm_minutes: norm))
                             : "\(date): \(KnowledgeWorkLog.Report.h(norm)) h of work" + done)
                } else {
                    out(json ? encode(WorkLogHoursAnswer(hours: hours))
                             : "A work day has \(KnowledgeWorkLog.hoursText(hours)) h, Monday to Friday" + done)
                }
            default:
                throw Failure(message: "Unknown command akit worklog \(command ?? ""). akit worklog --help lists them.")
            }
        } catch let error as KnowledgeBase.Failure {
            throw Failure(message: error.message)
        }
        return 0
    }

    /// `today`, `yesterday` or a `YYYY-MM-DD`.
    static func day(_ text: String, now: Date) throws -> String {
        switch text.lowercased() {
        case "today": return KnowledgeWorkLog.stamp(now).day
        case "yesterday": return KnowledgeWorkLog.stamp(Calendar.current.date(byAdding: .day, value: -1, to: now) ?? now).day
        default:
            guard KnowledgeWorkLog.isDate(text) else { throw Failure(message: "“\(text)” is no day: use today, yesterday or YYYY-MM-DD.") }
            return text
        }
    }

    /// `week`, `month`, `last-week`, `last-month`, a day, or `DAY..DAY`.
    static func reportRange(_ text: String, now: Date) throws -> (from: String, to: String) {
        let calendar = Calendar.current
        switch text.lowercased() {
        case "week": return KnowledgeWorkLog.range(.week, containing: now)
        case "month": return KnowledgeWorkLog.range(.month, containing: now)
        case "last-week": return KnowledgeWorkLog.range(.week, containing: calendar.date(byAdding: .day, value: -7, to: now) ?? now)
        case "last-month": return KnowledgeWorkLog.range(.month, containing: calendar.date(byAdding: .month, value: -1, to: now) ?? now)
        default:
            let parts = text.components(separatedBy: "..")
            guard parts.count <= 2 else { throw Failure(message: "Use week, month, last-week, last-month, DAY or DAY..DAY.") }
            return (try day(parts[0], now: now), try day(parts.last ?? parts[0], now: now))
        }
    }

    /// A report as `report` prints it: one line per day, then the totals.
    static func describe(_ report: KnowledgeWorkLog.Report) -> String {
        let h = KnowledgeWorkLog.Report.h
        let lines = report.rows.map { row in
            let weekday = KnowledgeWorkLog.date(row.date).map { $0.formatted(.dateTime.weekday(.abbreviated)) } ?? ""
            return "\(row.date) \(weekday)  work \(h(row.work)) h of \(h(row.norm))" + (row.missing > 0 ? ", missing \(h(row.missing)) h" : "")
                + (row.open ? "  (last entry without an end)" : "")
        }
        let kinds = report.kinds.map { "\($0.kind.isEmpty ? "none" : "#\($0.kind)") \(h($0.minutes))" }
        let tickets = report.tickets.map { "\($0.ticket.isEmpty ? "no ticket" : $0.ticket) \(h($0.minutes))" }
        let hours = KnowledgeWorkLog.hoursText(report.hours)
        var result: [String] = ["## \(report.from) – \(report.to)  work \(h(report.work)) h of \(h(report.norm)), missing \(h(report.missing)) h (\(hours) h a day)"]
        result += lines
        if !kinds.isEmpty { result.append("Kinds (h): " + kinds.joined(separator: ", ")) }
        if !tickets.isEmpty { result.append("Tickets (h): " + tickets.joined(separator: ", ")) }
        return result.joined(separator: "\n")
    }

    /// A day as `show` prints it: the entries with their length, then the totals.
    static func describe(_ day: KnowledgeWorkLog.Day) -> String {
        let lines = zip(day.entries, day.minutes).map { entry, minutes in
            "\(entry.time)\(entry.end.map { "-\($0)" } ?? "")  \(entry.kind.map { "#\($0)" } ?? "-")  \(entry.text)" + (minutes.map { "  (\(KnowledgeWorkLog.duration($0)))" } ?? "")
                + (entry.summary.map { "\n       " + $0.replacingOccurrences(of: "\n", with: "\n       ") } ?? "")
        }
        let totals = day.totals.map { "\($0.kind.isEmpty ? "none" : "#\($0.kind)") \(KnowledgeWorkLog.duration($0.minutes))" }
        return (["## \(day.date)  work \(KnowledgeWorkLog.duration(day.workMinutes))"] + lines
            + (totals.isEmpty ? [] : ["Totals: " + totals.joined(separator: ", ")])).joined(separator: "\n")
    }
}
