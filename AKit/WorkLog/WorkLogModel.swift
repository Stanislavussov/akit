import AKitFoundation
import AKitKnowledge
import AKitLab
import AKitModel
import AKitSessions
import Foundation
import Observation

/// The Work Log screen (docs/design/worklog.md): the days of the knowledge base's `worklog/`
/// folder, newest first, and the entry field. An entry gets the day and time of the moment it is
/// added (W2). Writes go to the base's commit queue like notebook saves (U2); the watcher reads
/// the days again after an outside edit (Obsidian, `akit worklog add`).
@MainActor
@Observable
final class WorkLogModel {
    let knowledge: KnowledgeModel

    /// The days on screen, newest first, with their file's text; today is always first.
    private(set) var days: [(date: String, text: String)] = []
    /// The days before today, parsed once per change of their file (their lengths don't move).
    private(set) var pastDays: [KnowledgeWorkLog.Day] = []
    /// The minute the screen shows: today's last entry runs until it (`tick`).
    private(set) var now = Date.now
    /// Today with its lengths up to `now`: the only day redrawn every minute.
    var today: KnowledgeWorkLog.Day? {
        days.first.map { KnowledgeWorkLog.day($0.date, text: $0.text, now: now) }
    }
    /// Days are shown a page at a time: today and the latest `shownDays` days with entries.
    static let pageSize = 14
    var shownDays = pageSize
    /// Days with entries not shown yet (Show More Days, Go to Day…).
    private(set) var remainingDays = 0
    /// The day Go to Day… asked for: the list scrolls to it.
    var scrollTarget: String?
    /// File texts as last read, by path, with the file's change date and size: a reload reads
    /// only files that changed, so many days stay cheap.
    @ObservationIgnored private var fileCache: [String: (modified: Date?, size: Int?, text: String)] = [:]
    @ObservationIgnored private var dayCache: [String: KnowledgeWorkLog.Day] = [:]
    /// The entry field and the chosen kind (nil: none, or a `#tag` typed in the text).
    var text = ""
    var kind: String?
    /// Bumped to put the cursor in the entry field (the screen opens, ⌘L, a link).
    var focusRequest = 0
    var notice: String?
    var problem: String?
    /// An entry in Edit…; Delete… waiting for its confirmation.
    struct EditRequest: Identifiable, Equatable {
        var date: String
        var entry: KnowledgeWorkLog.Entry
        var id: String { "\(date) \(entry.line)" }
    }
    var editRequest: EditRequest?
    var deleteRequest: EditRequest?

    /// Per base folder and base-relative path: the hash of the bytes AKit last wrote.
    private var written: [String: String] = [:]
    /// The own-write rule of the base in view: base-relative path → hash.
    var ownHashes: [String: String] {
        guard let root = knowledge.base?.root.path else { return [:] }
        return written.reduce(into: [:]) { own, pair in
            let parts = pair.key.split(separator: "\n", maxSplits: 1).map(String.init)
            if parts.count == 2, parts[0] == root { own[parts[1]] = pair.value }
        }
    }
    /// An `akit://worklog/add?…` link that came before the bases were read.
    private var pendingAdd: (text: String, kind: String?)?

    private(set) static weak var current: WorkLogModel?

    init(knowledge: KnowledgeModel) {
        self.knowledge = knowledge
        Self.current = self
    }

    var worklog: KnowledgeWorkLog? { knowledge.base.map(KnowledgeWorkLog.init) }

    /// The screen appears: the bases are read (once), then the days.
    func load() async {
        await knowledge.loadIfNeeded()
        reload()
        if let pendingAdd {
            self.pendingAdd = nil
            add(pendingAdd.text, kind: pendingAdd.kind)
        }
        // Snapshots: `--query` fills the entry field, or with `--tab worklog-fill` names the Auto-Fill day.
        if let query = DebugSnapshot.options?.query, DebugSnapshot.options?.section == .worklog {
            if tab == .autoFill, let day = KnowledgeWorkLog.date(query) { fillDay = day }
            else if tab == .calendar, let day = KnowledgeWorkLog.date(query) {
                calendarAnchor = day
                if DebugSnapshot.options?.tab == "worklog-calendar-day" { calendarDay = query }
            } else if tab == .report, let day = KnowledgeWorkLog.date(query) {
                reportAnchor = day
                if DebugSnapshot.options?.tab == "worklog-report-month" { reportPeriod = .month }
            } else { text = query }
        }
        if let tab = DebugSnapshot.options?.tab, tab.hasPrefix("worklog-kind-") { kind = String(tab.dropFirst("worklog-kind-".count)) }
        // Snapshots: `--tab worklog-edit` opens Edit… for the last entry of the newest day with entries.
        if DebugSnapshot.options?.tab == "worklog-edit", let day = days.first(where: { !KnowledgeWorkLog.entries(in: $0.text).isEmpty }),
           let entry = KnowledgeWorkLog.entries(in: day.text).last {
            editRequest = EditRequest(date: day.date, entry: entry)
        }
        focusRequest += 1
    }

    /// The days again from disk: today first (empty or not), then the latest days with a file.
    func reload() {
        guard let worklog else {
            (days, pastDays) = ([], [])
            return
        }
        now = .now
        let today = KnowledgeWorkLog.stamp(now).day
        let found = worklog.days().filter { $0 != today }
        remainingDays = max(0, found.count - shownDays)
        var read: [(date: String, text: String)] = []
        for date in [today] + found.prefix(shownDays) {
            do { read.append((date, try cachedText(date, in: worklog))) } catch { problem = error.message }
        }
        days = read
        revision += 1
        // Only the days on screen stay in the parse cache.
        var kept: [String: KnowledgeWorkLog.Day] = [:]
        pastDays = read.dropFirst().map { date, text in
            let key = worklog.base.root.path + "\n" + date + "\n" + KnowledgeWrite.hash(Data(text.utf8))
            let day = dayCache[key] ?? KnowledgeWorkLog.day(date, text: text, now: now)
            kept[key] = day
            return day
        }
        dayCache = kept
    }

    /// A day's text, read again only when its file's change date or size moved.
    func cachedText(_ date: String, in worklog: KnowledgeWorkLog) throws(KnowledgeBase.Failure) -> String {
        let file = worklog.file(date)
        let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        if let cached = fileCache[file.path], values != nil, cached.modified == values?.contentModificationDate, cached.size == values?.fileSize {
            return cached.text
        }
        let text = try worklog.text(date)
        fileCache[file.path] = (values?.contentModificationDate, values?.fileSize, text)
        return text
    }

    /// Show More Days: the next page.
    func showMore() {
        shownDays += Self.pageSize
        reload()
    }

    /// Go to Day…: that day's section, loading pages up to it; a notice when it has no entries.
    func goTo(_ date: Date) {
        let day = KnowledgeWorkLog.stamp(date).day
        guard let worklog else { return }
        let today = KnowledgeWorkLog.stamp(.now).day
        let found = worklog.days().filter { $0 != today }
        if day != today {
            guard let index = found.firstIndex(of: day) else {
                notice = "No entries on \(day)."
                return
            }
            if index >= shownDays { shownDays = (index / Self.pageSize + 1) * Self.pageSize }
        }
        reload()
        scrollTarget = day
        tab = .log
    }

    /// Every minute: today's running entry grows; after midnight the new day gets its section.
    func tick() async {
        while !Task.isCancelled {
            let seconds = 60 - Calendar.current.component(.second, from: .now)
            try? await Task.sleep(for: .seconds(seconds))
            if KnowledgeWorkLog.stamp(.now).day != days.first?.date { reload() } else { now = .now }
        }
    }

    // MARK: - Writing

    /// Enter in the entry field: today, now, the chosen kind. The field empties and the kind resets.
    func addFromField() {
        if add(text, kind: kind) {
            text = ""
            kind = nil
        }
    }

    /// An `akit://worklog[/add]` link: the kind (checked, lowercased) is chosen, or the entry is
    /// added; the cursor goes to the field.
    func open(kind: String?, add text: String?) {
        let kind = (try? KnowledgeWorkLog.checkedKind(kind)) ?? nil
        if let text { addFromLink(text: text, kind: kind) } else if let kind { self.kind = kind }
        focusRequest += 1
    }

    /// An `akit://worklog/add?text=…&kind=…` link: added now, or when the bases are read.
    func addFromLink(text: String, kind: String?) {
        guard knowledge.loaded else {
            pendingAdd = (text, kind)
            return
        }
        add(text, kind: kind)
    }

    @discardableResult
    func add(_ text: String, kind: String?) -> Bool {
        guard let worklog else {
            problem = "The work log lives in a knowledge base. Create a base on the Knowledge screen first."
            return false
        }
        do {
            let added = try worklog.add(text, kind: kind, at: .now)
            saved(added.path, added.hash, in: worklog)
            notice = "Added \(added.entry.time)" + (added.entry.kind.map { " #\($0)" } ?? "")
            return true
        } catch {
            problem = error.message
            return false
        }
    }

    /// Meetings → Add to Work Log (docs/design/meetings.md, M25): a `#meeting` line at the
    /// meeting's start, with its summary.
    func addMeeting(_ text: String, at date: Date, summary: String?) throws(KnowledgeBase.Failure) {
        guard let worklog else {
            throw KnowledgeBase.Failure(message: "The work log lives in a knowledge base. Create a base on the Knowledge screen first.")
        }
        let (day, time) = KnowledgeWorkLog.stamp(date)
        let added = try worklog.add(text, kind: "meeting", day: day, time: time, summary: summary)
        saved(added.path, added.hash, in: worklog)
    }

    /// Again Now: the same kind and text, now (back to something you left).
    func again(_ entry: KnowledgeWorkLog.Entry) {
        add(entry.text, kind: entry.kind)
    }

    /// Edit… → Save: the entry's new time, kind and text, in time order.
    @discardableResult
    func replace(_ request: EditRequest, with entry: KnowledgeWorkLog.Entry) -> Bool {
        guard let worklog else { return false }
        do {
            let (path, hash) = try worklog.replace(request.entry, on: request.date, with: entry)
            saved(path, hash, in: worklog)
            notice = "Changed the entry of \(request.entry.time)."
            return true
        } catch {
            problem = error.message
            reload()
            return false
        }
    }

    func delete(_ request: EditRequest) {
        guard let worklog else { return }
        do {
            let (path, hash) = try worklog.remove(request.entry, on: request.date)
            saved(path, hash, in: worklog)
            notice = "Deleted the entry of \(request.entry.time); the base's git keeps it."
        } catch {
            problem = error.message
            reload()
        }
    }

    private func saved(_ path: String, _ hash: String, in worklog: KnowledgeWorkLog) {
        written[worklog.base.root.path + "\n" + path] = hash
        knowledge.enqueueEdit(path, in: worklog.base)
        reload()
    }

    // MARK: - Auto-Fill (W8)

    enum Tab: String, CaseIterable { case log = "Log", calendar = "Calendar", report = "Report", autoFill = "Auto-Fill" }
    var tab: Tab = {
        let tab = DebugSnapshot.options?.tab ?? ""
        if tab.hasPrefix("worklog-fill") { return .autoFill }
        if tab.hasPrefix("worklog-calendar") { return .calendar }
        if tab.hasPrefix("worklog-report") { return .report }
        return .log
    }()

    // MARK: - Calendar and report (W11–W13)

    /// A day of the week on screen; the calendar shows its week (Monday first).
    var calendarAnchor = Date.now
    /// The day the calendar shows alone; nil shows the week.
    var calendarDay: String?
    var showWeekend = UserDefaults.standard.bool(forKey: "worklogShowWeekend") {
        didSet { UserDefaults.standard.set(showWeekend, forKey: "worklogShowWeekend") }
    }
    /// Bumped by every write and reload: the calendar and report read their days again.
    private(set) var revision = 0
    /// A new block waiting for its kind and text (a drag in the calendar, New Block…).
    struct BlockRequest: Identifiable, Equatable {
        var date: String
        var start: Int
        var end: Int
        var id: String { "\(date) \(start) \(end)" }
    }
    var blockRequest: BlockRequest?
    var importRequest: [String]?
    var reportPeriod: KnowledgeWorkLog.Period = .week
    var reportAnchor = Date.now
    /// A work day's norm, from the base's settings.
    var hours: Double { _ = revision; return worklog?.hours() ?? KnowledgeWorkLog.defaultHours }

    /// The days of the calendar's week (Monday to Friday, or to Sunday), or the one chosen day.
    var calendarDates: [String] {
        if let calendarDay { return [calendarDay] }
        let week = KnowledgeWorkLog.range(.week, containing: calendarAnchor)
        guard let start = KnowledgeWorkLog.date(week.from) else { return [] }
        return (0..<(showWeekend ? 7 : 5)).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: start) }
            .map { KnowledgeWorkLog.stamp($0).day }
    }

    /// A day as the calendar draws it; today follows the clock.
    func dayOnCalendar(_ date: String) -> KnowledgeWorkLog.Day {
        _ = revision
        let text = worklog.flatMap { try? cachedText(date, in: $0) } ?? ""
        return KnowledgeWorkLog.day(date, text: text, now: now)
    }

    /// ‹ and ›: a week (or a day) back or on.
    func moveCalendar(_ step: Int) {
        if let day = calendarDay, let date = KnowledgeWorkLog.date(day),
           let moved = Calendar.current.date(byAdding: .day, value: step, to: date) {
            calendarDay = KnowledgeWorkLog.stamp(moved).day
            calendarAnchor = moved
        } else if let moved = Calendar.current.date(byAdding: .day, value: 7 * step, to: calendarAnchor) {
            calendarAnchor = moved
        }
    }

    func calendarToday() {
        calendarAnchor = .now
        if calendarDay != nil { calendarDay = KnowledgeWorkLog.stamp(.now).day }
    }

    /// New Block → Add: a block with its own start and end.
    @discardableResult
    func addBlock(_ request: BlockRequest, kind: String?, text: String) -> Bool {
        guard let worklog else { return false }
        do {
            let added = try worklog.add(text, kind: kind, day: request.date, time: KnowledgeWorkLog.time(request.start),
                                        end: Self.endText(request.end))
            saved(added.path, added.hash, in: worklog)
            notice = "Added \(added.entry.time)-\(added.entry.end ?? "") on \(request.date)."
            return true
        } catch {
            problem = error.message
            return false
        }
    }

    /// A drag moved or stretched a block: same kind and text, new times.
    func moveBlock(_ entry: KnowledgeWorkLog.Entry, on date: String, start: Int, end: Int) {
        var moved = entry
        moved.time = KnowledgeWorkLog.time(start)
        moved.end = Self.endText(end)
        guard moved != entry else { return }
        replace(EditRequest(date: date, entry: entry), with: moved)
    }

    static func endText(_ minute: Int) -> String { minute >= 24 * 60 ? "24:00" : KnowledgeWorkLog.time(minute) }

    /// Work day: the base's norm (worklog/settings.yaml).
    func setHours(_ hours: Double) {
        guard let worklog, hours != worklog.hours() else { return }
        do {
            let path = try worklog.setHours(hours)
            knowledge.enqueueEdit(path, in: worklog.base)
            notice = "A work day has \(KnowledgeWorkLog.hoursText(hours)) h now."
            reload()
        } catch { problem = error.message }
    }

    /// One day's own norm; nil goes back to the default.
    func setNorm(_ hours: Double?, on date: String) {
        guard let worklog else { return }
        do {
            let (path, hash) = try worklog.setNorm(hours, on: date)
            saved(path, hash, in: worklog)
            notice = hours.map { "\(date) has a norm of \(KnowledgeWorkLog.hoursText($0)) h." } ?? "\(date) has the default norm again."
        } catch { problem = error.message }
    }

    var reportRange: (from: String, to: String) { KnowledgeWorkLog.range(reportPeriod, containing: reportAnchor) }

    var report: KnowledgeWorkLog.Report? {
        _ = revision
        let range = reportRange
        return try? worklog?.report(from: range.from, to: range.to, now: now)
    }

    func moveReport(_ step: Int) {
        let component: Calendar.Component = reportPeriod == .week ? .weekOfYear : .month
        reportAnchor = Calendar.current.date(byAdding: component, value: step, to: reportAnchor) ?? reportAnchor
    }

    /// Import from Calendar → Add Selected: the ticked events become blocks.
    func addEvents(_ events: [CalendarEvents.Event], kind: String) {
        guard let worklog else { return }
        var added = 0, skipped = 0
        for event in events {
            let present = (try? worklog.day(event.date).entries) ?? []
            if present.contains(where: { $0.minute == event.start && $0.endMinute == event.end && $0.text == event.title }) {
                skipped += 1
                continue
            }
            do {
                let result = try worklog.add(event.title, kind: kind, day: event.date, time: KnowledgeWorkLog.time(event.start),
                                             end: Self.endText(event.end))
                saved(result.path, result.hash, in: worklog)
                added += 1
            } catch {
                problem = error.message
                break
            }
        }
        notice = "Added \(added) meetings from Calendar" + (skipped > 0 ? "; \(skipped) were there already." : ".")
    }

    enum FillSource: String, CaseIterable {
        case all = "All Harnesses", claude = "Claude Code", pi = "Pi"
        var harnesses: Set<HarnessID> {
            switch self {
            case .all: [.claudeCode, .pi]
            case .claude: [.claudeCode]
            case .pi: [.pi]
            }
        }
    }

    var fillDay = Date.now
    /// Pi's thinking level for Auto-Fill (low by default), remembered between launches.
    var fillThinking = UserDefaults.standard.string(forKey: "worklogFillThinking") ?? WorkLogFill.defaultThinking {
        didSet { UserDefaults.standard.set(fillThinking, forKey: "worklogFillThinking") }
    }
    /// The entries' language: Czech by default (the user's choice), remembered between launches.
    var fillLanguage = LabLanguage(rawValue: UserDefaults.standard.string(forKey: "worklogFillLanguage") ?? "") ?? .czech {
        didSet { UserDefaults.standard.set(fillLanguage.rawValue, forKey: "worklogFillLanguage") }
    }
    var fillSource: FillSource = .all
    var fillSlot = 30
    /// "" = the default (GPT-6 Luna); remembered between launches.
    var fillModel = UserDefaults.standard.string(forKey: "worklogFillModel") ?? "" {
        didSet { UserDefaults.standard.set(fillModel, forKey: "worklogFillModel") }
    }
    /// Pi's models, as the picker offers them (GitHub Copilot's when Pi lists any).
    private(set) var fillModels: [String] = []
    private(set) var availableModels: [String] = []
    /// What the chosen day holds, read locally before anything is sent.
    private(set) var fillSlots: [WorkLogFill.Slot] = []
    private(set) var fillSessions: [SessionSummary] = []
    private(set) var fillReading = false
    private(set) var fillRunning = false
    /// The model's proposals and the ones ticked for Add.
    var proposals: [KnowledgeWorkLog.Entry] = []
    var chosen: Set<Int> = []
    /// The model and day of the proposals on screen; `proposalDay` is the day they go into.
    private(set) var proposalNote: String?
    private(set) var proposalDay: String?
    /// Bumped by each answer: the list starts fresh (every summary open again).
    private(set) var proposalGeneration = 0

    /// What the proposals depend on: a new day, source or slot drops them.
    var fillKey: String { "\(fillDayString) \(fillSource.rawValue) \(fillSlot)" }

    func clearProposals() {
        (proposals, chosen, proposalNote, proposalDay) = ([], [], nil, nil)
    }

    var fillDayString: String { KnowledgeWorkLog.stamp(fillDay).day }

    func loadModels() async {
        guard availableModels.isEmpty else { return }
        availableModels = await LabRuns.models(for: .pi, env: .current)
        fillModels = WorkLogFill.offered(availableModels)
    }

    var defaultModel: String? { WorkLogFill.defaultModel(available: availableModels) }

    /// The day's prompts in slots, read from the sessions on this Mac (nothing is sent).
    func readDay(_ all: [SessionSummary]) async {
        fillReading = true
        let day = fillDayString, harnesses = fillSource.harnesses, minutes = fillSlot
        // A calendar block holds its time: its prompts aren't shown or sent (W11).
        let blocks = ((try? worklog?.day(day).entries) ?? []).filter(\.isBlock)
        let (sessions, slots) = await Task.detached {
            let sessions = WorkLogFill.sessions(all, day: day, harnesses: harnesses)
            return (sessions, WorkLogFill.slots(WorkLogFill.uncovered(WorkLogFill.moments(sessions, day: day), blocks: blocks), minutes: minutes))
        }.value
        guard day == fillDayString, harnesses == fillSource.harnesses, minutes == fillSlot else { return }
        (fillSessions, fillSlots, fillReading) = (sessions, slots, false)
    }

    /// Propose Entries: the slots go to the model; the proposals come back ticked.
    func propose() async {
        guard !fillRunning else { return }
        fillRunning = true
        defer { fillRunning = false }
        let day = fillDayString, key = fillKey
        let existing = (try? worklog?.day(day).entries) ?? []
        do {
            let result = try await WorkLogFill.propose(day: day, sessions: fillSessions, existing: existing, model: fillModel,
                                                       slotMinutes: fillSlot, language: fillLanguage,
                                                       thinking: fillThinking, env: .current)
            // The day, source or slot changed during the call: the answer is for another view.
            guard key == fillKey else {
                notice = "The answer for \(day) came after you changed the day; nothing is shown. Propose again."
                return
            }
            proposals = result.entries
            proposalDay = day
            proposalGeneration += 1
            chosen = Set(proposals.indices)
            proposalNote = "\(result.entries.count) entries for \(day) from \(result.prompts) prompts, by \(result.model)."
        } catch {
            problem = error.message
        }
    }

    /// Add Selected: the ticked proposals go into the day's file with their own times.
    func addProposals() {
        guard let worklog, !proposals.isEmpty, let day = proposalDay else { return }
        func plain(_ entry: KnowledgeWorkLog.Entry) -> KnowledgeWorkLog.Entry { .init(time: entry.time, kind: entry.kind, text: entry.text) }
        let present = Set(((try? worklog.day(day).entries) ?? []).map(plain))
        var added = 0, skipped = 0, failed = false
        var left: [KnowledgeWorkLog.Entry] = []
        for (index, entry) in proposals.enumerated() {
            // Unticked ones, and all after a failed write, stay to try again.
            guard chosen.contains(index), !failed else { left.append(entry); continue }
            // The same entry is in the log already: not added twice.
            if present.contains(plain(entry)) { skipped += 1; continue }
            do {
                let result = try worklog.add(entry.text, kind: entry.kind, day: day, time: entry.time, summary: entry.summary)
                saved(result.path, result.hash, in: worklog)
                added += 1
            } catch {
                problem = error.message
                failed = true
                left.append(entry)
            }
        }
        notice = "Added \(added) entries to \(day)" + (skipped > 0 ? "; \(skipped) were there already." : ".")
        if !failed {
            clearProposals()
            tab = .log
        } else {
            // What wasn't added stays, ticked, to try again.
            proposals = left
            chosen = Set(left.indices)
        }
    }

    /// The watcher saw a change under `worklog/`.
    func changedOnDisk() { reload() }
}
