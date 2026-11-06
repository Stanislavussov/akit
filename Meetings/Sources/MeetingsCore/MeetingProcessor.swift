import CryptoKit
import Foundation

/// Turns a stopped recording into its transcript and summary (M13, M15). The mixed pieces not yet
/// transcribed are sent in chunks of up to `piecesPerChunk` pieces (6 × 5 min = 30 min); after
/// each chunk the meeting is saved, so a failed run goes on from the next piece. While it runs it
/// holds the meeting's processing lock, so a second host does not send the same audio again.
public struct MeetingProcessor: Sendable {
    public static let piecesPerChunk = 6
    let store: MeetingStore
    let settings: MeetingsSettings
    let transcriber: Transcriber
    /// Called after each saved step, for the screen.
    let progress: @Sendable (Meeting) -> Void

    public init(store: MeetingStore, settings: MeetingsSettings, client: OpenRouterClient, progress: @escaping @Sendable (Meeting) -> Void = { _ in }) {
        self.store = store
        self.settings = settings
        transcriber = Transcriber(client: client, settings: settings)
        self.progress = progress
    }

    /// A chunk: its pieces, where it starts in the recording, and how many pieces end with it.
    struct Chunk {
        var pieces: [URL]
        var offset: TimeInterval
        var length: TimeInterval
        var me: [TimeSpan]
        var endPiece: Int
    }

    /// The chunks of the pieces after the first `done`; offsets count every piece before.
    func chunks(_ id: String, after done: Int) -> (chunks: [Chunk], duration: TimeInterval) {
        let pieces = store.pieces(id)
        let infos = pieces.map { store.pieceInfo($0) ?? PieceInfo(duration: 300, me: []) }
        let start = min(done, pieces.count)
        var offset = infos.prefix(start).reduce(0) { $0 + $1.duration }
        var result: [Chunk] = []
        var index = start
        while index < pieces.count {
            let end = min(index + Self.piecesPerChunk, pieces.count)
            var chunk = Chunk(pieces: Array(pieces[index..<end]), offset: offset, length: 0, me: [], endPiece: end)
            for info in infos[index..<end] {
                chunk.me += info.me.map { TimeSpan(start: $0.start + chunk.length, end: $0.end + chunk.length) }
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
        // A restart without audio keeps the transcript it has (L1).
        if store.pieces(id).isEmpty && (restart || meeting.segments.isEmpty) {
            return try fail(&meeting, MeetingsError.noAudio)
        }
        let done = restart ? 0 : meeting.transcribedPieces ?? meeting.transcribedChunks * Self.piecesPerChunk
        let plan = chunks(id, after: done)
        if restart {
            meeting.segments = []
            meeting.transcribedChunks = 0
        }
        if plan.duration > 0 { meeting.duration = plan.duration }
        meeting.state = .transcribing
        meeting.failure = nil
        meeting.model = settings.model
        meeting.transcribedPieces = min(done, store.pieces(id).count)
        try save(&meeting)
        do {
            for chunk in plan.chunks {
                try checkLimit()
                var audio = Data()
                // ADTS frames carry their own headers, so pieces join by bytes.
                for piece in chunk.pieces { audio += try Data(contentsOf: piece) }
                let answer = try await transcriber.transcribe(audio: audio, format: "aac", length: chunk.length,
                                                              offset: chunk.offset, me: chunk.me, previous: meeting.segments)
                meeting.segments += answer.segments
                meeting.costUSD += answer.completion.cost
                meeting.transcribedChunks += 1
                meeting.transcribedPieces = chunk.endPiece
                try save(&meeting)
            }
            let summary: String
            if meeting.segments.isEmpty {
                summary = "## Summary\n\nNothing was said in this recording.\n"
            } else {
                try checkLimit()
                let answer = try await transcriber.summarize(meeting)
                meeting.costUSD += answer.completion.cost
                meeting.summaryModel = settings.summaryModel ?? settings.model
                if !answer.summary.title.isEmpty { meeting.title = answer.summary.title }
                summary = answer.summary.markdown
            }
            try keepUserSummary(meeting.id)
            try store.writeSummary(id, summary)
            meeting.summaryHash = Self.hash(summary)
            meeting.state = .done
            try save(&meeting)
            return meeting
        } catch {
            return try fail(&meeting, error)
        }
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
    func save(_ meeting: inout Meeting) throws {
        if var disk = store.load(meeting.id) {
            disk.segments = meeting.segments
            disk.transcribedChunks = meeting.transcribedChunks
            disk.transcribedPieces = meeting.transcribedPieces
            disk.costUSD = meeting.costUSD
            disk.state = meeting.state
            disk.failure = meeting.failure
            disk.model = meeting.model
            disk.summaryModel = meeting.summaryModel
            disk.summaryHash = meeting.summaryHash
            disk.duration = meeting.duration
            if !meeting.title.isEmpty { disk.title = meeting.title }
            meeting = disk
        }
        try store.save(meeting)
        progress(meeting)
    }

    func checkLimit() throws {
        if store.monthCost() >= settings.monthlyLimitUSD { throw MeetingsError.monthlyLimit(settings.monthlyLimitUSD) }
    }

    func fail(_ meeting: inout Meeting, _ error: Error) throws -> Meeting {
        meeting.state = .failed
        meeting.failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        try save(&meeting)
        throw error
    }
}
