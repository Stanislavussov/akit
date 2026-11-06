import Foundation

/// Turns a stopped recording into its transcript and summary (M13, M15). The mixed pieces are
/// sent in chunks of up to `piecesPerChunk` pieces (6 × 5 min = 30 min); after each chunk the
/// meeting is saved, so a failed run goes on from the chunk that failed.
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

    /// A chunk: its pieces and where it starts in the recording.
    struct Chunk {
        var pieces: [URL]
        var offset: TimeInterval
        var length: TimeInterval
        var me: [TimeSpan]
    }

    func chunks(_ id: String) -> [Chunk] {
        let pieces = store.pieces(id)
        var result: [Chunk] = []
        var offset: TimeInterval = 0
        var index = 0
        while index < pieces.count {
            let group = Array(pieces[index..<min(index + Self.piecesPerChunk, pieces.count)])
            var chunk = Chunk(pieces: group, offset: offset, length: 0, me: [])
            for piece in group {
                let info = store.pieceInfo(piece) ?? PieceInfo(duration: 300, me: [])
                chunk.me += info.me.map { TimeSpan(start: $0.start + chunk.length, end: $0.end + chunk.length) }
                chunk.length += info.duration
            }
            result.append(chunk)
            offset += chunk.length
            index += Self.piecesPerChunk
        }
        return result
    }

    /// Runs the chunks not yet done, then the summary. A start over (Transcribe Again) passes
    /// `restart`. Throws after saving the meeting as `failed` with the reason.
    @discardableResult
    public func run(_ id: String, restart: Bool = false) async throws -> Meeting {
        guard var meeting = store.load(id) else { throw MeetingsError.noAudio }
        let chunks = chunks(id)
        if restart {
            meeting.segments = []
            meeting.transcribedChunks = 0
        }
        guard !chunks.isEmpty || meeting.transcribedChunks > 0 && !meeting.segments.isEmpty else {
            return try fail(&meeting, MeetingsError.noAudio)
        }
        if !chunks.isEmpty { meeting.duration = chunks.reduce(0) { $0 + $1.length } }
        meeting.state = .transcribing
        meeting.failure = nil
        meeting.model = settings.model
        try store.save(meeting)
        progress(meeting)
        do {
            for (number, chunk) in chunks.enumerated() where number >= meeting.transcribedChunks {
                try checkLimit()
                var audio = Data()
                // ADTS frames carry their own headers, so pieces join by bytes.
                for piece in chunk.pieces { audio += try Data(contentsOf: piece) }
                let answer = try await transcriber.transcribe(audio: audio, format: "aac", length: chunk.length,
                                                              offset: chunk.offset, me: chunk.me, previous: meeting.segments)
                meeting.segments += answer.segments
                meeting.costUSD += answer.completion.cost
                meeting.transcribedChunks = number + 1
                try store.save(meeting)
                progress(meeting)
            }
            if meeting.segments.isEmpty {
                try store.writeSummary(id, "## Summary\n\nNothing was said in this recording.\n")
            } else {
                try checkLimit()
                let answer = try await transcriber.summarize(meeting)
                meeting.costUSD += answer.completion.cost
                meeting.summaryModel = settings.summaryModel ?? settings.model
                if !answer.summary.title.isEmpty { meeting.title = answer.summary.title }
                try store.writeSummary(id, answer.summary.markdown)
            }
            meeting.state = .done
            try store.save(meeting)
            progress(meeting)
            return meeting
        } catch {
            return try fail(&meeting, error)
        }
    }

    func checkLimit() throws {
        if store.monthCost() >= settings.monthlyLimitUSD { throw MeetingsError.monthlyLimit(settings.monthlyLimitUSD) }
    }

    func fail(_ meeting: inout Meeting, _ error: Error) throws -> Meeting {
        meeting.state = .failed
        meeting.failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        try store.save(meeting)
        progress(meeting)
        throw error
    }
}
