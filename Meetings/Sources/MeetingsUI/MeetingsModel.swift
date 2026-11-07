import Foundation
import MeetingsAudio
import MeetingsBackground
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
    /// M31: a meeting another process records now (the background recorder), read on refresh.
    public private(set) var remoteRecordingID: String?
    /// M31: true in the background recorder itself: it records here, never forwards.
    public var isBackgroundHost = false
    /// Called after each refresh (the background recorder announces its changes with it).
    @ObservationIgnored public var didRefresh: (@MainActor () -> Void)?
    /// A problem while it records (the microphone went silent, a piece did not write): the
    /// background recorder has no window, so it plays a sound.
    @ObservationIgnored public var didReportProblem: (@MainActor (String) -> Void)?
    @ObservationIgnored private var changeObserver: NSObjectProtocol?
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
    /// M27: what each meeting's local run does now (queued, a piece, paused …).
    public private(set) var localStatus: [String: LocalStatus] = [:]
    /// M26: whisper.cpp and its model on this Mac.
    public private(set) var whisperCLI: URL?
    public private(set) var hasWhisperModel = false
    /// The model download's progress (0…1) while it runs.
    public private(set) var modelDownload: Double?
    public private(set) var installingWhisper = false
    /// M28: Pi's models (`provider/id`), from `pi --list-models`.
    public private(set) var piModels: [String] = []
    public private(set) var loadingPiModels = false
    /// The pieces of each meeting being processed, for its progress bar.
    public private(set) var pieceTotals: [String: Int] = [:]
    /// When each meeting's run started, for the elapsed time beside the progress bar.
    public private(set) var processingSince: [String: Date] = [:]
    /// M32: where each run started counting pieces (pieces done then, the time), and its way,
    /// for the time left.
    /// M32: each run's work clock and its way (for the remembered speed); observed, so the strip
    /// redraws when a piece is done or the clock stops.
    public private(set) var clocks: [String: WorkClock] = [:]
    @ObservationIgnored private var runWays: [String: ProcessingEstimate.Way] = [:]
    /// When the summary started (Pi's in a run, or Summarize Again).
    public private(set) var summaryStarted: [String: Date] = [:]
    /// The meetings whose summary is written again now (Summarize Again, a new template).
    public private(set) var summarizingAgain: Set<String> = []
    /// The meetings whose local run the user paused.
    public private(set) var pausedByUser: Set<String> = []
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

    /// M25: what the host app does with a meeting (AKit: Notebook, Work Log, knowledge base).
    public var links: MeetingsLinks = .none
    public var tasksRequest = false
    public var factsRequest = false
    public var saveNoteRequest = false
    public private(set) var facts: [MeetingFact] = []
    public private(set) var findingFacts = false
    public private(set) var factsProblem: String?

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
    /// Meetings read on their own since the last full read began: a full read that lands later
    /// keeps their newer documents.
    @ObservationIgnored private var readAlone: Set<String> = []
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
    /// Recording here or in the background recorder.
    public func isLive(_ id: String) -> Bool { id == recordingID || id == remoteRecordingID }
    public var remoteRecording: Meeting? { remoteRecordingID.flatMap { id in meetings.first { $0.id == id } } }
    /// The live waves while it records (read by the screen several times a second).
    public var levels: (mic: [Float], system: [Float]) { recorder?.levels ?? ([], []) }
    public var selected: Meeting? { meetings.first { $0.id == selectedID } }
    /// Whether a meeting can be transcribed now: the key is there, or no step needs it.
    public var canProcess: Bool { hasKey || !settings.needsKey }
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
        refreshLocalTools()
        refresh()
        guard !loaded else { return }
        loaded = true
        if !isBackgroundHost, changeObserver == nil {
            // M31: the background recorder started, stopped or transcribed something.
            changeObserver = BackgroundControl.onChange { [weak self] in Task { @MainActor in self?.refresh() } }
        }
        // M27: whisper or Pi that a crash or a force quit left running, before any run starts.
        ChildRun.endLeftovers()
        startAudioCleanup()
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

    /// M7, M29: audio past its 14 days goes to the Trash now and every 6 hours while the app
    /// runs (AKit can stay open for weeks), never during a recording's start.
    private func startAudioCleanup() {
        Task { [weak self] in
            while let self, !Task.isCancelled {
                let store = self.store
                let count = await Task.detached { store.trashExpiredAudio() }.value
                if count > 0 {
                    MeetingsLog.info(.store, "audio of \(count) meeting(s) past \(MeetingStore.audioDays) days moved to the Trash")
                    self.refresh()
                }
                try? await Task.sleep(for: .seconds(6 * 3600))
            }
        }
    }

    public func refresh() {
        meetings = store.list()
        askEntries = AskLog(root: settings.root).entries()
        let store = self.store
        remoteRecordingID = meetings.first { meeting in
            meeting.state == .recording && meeting.id != recordingID && !MeetingLock.isFree(MeetingLock.recording(store, meeting.id))
        }?.id
        defer { didRefresh?() }
        if let id = selectedID, !meetings.contains(where: { $0.id == id }) {
            selectedID = nil
            page = nil
        }
        reindex()
    }

    /// Reads every meeting's text for search off the main thread; a newer call wins.
    func reindex(only id: String? = nil) {
        if let id { readAlone.insert(id) } else {
            indexGeneration += 1
            readAlone = []
        }
        let generation = indexGeneration
        let store = self.store
        let chosen = id.map { id in meetings.filter { $0.id == id } } ?? meetings
        Task {
            let found = await Task.detached { chosen.map { MeetingSearch.document($0, store: store) } }.value
            // A newer full read replaces an older one; one meeting's read always lands.
            guard id != nil || generation == indexGeneration else { return }
            if id == nil {
                var fresh = Dictionary(found.map { ($0.id, $0) }) { a, _ in a }
                for kept in readAlone { fresh[kept] = documents[kept] ?? fresh[kept] }
                documents = fresh
            } else {
                for document in found { documents[document.id] = document }
            }
        }
    }

    // MARK: Recording (M3)

    public func record() async { await startRecording(into: nil) }

    /// M34: a second talk after Stop goes into the same meeting: new pieces after its last one,
    /// then the transcript goes on from the next piece and the summary is written again.
    public func recordMore(_ id: String) async {
        guard canRecordMore(id) else { return }
        if !isBackgroundHost, BackgroundControl.recorderRuns {
            BackgroundControl.send(Self.recordMoreAction + id)
            notice = "Meetings Recorder records in the background; ⌥⌘R or Stop ends it."
            return
        }
        await startRecording(into: id)
    }

    static let recordMoreAction = "record-more:"

    /// Whether Record More can start on this meeting now: nothing records, it is not processed
    /// or imported, and its audio is still here.
    public func canRecordMore(_ id: String) -> Bool {
        guard !isRecording, !starting, remoteRecordingID == nil, !processing.contains(id), importing[id] == nil,
              let meeting = meetings.first(where: { $0.id == id }) else { return false }
        // Not while the other Meetings app processes it (it holds the processing lock).
        return meeting.state != .recording && meeting.state != .transcribing && !meeting.audioTrashed
            && recordingRuns[id] == nil && MeetingLock.isFree(MeetingLock.processing(store, id))
    }

    /// A new meeting (`existing` nil) or more pieces for `existing`.
    private func startRecording(into existing: String?) async {
        guard !isRecording, !starting else { return }
        // M31: with the background recorder running, it records, so a meeting is never recorded twice.
        if existing == nil, !isBackgroundHost, BackgroundControl.recorderRuns {
            guard remoteRecordingID == nil else { return }
            BackgroundControl.send("record")
            notice = "Meetings Recorder records in the background; ⌥⌘R or Stop ends it."
            return
        }
        starting = true
        defer { starting = false }
        var before: Meeting?
        do {
            let meeting: Meeting
            if let existing {
                guard var old = store.load(existing) else { return }
                before = old
                old.state = .recording
                try store.save(old)
                meeting = old
            } else {
                meeting = try store.create(template: settings.defaultTemplate)
            }
            let id = meeting.id
            let folder = store.audioFolder(id)
            // The lock right after the meeting exists, so the other host never takes it for a crash.
            let held = MeetingLock.take(Recorder.lockFile(folder))
            let mixed: @Sendable () -> Void = { [weak self] in
                Task { @MainActor in self?.transcribeWhileRecording(id) }
            }
            let report: @Sendable (String) -> Void = { [weak self] text in
                Task { @MainActor in
                    self?.problem = text
                    self?.didReportProblem?(text)
                }
            }
            let recorder = Recorder(folder: folder, echoCancellation: settings.echoCancellation, lock: held,
                                    firstPiece: store.nextPieceNumber(id), piecesMixed: mixed, problem: report)
            do {
                try await recorder.start()
            } catch {
                held?.release()
                if let before { try? store.save(before) } else { try? store.moveToTrash(id) }
                throw error
            }
            if existing != nil { MeetingsLog.info(.recorder, "\(id): record more from piece \(store.nextPieceNumber(id))") }
            self.recorder = recorder
            RecordingSignal.set(Self.recordingActiveFile(store.root), recording: true)
            recordingID = id
            for control in controls.values { control.recording = true }
            recordingStarted = Date()
            refresh()
            select(id)
        } catch {
            problem = "Could not start the recording: \(error.localizedDescription)"
            if before != nil { refresh() }
        }
    }

    // MARK: Transcription while recording (M35)

    /// Meetings with a run while they record; Stop waits for it before it saves the meeting.
    @ObservationIgnored private var recordingRuns: [String: Task<Void, Never>] = [:]

    /// The whole pieces not yet transcribed go to the cloud now, so after Stop only the last piece
    /// and the summary are left. Pieces mixed while it runs are taken by the next turn.
    private func transcribeWhileRecording(_ id: String) {
        guard settings.transcribeWhileRecording, settings.transcription == .cloud, recordingID == id,
              recordingRuns[id] == nil, !processing.contains(id), !quitting, let key = keyStore.read() else { return }
        let processor = MeetingProcessor(store: store, settings: settings, client: OpenRouterClient(key: key, transport: transport)) { [weak self] meeting in
            Task { @MainActor in self?.updated(meeting) }
        }
        recordingRuns[id] = Task {
            let count = (try? await processor.runWhileRecording(id)) ?? 0
            recordingRuns[id] = nil
            if recordingID == id, count > 0 { transcribeWhileRecording(id) }
        }
    }

    // MARK: Import (M33)

    /// Meetings being imported now → seconds read so far (the list shows it).
    public var importing: [String: TimeInterval] = [:]
    public var showImporter = false

    /// Each file becomes its own meeting: the title is the file's name, the start is when the
    /// file was made, and then it is transcribed as a recording.
    public func importAudio(_ urls: [URL]) {
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            let started = values?.creationDate ?? values?.contentModificationDate ?? Date()
            let meeting: Meeting
            do {
                var created = try store.create(started: started, template: settings.defaultTemplate)
                created.title = url.deletingPathExtension().lastPathComponent
                try store.save(created)
                meeting = created
            } catch {
                if access { url.stopAccessingSecurityScopedResource() }
                problem = "Could not import \(url.lastPathComponent): \(error.localizedDescription)"
                continue
            }
            let id = meeting.id
            let folder = store.audioFolder(id)
            importing[id] = 0
            refresh()
            select(id)
            MeetingsLog.info(.mixer, "import \(id): .\(url.pathExtension.lowercased()) file")
            let report: @Sendable (TimeInterval) -> Void = { [weak self] seconds in
                Task { @MainActor in if self?.importing[id] != nil { self?.importing[id] = seconds } }
            }
            Task { [weak self] in
                let result: Result<TimeInterval, Error> = await Task.detached {
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    do { return .success(try AudioImport.importFile(url, into: folder, progress: report)) } catch { return .failure(error) }
                }.value
                self?.finishImport(id, result: result)
            }
        }
    }

    private func finishImport(_ id: String, result: Result<TimeInterval, Error>) {
        importing[id] = nil
        switch result {
        case .success(let seconds):
            if var meeting = store.load(id) {
                meeting.duration = seconds
                meeting.state = .waiting
                try? store.save(meeting)
            }
            refresh()
            if canProcess {
                process(id)
            } else {
                notice = "Imported \(lengthText(seconds)). Add your OpenRouter key in Settings, or choose Local in Settings, to transcribe it."
            }
        case .failure(let error):
            MeetingsLog.info(.mixer, "import \(id) failed: \(error.localizedDescription)")
            try? store.moveToTrash(id)
            problem = error.localizedDescription
            refresh()
        }
        if selectedID == id { reloadPage() }
    }

    public func stop() async {
        if recordingID == nil, remoteRecordingID != nil {
            BackgroundControl.send("stop")
            return
        }
        guard let id = recordingID, let recorder else { return }
        let result = await recorder.stop()
        // M35: a piece still being transcribed is saved first, so this save does not undo it.
        if let run = recordingRuns[id] { await run.value }
        self.recorder = nil
        RecordingSignal.set(Self.recordingActiveFile(store.root), recording: false)
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
        case "toggle": if isRecording || remoteRecordingID != nil { await stop() } else { await record() }
        case let more where more.hasPrefix(Self.recordMoreAction):
            await recordMore(String(action.dropFirst(Self.recordMoreAction.count)))
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
        pieceTotals[id] = store.pieces(id).count
        processingSince[id] = Date()
        var clock = WorkClock()
        // Cloud runs report no status: their clock runs from the start. A local run's starts at
        // its first piece (not while it is queued).
        if settings.transcription == .cloud { clock.run(true) }
        clocks[id] = clock
        runWays[id] = ProcessingEstimate.Way(settings)
        summaryStarted[id] = nil
        // The count the run starts from, as the processor sees it, so its first save is not taken
        // for pieces done in this run (an older file counts chunks of 6 pieces).
        if let index = meetings.firstIndex(where: { $0.id == id }), let disk = store.load(id) {
            meetings[index] = disk
            meetings[index].transcribedPieces = restart ? 0 : disk.transcribedPieces ?? disk.transcribedChunks * MeetingProcessor.piecesPerChunk
        }
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
                self.clockFollows(id, status)
            }
        }, recordingElsewhere: { RecordingSignal.elsewhere(activeFile) })
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
            rememberSpeed(id)
            pieceTotals[id] = nil
            processingSince[id] = nil
            controls[id] = nil
            runTokens[id] = nil
            localStatus[id] = nil
            pausedByUser.remove(id)
            refresh()
            if selectedID == id { reloadPage() }
        }
    }

    /// M22: only the summary again (a new template): one text call over the transcript.
    public func summarizeAgain(_ id: String) {
        guard !processing.contains(id), !quitting else { return }
        let key = keyStore.read()
        if key == nil && settings.summarizer == .openRouter {
            problem = MeetingsError.noKey.errorDescription
            return
        }
        processing.insert(id)
        summarizingAgain.insert(id)
        summaryStarted[id] = Date()
        processingSince[id] = Date()
        // M28: Pi writes it when chosen; Stop kills it like a local run.
        let control = LocalControl()
        controls[id] = control
        let token = UUID()
        runTokens[id] = token
        let local = LocalEnvironment(control: control, status: { [weak self] status in
            Task { @MainActor in
                guard let self, self.runTokens[id] == token else { return }
                self.localStatus[id] = status
            }
        })
        let processor = MeetingProcessor(store: store, settings: settings, client: key.map { OpenRouterClient(key: $0, transport: transport) },
                                         local: local) { [weak self] meeting in
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
            summaryStarted[id] = nil
            summarizingAgain.remove(id)
            processing.remove(id)
            pieceTotals[id] = nil
            processingSince[id] = nil
            controls[id] = nil
            runTokens[id] = nil
            localStatus[id] = nil
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
            if meeting.state == .done, !meeting.segments.isEmpty, hasKey || settings.summarizer == .pi {
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

    // MARK: Links to the host app (M25)

    /// The selected meeting's open tasks, from its summary.
    public var selectedTasks: [SummaryTask] {
        guard let meeting = selected else { return [] }
        return SummaryTask.open(in: store.summary(meeting.id))
    }

    /// Whether a task is the user's own (`Me` or the name given to Me).
    public func isMine(_ task: SummaryTask) -> Bool {
        task.owner == "Me" || (selected.map { task.owner == $0.speakerName("Me") } ?? false)
    }

    /// Add Tasks to Notebook…: each task as `- [ ] task — title, date` (an owner other than Me
    /// stays in front) under today's heading of `tab`.
    public func addTasks(_ tasks: [SummaryTask], to tab: String) async -> Bool {
        guard let addTasks = links.addTasks, var meeting = fresh, !tasks.isEmpty else { return false }
        let source = "\(meeting.displayTitle), \(meeting.started.formatted(.dateTime.day().month(.defaultDigits)))"
        let lines = tasks.map { task in (isMine(task) || task.owner.isEmpty ? "" : task.owner + ": ") + task.text + " — " + source }
        do {
            try await addTasks(lines, tab)
            meeting = store.load(meeting.id) ?? meeting
            try? store.markExport(&meeting, "notebook")
            updated(meeting)
            notice = "Added \(lines.count) task\(lines.count == 1 ? "" : "s") to the Notebook tab \(tab)."
            MeetingsLog.info(.ui, "\(meeting.id): \(lines.count) tasks to the Notebook")
            return true
        } catch {
            problem = "Could not add the tasks to the Notebook: " + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            return false
        }
    }

    /// Add to Work Log: one `#meeting` line at the meeting's start.
    public func addToWorkLog() async {
        guard let addToWorkLog = links.addToWorkLog, var meeting = fresh else { return }
        let line = MeetingsLinks.WorkLogLine(started: meeting.started, title: meeting.displayTitle, summary: summaryParagraph(store.summary(meeting.id)))
        do {
            try await addToWorkLog(line)
            meeting = store.load(meeting.id) ?? meeting
            try? store.markExport(&meeting, "worklog")
            updated(meeting)
            notice = "Added to the Work Log at \(meeting.started.formatted(date: .omitted, time: .shortened))."
            MeetingsLog.info(.ui, "\(meeting.id): to the Work Log")
        } catch {
            problem = "Could not add the meeting to the Work Log: " + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Save to Knowledge…: the whole summary as a new note, with the meeting's date, people and
    /// tags on top; with `transcript` the transcript as a second note, each linking the other.
    /// No model call.
    public func saveToKnowledge(area: String, name: String, transcript: Bool = true) async -> Bool {
        guard let saveNote = links.saveNote, var meeting = fresh else { return false }
        let withTranscript = transcript && !meeting.segments.isEmpty
        let transcriptName = Transcriber.transcriptTitle(name)
        do {
            if withTranscript {
                _ = try await saveNote(area, transcriptName, Transcriber.knowledgeTranscript(meeting, name: name, summaryNote: "\(area)/\(name)"))
            }
            let id = try await saveNote(area, name, Transcriber.knowledgeNote(meeting, name: name, summary: store.summary(meeting.id),
                                                                               transcriptNote: withTranscript ? "\(area)/\(transcriptName)" : nil))
            meeting = store.load(meeting.id) ?? meeting
            try? store.markExport(&meeting, "knowledge")
            updated(meeting)
            notice = "Saved to the knowledge base as \(id)" + (withTranscript ? ", with its transcript." : ".")
            MeetingsLog.info(.ui, "\(meeting.id): to the knowledge base")
            return true
        } catch {
            problem = "Could not save the meeting to the knowledge base: " + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            return false
        }
    }

    /// Propose to Knowledge…: one text call over the summary and the transcript with the base's
    /// notes; its cost goes to the meeting.
    public func findFacts() async {
        guard let knowledgeNotes = links.knowledgeNotes, let meeting = fresh, !findingFacts else { return }
        facts = []
        factsProblem = nil
        guard let key = keyStore.read() else {
            factsProblem = MeetingsError.noKey.errorDescription
            return
        }
        guard monthCost < settings.monthlyLimitUSD else {
            factsProblem = MeetingsError.monthlyLimit(settings.monthlyLimitUSD).errorDescription
            return
        }
        findingFacts = true
        defer { findingFacts = false }
        do {
            let notes = try await knowledgeNotes()
            let finder = FactFinder(client: OpenRouterClient(key: key, transport: transport), settings: settings)
            let answer = try await finder.find(meeting, summary: store.summary(meeting.id), notes: notes)
            if var current = store.load(meeting.id) {
                try? store.addCost(&current, answer.completion.cost)
                updated(current)
            }
            facts = answer.facts
            if facts.isEmpty { factsProblem = "The model found no facts about systems in this meeting." }
            MeetingsLog.info(.ui, "\(meeting.id): \(facts.count) facts for the knowledge base (\(notes.count) notes known), $\(answer.completion.cost)")
        } catch {
            if PaidFailure.cost(of: error) > 0, var current = store.load(meeting.id) {
                try? store.addCost(&current, PaidFailure.cost(of: error))
                updated(current)
            }
            factsProblem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// The chosen facts as proposals in the base's Inbox.
    public func propose(_ chosen: [MeetingFact]) async -> Bool {
        guard let propose = links.propose, var meeting = fresh, !chosen.isEmpty else { return false }
        let source = "From the meeting “\(meeting.displayTitle)” of \(meeting.started.formatted(date: .abbreviated, time: .shortened))"
        do {
            let result = try await propose(chosen, source)
            meeting = store.load(meeting.id) ?? meeting
            if result.written > 0 { try? store.markExport(&meeting, "knowledge") }
            updated(meeting)
            if result.refused.isEmpty {
                notice = "\(result.written) proposal\(result.written == 1 ? "" : "s") wait in the knowledge base's Inbox (Knowledge → Inbox)."
                return true
            }
            factsProblem = "\(result.written) went to the Inbox. Refused: " + result.refused.joined(separator: "; ")
            return false
        } catch {
            factsProblem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
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
            if PaidFailure.cost(of: error) > 0 {
                let entry = AskLog.Entry(date: Date(), model: settings.summaryModel ?? settings.model, promptTokens: 0, completionTokens: 0,
                                         costUSD: PaidFailure.cost(of: error))
                try? AskLog(root: settings.root).append(entry)
                askEntries.append(entry)
            }
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

    // MARK: Time left (M32)

    /// The seconds one piece takes in this meeting's run: measured once a piece is done, else
    /// what earlier runs on this Mac took.
    public func secondsPerPiece(_ id: String) -> TimeInterval? {
        guard let way = runWays[id] else { return nil }
        return clocks[id]?.perPiece ?? ProcessingEstimate.perPiece(way)
    }

    /// The clock runs while pieces are transcribed or rest, and stands otherwise.
    private func clockFollows(_ id: String, _ status: LocalStatus) {
        guard clocks[id] != nil else { return }
        switch status.phase {
        case .transcribing, .resting: clocks[id]?.run(true)
        case .summarizing:
            clocks[id]?.run(false)
            if summaryStarted[id] == nil { summaryStarted[id] = Date() }
        case .queued, .paused: clocks[id]?.run(false)
        }
    }

    /// The run's measured speed for the next estimate (only when it did pieces).
    private func rememberSpeed(_ id: String) {
        // Work up to the last piece only: no waits, no summary.
        if let way = runWays.removeValue(forKey: id), let perPiece = clocks[id]?.perPiece { ProcessingEstimate.remember(perPiece, for: way) }
        clocks[id] = nil
        summaryStarted[id] = nil
    }

    // MARK: Local runs (M27)

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

    static func recordingActiveFile(_ root: URL) -> URL { root.appending(path: ".recording-active") }

    /// Quit (after a running recording is stopped): no new run starts, and whisper or Pi are
    /// killed now, so nothing keeps working (or stays paused) after the app is gone. The
    /// meetings go on from their next piece at the next start.
    public func prepareToQuit() {
        quitting = true
        for control in controls.values {
            control.quitting = true
            control.stopped = true
        }
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
        pieceTotals[id] = status.pieces
        processingSince[id] = Date().addingTimeInterval(-150)
        var clock = WorkClock()
        clock.run(true, at: Date().addingTimeInterval(-150))
        clock.done(2, at: Date().addingTimeInterval(-10))
        clocks[id] = clock
        runWays[id] = .localGPU
        controls[id] = LocalControl()
        localStatus[id] = status
    }

    // MARK: Local tools (M26, M28)

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
        // M32: the time of the last piece done, the base of the finish time.
        if let old = meetings.first(where: { $0.id == meeting.id }), clocks[meeting.id] != nil {
            clocks[meeting.id]?.done((meeting.transcribedPieces ?? 0) - (old.transcribedPieces ?? 0))
        }
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
        guard !isLive(id) else { return }
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

/// M32: how far a meeting's processing is, for the progress strip.
public struct MeetingProgress: Equatable, Sendable {
    public var text: String
    /// Pieces done and in all; 0 in all when unknown.
    public var done: Int
    public var total: Int
    public var paused: Bool
    public var since: Date?
    /// For the time left (nil when unknown or paused): the run's clock, the pieces left and the
    /// seconds per piece, or when the summary started.
    public var clock: WorkClock?
    public var piecesLeft = 0
    public var perPiece: TimeInterval = 0
    public var summaryStarted: Date?
    public var summaryLeft = true

    /// Whether the pieces take longer than the estimate: the guess ran out with pieces left.
    public func overEstimate(at date: Date) -> Bool {
        guard summaryStarted == nil, let clock, !paused, piecesLeft > 0 else { return false }
        return clock.left(piecesLeft: piecesLeft, perPiece: perPiece, at: date) <= 0
    }

    /// Seconds left at `date`: the pieces left, then the summary.
    public func left(at date: Date) -> TimeInterval? {
        if let summaryStarted { return max(0, ProcessingEstimate.summarySeconds - date.timeIntervalSince(summaryStarted)) }
        guard let clock, !paused else { return nil }
        return clock.left(piecesLeft: piecesLeft, perPiece: perPiece, at: date) + (summaryLeft ? ProcessingEstimate.summarySeconds : 0)
    }
}
