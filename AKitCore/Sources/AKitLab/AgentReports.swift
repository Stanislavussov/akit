import AKitFoundation
import AKitModel
import AKitSessions
import Foundation

/// Agent reports (docs/design/agent-reports.md): the sections an agent writes at the end of a
/// task (Pi's `Agent decisions`, `Autonomy improvements`, `Unknown unknowns`, as the global
/// AGENTS.md asks), gathered from every session of a period, so nobody has to open each session.
/// Gathering reads only; Summarize sends the found sections (never a whole transcript) to a Pi
/// model through `ModelCall` (sending policy, scrub, monthly limit, send log, purpose
/// `agent-reports`) and keeps the answer in `~/.akit/lab/agent-reports`.
public enum AgentReports {
    public struct Failure: Error, LocalizedError, Sendable {
        public let message: String
        public var errorDescription: String? { message }
        public init(message: String) { self.message = message }
    }

    public static let purpose = "agent-reports"

    /// A section to look for: its heading and other spellings of it (another language).
    public struct Section: Sendable, Hashable, Codable {
        public let name: String
        public let aliases: [String]

        public init(name: String, aliases: [String] = []) {
            self.name = name
            self.aliases = aliases
        }

        public var spellings: [String] { [name] + aliases }
    }

    /// What Pi's global AGENTS.md asks for at the end of a task, with the Russian headings it
    /// writes when it answers in Russian.
    public static let defaultSections: [Section] = [
        Section(name: "Agent decisions", aliases: ["Решения агента"]),
        Section(name: "Autonomy improvements", aliases: ["Улучшения автономности", "Улучшения автономии"]),
        Section(name: "Unknown unknowns", aliases: ["Неизвестные неизвестные", "Неизвестные факторы"]),
    ]

    /// One section per line, its spellings split by `|`: `Unknown unknowns | Неизвестные факторы`.
    public static func sections(fromText text: String) -> [Section] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let names = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard let name = names.first else { return nil }
            return Section(name: name, aliases: Array(names.dropFirst()))
        }
    }

    public static func text(of sections: [Section]) -> String {
        sections.map { $0.spellings.joined(separator: " | ") }.joined(separator: "\n")
    }

    // MARK: - Reading one message

    /// One section of a report: its items, none when the agent wrote "none".
    public struct Part: Sendable, Hashable, Codable {
        public let section: String
        public var items: [String]

        public init(section: String, items: [String]) {
            self.section = section
            self.items = items
        }
    }

    /// The sections found in one message, in the order of `sections`; empty when it has none of them.
    /// A heading counts when it is bold (`**Agent decisions:**`), a Markdown heading, or starts a
    /// line with a colon after it; a section runs to the next heading, the next bold label or a
    /// paragraph that isn't a list item.
    public static func parse(_ text: String, sections: [Section]) -> [Part] {
        let names = sections.flatMap { section in section.spellings.map { ($0, section.name) } }
        guard !names.isEmpty else { return [] }
        let alternatives = names.map { NSRegularExpression.escapedPattern(for: $0.0) }.joined(separator: "|")
        // 1: line start (bullet or heading allowed), 2: opening bold, 3: name, 4: closing bold or colon.
        let pattern = #"(^[ \t>]*(?:[-*+][ \t]+)?(?:#{1,6}[ \t]+)?)?(\*\*|__)?("# + alternatives
            + #")[ \t]*((?:\*\*|__)[ \t]*:?|:[ \t]*(?:\*\*|__)?)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .anchorsMatchLines]) else { return [] }
        let ns = text as NSString
        var heads: [(range: NSRange, section: String)] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let lineStart = match.range(at: 1).location != NSNotFound
            let bold = match.range(at: 2).location != NSNotFound
            let closer = match.range(at: 4).location != NSNotFound ? ns.substring(with: match.range(at: 4)) : ""
            let heading = lineStart && ns.substring(with: match.range(at: 1)).contains("#")
            // Bold on both sides, a Markdown heading, or "Name:" at a line's start; not a name in a sentence.
            guard (bold && (closer.contains("*") || closer.contains("_"))) || heading || (lineStart && closer.contains(":")) else { continue }
            // The name must end at a word's end ("Agent decisions" not in "Agent decisionsX").
            let end = match.range(at: 3).location + match.range(at: 3).length
            if closer.isEmpty, end < ns.length, let next = Unicode.Scalar(ns.character(at: end)), CharacterSet.alphanumerics.contains(next) { continue }
            let spelled = ns.substring(with: match.range(at: 3)).lowercased()
            guard let section = names.first(where: { $0.0.lowercased() == spelled })?.1 else { continue }
            heads.append((match.range, section))
        }
        var parts: [Part] = []
        for (index, head) in heads.enumerated() {
            let start = head.range.location + head.range.length
            let stop = index + 1 < heads.count ? heads[index + 1].range.location : ns.length
            let body = cut(ns.substring(with: NSRange(location: start, length: max(0, stop - start))))
            let found = items(body)
            if let existing = parts.firstIndex(where: { $0.section == head.section }) {
                parts[existing].items += found.filter { !parts[existing].items.contains($0) }
            } else {
                parts.append(Part(section: head.section, items: found))
            }
        }
        let order = sections.map(\.name)
        return parts.sorted { (order.firstIndex(of: $0.section) ?? 0) < (order.firstIndex(of: $1.section) ?? 0) }
    }

    /// The body up to the next bold label, Markdown heading or paragraph that isn't a list item.
    static func cut(_ body: String) -> String {
        let stops = [#"\*\*[^*\n]{1,80}:\*\*"#, #"\*\*[^*\n]{1,80}\*\*[ \t]*:"#, #"\n[ \t]*#{1,6}[ \t]"#,
                     #"\n[ \t]*\n(?![ \t]*(?:[-*+]|\d+[.)])[ \t])"#]
        var end = body.endIndex
        for stop in stops {
            if let range = body.range(of: stop, options: .regularExpression), range.lowerBound < end { end = range.lowerBound }
        }
        return String(body[..<end])
    }

    /// The list items of a body (a line without a bullet continues the item before it); the
    /// "none" items left out.
    static func items(_ body: String) -> [String] {
        var items: [String] = []
        for raw in body.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if let bullet = line.firstMatch(of: /^(?:[-*+]|\d+[.)])\s+/) {
                items.append(String(line[bullet.range.upperBound...]))
            } else if items.isEmpty {
                items.append(line)
            } else {
                items[items.count - 1] += " " + line
            }
        }
        return items.map { $0.replacing(/\s+/, with: " ").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !isNone($0) }
    }

    /// "none", "- none identified.", "`- none`", "нет." and the like.
    public static func isNone(_ item: String) -> Bool {
        let plain = item.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " `*_-.;:!()").union(.whitespaces))
        return plain.wholeMatch(of: /(none|нет|n\/a|ничего|отсутству(ют|ет)|не (выявлен[оы]?|обнаружен[оы]?))( identified| found| so far| выявлено)?/) != nil
            || plain.wholeMatch(of: /no (additional |other |further |new )?(blind spots|improvements|unknowns)( identified| found)?/) != nil
    }

    // MARK: - A period

    /// One report: a message with at least one of the sections.
    public struct Report: Sendable, Hashable, Codable, Identifiable {
        public var id: String { "\(session)#\(item)" }
        public let harness: String
        /// The session file.
        public let session: String
        public let item: Int
        public let title: String
        public let project: String
        public let time: Date
        /// The user's last prompt before the report (its start).
        public let task: String?
        public let parts: [Part]

        public init(harness: String, session: String, item: Int, title: String, project: String, time: Date, task: String?, parts: [Part]) {
            (self.harness, self.session, self.item, self.title, self.project, self.time, self.task, self.parts) =
                (harness, session, item, title, project, time, task, parts)
        }

        /// No section has an item ("none" everywhere).
        public var isEmpty: Bool { parts.allSatisfy(\.items.isEmpty) }
    }

    /// What a period holds: the reports found and how many sessions were read.
    public struct Collection: Sendable, Hashable {
        public let from: Date
        public let to: Date
        public let sections: [Section]
        public let sessionsRead: Int
        public let reports: [Report]

        public init(from: Date, to: Date, sections: [Section], sessionsRead: Int, reports: [Report]) {
            (self.from, self.to, self.sections, self.sessionsRead, self.reports) = (from, to, sections, sessionsRead, reports)
        }

        public var sessionsWithReports: Int { Set(reports.map(\.session)).count }
        public var withItems: [Report] { reports.filter { !$0.isEmpty } }

        /// Per section: its items with their reports, in time order.
        public func items(of section: String) -> [(item: String, report: Report)] {
            reports.flatMap { report in report.parts.filter { $0.section == section }.flatMap { $0.items.map { ($0, report) } } }
        }

        /// How many reports have the section at all, and how many with items.
        public func count(_ section: String) -> (reports: Int, withItems: Int, items: Int) {
            let parts = reports.compactMap { $0.parts.first { $0.section == section } }
            return (parts.count, parts.filter { !$0.items.isEmpty }.count, parts.map(\.items.count).reduce(0, +))
        }
    }

    /// The sessions of `harnesses` that may hold messages between `from` and `to`.
    public static func sessions(_ all: [SessionSummary], from: Date, to: Date, harnesses: Set<HarnessID>) -> [SessionSummary] {
        all.filter { harnesses.contains($0.harness) && $0.modified >= from && ($0.started ?? $0.modified) <= to }
    }

    /// The task text cut to this many characters.
    static let taskCharacters = 300

    /// The reports of the sessions between `from` and `to`, oldest first. A message seen before (a
    /// forked session copies its history) counts once. Sessions are read in parallel.
    public static func collect(_ sessions: [SessionSummary], from: Date, to: Date, sections: [Section],
                               read: @Sendable (SessionSummary) throws -> SessionTranscript = transcript) -> Collection {
        let found = JSONLines.summaries(of: sessions.map(\.file)) { file -> [(hash: String, report: Report)]? in
            guard let session = sessions.first(where: { $0.file == file }), let transcript = try? read(session) else { return nil }
            var reports: [(String, Report)] = []
            var task: String?
            for item in transcript.items {
                switch item.kind {
                case .user:
                    let text = item.text.replacing(/\s+/, with: " ").trimmingCharacters(in: .whitespaces)
                    if !text.isEmpty, !text.hasPrefix("<") { task = String(text.prefix(taskCharacters)) }
                case .assistant:
                    let time = item.timestamp ?? session.modified
                    guard time >= from, time <= to else { continue }
                    let parts = parse(item.text, sections: sections)
                    guard !parts.isEmpty else { continue }
                    reports.append((Checksum.sha256(Data(item.text.utf8)),
                                    Report(harness: session.harness.rawValue, session: session.file.path, item: item.id, title: session.title,
                                           project: session.project?.lastPathComponent ?? "-", time: time, task: task, parts: parts)))
                default:
                    continue
                }
            }
            return reports
        }
        var seen = Set<String>()
        let reports = found.flatMap { $0 }.sorted { $0.report.time < $1.report.time }.filter { seen.insert($0.hash).inserted }.map(\.report)
        return Collection(from: from, to: to, sections: sections, sessionsRead: sessions.count, reports: reports)
    }

    /// The user's prompts and the agent's answers of a session. A Pi file is read fast: its tool
    /// results and system prompt (most of its bytes) are never decoded.
    @Sendable public static func transcript(_ session: SessionSummary) throws -> SessionTranscript {
        guard session.harness == .pi else { return try SessionReader.transcript(of: session) }
        let data = try Data(contentsOf: session.file, options: .mappedIfSafe)
        let user = Data(#""role":"user""#.utf8), assistant = Data(#""role":"assistant""#.utf8)
        var items: [TranscriptItem] = []
        let entries = try JSONLines.objects(in: data) { line in
            let head = line.prefix(400)
            return head.range(of: assistant) != nil || head.range(of: user) != nil
        }
        for entry in entries {
            guard entry["type"] as? String == "message", let message = entry["message"] as? JSONLines.Object else { continue }
            let time = JSONLines.date(entry["timestamp"])
            switch message["role"] as? String {
            case "user":
                items.append(TranscriptItem(id: items.count, kind: .user, text: JSONLines.text(of: message["content"]), timestamp: time))
            case "assistant":
                for block in message["content"] as? [JSONLines.Object] ?? [] where block["type"] as? String == "text" {
                    items.append(TranscriptItem(id: items.count, kind: .assistant, text: block["text"] as? String ?? "", timestamp: time))
                }
            default:
                continue
            }
        }
        return SessionTranscript(items: items)
    }

    // MARK: - Markdown without a model

    public static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    public static func period(_ collection: Collection) -> String { "\(stamp(collection.from)) – \(stamp(collection.to))" }

    /// The counts line: sessions read, with reports, reports, only "none".
    public static func counts(_ collection: Collection) -> String {
        let empty = collection.reports.count - collection.withItems.count
        return "\(collection.sessionsRead) sessions read, \(collection.sessionsWithReports) with reports; "
            + "\(collection.reports.count) reports, \(empty) of them only “none”."
    }

    /// Every item by section, each with where it came from: what Copy and Export give without a model.
    public static func markdown(_ collection: Collection) -> String {
        var lines = ["# Agent reports \(period(collection))", "", counts(collection)]
        for section in collection.sections {
            let count = collection.count(section.name)
            lines += ["", "## \(section.name) (\(count.items) in \(count.withItems) of \(count.reports) reports)", ""]
            let items = collection.items(of: section.name)
            if items.isEmpty { lines.append("- none") }
            for (item, report) in items {
                lines.append("- \(item) — *\(stamp(report.time)) · \(report.project) · \(report.title.prefix(80))*")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Summary by a model

    /// One call's input is at most about this many characters; a longer period is summarized in
    /// parts and the parts merged by one more call.
    public static let maxCharacters = 60_000
    /// One item is cut to this many characters.
    static let itemCharacters = 600

    /// A report as the model reads it: its number (`R12`), when, where, the task and the sections.
    static func block(_ report: Report, number: Int) -> String {
        var lines = ["### R\(number) · \(stamp(report.time)) · \(report.project) · \(report.title.prefix(100))"]
        if let task = report.task { lines.append("Task: \(task)") }
        for part in report.parts {
            lines.append("\(part.section):")
            lines += part.items.isEmpty ? ["- none"] : part.items.map { "- \($0.prefix(itemCharacters))" }
        }
        return lines.joined(separator: "\n")
    }

    /// The reports with at least one item, numbered from 1 in time order (the numbers the summary cites).
    public static func numbered(_ collection: Collection) -> [(number: Int, report: Report)] {
        collection.withItems.enumerated().map { ($0.offset + 1, $0.element) }
    }

    /// The inputs of the first calls: the numbered reports in time order, cut into parts of at most
    /// `maxCharacters` (one report is never split).
    public static func inputs(_ collection: Collection, limit: Int = maxCharacters) -> [String] {
        let header = "Period: \(period(collection)). \(counts(collection)) Reports that say only “none” are left out.\n\n"
        var chunks: [String] = [], current = ""
        for (number, report) in numbered(collection) {
            let text = block(report, number: number) + "\n\n"
            if !current.isEmpty, header.count + current.count + text.count > limit {
                chunks.append(current)
                current = ""
            }
            current += text
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks.enumerated().map { index, chunk in
            header + (chunks.count > 1 ? "Part \(index + 1) of \(chunks.count).\n\n" : "") + chunk
        }
    }

    /// What Summarize sends: the calls and characters.
    public struct Plan: Sendable, Equatable {
        public let reports: Int
        public let calls: Int
        public let characters: Int
    }

    public static func plan(_ collection: Collection) -> Plan {
        let inputs = inputs(collection)
        // A merge call reads the parts' answers: about a sixth of what they read, at most one call.
        let merge = inputs.count > 1 ? inputs.map(\.count).reduce(0, +) / 6 : 0
        return Plan(reports: collection.withItems.count, calls: inputs.count + (inputs.count > 1 ? 1 : 0),
                    characters: inputs.map(\.count).reduce(0, +) + merge)
    }

    /// The focus with its newlines folded: one line in the prompt and the front matter.
    static func folded(_ focus: String) -> String {
        focus.replacing(/\s+/, with: " ").trimmingCharacters(in: .whitespaces)
    }

    /// How much a finding matters: High can make the agent's work wrong or harmful, Medium costs
    /// time or the person's attention, Low is minor.
    public enum Severity: String, Codable, Sendable, CaseIterable, Comparable {
        case high, medium, low

        public var title: String { rawValue.capitalized }
        /// For Markdown, where there are no colors.
        public var mark: String {
            switch self {
            case .high: "🔴"
            case .medium: "🟠"
            case .low: "🔵"
            }
        }

        public static func < (a: Severity, b: Severity) -> Bool {
            allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
        }
    }

    /// One finding: what repeats in the reports, how much it matters, and a prompt that fixes it.
    public struct Finding: Codable, Sendable, Hashable {
        public var severity: Severity
        /// One short sentence.
        public var title: String
        /// One sentence: what the reports show.
        public var detail: String
        /// The section it comes from (one of the gathered ones), or "".
        public var section: String
        /// How many reports show it.
        public var count: Int
        /// Up to five report numbers (R12 → 12).
        public var reports: [Int]
        /// A prompt to paste into the coding agent to make the change.
        public var prompt: String

        public init(severity: Severity, title: String, detail: String, section: String, count: Int, reports: [Int], prompt: String) {
            (self.severity, self.title, self.detail, self.section, self.count, self.reports, self.prompt) =
                (severity, title, detail, section, count, reports, prompt)
        }
    }

    /// The model's report: one or two sentences, the answer to the focus, the findings.
    public struct Analysis: Codable, Sendable, Hashable {
        public var summary: String
        public var focus: String
        public var findings: [Finding]

        public init(summary: String, focus: String = "", findings: [Finding]) {
            (self.summary, self.focus, self.findings) = (summary, focus, findings)
        }
    }

    /// At most this many findings, the most severe and frequent first.
    public static let maxFindings = 8

    static func rules(_ sections: [Section], language: LabLanguage, focus: String) -> String {
        let focus = folded(focus)
        return """
        Answer with JSON only: {"summary": "...", "focus": "...", "findings": [{"severity": "high|medium|low", \
        "title": "...", "detail": "...", "section": "...", "count": 4, "reports": [3, 9, 17], "prompt": "..."}]}.

        - summary: one or two plain sentences on how the agent's work went in this period.
        - findings: at most \(maxFindings), the most important first. Each is a point that repeats across reports, \
        or one that is serious even once. Merge points that say the same thing in other words.
        - severity: high when it can make the agent's work wrong, unsafe or unverified and the person may not notice; \
        medium when it costs time or needs the person's attention; low when it is minor.
        - title: one short sentence (at most 15 words) a person understands without the reports.
        - detail: one sentence (at most 25 words): what the reports show.
        - section: the section it comes from, one of \(sections.map(\.name).joined(separator: ", ")).
        - count: how many reports show it; reports: up to five of their numbers (R12 → 12).
        - prompt: a prompt the person pastes into their coding agent to fix it, 2 to 4 sentences: what to change \
        (the global AGENTS.md, a skill or a check), the rule to add in the imperative, and how to tell it works. \
        No project names, secrets or personal data.
        """ + (focus.isEmpty ? "\n- focus: \"\"." : """

        - focus: the person asks you to look first at "\(focus)": answer it in one to three sentences from the \
        reports ("Nothing in the reports" when none bears on it), and put the findings that bear on it first.
        """) + """

        Write only what the reports support: no guesses. Plain words, no jargon. Write every text in \(language.name), \
        keeping code, file names and commands as they are.
        """
    }

    public static func system(sections: [Section], language: LabLanguage, focus: String = "") -> String {
        """
        You read the final task reports a coding agent wrote over a period. Each report has a number (R12), its \
        time, project and session, the user's task, and the agent's own sections: \
        \(sections.map(\.name).joined(separator: ", ")). The person who runs the agent can't read every session; give \
        them a short, simple report of what to improve.

        """ + rules(sections, language: language, focus: focus)
    }

    public static func mergeSystem(sections: [Section], language: LabLanguage, focus: String = "") -> String {
        """
        You merge partial reports about a coding agent's final task reports over one period into one report. Each \
        part covers some of the reports (numbered R1, R2, …; the numbers are the same across parts). Merge findings \
        that say the same thing: add up their counts, keep up to five report numbers, keep the highest severity and \
        the clearest prompt.

        """ + rules(sections, language: language, focus: focus)
    }

    public static let schema = #"{"type":"object","properties":{"summary":{"type":"string"},"focus":{"type":"string"},"findings":{"type":"array","items":{"type":"object","properties":{"severity":{"type":"string","enum":["high","medium","low"]},"title":{"type":"string"},"detail":{"type":"string"},"section":{"type":"string"},"count":{"type":"integer"},"reports":{"type":"array","items":{"type":"integer"}},"prompt":{"type":"string"}},"required":["severity","title","detail","section","count","reports","prompt"]}}},"required":["summary","focus","findings"]}"#

    /// The first JSON object of an answer. Models sometimes add a stray `"}` after it, so the
    /// object may end at an earlier `}` than the last one.
    static func jsonObject(_ text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var end = text.endIndex
        for _ in 0..<5 {
            guard let close = text[start..<end].lastIndex(of: "}") else { return nil }
            if let object = try? JSONSerialization.jsonObject(with: Data(text[start...close].utf8)) as? [String: Any] { return object }
            end = close
        }
        return nil
    }

    /// The model's answer, checked: a known severity (else medium), one-line texts, report numbers
    /// that exist (`reports` of them), a count no lower than the numbers kept; the most severe and
    /// frequent first, at most `maxFindings`. Throws when it isn't the JSON asked for.
    static func analysis(fromAnswer answer: String, reports: Int) throws(Failure) -> Analysis {
        guard let object = jsonObject(answer), let items = object["findings"] as? [[String: Any]] else {
            throw Failure(message: "The model's answer isn't the report asked for; try again or pick another model.")
        }
        func line(_ value: Any?) -> String { ((value as? String) ?? "").replacing(/\s+/, with: " ").trimmingCharacters(in: .whitespaces) }
        let findings = items.compactMap { item -> Finding? in
            let title = line(item["title"])
            guard !title.isEmpty else { return nil }
            let numbers = ((item["reports"] as? [Any]) ?? []).compactMap { ($0 as? Int) ?? Int(line($0).trimmingCharacters(in: CharacterSet(charactersIn: "Rr"))) }
            var kept: [Int] = []
            for number in numbers where (1...max(1, reports)).contains(number) && !kept.contains(number) { kept.append(number) }
            let prompt = ((item["prompt"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return Finding(severity: Severity(rawValue: line(item["severity"]).lowercased()) ?? .medium, title: title, detail: line(item["detail"]),
                           section: line(item["section"]), count: max((item["count"] as? Int) ?? 0, kept.count, 1),
                           reports: Array(kept.prefix(5)), prompt: prompt)
        }
        let sorted = findings.enumerated().sorted { a, b in
            (a.element.severity, -a.element.count, a.offset) < (b.element.severity, -b.element.count, b.offset)
        }.map(\.element)
        return Analysis(summary: line(object["summary"]), focus: line(object["focus"]), findings: Array(sorted.prefix(maxFindings)))
    }

    /// Every finding's prompt as one message to paste into the coding agent.
    public static func allPrompts(_ analysis: Analysis, period: String) -> String {
        let list = analysis.findings.filter { !$0.prompt.isEmpty }.enumerated().map { index, finding in
            "\(index + 1). [\(finding.severity.title)] \(finding.title)\n\(finding.prompt)"
        }
        return """
        My coding agent's own end-of-task reports (\(period)) show what to improve in its setup. Make these changes \
        one at a time, most severe first; show me each diff before you write it.

        \(list.joined(separator: "\n\n"))
        """
    }

    public static func defaultModel(available: [String]) -> String? { WorkLogFill.defaultModel(available: available) }
    public static let defaultThinking = "low"

    /// A finished summary: the report as Markdown (for the file) and as data (for the screen).
    public struct Summary: Sendable {
        public let markdown: String
        public let analysis: Analysis
        public let model: String
        public let calls: Int
    }

    /// Sends the reports with items to the model (in parts when they are long, then a merge) and
    /// returns the report: the findings with severity and prompt, and the same as Markdown with the
    /// period, the counts and the reports its numbers name. `focus` (optional) is what the person
    /// wants looked at first. `progress` gets "Part 2 of 4…". Nothing is written here.
    public static func summarize(_ collection: Collection, model: String, thinking: String = defaultThinking,
                                 language: LabLanguage = .english, focus: String = "", env: HarnessEnvironment,
                                 progress: (@Sendable (String) -> Void)? = nil) async throws(Failure) -> Summary {
        let inputs = inputs(collection)
        guard !inputs.isEmpty else {
            throw Failure(message: "No report in this period has anything but “none”, so there is nothing to summarize.")
        }
        let total = numbered(collection).count
        do {
            let available = await LabRuns.models(for: .pi, env: env)
            let agent = try KnowledgeCheckModel.resolved(LabAgent(harness: .pi, model: model.isEmpty ? (defaultModel(available: available) ?? "") : model,
                                                                  effort: LabHarness.pi.efforts.contains(thinking) ? thinking : defaultThinking,
                                                                  mode: .call), available: available)
            let harnesses = Dictionary(collection.reports.map { ($0.session, $0.harness) }, uniquingKeysWith: { a, _ in a })
            let origins = Array(Set(Set(collection.withItems.map(\.session)).map { file in
                SendOrigin.of(harness: harnesses[file] == HarnessID.claudeCode.rawValue ? .claudeCode : .pi, sessionFile: URL(filePath: file))
            }))
            let gate = try await SendGate.open(agent: agent, env: env)
            let folder = FileManager.default.temporaryDirectory.appending(path: "akit-agent-reports-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: folder) }
            func call(_ system: String, _ input: String) async throws -> Analysis {
                let request = ModelCall.Request(agent: agent, purpose: purpose, system: system, input: input, schema: schema, origins: origins)
                return try analysis(fromAnswer: try await ModelCall.run(request, gate: gate, folder: folder, env: env).text, reports: total)
            }
            var parts: [Analysis] = []
            for (index, input) in inputs.enumerated() {
                progress?(inputs.count > 1 ? "Part \(index + 1) of \(inputs.count)…" : "Waiting for the model…")
                parts.append(try await call(system(sections: collection.sections, language: language, focus: focus), input))
            }
            var result = parts[0]
            if parts.count > 1 {
                progress?("Merging \(parts.count) parts…")
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                let merged = parts.enumerated().map { index, part in
                    "# Part \(index + 1) of \(parts.count)\n\n" + String(decoding: (try? encoder.encode(part)) ?? Data(), as: UTF8.self)
                }.joined(separator: "\n\n")
                result = try await call(mergeSystem(sections: collection.sections, language: language, focus: focus), merged)
            }
            return Summary(markdown: document(collection, analysis: result, model: agent.model, focus: focus), analysis: result,
                           model: agent.model, calls: parts.count + (parts.count > 1 ? 1 : 0))
        } catch let failure as Failure {
            throw failure
        } catch let error as KnowledgeCheckModel.Failure {
            throw Failure(message: error.message)
        } catch {
            throw Failure(message: error.localizedDescription)
        }
    }

    /// The saved report: front matter, title, counts, the summary, the findings with their prompts,
    /// and the reports cited.
    static func document(_ collection: Collection, analysis: Analysis, model: String, focus: String = "", created: Date = .now) -> String {
        let focus = folded(focus)
        let refs = numbered(collection).map { number, report in
            "| R\(number) | \(stamp(report.time)) | \(report.project) | \(report.title.prefix(80).replacingOccurrences(of: "|", with: "/")) | `\(report.session)` |"
        }
        let findings = analysis.findings.map { finding in
            var lines = ["### \(finding.severity.mark) \(finding.severity.title) · \(finding.title)", ""]
            let seen = "\(finding.count) report\(finding.count == 1 ? "" : "s")"
                + (finding.reports.isEmpty ? "" : ": " + finding.reports.map { "R\($0)" }.joined(separator: ", "))
            lines.append([finding.detail, "(\(seen)\(finding.section.isEmpty ? "" : " · \(finding.section)"))"].filter { !$0.isEmpty }.joined(separator: " "))
            if !finding.prompt.isEmpty { lines += ["", "Prompt:", "", "```text", finding.prompt, "```"] }
            return lines.joined(separator: "\n")
        }
        return """
        ---
        from: \(stamp(collection.from))
        to: \(stamp(collection.to))
        created: \(stamp(created))
        model: \(model)
        sessions: \(collection.sessionsRead)
        reports: \(collection.reports.count)
        focus: \(focus)
        ---

        # Agent reports \(period(collection))

        \(counts(collection)) Model: \(model).\(focus.isEmpty ? "" : " Focus: \(focus)")

        \(analysis.summary)
        \(focus.isEmpty || analysis.focus.isEmpty ? "" : "\n**Focus:** \(analysis.focus)\n")
        ## Findings

        \(findings.isEmpty ? "No findings." : findings.joined(separator: "\n\n"))

        ## Reports cited

        | # | Time | Project | Session | File |
        |---|---|---|---|---|
        \(refs.joined(separator: "\n"))

        """
    }
}

/// Saved summaries: `~/.akit/lab/agent-reports/<created>.md`, local only (never in the brain).
public struct AgentReportStore: Sendable {
    public let folder: URL

    public init(env: HarnessEnvironment) { folder = LabPaths(env: env).folder.appending(path: "agent-reports", directoryHint: .isDirectory) }

    /// One saved report: its file and the front matter's period and counts.
    public struct Saved: Sendable, Hashable, Identifiable {
        public var id: String { file.path }
        public let file: URL
        public let from: String
        public let to: String
        public let created: String
        public let model: String
        public let reports: Int
        public var focus: String = ""
    }

    /// Writes the report; returns its file.
    @discardableResult
    public func save(_ summary: AgentReports.Summary, now: Date = .now) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        var file = folder.appending(path: "\(formatter.string(from: now)).md")
        var suffix = 2
        while FileManager.default.fileExists(atPath: file.path) {
            file = folder.appending(path: "\(formatter.string(from: now))-\(suffix).md")
            suffix += 1
        }
        try Data(summary.markdown.utf8).write(to: file, options: .atomic)
        // The findings as data beside it, for the screen's colors and Copy Prompt.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(summary.analysis).write(to: file.deletingPathExtension().appendingPathExtension("json"), options: .atomic)
        return file
    }

    /// The findings saved beside a report; nil for a report saved before findings had their own file.
    public func analysis(of file: URL) -> AgentReports.Analysis? {
        (try? Data(contentsOf: file.deletingPathExtension().appendingPathExtension("json")))
            .flatMap { try? JSONDecoder().decode(AgentReports.Analysis.self, from: $0) }
    }

    /// The saved reports, newest first.
    public func list() -> [Saved] {
        FileWalk.children(of: folder).filter { $0.pathExtension == "md" }.compactMap { file in
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            var fields: [String: String] = [:]
            for line in text.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().prefix(12) {
                if line == "---" { break }
                let pair = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if pair.count == 2 { fields[pair[0]] = pair[1] }
            }
            return Saved(file: file, from: fields["from"] ?? "", to: fields["to"] ?? "", created: fields["created"] ?? "",
                         model: fields["model"] ?? "", reports: Int(fields["reports"] ?? "") ?? 0, focus: fields["focus"] ?? "")
        }
        .sorted { $0.file.lastPathComponent > $1.file.lastPathComponent }
    }
}
