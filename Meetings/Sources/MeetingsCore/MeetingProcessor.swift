import CryptoKit
import Foundation

/// Turns a stopped recording into its transcript and summary (M13, M15). The mixed pieces not yet
/// transcribed are sent in chunks of up to `piecesPerChunk` pieces (6 × 5 min = 30 min); after
/// each chunk the meeting is saved, so a failed run goes on from the next piece. While it runs it
/// holds the meeting's processing lock, so a second host does not send the same audio again.
public struct MeetingProcessor: Sendable {
    public static let piecesPerChunk = 6
    /// Pieces per cloud call. One: the progress bar moves every 5 minutes of audio, a looping
    /// or unreadable answer costs one piece, and the output cap stays small. Earlier files
    /// counted chunks of `piecesPerChunk`.
    public var cloudChunkSize = 1
    let store: MeetingStore
    let settings: MeetingsSettings
    /// nil without an OpenRouter key: then only local steps run (M26, M28).
    let transcriber: Transcriber?
    let local: LocalEnvironment
    /// whisper-cli, its model and the converter; nil finds them (tests pass their own).
    let whisper: LocalWhisper.Tools?
    /// The login shell's environment for Pi; nil reads it (tests pass their own).
    let piEnvironment: [String: String]?
    /// Called after each saved step, for the screen.
    let progress: @Sendable (Meeting) -> Void

    public init(store: MeetingStore, settings: MeetingsSettings, client: OpenRouterClient?, local: LocalEnvironment = LocalEnvironment(),
                whisper: LocalWhisper.Tools? = nil, piEnvironment: [String: String]? = nil,
                progress: @escaping @Sendable (Meeting) -> Void = { _ in }) {
        self.store = store
        self.settings = settings
        transcriber = client.map { Transcriber(client: $0, settings: settings) }
        self.local = local
        self.whisper = whisper
        self.piEnvironment = piEnvironment
        self.progress = progress
    }

    /// M27: a rest after each local piece as long as the piece took (at most a minute), so the
    /// Mac is never busy for long at a time.
    public static let longestRest: TimeInterval = 60

    /// A chunk: its pieces, where it starts in the recording, and how many pieces end with it.
    struct Chunk {
        var pieces: [URL]
        var offset: TimeInterval
        var length: TimeInterval
        var me: [TimeSpan]
        var others: [TimeSpan]
        var endPiece: Int
    }

    /// The overlap that makes Auto send a chunk as two tracks: room and call voices at once.
    public static let overlapForTwoTracks: TimeInterval = 3

    /// The chunks of the pieces after the first `done`; offsets count every piece before.
    func chunks(_ id: String, after done: Int, size: Int = piecesPerChunk) -> (chunks: [Chunk], duration: TimeInterval) {
        let pieces = store.pieces(id)
        let infos = pieces.map { store.pieceInfo($0) ?? PieceInfo(duration: 300, me: []) }
        let start = min(done, pieces.count)
        var offset = infos.prefix(start).reduce(0) { $0 + $1.duration }
        var result: [Chunk] = []
        var index = start
        while index < pieces.count {
            let end = min(index + max(1, size), pieces.count)
            var chunk = Chunk(pieces: Array(pieces[index..<end]), offset: offset, length: 0, me: [], others: [], endPiece: end)
            for info in infos[index..<end] {
                chunk.me += info.me.map { TimeSpan(start: $0.start + chunk.length, end: $0.end + chunk.length) }
                chunk.others += (info.others ?? []).map { TimeSpan(start: $0.start + chunk.length, end: $0.end + chunk.length) }
                chunk.length += info.duration
            }
            result.append(chunk)
            offset += chunk.length
            index = end
        }
        return (result, infos.reduce(0) { $0 + $1.duration })
    }

    public static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Runs the pieces not yet done, then the summary. A start over (Transcribe Again) passes
    /// `restart`. Throws after saving the meeting as `failed` with the reason; throws
    /// `MeetingsError.busy`, without touching the meeting, when another run holds the lock.
    @discardableResult
    public func run(_ id: String, restart: Bool = false) async throws -> Meeting {
        guard let lock = MeetingLock.take(MeetingLock.processing(store, id)) else { throw MeetingsError.busy }
        defer { lock.release() }
        guard var meeting = store.load(id) else { throw MeetingsError.noAudio }
        let isLocal = settings.transcription == .local
        MeetingsLog.info(.processor, "\(id): run\(restart ? " (restart)" : ""), \(store.pieces(id).count) pieces, \(isLocal ? "local whisper" : "model \(settings.model)"), summary by \(settings.summarizer.rawValue)")
        // A restart without audio keeps the transcript it has (L1).
        if store.pieces(id).isEmpty && (restart || meeting.segments.isEmpty) {
            return try fail(&meeting, MeetingsError.noAudio)
        }
        let done = restart ? 0 : meeting.transcribedPieces ?? meeting.transcribedChunks * Self.piecesPerChunk
        let plan = chunks(id, after: done, size: isLocal ? Self.piecesPerChunk : cloudChunkSize)
        if restart {
            meeting.segments = []
            meeting.transcribedChunks = 0
        }
        if plan.duration > 0 { meeting.duration = plan.duration }
        meeting.state = .transcribing
        meeting.failure = nil
        meeting.transcribedPieces = min(done, store.pieces(id).count)
        // The model that wrote the transcript; a run with nothing left to transcribe keeps it.
        if !plan.chunks.isEmpty || restart { meeting.model = isLocal ? LocalWhisper.modelTitle + " (local)" : settings.model }
        try save(&meeting)
        // M27: one local run at a time on this Mac, across meetings and both apps.
        var turn: MeetingLock?
        defer { turn?.release() }
        do {
            if isLocal || settings.summarizer == .pi { turn = try await localTurn() }
            if isLocal {
                try await transcribeLocally(&meeting, from: done)
            } else {
                guard let transcriber else { throw MeetingsError.noKey }
                for chunk in plan.chunks {
                    try await transcribeCloud(chunk, into: &meeting, transcriber: transcriber)
                }
            }
            try await summarizeWithRetry(&meeting)
            MeetingsLog.info(.processor, "\(id): done, \(meeting.segments.count) segments, $\(meeting.costUSD) in all")
            return meeting
        } catch MeetingsError.stopped where local.control.quitting {
            // Quit: the meeting waits and goes on from its next piece at the next start.
            meeting.state = .waiting
            try save(&meeting)
            MeetingsLog.info(.processor, "\(id): left for the next start (quit)")
            throw MeetingsError.stopped
        } catch {
            return try fail(&meeting, error)
        }
    }

    /// M35: while it records, the whole pieces not yet transcribed, one per call, through the
    /// cloud. No summary, and the meeting's state, length and failure stay as the recorder keeps
    /// them. A failed call only ends this run: the run after Stop sends the piece again. Returns
    /// how many pieces it transcribed.
    @discardableResult
    public func runWhileRecording(_ id: String) async throws -> Int {
        guard settings.transcription == .cloud, let transcriber else { return 0 }
        guard let lock = MeetingLock.take(MeetingLock.processing(store, id)) else { throw MeetingsError.busy }
        defer { lock.release() }
        guard var meeting = store.load(id) else { return 0 }
        let done = meeting.transcribedPieces ?? meeting.transcribedChunks * Self.piecesPerChunk
        let ready = store.readyPieceCount(id)
        guard ready > done else { return 0 }
        let plan = chunks(id, after: done, size: 1).chunks.prefix(ready - done)
        MeetingsLog.info(.processor, "\(id): while recording, pieces \(done + 1)–\(ready), model \(settings.model)")
        meeting.model = settings.model
        var count = 0
        do {
            for chunk in plan {
                try await transcribeCloud(chunk, into: &meeting, transcriber: transcriber, keepState: true)
                count += 1
            }
        } catch {
            meeting.costUSD += PaidFailure.cost(of: error)
            try? save(&meeting, keepState: true)
            MeetingsLog.error(.processor, "\(id): while recording, stopped: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription); the run after Stop goes on")
            throw error
        }
        return count
    }

    /// One chunk through the cloud into the transcript, then saved. A long answer the model cut
    /// off or looped in sends the same pieces again, one per call. A piece whose answer stays
    /// unreadable after `unreadableTries` calls gets a note line in the transcript instead, so one
    /// bad answer does not stop the meeting; while recording it ends the run, and the run after
    /// Stop sends it again.
    private func transcribeCloud(_ chunk: Chunk, into meeting: inout Meeting, transcriber: Transcriber, keepState: Bool = false) async throws {
        let id = meeting.id
        try checkLimit()
        let answer: (segments: [Segment], cost: Double)
        do {
            answer = try await transcribe(chunk, id: id, previous: meeting.segments, transcriber: transcriber)
        } catch let failure as PaidFailure {
            meeting.costUSD += failure.cost
            if chunk.pieces.count > 1 {
                MeetingsLog.error(.processor, "\(id): answer for \(chunk.pieces.count) pieces not readable; trying them one by one")
            }
            var segments: [Segment] = []
            let first = chunk.endPiece - chunk.pieces.count
            let singles = chunk.pieces.count > 1 ? Array(chunks(id, after: first, size: 1).chunks.prefix(chunk.pieces.count)) : [chunk]
            for (n, single) in singles.enumerated() {
                // A single-piece chunk already had its first try above.
                let tried = chunk.pieces.count == 1 ? 1 : 0
                segments += try await transcribeSingle(single, number: first + n + 1, tried: tried, id: id,
                                                       previous: meeting.segments + segments, meeting: &meeting,
                                                       transcriber: transcriber, mayGiveUp: !keepState)
            }
            answer = (segments, 0)
        }
        meeting.segments += answer.segments
        meeting.costUSD += answer.cost
        meeting.transcribedChunks += 1
        meeting.transcribedPieces = chunk.endPiece
        try save(&meeting, keepState: keepState)
    }

    /// Calls for one piece until an answer reads, at most `unreadableTries` in all. When
    /// `mayGiveUp`, the last unreadable answer becomes one note line; else it is thrown.
    private func transcribeSingle(_ single: Chunk, number: Int, tried: Int, id: String, previous: [Segment], meeting: inout Meeting,
                                  transcriber: Transcriber, mayGiveUp: Bool) async throws -> [Segment] {
        var attempt = tried
        while true {
            try checkLimit()
            do {
                let part = try await transcribe(single, id: id, previous: previous, transcriber: transcriber)
                meeting.costUSD += part.cost
                return part.segments
            } catch let failure as PaidFailure {
                meeting.costUSD += failure.cost
                attempt += 1
                guard attempt >= Self.unreadableTries else {
                    MeetingsLog.error(.processor, "\(id): piece \(number) not readable; try \(attempt + 1) of \(Self.unreadableTries)")
                    continue
                }
                guard mayGiveUp else { throw failure }
                MeetingsLog.error(.processor, "\(id): piece \(number) not readable after \(attempt) tries; skipped with a note")
                return [Self.skippedNote(single)]
            }
        }
    }

    /// How many calls one piece gets before its unreadable answer is skipped.
    static let unreadableTries = 3

    /// The transcript line that stands for a piece the model never answered readably.
    static func skippedNote(_ chunk: Chunk) -> Segment {
        func clock(_ t: TimeInterval) -> String { String(format: "%d:%02d", Int(t) / 60, Int(t) % 60) }
        return Segment(start: chunk.offset, speaker: "Note",
                       text: "[Not transcribed: \(clock(chunk.offset))–\(clock(chunk.offset + chunk.length)). The model's answer could not be read three times.]")
    }

    /// M22: only the summary again, from the transcript it has (a new template, a new model):
    /// one text call, no audio.
    @discardableResult
    public func summarizeAgain(_ id: String) async throws -> Meeting {
        guard let lock = MeetingLock.take(MeetingLock.processing(store, id)) else { throw MeetingsError.busy }
        defer { lock.release() }
        guard var meeting = store.load(id) else { throw MeetingsError.noAudio }
        guard !meeting.segments.isEmpty else { throw MeetingsError.noTranscript }
        // A meeting with audio not yet transcribed must stay failed/waiting, or Try Again goes away.
        guard meeting.state == .done || (meeting.transcribedPieces ?? 0) >= store.pieces(id).count else { throw MeetingsError.notTranscribed }
        MeetingsLog.info(.processor, "\(id): summarize again, template \(settings.template(meeting.template).id)")
        let before = (state: meeting.state, failure: meeting.failure)
        meeting.state = .transcribing
        meeting.failure = nil
        try save(&meeting)
        do {
            try await summarize(&meeting)
            return meeting
        } catch {
            // The transcript is whole: a failed summary leaves the meeting as it was.
            meeting.costUSD += PaidFailure.cost(of: error)
            meeting.state = before.state == .failed ? .failed : .done
            meeting.failure = before.failure
            MeetingsLog.error(.processor, "\(id): summary failed: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
            try save(&meeting)
            throw error
        }
    }

    /// The wait before the one more try of a failed summary; none in tests.
    static let summaryRetryDelay: Duration = MeetingsLog.isTest ? .zero : .seconds(15)

    /// The transcript is already saved, so a summary that fails (a short outage of the model or
    /// Pi, an unreadable answer) gets one more try before the meeting fails.
    func summarizeWithRetry(_ meeting: inout Meeting) async throws {
        do {
            try await summarize(&meeting)
        } catch {
            switch error {
            // A file error is local: another model call would not help.
            case MeetingsError.noKey, MeetingsError.monthlyLimit, MeetingsError.stopped, MeetingsError.tooHot, is CancellationError, is CocoaError: throw error
            default: break
            }
            meeting.costUSD += PaidFailure.cost(of: error)
            MeetingsLog.error(.processor, "\(meeting.id): summary failed, one more try: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
            try await Task.sleep(for: Self.summaryRetryDelay)
            try await summarize(&meeting)
        }
    }

    /// The summary call over the transcript, `summary.md` (a user's own text kept in a tab first),
    /// the title, proposed tags, state done.
    func summarize(_ meeting: inout Meeting) async throws {
        let summary: String
        if meeting.segments.isEmpty {
            summary = "## Summary\n\nNothing was said in this recording.\n"
        } else if settings.summarizer == .pi {
            // M28: the same prompt and template through Pi; no OpenRouter cost.
            local.status(LocalStatus(phase: .summarizing))
            let (answer, usage) = try await PiSummarizer(settings: settings, local: local, environment: piEnvironment).summarize(meeting)
            // A new summary counts Pi's tokens from here (its lookup adds its own).
            meeting.piUsage = usage
            meeting.summaryModel = "pi" + (settings.piModel.map { ": \($0)" } ?? "")
            if !answer.title.isEmpty { meeting.title = answer.title }
            if meeting.tags == nil, !answer.tags.isEmpty { meeting.tags = answer.tags }
            summary = answer.markdown
        } else {
            guard let transcriber else { throw MeetingsError.noKey }
            try checkLimit()
            let answer = try await transcriber.summarize(meeting)
            meeting.costUSD += answer.completion.cost
            meeting.summaryModel = settings.summaryModel ?? settings.model
            if !answer.summary.title.isEmpty { meeting.title = answer.summary.title }
            if meeting.tags == nil, !answer.summary.tags.isEmpty { meeting.tags = answer.summary.tags }
            summary = answer.summary.markdown
        }
        try keepUserSummary(meeting.id)
        try store.writeSummary(meeting.id, summary)
        meeting.summaryHash = Self.hash(summary)
        meeting.state = .done
        try save(&meeting)
        if settings.summarizer == .pi, settings.piDevOps, !meeting.segments.isEmpty { try await researchDevOps(&meeting, summary: summary) }
    }

    /// M37: Pi's Azure DevOps lookup into its own tab. A failure is written in the tab and
    /// logged; the summary stays.
    func researchDevOps(_ meeting: inout Meeting, summary: String) async throws {
        let text: String
        var usage = PiEvents.Usage()
        do {
            (text, usage) = try await PiDevOpsResearch(settings: settings, local: local, environment: piEnvironment).research(meeting, summary: summary)
        } catch MeetingsError.stopped {
            throw MeetingsError.stopped
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            MeetingsLog.error(.pi, "\(meeting.id): azure devops failed: \(reason)")
            text = "Pi could not look in Azure DevOps: \(reason)\n"
        }
        let answer = PiDevOpsResearch.split(text)
        try store.writeTab(meeting.id, PiDevOpsResearch.tabName, answer.tab + "\n")
        // Tabs are the user's: `save` keeps the file's own, so the new tab goes in the file's copy.
        var disk = store.load(meeting.id) ?? meeting
        if !disk.tabs.contains(PiDevOpsResearch.tabName) { disk.tabs.append(PiDevOpsResearch.tabName) }
        if !usage.isEmpty { disk.piUsage = (disk.piUsage ?? PiEvents.Usage()) + usage }
        // The found items go into the summary's lines too (a task gets its ticket); the summary
        // was just written by the model, so its hash moves with it and it is not taken for an edit.
        if !answer.links.isEmpty, store.summary(meeting.id) == summary {
            let withLinks = PiDevOpsResearch.linked(summary, answer.links)
            try store.writeSummary(meeting.id, withLinks)
            disk.summaryHash = Self.hash(withLinks)
            MeetingsLog.info(.pi, "\(meeting.id): links put on \(answer.links.count) summary line(s)")
        }
        try store.save(disk)
        meeting = disk
        progress(meeting)
    }

    /// The lock file for one local run at a time; it is in the meetings folder both apps share.
    var localTurnFile: URL { store.root.appending(path: ".local-run.lock") }

    /// Waits (queued) until no other local run holds the turn.
    func localTurn() async throws -> MeetingLock {
        var reported = false
        while true {
            if let lock = MeetingLock.take(localTurnFile) { return lock }
            if !reported {
                local.status(LocalStatus(phase: .queued))
                reported = true
            }
            try local.check()
            try await Task.sleep(for: .seconds(1))
        }
    }

    /// M26: each piece after `done` through whisper, saved after each piece, with a pause while
    /// the Mac must not be busy and a rest after each piece (M27).
    func transcribeLocally(_ meeting: inout Meeting, from done: Int) async throws {
        let pieces = store.pieces(meeting.id)
        guard done < pieces.count else { return }
        guard let tools = whisper ?? LocalWhisper.findCLI().map({ LocalWhisper.Tools(cli: $0) }) else {
            throw MeetingsError.local("whisper-cli is not installed. Click Install whisper.cpp in Meetings Settings.")
        }
        guard LocalWhisper.hasModel(tools.model) else {
            throw MeetingsError.local("the whisper model is not downloaded. Click Download Model in Meetings Settings.")
        }
        let transcriber = LocalTranscriber(tools: tools, settings: settings, local: local)
        let infos = pieces.map { store.pieceInfo($0) ?? PieceInfo(duration: 300, me: []) }
        var offset = infos.prefix(done).reduce(0) { $0 + $1.duration }
        for index in done..<pieces.count {
            let phase = LocalStatus(phase: .transcribing, piece: index + 1, pieces: pieces.count)
            try await local.waitWhilePaused(resume: phase)
            local.status(phase)
            let started = Date()
            let segments = try await transcriber.transcribe(piece: pieces[index], info: infos[index], store: store, offset: offset, phase: phase)
            meeting.segments = (meeting.segments + segments).sorted { $0.start < $1.start }
            meeting.transcribedPieces = index + 1
            try save(&meeting)
            offset += infos[index].duration
            MeetingsLog.info(.processor, "\(meeting.id): local piece \(index + 1)/\(pieces.count) → \(segments.count) segments in \(Int(Date().timeIntervalSince(started))) s")
            if index + 1 < pieces.count {
                let rest = min(Self.longestRest, Date().timeIntervalSince(started))
                try await local.rest(rest, status: LocalStatus(phase: .resting, piece: index + 1, pieces: pieces.count))
            }
        }
    }

    /// M20: whether this chunk goes as two tracks (mic, system) instead of the mix.
    func twoTracks(_ chunk: Chunk) -> Bool {
        let haveTracks = chunk.pieces.allSatisfy { store.track($0, .mic) != nil || store.track($0, .sys) != nil }
        guard haveTracks else { return false }
        switch settings.tracks {
        case .mixed: return false
        case .separate: return true
        case .auto: return overlapSeconds(chunk.me, chunk.others) >= Self.overlapForTwoTracks
        }
    }

    /// One chunk: the mix in one call, or each source's track in its own call, the lines merged by
    /// time. ADTS frames carry their own headers, so pieces join by bytes.
    func transcribe(_ chunk: Chunk, id: String, previous: [Segment], transcriber: Transcriber) async throws -> (segments: [Segment], cost: Double) {
        if twoTracks(chunk) {
            var segments: [Segment] = []
            var cost = 0.0
            for (source, track) in [(TrackSource.mic, Transcriber.Track.mic), (.sys, .system)] {
                let files = chunk.pieces.compactMap { store.track($0, source) }
                // A source silent for the whole chunk has no track files: nothing to send.
                guard !files.isEmpty else { continue }
                var audio = Data()
                for file in files { audio += try Data(contentsOf: file) }
                let mine = previous.filter { track == .system ? $0.speaker.hasPrefix("S") : !$0.speaker.hasPrefix("S") }
                let answer = try await transcriber.transcribe(audio: audio, format: "aac", length: chunk.length, offset: chunk.offset,
                                                              me: track == .mic ? chunk.me : [], previous: mine, track: track)
                MeetingsLog.info(.processor, "\(id): \(track.rawValue) track of \(files.count) piece(s) (\(Int(chunk.length)) s, \(audio.count) bytes) → \(answer.segments.count) segments, \(answer.completion.promptTokens)+\(answer.completion.completionTokens) tokens, $\(answer.completion.cost)")
                segments += answer.segments
                cost += answer.completion.cost
            }
            MeetingsLog.info(.processor, "\(id): two tracks (overlap \(Int(overlapSeconds(chunk.me, chunk.others))) s, mode \(settings.tracks.rawValue))")
            return (segments.sorted { $0.start < $1.start }, cost)
        }
        var audio = Data()
        for piece in chunk.pieces { audio += try Data(contentsOf: piece) }
        let answer = try await transcriber.transcribe(audio: audio, format: "aac", length: chunk.length,
                                                      offset: chunk.offset, me: chunk.me, previous: previous)
        MeetingsLog.info(.processor, "\(id): mixed chunk of \(chunk.pieces.count) pieces (\(Int(chunk.length)) s, \(audio.count) bytes, overlap \(Int(overlapSeconds(chunk.me, chunk.others))) s) → \(answer.segments.count) segments, \(answer.completion.promptTokens)+\(answer.completion.completionTokens) tokens, $\(answer.completion.cost)")
        return (answer.segments, answer.completion.cost)
    }

    /// H5: a `summary.md` the user wrote or changed (not the model's last one) moves to an own
    /// tab, `Notes` (`Notes 2` …), before a new summary replaces it.
    func keepUserSummary(_ id: String) throws {
        guard var current = store.load(id) else { return }
        let text = store.summary(id)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, Self.hash(text) != current.summaryHash else { return }
        var name = "Notes"
        var n = 2
        while MeetingStore.validTabName(name, taken: current.tabs) == nil {
            name = "Notes \(n)"
            n += 1
        }
        try store.addTab(&current, name: name)
        try store.writeTab(id, name, text)
    }

    /// M3: saves the fields this run owns over the file as it is now, so tabs and speakers the
    /// user changed meanwhile stay.
    /// `keepState`: a run while it records leaves the state, failure and length to the recorder.
    func save(_ meeting: inout Meeting, keepState: Bool = false) throws {
        if var disk = store.load(meeting.id) {
            disk.segments = meeting.segments
            disk.transcribedChunks = meeting.transcribedChunks
            disk.transcribedPieces = meeting.transcribedPieces
            disk.costUSD = meeting.costUSD
            if !keepState {
                disk.state = meeting.state
                disk.failure = meeting.failure
                disk.duration = meeting.duration
            }
            disk.model = meeting.model
            disk.summaryModel = meeting.summaryModel
            disk.summaryHash = meeting.summaryHash
            disk.piUsage = meeting.piUsage
            if !meeting.title.isEmpty { disk.title = meeting.title }
            // Proposed tags only while the user has never set any.
            if disk.tags == nil, let tags = meeting.tags { disk.tags = tags }
            meeting = disk
        }
        try store.save(meeting)
        progress(meeting)
    }

    func checkLimit() throws {
        if store.monthCost() >= settings.monthlyLimitUSD { throw MeetingsError.monthlyLimit(settings.monthlyLimitUSD) }
    }

    func fail(_ meeting: inout Meeting, _ error: Error) throws -> Meeting {
        meeting.costUSD += PaidFailure.cost(of: error)
        MeetingsLog.error(.processor, "\(meeting.id): failed: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
        meeting.state = .failed
        meeting.failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        try save(&meeting)
        throw error
    }
}
