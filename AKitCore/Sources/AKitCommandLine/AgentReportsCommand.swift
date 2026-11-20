import AKitFoundation
import AKitHarnesses
import AKitLab
import AKitModel
import AKitSessions
import Foundation

/// `akit reports`: the sections agents write at the end of a task (Pi's Agent decisions, Autonomy
/// improvements, Unknown unknowns), gathered from every session of a period
/// (docs/design/agent-reports.md), what Error Analysis → Agent Reports shows. Only
/// `summarize --yes` calls a model.
extension AKitCLI {
    static let reportsUsage = """
    akit reports: the sections an agent writes at the end of each task, gathered from every session
    of a period, so you don't open each session (docs/design/agent-reports.md). By default Pi's
    "Agent decisions", "Autonomy improvements" and "Unknown unknowns" (also their Russian headings).

      akit reports [PERIOD] [--harness pi|claude|all] [--section "NAME|ALIAS"]… [--markdown] [--json]
                                        Read only. The counts, then every item by section with its
                                        time, project and session; "none" items left out. --markdown:
                                        the same as a Markdown document (what Copy gives).
                                        --json: {from, to, sessions_read, sessions_with_reports,
                                        reports: [{time, harness, project, title, session, task,
                                        parts: [{section, items}]}]}
      akit reports summarize [PERIOD] [--harness …] [--section …] [--model M] [--thinking LEVEL]
                             [--language en] [--focus TEXT] [--show | --yes] [--json]
                                        One short report by a Pi model (default GPT-6 Luna) of the
                                        reports with items: a summary and up to 8 findings, each
                                        with a severity (high, medium, low), how many reports show
                                        it (R12 numbers) and a prompt to paste into the agent that
                                        fixes it. Without --yes: what would be
                                        sent (reports, calls, characters); --show prints the input
                                        after the scrub. --yes sends it under the sending policy and
                                        the send log (agent-reports) and saves the report in
                                        ~/.akit/lab/agent-reports. A long period goes in parts of
                                        ≤ 60,000 characters and one call merges them. --language:
                                        the report's language (default en). --focus (optional):
                                        what to look at first, as "flaky tests and CI"; the
                                        report answers it and puts its findings first.
                                        --json (with --yes): {file, model, calls, summary, focus,
                                        findings: [{severity, title, detail, section, count,
                                        reports, prompt}], markdown}; without: {reports, calls,
                                        characters}
      akit reports list [--json]        The saved reports, newest first: file, period, model, focus.
      akit reports show [FILE|latest] [--prompts]
                                        A saved report's Markdown (default the newest).
                                        --prompts: only its findings' prompts as one message
                                        to paste into the agent.

    PERIOD: --days N (default 7: from N days ago until now), or --from WHEN [--to WHEN] with WHEN
    YYYY-MM-DD, "YYYY-MM-DD HH:MM", today or yesterday. A day alone in --from starts at 00:00,
    in --to ends at 23:59; --to defaults to now. Default harness: pi.
    """

    struct ReportsPartAnswer: Encodable {
        let section: String
        let items: [String]
    }

    struct ReportsReportAnswer: Encodable {
        let time: String
        let harness: String
        let project: String
        let title: String
        let session: String
        let task: String?
        let parts: [ReportsPartAnswer]
    }

    struct ReportsAnswer: Encodable {
        let from: String
        let to: String
        let sessions_read: Int
        let sessions_with_reports: Int
        let reports: [ReportsReportAnswer]
    }

    struct ReportsPlanAnswer: Encodable {
        let reports: Int
        let calls: Int
        let characters: Int
    }

    struct ReportsSummaryAnswer: Encodable {
        let file: String
        let model: String
        let calls: Int
        let summary: String
        let focus: String
        let findings: [AgentReports.Finding]
        let markdown: String
    }

    struct ReportsSavedAnswer: Encodable {
        let file: String
        let focus: String
        let from: String
        let to: String
        let created: String
        let model: String
        let reports: Int
    }

    static func reports(_ arguments: [String], env: HarnessEnvironment, out: (String) -> Void, now: Date = .now) async throws -> Int32 {
        var args = Arguments(arguments)
        if args.flag("--help") || args.flag("-h") {
            out(reportsUsage)
            return 0
        }
        let json = args.flag("--json"), markdown = args.flag("--markdown"), show = args.flag("--show"), yes = args.flag("--yes")
        let prompts = args.flag("--prompts")
        let fromText = args.value("--from"), toText = args.value("--to"), daysText = args.value("--days")
        let harnessText = args.value("--harness"), sectionTexts = args.values("--section")
        let model = args.value("--model"), thinking = args.value("--thinking"), languageCode = args.value("--language")
        let focus = args.value("--focus")
        let command = args.positional()
        let file = command == "show" ? args.positional() : nil
        try args.finish()
        guard command == nil || ["summarize", "list", "show"].contains(command!) else {
            throw Failure(message: "Unknown command akit reports \(command!). akit reports --help lists them.")
        }
        let gathers = command == nil || command == "summarize"
        try refuse([(!gathers && (fromText != nil || toText != nil || daysText != nil), "--from, --to and --days"),
                    (!gathers && !sectionTexts.isEmpty, "--section"), (!gathers && harnessText != nil, "--harness"),
                    (markdown && command != nil, "--markdown"), (markdown && json, "--markdown and --json; --markdown"),
                    (command != "summarize" && (model != nil || thinking != nil || languageCode != nil || focus != nil || show || yes),
                     "--model, --thinking, --language, --focus, --show and --yes"),
                    (show && yes, "--show and --yes; --show"), (show && json, "--show and --json; --show"),
                    (json && command == "show", "--json"), (prompts && command != "show", "--prompts")], command: "reports \(command ?? "")")
        let store = AgentReportStore(env: env)
        switch command {
        case "list":
            let saved = store.list()
            if json {
                out(encode(saved.map { ReportsSavedAnswer(file: $0.file.path, focus: $0.focus, from: $0.from, to: $0.to, created: $0.created, model: $0.model, reports: $0.reports) }))
            } else {
                out(saved.isEmpty ? "No saved reports yet: akit reports summarize --yes writes one."
                    : saved.map { "\($0.file.path)  \($0.from) – \($0.to)  \($0.reports) reports  \($0.model)" + ($0.focus.isEmpty ? "" : "  focus: \($0.focus)") }.joined(separator: "\n"))
            }
            return 0
        case "show":
            let saved = store.list()
            let chosen: URL?
            if let file, file != "latest" {
                let url = URL(filePath: (file as NSString).expandingTildeInPath)
                chosen = FileManager.default.fileExists(atPath: url.path) ? url
                    : saved.first { $0.file.lastPathComponent == file || $0.file.deletingPathExtension().lastPathComponent == file }?.file
            } else {
                chosen = saved.first?.file
            }
            guard let chosen, let text = try? String(contentsOf: chosen, encoding: .utf8) else {
                throw Failure(message: saved.isEmpty ? "No saved reports yet: akit reports summarize --yes writes one." : "No saved report “\(file ?? "")”; akit reports list names them.")
            }
            if prompts {
                guard let analysis = store.analysis(of: chosen) else {
                    throw Failure(message: "\(chosen.lastPathComponent) was saved before reports had findings with prompts; summarize again.")
                }
                let entry = saved.first { $0.file == chosen }
                out(SecretFilter.masked(AgentReports.allPrompts(analysis, period: entry.map { "\($0.from) – \($0.to)" } ?? "")))
                return 0
            }
            out(SecretFilter.masked(text))
            return 0
        default:
            break
        }
        let harnesses: Set<HarnessID>
        switch harnessText ?? "pi" {
        case "pi": harnesses = [.pi]
        case "claude": harnesses = [.claudeCode]
        case "all": harnesses = [.pi, .claudeCode]
        default: throw Failure(message: "--harness takes pi, claude or all.")
        }
        let (from, to) = try reportsPeriod(from: fromText, to: toText, days: daysText, now: now)
        let sections = sectionTexts.isEmpty ? AgentReports.defaultSections : AgentReports.sections(fromText: sectionTexts.joined(separator: "\n"))
        guard !sections.isEmpty else { throw Failure(message: "--section takes a heading, with other spellings after |.") }
        let all = SessionScanner.scan(installations: HarnessCatalog.detectAll(in: env), in: env)
        let collection = AgentReports.collect(AgentReports.sessions(all, from: from, to: to, harnesses: harnesses), from: from, to: to, sections: sections)

        guard command == "summarize" else {
            if json {
                out(SecretFilter.masked(encode(ReportsAnswer(
                    from: AgentReports.stamp(from), to: AgentReports.stamp(to), sessions_read: collection.sessionsRead,
                    sessions_with_reports: collection.sessionsWithReports,
                    reports: collection.reports.map { report in
                        ReportsReportAnswer(time: AgentReports.stamp(report.time), harness: report.harness, project: report.project, title: report.title,
                                            session: report.session, task: report.task,
                                            parts: report.parts.map { ReportsPartAnswer(section: $0.section, items: $0.items) })
                    }))))
            } else if markdown {
                out(SecretFilter.masked(AgentReports.markdown(collection)))
            } else {
                var lines = ["Agent reports \(AgentReports.period(collection)): \(AgentReports.counts(collection))"]
                for section in sections {
                    let count = collection.count(section.name)
                    lines += ["", "\(section.name): \(count.items) in \(count.withItems) of \(count.reports) reports"]
                    for (item, report) in collection.items(of: section.name) {
                        lines.append("  - \(item)  [\(AgentReports.stamp(report.time)) · \(report.project)]")
                    }
                }
                out(SecretFilter.masked(lines.joined(separator: "\n")))
            }
            return 0
        }

        let thinkingLevel = thinking ?? AgentReports.defaultThinking
        guard LabHarness.pi.efforts.contains(thinkingLevel) else {
            throw Failure(message: "--thinking takes one of \(LabHarness.pi.efforts.joined(separator: ", ")).")
        }
        guard let language = LabLanguage(rawValue: languageCode ?? LabLanguage.english.rawValue) else {
            throw Failure(message: "--language takes one of \(LabLanguage.codes).")
        }
        if show {
            let inputs = AgentReports.inputs(collection)
            let own = LabSettings.load(env: env).scrub
            if let focus, !focus.isEmpty { out("Focus (in the instructions): \(focus)\n") }
            out(inputs.isEmpty ? "Nothing to send." : inputs.map { Scrubber.scrub($0, own: own).text }.joined(separator: "\n\n---\n\n"))
            return 0
        }
        let plan = AgentReports.plan(collection)
        guard yes else {
            if json {
                out(encode(ReportsPlanAnswer(reports: plan.reports, calls: plan.calls, characters: plan.characters)))
            } else if plan.reports == 0 {
                out("Agent reports \(AgentReports.period(collection)): \(AgentReports.counts(collection)) Nothing but “none”: there is nothing to send.")
            } else {
                out("Summarize would send \(plan.reports) report\(plan.reports == 1 ? "" : "s") with items (≈ \(plan.characters) characters, "
                    + "\(plan.calls) call\(plan.calls == 1 ? "" : "s")) to a Pi model, after the sending policy and the scrub.\n"
                    + "Only the found sections, the task's start and the session's title go out, no transcript. --show prints it; run again with --yes to send.")
            }
            return 0
        }
        let summary: AgentReports.Summary
        do {
            summary = try await AgentReports.summarize(collection, model: model ?? "", thinking: thinkingLevel, language: language, focus: focus ?? "", env: env)
        } catch {
            throw Failure(message: error.message)
        }
        let saved = try store.save(summary)
        if json {
            out(SecretFilter.masked(encode(ReportsSummaryAnswer(file: saved.path, model: summary.model, calls: summary.calls,
                                                                summary: summary.analysis.summary, focus: summary.analysis.focus,
                                                                findings: summary.analysis.findings, markdown: summary.markdown))))
        } else {
            out(SecretFilter.masked(summary.markdown) + "\nSaved to \(saved.path).")
        }
        return 0
    }

    /// The period of `--from`/`--to` or `--days` (default the last 7 days until now).
    static func reportsPeriod(from: String?, to: String?, days: String?, now: Date) throws -> (Date, Date) {
        if let days {
            guard from == nil, to == nil else { throw Failure(message: "--days takes no --from or --to.") }
            guard let n = Int(days), n > 0 else { throw Failure(message: "--days takes a number above 0.") }
            return (now.addingTimeInterval(-Double(n) * 86_400), now)
        }
        guard let from else {
            guard to == nil else { throw Failure(message: "--to needs --from.") }
            return (now.addingTimeInterval(-7 * 86_400), now)
        }
        let start = try reportsMoment(from, end: false, now: now)
        let end = try to.map { try reportsMoment($0, end: true, now: now) } ?? now
        guard start < end else { throw Failure(message: "--from must be before --to.") }
        return (start, end)
    }

    /// `YYYY-MM-DD`, `YYYY-MM-DD HH:MM` (or with a `T`), `today`, `yesterday`, `now`; a day alone
    /// starts at 00:00, or ends at 23:59:59 for `end`.
    static func reportsMoment(_ text: String, end: Bool, now: Date) throws -> Date {
        let calendar = Calendar.current
        let lower = text.lowercased().trimmingCharacters(in: .whitespaces)
        if lower == "now" { return now }
        let dayStart: Date?
        switch lower {
        case "today": dayStart = calendar.startOfDay(for: now)
        case "yesterday": dayStart = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))
        default:
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            for format in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm"] {
                formatter.dateFormat = format
                if let date = formatter.date(from: lower) { return date }
            }
            formatter.dateFormat = "yyyy-MM-dd"
            dayStart = formatter.date(from: lower).map { calendar.startOfDay(for: $0) }
        }
        guard let dayStart else { throw Failure(message: "“\(text)” is no time: use YYYY-MM-DD, \"YYYY-MM-DD HH:MM\", today or yesterday.") }
        return end ? dayStart.addingTimeInterval(86_400 - 1) : dayStart
    }
}
