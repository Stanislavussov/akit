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
    public private(set) var audioModels: [ModelCatalog.Row] = []
    public private(set) var textModels: [ModelCatalog.Row] = []
    public private(set) var modelsProblem: String?
    public private(set) var loadingModels = false
    public var problem: String?
    public var notice: String?
    /// Sheets and dialogs the view shows.
    public var showSettings = false
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
    public var selected: Meeting? { meetings.first { $0.id == selectedID } }
    public var monthCost: Double { meetings.filter { Calendar.current.isDate($0.started, equalTo: Date(), toGranularity: .month) }.reduce(0) { $0 + $1.costUSD } }

    /// The meetings by day, newest day first.
    public var days: [(day: Date, meetings: [Meeting])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: meetings) { calendar.startOfDay(for: $0.started) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0]!.sorted { $0.started > $1.started }) }
    }

    // MARK: Loading

    /// First show: the key, the list, audio past its 14 days to the Trash, recordings left by a
    /// quit or a crash mixed and queued, waiting meetings transcribed.
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
                var copy = meeting
                let folder = store.audioFolder(meeting.id)
                copy.duration = await Task.detached { Recorder.recover(folder: folder) }.value
                copy.state = .waiting
                try? store.save(copy)
            case .transcribing:
                var copy = meeting
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
        if let id = selectedID, !meetings.contains(where: { $0.id == id }) {
            selectedID = nil
            page = nil
        }
    }

    // MARK: Recording (M3)

    public func record() async {
        guard !isRecording, !starting else { return }
        starting = true
        defer { starting = false }
        do {
            let meeting = try store.create()
            let recorder = Recorder(folder: store.audioFolder(meeting.id), echoCancellation: settings.echoCancellation)
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
        let seconds = await recorder.stop()
        self.recorder = nil
        recordingID = nil
        recordingStarted = nil
        if var meeting = store.load(id) {
            meeting.duration = seconds
            meeting.state = .waiting
            try? store.save(meeting)
        }
        refresh()
        if hasKey {
            process(id)
        } else {
            notice = "Recorded \(lengthText(seconds)). Add your OpenRouter key in Settings to transcribe it."
        }
    }

    // MARK: Transcription

    /// Transcribes in the background; `restart` starts the transcript over (Transcribe Again).
    public func process(_ id: String, restart: Bool = false) {
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
            } catch {
                problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            processing.remove(id)
            refresh()
            if selectedID == id { reloadPage() }
        }
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

    public func reloadPage() {
        guard let meeting = selected, selectedTab != Self.transcriptTab else {
            page = nil
            return
        }
        generation += 1
        let isSummary = selectedTab == Self.summaryTab
        if !isSummary, !meeting.tabs.contains(selectedTab) {
            selectedTab = Self.summaryTab
            return reloadPage()
        }
        let text = isSummary ? store.summary(meeting.id) : store.tab(meeting.id, selectedTab)
        page = MeetingsPage(key: "\(meeting.id)#\(selectedTab)", text: text, generation: generation,
                            folder: store.folder(meeting.id).appending(path: "tabs", directoryHint: .isDirectory), meetingID: meeting.id)
    }

    /// A save from the editor. The key names the meeting and the tab, so a late save after a
    /// switch still lands in its own file.
    public func save(key: String, text: String) {
        guard let hash = key.lastIndex(of: "#") else { return }
        let id = String(key[..<hash]), tab = String(key[key.index(after: hash)...])
        guard let meeting = store.load(id) else { return }
        do {
            if tab == Self.summaryTab {
                try store.writeSummary(id, text)
            } else if meeting.tabs.contains(tab) {
                try store.writeTab(id, tab, text)
            }
        } catch {
            problem = "Could not save \(tab): \(error.localizedDescription)"
        }
    }

    public func imageFile(meetingID: String, link: String) -> URL? { store.tabImage(meetingID, link: link) }

    public func saveImage(meetingID: String, data: Data, ext: String) throws -> String {
        try store.saveTabImage(meetingID, data: data, ext: ext)
    }

    public func addTab(_ name: String) -> Bool {
        guard var meeting = selected else { return false }
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
        guard var meeting = selected else { return false }
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
        guard var meeting = selected else { return }
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
        guard var meeting = selected else { return }
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
        do {
            try keyStore.save(key)
            hasKey = keyStore.hasKey
            notice = hasKey ? "The OpenRouter key is saved in the Keychain." : nil
            if hasKey {
                Task { await loadModels() }
                for meeting in meetings where meeting.state == .waiting { process(meeting.id) }
            }
        } catch {
            problem = "Could not save the key in the Keychain: \(error.localizedDescription)"
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
