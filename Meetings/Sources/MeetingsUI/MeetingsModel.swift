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
    /// M23: what each meeting's local run does now (queued, a piece, paused …).
    public private(set) var localStatus: [String: LocalStatus] = [:]
    /// M22: whisper.cpp and its model on this Mac.
    public private(set) var whisperCLI: URL?
    public private(set) var hasWhisperModel = false
    /// The model download's progress (0…1) while it runs.
    public private(set) var modelDownload: Double?
    public private(set) var installingWhisper = false
    /// M24: Pi's models (`provider/id`), from `pi --list-models`.
    public private(set) var piModels: [String] = []
    public private(set) var loadingPiModels = false
    /// The meetings whose local run the user paused.
    public private(set) var pausedByUser: Set<String> = []
    public var problem: String?
    public var notice: String?
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
    /// The control of each running local run.
    @ObservationIgnored private var controls: [String: LocalControl] = [:]
    @ObservationIgnored private var download: URLSessionDownloadTask?
    /// M23: held while this app records, so a local run in the other app pauses too.
    @ObservationIgnored private var recordingActive: MeetingLock?
    /// The current run of each meeting; a status from an older run is dropped.
    @ObservationIgnored private var runTokens: [String: UUID] = [:]
    /// Set by Quit: no new run starts.
    @ObservationIgnored private var quitting = false
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
    /// Whether a meeting can be transcribed now: the key is there, or no step needs it.
    public var canProcess: Bool { hasKey || !settings.needsKey }
    public var monthCost: Double { meetings.filter { Calendar.current.isDate($0.started, equalTo: Date(), toGranularity: .month) }.reduce(0) { $0 + $1.costUSD } }

    /// The meetings by day, newest day first.
    public var days: [(day: Date, meetings: [Meeting])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: meetings) { calendar.startOfDay(for: $0.started) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0]!.sorted { $0.started > $1.started }) }
    }

    // MARK: Loading

    /// First show (also at app start): the key, the list, audio past its 14 days to the Trash,
    /// recordings left by a quit or a crash mixed and queued, waiting meetings transcribed. A
    /// meeting whose lock another host holds (the other Meetings app records or transcribes it)
    /// is left alone (H2).
    public func load() async {
        hasKey = keyStore.hasKey
        refreshLocalTools()
        refresh()
        guard !loaded else { return }
        loaded = true
        // M23: whisper or Pi that a crash or a force quit left running.
        Task.detached { ChildRun.endLeftovers() }
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
        if canProcess {
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
            recordingActive = MeetingLock.take(Self.recordingActiveFile(store.root))
            recordingID = meeting.id
            for control in controls.values { control.recording = true }
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
        recordingActive?.release()
        recordingActive = nil
        recordingID = nil
        recordingStarted = nil
        for control in controls.values { control.recording = false }
        if var meeting = store.load(id) {
            meeting.duration = result.seconds
            meeting.state = .waiting
            if !result.problems.isEmpty { meeting.warnings = (meeting.warnings ?? []) + result.problems }
            try? store.save(meeting)
        }
        refresh()
        if !result.problems.isEmpty { problem = result.problems.joined(separator: " ") }
        if quitting {
            // Transcribed at the next start (it waits).
        } else if canProcess {
            process(id)
        } else {
            notice = "Recorded \(lengthText(result.seconds)). Add your OpenRouter key in Settings, or choose Local in Settings, to transcribe it."
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
        guard !processing.contains(id), !quitting else { return }
        let key = keyStore.read()
        if key == nil && settings.needsKey {
            problem = MeetingsError.noKey.errorDescription
            return
        }
        processing.insert(id)
        let client = key.map { OpenRouterClient(key: $0, transport: transport) }
        let control = LocalControl(recording: isRecording)
        controls[id] = control
        let token = UUID()
        runTokens[id] = token
        localStatus[id] = nil
        let activeFile = Self.recordingActiveFile(store.root)
        let local = LocalEnvironment(control: control, status: { [weak self] status in
            Task { @MainActor in
                guard let self, self.runTokens[id] == token else { return }
                self.localStatus[id] = status
            }
        }, recordingElsewhere: { !MeetingLock.isFree(activeFile) })
        let processor = MeetingProcessor(store: store, settings: settings, client: client, local: local) { [weak self] meeting in
            Task { @MainActor in self?.updated(meeting) }
        }
        Task {
            do {
                _ = try await processor.run(id, restart: restart)
            } catch MeetingsError.busy {
                // The other Meetings app transcribes it; its saves show up on the next refresh.
                if byUser { notice = MeetingsError.busy.errorDescription }
            } catch MeetingsError.http(401, _) {
                problem = (MeetingsError.http(401, "").errorDescription ?? "") + " " + KeyStore.shape(key ?? "")
            } catch MeetingsError.stopped {
                notice = MeetingsError.stopped.errorDescription
            } catch {
                problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            processing.remove(id)
            controls[id] = nil
            runTokens[id] = nil
            localStatus[id] = nil
            pausedByUser.remove(id)
            refresh()
            if selectedID == id { reloadPage() }
        }
    }

    // MARK: Local runs (M23)

    /// Whether the user paused this meeting's local run.
    public func isPaused(_ id: String) -> Bool { pausedByUser.contains(id) }

    public func pause(_ id: String) {
        controls[id]?.userPaused = true
        pausedByUser.insert(id)
        localStatus[id].map { localStatus[id] = LocalStatus(phase: .paused(.user), piece: $0.piece, pieces: $0.pieces) }
    }

    public func resume(_ id: String) {
        controls[id]?.userPaused = false
        pausedByUser.remove(id)
    }

    /// Kills the running whisper or Pi; the pieces done so far stay.
    public func stopLocal(_ id: String) {
        MeetingsLog.info(.ui, "\(id): Stop local run")
        controls[id]?.stopped = true
    }

    /// Whether this meeting runs on this Mac (whisper or Pi), so Pause and Stop apply.
    public func runsLocally(_ id: String) -> Bool { processing.contains(id) && localStatus[id] != nil }

    static func recordingActiveFile(_ root: URL) -> URL { root.appending(path: ".recording-active.lock") }

    /// Quit (after a running recording is stopped): no new run starts, and whisper or Pi are
    /// killed now, so nothing keeps working (or stays paused) after the app is gone. The
    /// meetings go on from their next piece at the next start.
    public func prepareToQuit() {
        quitting = true
        for control in controls.values { control.stopped = true }
        ChildRun.endAll()
    }

    /// Whether Pause applies now: Pi's call is not paused.
    public func canPause(_ id: String) -> Bool { localStatus[id]?.phase != .summarizing }

    /// For the guide's screenshots: settings shown but not saved, and no meeting starts.
    public func showMadeUpSettings(_ change: (inout MeetingsSettings) -> Void) {
        change(&settings)
    }

    /// For the guide's screenshots: shows a local run's status and buttons without running one.
    public func showMadeUpLocalRun(_ id: String, _ status: LocalStatus) {
        processing.insert(id)
        controls[id] = LocalControl()
        localStatus[id] = status
    }

    // MARK: Local tools (M22, M24)

    public func refreshLocalTools() {
        whisperCLI = LocalWhisper.findCLI()
        hasWhisperModel = LocalWhisper.hasModel()
    }

    /// `brew install whisper-cpp` in the login shell.
    public func installWhisper() async {
        guard !installingWhisper else { return }
        installingWhisper = true
        defer { installingWhisper = false }
        let variables = await LoginEnvironment.variables()
        guard let brew = LoginEnvironment.find("brew", in: variables) ?? ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .map({ URL(filePath: $0) }).first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            problem = "Homebrew is not installed. Install it from brew.sh, then click Install whisper.cpp again."
            return
        }
        MeetingsLog.info(.local, "brew install whisper-cpp")
        let result = try? await ChildRun.run(brew, ["install", "whisper-cpp"], environment: variables, background: false, pausable: false,
                                             timeout: 1800, local: LocalEnvironment(), resume: LocalStatus(phase: .queued))
        refreshLocalTools()
        if whisperCLI == nil {
            let detail = result.map { String(decoding: $0.errors + $0.output, as: UTF8.self).suffix(300) } ?? "brew did not finish"
            problem = "Could not install whisper.cpp: \(detail)"
        } else {
            notice = "whisper.cpp is installed."
        }
    }

    /// Downloads the whisper model (~570 MB) to `~/Library/Application Support/Meetings/models`.
    public func downloadModel() {
        guard download == nil else { return }
        let target = LocalWhisper.modelFile
        modelDownload = 0
        MeetingsLog.info(.local, "download \(LocalWhisper.modelName)")
        let task = URLSession.shared.downloadTask(with: LocalWhisper.modelURL) { [weak self] file, response, error in
            var failure = error?.localizedDescription
            if failure == nil, let file {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                do {
                    guard code == 200 else { throw MeetingsError.local("the download answered \(code)") }
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? FileManager.default.removeItem(at: target)
                    try FileManager.default.moveItem(at: file, to: target)
                    if !LocalWhisper.hasModel(target) { throw MeetingsError.local("the file is too small") }
                } catch {
                    try? FileManager.default.removeItem(at: target)
                    failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
            Task { @MainActor in
                guard let self else { return }
                self.download = nil
                self.modelDownload = nil
                self.refreshLocalTools()
                if let failure { self.problem = "Could not download the whisper model: \(failure)" } else { self.notice = "The whisper model is downloaded." }
            }
        }
        download = task
        task.resume()
        Task { [weak self] in
            while let self, self.download === task {
                self.modelDownload = task.progress.fractionCompleted
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    public func cancelDownload() {
        download?.cancel()
    }

    public func loadPiModels() async {
        guard !loadingPiModels else { return }
        loadingPiModels = true
        defer { loadingPiModels = false }
        piModels = await PiSummarizer.models()
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
        let couldProcess = canProcess
        settings = next
        do { try settings.save(to: settingsFile) } catch { problem = "Could not save the settings: \(error.localizedDescription)" }
        if rootChanged {
            select(nil)
            refresh()
        }
        // Local needs no key: the meetings that waited for one go now.
        if !couldProcess && canProcess {
            for meeting in meetings where meeting.state == .waiting { process(meeting.id) }
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
