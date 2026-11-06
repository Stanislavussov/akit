import Foundation
import MeetingsAudio
import MeetingsCore
import Observation

/// What the editor shows: one page of a meeting (Summary or an own tab), the folder its
/// `assets/…` pictures live in, and a generation that a reload raises.
public struct MeetingsPage: Equatable, Sendable {
    public var key: String
    public var text: String
    public var generation: Int
    /// `<meeting>/tabs`: a page's `assets/…` links are relative to it.
    public var folder: URL
    public var meetingID: String
}

/// The screen's state. One per app run: a recording goes on while the user looks at other screens.
@MainActor @Observable
public final class MeetingsModel {
    public static let summaryTab = "Summary"
    public static let transcriptTab = "Transcript"

    public private(set) var settings: MeetingsSettings
    public private(set) var meetings: [Meeting] = []
    public private(set) var selectedID: String?
    public private(set) var selectedTab = summaryTab
    public private(set) var page: MeetingsPage?
    public private(set) var recordingID: String?
    public private(set) var recordingStarted: Date?
    public private(set) var starting = false
    public private(set) var processing: Set<String> = []
    public private(set) var hasKey = false
    /// The answer of the last key check, when OpenRouter refused the key.
    public private(set) var keyProblem: String?
    public private(set) var audioModels: [ModelCatalog.Row] = []
    public private(set) var textModels: [ModelCatalog.Row] = []
    public private(set) var modelsProblem: String?
    public private(set) var loadingModels = false
    public var problem: String?
    public var notice: String?
    /// M23: the list's search field (`#tag` words filter by tag) and each meeting's searchable text.
    public var searchText = ""
    public private(set) var documents: [String: MeetingSearch.Document] = [:]
    /// M24: the questions' costs, and the Ask chat.
    public private(set) var askEntries: [AskLog.Entry] = []
    public var showAsk = false
    public var askScope: MeetingAsk.Scope = .days(30)
    public var askTag: String?
    public private(set) var askTurns: [AskTurn] = []
    public private(set) var asking = false

    public struct AskTurn: Identifiable, Equatable {
        public let id = UUID()
        public var question: String
        public var scope: String
        public var answer: String?
        /// `[n]` → meeting id of the marks the answer uses.
        public var sources: [Int: String] = [:]
        public var problem: String?
        public var cost: Double = 0
        public var meetings = 0
    }
    @ObservationIgnored private var indexGeneration = 0
    /// Sheets and dialogs the view shows.
    public var showSettings = false
    public var showCosts = false
    public var tabNameRequest: TabNameRequest?
    public var trashRequest: String?
    public var removeTabRequest: String?
    public var renameSpeakersRequest = false

    public struct TabNameRequest: Identifiable, Equatable {
        public var id: String { old ?? "+" }
        public var old: String?
        public init(old: String?) { self.old = old }
    }

    let settingsFile: URL
    let keyStore: KeyStore
    let transport: OpenRouterClient.Transport
    private var recorder: Recorder?
    private var generation = 0
    @ObservationIgnored private var savedText: (key: String, text: String)?
    private var loaded = false

    public init(settingsFile: URL = MeetingsSettings.defaultFile, keyStore: KeyStore = KeyStore(),
                transport: @escaping OpenRouterClient.Transport = { try await URLSession.shared.data(for: $0) }) {
        self.settingsFile = settingsFile
        self.keyStore = keyStore
        self.transport = transport
        settings = MeetingsSettings.load(from: settingsFile)
    }

    var store: MeetingStore { MeetingStore(root: settings.root) }
    public var root: URL { settings.root }
    public var isRecording: Bool { recordingID != nil }
    /// The live waves while it records (read by the screen several times a second).
    public var levels: (mic: [Float], system: [Float]) { recorder?.levels ?? ([], []) }
    public var selected: Meeting? { meetings.first { $0.id == selectedID } }
    public var monthCost: Double {
        let calendar = Calendar.current
        return meetings.filter { calendar.isDate($0.started, equalTo: Date(), toGranularity: .month) }.reduce(0) { $0 + $1.costUSD }
            + askEntries.filter { calendar.isDate($0.date, equalTo: Date(), toGranularity: .month) }.reduce(0) { $0 + $1.costUSD }
    }

    /// The meetings by day, newest day first; while the search field has text, only the ones
    /// that match (a meeting not indexed yet shows until its text is read).
    public var days: [(day: Date, meetings: [Meeting])] {
        let calendar = Calendar.current
        let query = MeetingSearch.Query(searchText)
        let shown = query.isEmpty ? meetings : meetings.filter { meeting in
            documents[meeting.id].map { MeetingSearch.match($0, query) != nil } ?? true
        }
        let groups = Dictionary(grouping: shown) { calendar.startOfDay(for: $0.started) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0]!.sorted { $0.started > $1.started }) }
    }

    /// Where a meeting matched the search field, for its row.
    public func hit(_ id: String) -> MeetingSearch.Hit? {
        let query = MeetingSearch.Query(searchText)
        guard !query.isEmpty, let document = documents[id] else { return nil }
        return MeetingSearch.match(document, query)
    }

    /// Every tag with how many meetings have it, most used first.
    public var allTags: [(tag: String, count: Int)] {
        var counts: [String: Int] = [:]
        for meeting in meetings { for tag in meeting.tagList { counts[tag, default: 0] += 1 } }
        return counts.map { ($0.key, $0.value) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.tag < $1.tag }
    }

    /// The search field with only this tag (a click on a tag), or without it again.
    public func filter(tag: String) {
        let word = "#" + tag.replacingOccurrences(of: " ", with: "")
        searchText = searchText == word ? "" : word
    }

    // MARK: Loading

    /// First show (also at app start): the key, the list, audio past its 14 days to the Trash,
    /// recordings left by a quit or a crash mixed and queued, waiting meetings transcribed. A
    /// meeting whose lock another host holds (the other Meetings app records or transcribes it)
    /// is left alone (H2).
    public func load() async {
        hasKey = keyStore.hasKey
        refresh()
        guard !loaded else { return }
        loaded = true
        let store = self.store
        Task.detached { store.trashExpiredAudio() }
        for meeting in meetings where meeting.id != recordingID {
            switch meeting.state {
            case .recording:
                let folder = store.audioFolder(meeting.id)
                let recovered = await Task.detached { Recorder.recover(folder: folder) }.value
                guard let recovered, var copy = store.load(meeting.id) else { continue }
                copy.duration = recovered.seconds
                copy.state = .waiting
                if !recovered.problems.isEmpty { copy.warnings = (copy.warnings ?? []) + recovered.problems }
                try? store.save(copy)
            case .transcribing:
                guard MeetingLock.isFree(MeetingLock.processing(store, meeting.id)), var copy = store.load(meeting.id) else { continue }
                copy.state = .waiting
                try? store.save(copy)
            default: break
            }
        }
        refresh()
        if selectedID == nil, let first = meetings.first { select(first.id) }
        if hasKey {
            for meeting in meetings where meeting.state == .waiting { process(meeting.id) }
        }
    }

    public func refresh() {
        meetings = store.list()
        askEntries = AskLog(root: settings.root).entries()
        if let id = selectedID, !meetings.contains(where: { $0.id == id }) {
            selectedID = nil
            page = nil
        }
        reindex()
    }

    /// Reads every meeting's text for search off the main thread; a newer call wins.
    func reindex(only id: String? = nil) {
        if id == nil { indexGeneration += 1 }
        let generation = indexGeneration
        let store = self.store
        let chosen = id.map { id in meetings.filter { $0.id == id } } ?? meetings
        Task {
            let found = await Task.detached { chosen.map { MeetingSearch.document($0, store: store) } }.value
            // A newer full read replaces an older one; one meeting's read always lands.
            guard id != nil || generation == indexGeneration else { return }
            if id == nil {
                documents = Dictionary(found.map { ($0.id, $0) }) { a, _ in a }
            } else {
                for document in found { documents[document.id] = document }
            }
        }
    }

    // MARK: Recording (M3)

    public func record() async {
        guard !isRecording, !starting else { return }
        starting = true
        defer { starting = false }
        do {
            let meeting = try store.create(template: settings.defaultTemplate)
            // The lock right after the meeting exists, so the other host never takes it for a crash.
            let held = MeetingLock.take(Recorder.lockFile(store.audioFolder(meeting.id)))
            let recorder = Recorder(folder: store.audioFolder(meeting.id), echoCancellation: settings.echoCancellation, lock: held) { [weak self] text in
                Task { @MainActor in self?.problem = text }
            }
            do {
                try await recorder.start()
            } catch {
                try? store.moveToTrash(meeting.id)
                throw error
            }
            self.recorder = recorder
            recordingID = meeting.id
            recordingStarted = Date()
            refresh()
            select(meeting.id)
        } catch {
            problem = "Could not start the recording: \(error.localizedDescription)"
        }
    }

    public func stop() async {
        guard let id = recordingID, let recorder else { return }
        let result = await recorder.stop()
        self.recorder = nil
        recordingID = nil
        recordingStarted = nil
        if var meeting = store.load(id) {
            meeting.duration = result.seconds
            meeting.state = .waiting
            if !result.problems.isEmpty { meeting.warnings = (meeting.warnings ?? []) + result.problems }
            try? store.save(meeting)
        }
        refresh()
        if !result.problems.isEmpty { problem = result.problems.joined(separator: " ") }
        if hasKey {
            process(id)
        } else {
            notice = "Recorded \(lengthText(result.seconds)). Add your OpenRouter key in Settings to transcribe it."
        }
        if selectedID == id { reloadPage() }
    }

    /// `akit://meetings/record`, `/stop`, `/toggle` (a Raycast quicklink or a hotkey).
    public func perform(_ action: String) async {
        switch action.lowercased() {
        case "record", "start": await record()
        case "stop": await stop()
        case "toggle": if isRecording { await stop() } else { await record() }
        default: break
        }
    }

    // MARK: Transcription

    /// Transcribes in the background; `restart` starts the transcript over (Transcribe Again).
    /// `byUser`: a click (Try Again, Transcribe Again), which gets a notice when the other
    /// Meetings app is already on it.
    public func process(_ id: String, restart: Bool = false, byUser: Bool = false) {
        guard !processing.contains(id) else { return }
        guard let key = keyStore.read() else {
            problem = MeetingsError.noKey.errorDescription
            return
        }
        processing.insert(id)
        let client = OpenRouterClient(key: key, transport: transport)
        let processor = MeetingProcessor(store: store, settings: settings, client: client) { [weak self] meeting in
            Task { @MainActor in self?.updated(meeting) }
        }
        Task {
            do {
                _ = try await processor.run(id, restart: restart)
            } catch MeetingsError.busy {
                // The other Meetings app transcribes it; its saves show up on the next refresh.
                if byUser { notice = MeetingsError.busy.errorDescription }
            } catch MeetingsError.http(401, _) {
                problem = (MeetingsError.http(401, "").errorDescription ?? "") + " " + KeyStore.shape(key)
            } catch {
                problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            processing.remove(id)
            refresh()
            if selectedID == id { reloadPage() }
        }
    }

    /// M22: only the summary again (a new template): one text call over the transcript.
    public func summarizeAgain(_ id: String) {
        guard !processing.contains(id) else { return }
        guard let key = keyStore.read() else {
            problem = MeetingsError.noKey.errorDescription
            return
        }
        processing.insert(id)
        let processor = MeetingProcessor(store: store, settings: settings, client: OpenRouterClient(key: key, transport: transport)) { [weak self] meeting in
            Task { @MainActor in self?.updated(meeting) }
        }
        Task {
            do {
                _ = try await processor.summarizeAgain(id)
            } catch MeetingsError.busy {
                notice = MeetingsError.busy.errorDescription
            } catch {
                problem = "The summary was not written again: " + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
            processing.remove(id)
            refresh()
            if selectedID == id { reloadPage() }
        }
    }

    /// M22: a new template for the selected meeting; a done one gets its summary written again.
    public func setTemplate(_ templateID: String) {
        guard var meeting = fresh, meeting.template != templateID else { return }
        do {
            try store.setTemplate(&meeting, templateID)
            updated(meeting)
            if meeting.state == .done, !meeting.segments.isEmpty, hasKey {
                notice = "Writing the summary again as \(settings.template(templateID).name)…"
                summarizeAgain(meeting.id)
            }
        } catch {
            problem = error.localizedDescription
        }
    }

    /// M23: the selected meeting's tags.
    public func setTags(_ tags: [String]) {
        guard var meeting = fresh else { return }
        do {
            try store.setTags(&meeting, tags)
            updated(meeting)
            reindex(only: meeting.id)
        } catch {
            problem = error.localizedDescription
        }
    }

    // MARK: Ask (M24)

    /// Ask… from the toolbar (`meetingID` nil) or About This Meeting….
    public func openAsk(meetingID: String? = nil) {
        if let meetingID {
            if askScope != .meeting(meetingID) { askTurns = [] }
            askScope = .meeting(meetingID)
        } else if case .meeting = askScope {
            askScope = .days(30)
            askTurns = []
        }
        showAsk = true
    }

    public func newChat() { askTurns = [] }

    /// One question over the meetings of the scope; earlier answers of the chat go with it.
    public func ask(_ question: String) async {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !asking else { return }
        let chosen = MeetingAsk.meetings(meetings, scope: askScope, tag: askTag)
        var turn = AskTurn(question: question, scope: askScopeTitle)
        turn.meetings = chosen.count
        let history = askTurns.compactMap { turn in turn.answer.map { MeetingAsk.Turn(question: turn.question, answer: $0) } }
        guard let key = keyStore.read() else {
            turn.problem = MeetingsError.noKey.errorDescription
            askTurns.append(turn)
            return
        }
        guard !chosen.isEmpty else {
            turn.problem = "No transcribed meeting in this scope. Choose a longer time or another tag."
            askTurns.append(turn)
            return
        }
        guard monthCost < settings.monthlyLimitUSD else {
            turn.problem = MeetingsError.monthlyLimit(settings.monthlyLimitUSD).errorDescription
            askTurns.append(turn)
            return
        }
        askTurns.append(turn)
        asking = true
        defer { asking = false }
        let turnID = turn.id
        let store = self.store
        let known = documents
        let context = await Task.detached {
            var documents = known
            for meeting in chosen where documents[meeting.id] == nil { documents[meeting.id] = MeetingSearch.document(meeting, store: store) }
            return MeetingAsk.context(chosen, documents: documents, question: question)
        }.value
        let asker = MeetingAsk(client: OpenRouterClient(key: key, transport: transport), settings: settings)
        MeetingsLog.info(.ask, "ask: \(chosen.count) meetings in scope, \(context.ids.count) sent, \(context.text.count) chars, \(history.count) earlier turns")
        do {
            let answer = try await asker.ask(question, context: context, history: history)
            let entry = AskLog.Entry(date: Date(), model: settings.summaryModel ?? settings.model, promptTokens: answer.completion.promptTokens,
                                     completionTokens: answer.completion.completionTokens, costUSD: answer.completion.cost)
            do { try AskLog(root: settings.root).append(entry) } catch { MeetingsLog.error(.ask, "ask: cost not logged: \(error.localizedDescription)") }
            askEntries.append(entry)
            MeetingsLog.info(.ask, "ask: answered, \(answer.sources.count) meetings cited, $\(answer.completion.cost)")
            // New Chat while it waited: the cost is kept, the answer has no turn to go to.
            guard let index = askTurns.firstIndex(where: { $0.id == turnID }) else { return }
            askTurns[index].answer = answer.text
            askTurns[index].sources = Dictionary(answer.sources.map { ($0.number, $0.id) }) { a, _ in a }
            askTurns[index].cost = answer.completion.cost
        } catch {
            let text = if case MeetingsError.http(401, _) = error {
                (MeetingsError.http(401, "").errorDescription ?? "") + " " + KeyStore.shape(key)
            } else {
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            MeetingsLog.error(.ask, "ask: \(text)")
            if let index = askTurns.firstIndex(where: { $0.id == turnID }) { askTurns[index].problem = text }
        }
    }

    public var askScopeTitle: String {
        var title = askScope.title
        if case .meeting(let id) = askScope, let meeting = meetings.first(where: { $0.id == id }) { title = meeting.displayTitle }
        if let askTag { title += " · #" + askTag }
        return title
    }

    /// M24: the meetings most like this one (local, no model).
    public func similar(to id: String) -> [Meeting] {
        MeetingSearch.similar(to: id, in: Array(documents.values)).compactMap { hit in meetings.first { $0.id == hit.id } }
    }

    private func updated(_ meeting: Meeting) {
        if let index = meetings.firstIndex(where: { $0.id == meeting.id }) { meetings[index] = meeting }
    }

    // MARK: Selection and pages (M17)

    public func select(_ id: String?) {
        selectedID = id
        selectedTab = Self.summaryTab
        reloadPage()
    }

    public func show(tab: String) {
        selectedTab = tab
        reloadPage()
    }

    /// H5: the Summary is the model's page; while the meeting records or waits for its summary
    /// it shows the status, and notes go into an own tab.
    public var summaryLocked: Bool {
        guard let meeting = selected else { return true }
        return meeting.id == recordingID || processing.contains(meeting.id) || meeting.state == .recording
            || meeting.state == .waiting || meeting.state == .transcribing
    }

    public func reloadPage() {
        guard let meeting = selected, selectedTab != Self.transcriptTab else {
            page = nil
            return
        }
        let isSummary = selectedTab == Self.summaryTab
        if !isSummary, !meeting.tabs.contains(selectedTab) {
            selectedTab = Self.summaryTab
            return reloadPage()
        }
        let key = "\(meeting.id)#\(selectedTab)"
        let text = isSummary ? store.summary(meeting.id) : store.tab(meeting.id, selectedTab)
        // M6: the same page with the same text keeps its editor (and the typing not yet saved).
        if let page, page.key == key, page.text == text || savedText.map({ $0.key == key && $0.text == text }) == true { return }
        savedText = nil
        generation += 1
        page = MeetingsPage(key: key, text: text, generation: generation,
                            folder: store.folder(meeting.id).appending(path: "tabs", directoryHint: .isDirectory), meetingID: meeting.id)
    }

    /// A save from the editor. The key names the meeting and the tab, so a late save after a
    /// switch still lands in its own file.
    public func save(key: String, text: String) {
        guard let hash = key.lastIndex(of: "#") else { return }
        let id = String(key[..<hash]), tab = String(key[key.index(after: hash)...])
        guard let meeting = store.load(id) else { return }
        // M6: the open page's newest text, so a reload of it keeps the editor (not observed: the
        // editor already shows it).
        if page?.key == key { savedText = (key, text) }
        do {
            if tab == Self.summaryTab {
                try store.writeSummary(id, text)
            } else if meeting.tabs.contains(tab) {
                try store.writeTab(id, tab, text)
            }
            reindex(only: id)
        } catch {
            problem = "Could not save \(tab): \(error.localizedDescription)"
        }
    }

    public func imageFile(meetingID: String, link: String) -> URL? { store.tabImage(meetingID, link: link) }

    public func saveImage(meetingID: String, data: Data, ext: String) throws -> String {
        try store.saveTabImage(meetingID, data: data, ext: ext)
    }

    /// The selected meeting as it is on disk: the processor may have saved since the list loaded.
    private var fresh: Meeting? { selectedID.flatMap { store.load($0) } }

    public func addTab(_ name: String) -> Bool {
        guard var meeting = fresh else { return false }
        do {
            try store.addTab(&meeting, name: name)
            updated(meeting)
            show(tab: meeting.tabs.last ?? Self.summaryTab)
            return true
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    public func renameTab(_ old: String, to name: String) -> Bool {
        guard var meeting = fresh else { return false }
        do {
            try store.renameTab(&meeting, from: old, to: name)
            updated(meeting)
            if selectedTab == old { show(tab: name.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return true
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    public func removeTab(_ name: String) {
        guard var meeting = fresh else { return }
        do {
            try store.removeTab(&meeting, name: name)
            updated(meeting)
            if selectedTab == name { show(tab: Self.summaryTab) }
        } catch {
            problem = error.localizedDescription
        }
    }

    public func tabNameProblem(_ name: String, old: String?) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != old else { return nil }
        let taken = (selected?.tabs ?? []).filter { $0 != old }
        return MeetingStore.validTabName(trimmed, taken: taken) == nil ? MeetingsError.badTabName(trimmed).errorDescription : nil
    }

    public func renameSpeaker(_ key: String, to name: String) {
        guard var meeting = fresh else { return }
        do {
            try store.renameSpeaker(&meeting, key: key, to: name)
            updated(meeting)
            reloadPage()
        } catch {
            problem = error.localizedDescription
        }
    }

    public func moveToTrash(_ id: String) {
        guard id != recordingID else { return }
        do {
            try store.moveToTrash(id)
            if selectedID == id { select(nil) }
            refresh()
            notice = "Moved the meeting to the Trash."
        } catch {
            problem = "Could not move it to the Trash: \(error.localizedDescription)"
        }
    }

    public func audioFolder(_ id: String) -> URL { store.audioFolder(id) }
    public func folder(_ id: String) -> URL { store.folder(id) }

    // MARK: Settings (M9, M10)

    public func update(_ change: (inout MeetingsSettings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        let rootChanged = next.root != settings.root
        settings = next
        do { try settings.save(to: settingsFile) } catch { problem = "Could not save the settings: \(error.localizedDescription)" }
        if rootChanged {
            select(nil)
            refresh()
        }
    }

    public func saveKey(_ key: String) {
        MeetingsLog.info(.ui, "Save Key: the field held \(key.count) chars")
        do {
            try keyStore.save(key)
            hasKey = keyStore.hasKey
            notice = hasKey ? "The OpenRouter key is saved in the Keychain. Checking it…" : nil
            if hasKey { Task { await checkKey() } }
            if hasKey {
                Task { await loadModels() }
                for meeting in meetings where meeting.state == .waiting { process(meeting.id) }
            }
        } catch {
            problem = "Could not save the key in the Keychain: \(error.localizedDescription)"
        }
    }

    /// Asks OpenRouter whether it accepts the saved key.
    public func checkKey() async {
        guard let key = keyStore.read() else { return }
        MeetingsLog.info(.key, "check: \(KeyStore.shape(key))")
        do {
            try await OpenRouterClient(key: key, transport: transport).checkKey()
            notice = "OpenRouter accepts the key."
            keyProblem = nil
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            keyProblem = reason + " " + KeyStore.shape(key)
            notice = nil
        }
    }

    public func removeKey() {
        keyStore.delete()
        hasKey = false
    }

    /// The model Pickers' rows from OpenRouter's list.
    public func loadModels() async {
        guard !loadingModels else { return }
        loadingModels = true
        defer { loadingModels = false }
        do {
            let models = try await OpenRouterClient(key: keyStore.read() ?? "", transport: transport).models()
            audioModels = ModelCatalog.audioRows(models)
            textModels = ModelCatalog.textRows(models)
            modelsProblem = nil
        } catch {
            modelsProblem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
