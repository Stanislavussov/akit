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
    /// How many days with entries are shown; Show More adds a week.
    var shownDays = 14
    private(set) var moreDays = false
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
            if tab == .autoFill, let day = KnowledgeWorkLog.date(query) { fillDay = day } else { text = query }
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
            days = []
            return
        }
        let today = KnowledgeWorkLog.stamp(.now).day
        let found = worklog.days().filter { $0 != today }
        moreDays = found.count > shownDays
        var read: [(date: String, text: String)] = []
        for date in [today] + found.prefix(shownDays) {
            do { read.append((date, try worklog.text(date))) } catch { problem = error.message }
        }
        days = read
    }

    func showMore() {
        shownDays += 7
        reload()
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

    enum Tab: String, CaseIterable { case log = "Log", autoFill = "Auto-Fill" }
    var tab: Tab = DebugSnapshot.options?.tab?.hasPrefix("worklog-fill") == true ? .autoFill : .log

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
        let (sessions, slots) = await Task.detached {
            let sessions = WorkLogFill.sessions(all, day: day, harnesses: harnesses)
            return (sessions, WorkLogFill.slots(WorkLogFill.moments(sessions, day: day), minutes: minutes))
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
                                                       slotMinutes: fillSlot, language: fillLanguage, env: .current)
            // The day, source or slot changed during the call: the answer is for another view.
            guard key == fillKey else {
                notice = "The answer for \(day) came after you changed the day; nothing is shown. Propose again."
                return
            }
            proposals = result.entries
            proposalDay = day
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
                let result = try worklog.add(entry.text, kind: entry.kind, day: day, time: entry.time)
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
