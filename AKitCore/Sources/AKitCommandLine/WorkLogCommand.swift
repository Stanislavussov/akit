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
                                        once. --json: {base, day, path, entry: {time, kind, text}}
      akit worklog show [DAY|today|yesterday] [--days N] [--json] [--base PATH|WORLD]
                                        The entries of a day (default today), with how long each
                                        lasted and the minutes per kind. --days N: the last N days
                                        with entries. --json: {base, days: [{date, path, entries:
                                        [{time, kind, text, minutes}], totals: {KIND: minutes},
                                        work_minutes}]}
      akit worklog fill [DAY|today|yesterday] [--slot 15|30] [--language cs] [--harness claude|pi|all] [--model M] [--add] [--json]
                                        Auto-Fill: the user's prompts of that day in the harness's
                                        sessions (default all), in slots of --slot minutes (default
                                        30) with the project, git branch and ticket (COL-123) of
                                        each, go to a Pi model (default GPT-6 Luna,
                                        --model from pi --list-models) under the sending policy and
                                        the send log (worklog-fill); prints the proposed entries.
                                        --language: the entries' language (default cs, Czech).
                                        --add (only when the user asked) adds them, one commit.
                                        --json: {day, model, prompts, entries: [{time, kind, text}]}
      akit worklog kinds [--json]       The preset kinds: agent, task, bug, research, reply,
                                        meeting, review, break. Any other #tag works too.

    Which base: as for akit kb (akit kb --help).
    """

    struct WorkLogEntryAnswer: Encodable {
        let time: String
        let kind: String?
        let text: String
        let minutes: Int?
    }

    struct WorkLogDayAnswer: Encodable {
        let date: String
        let path: String
        let entries: [WorkLogEntryAnswer]
        let totals: [String: Int]
        let work_minutes: Int
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
                let kind = args.value("--kind"), at = args.value("--at")
                guard let text = args.positional() else {
                    throw Failure(message: "Use: akit worklog add TEXT [--kind KIND] [--at HH:MM] [--json] [--base PATH|WORLD]")
                }
                try args.finish()
                let base = try await writable(chosen)
                let log = KnowledgeWorkLog(base: base)
                let today = KnowledgeWorkLog.stamp(now)
                let entry: KnowledgeWorkLog.Entry, path: String
                if let at {
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
                                                entry: WorkLogEntryAnswer(time: entry.time, kind: entry.kind, text: entry.text, minutes: nil))))
                } else {
                    out("Added to \(path): \(entry.markdown), committed.")
                }
            case "fill":
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
                do { proposal = try await WorkLogFill.propose(day: date, sessions: sessions, existing: existing, model: model, slotMinutes: slot, language: language, env: env) } catch {
                    throw Failure(message: error.message)
                }
                if add, let base {
                    let log = KnowledgeWorkLog(base: base)
                    var paths: Set<String> = []
                    for (index, entry) in proposal.entries.enumerated() {
                        do { paths.insert(try log.add(entry.text, kind: entry.kind, day: date, time: entry.time).path) } catch {
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
                                                 entries: proposal.entries.map { WorkLogEntryAnswer(time: $0.time, kind: $0.kind, text: $0.text, minutes: nil) })))
                } else {
                    out((["\(proposal.entries.count) entries from \(proposal.prompts) prompts on \(date) (\(proposal.model))"
                          + (add ? ", added and committed:" : ":")] + proposal.entries.map(\.markdown)).joined(separator: "\n"))
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
                                             WorkLogEntryAnswer(time: $0.time, kind: $0.kind, text: $0.text, minutes: $1)
                                         },
                                         totals: Dictionary(day.totals.map { ($0.kind.isEmpty ? "none" : $0.kind, $0.minutes) }, uniquingKeysWith: +),
                                         work_minutes: day.workMinutes)
                    })))
                } else if days.allSatisfy({ $0.entries.isEmpty }) {
                    out(daysOption == nil ? "No entries on \(dates.first ?? "")." : "No entries yet.")
                } else {
                    out(days.filter { !$0.entries.isEmpty }.map(describe).joined(separator: "\n\n"))
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

    /// A day as `show` prints it: the entries with their length, then the totals.
    static func describe(_ day: KnowledgeWorkLog.Day) -> String {
        let lines = zip(day.entries, day.minutes).map { entry, minutes in
            "\(entry.time)  \(entry.kind.map { "#\($0)" } ?? "-")  \(entry.text)" + (minutes.map { "  (\(KnowledgeWorkLog.duration($0)))" } ?? "")
        }
        let totals = day.totals.map { "\($0.kind.isEmpty ? "none" : "#\($0.kind)") \(KnowledgeWorkLog.duration($0.minutes))" }
        return (["## \(day.date)  work \(KnowledgeWorkLog.duration(day.workMinutes))"] + lines
            + (totals.isEmpty ? [] : ["Totals: " + totals.joined(separator: ", ")])).joined(separator: "\n")
    }
}
