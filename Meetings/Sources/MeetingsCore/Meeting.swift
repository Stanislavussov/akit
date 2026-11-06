import Foundation

/// One meeting: its state and transcript, kept as `meeting.json` in the meeting's folder
/// (docs/design/meetings.md, M5). The human pages beside it (`summary.md`, `transcript.md`,
/// `tabs/*.md`) are Markdown.
public struct Meeting: Codable, Equatable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable {
        case recording, waiting, transcribing, done, failed
    }

    /// The folder below the root, `YYYY-MM-DD/HHmm` (`-2`, `-3` … for more in the same minute).
    public var id: String
    public var title: String
    public var started: Date
    /// Seconds of audio, the sum of the mixed pieces.
    public var duration: TimeInterval
    public var state: State
    /// Why the last transcription stopped (state `failed`).
    public var failure: String?
    /// The model that wrote the transcript, and the one that wrote the summary.
    public var model: String?
    public var summaryModel: String?
    /// The sum of the costs OpenRouter reported for this meeting's calls.
    public var costUSD: Double
    /// Speaker key (`Me`, `S1`, `S2` …) → the name shown. A key without a name shows as itself
    /// (`S1` → "Speaker 1").
    public var speakers: [String: String]
    public var segments: [Segment]
    /// How many audio chunks (M13) are already in `segments` (shown while it transcribes).
    public var transcribedChunks: Int
    /// How many pieces are already in `segments`, so a retry goes on from the next piece (nil in
    /// files written before 2026-11-06's review: then all pieces of the done chunks).
    public var transcribedPieces: Int?
    /// The hash of the summary the model last wrote: a different `summary.md` holds the user's
    /// own edits, which a new summary keeps in an own tab.
    public var summaryHash: String?
    /// Audio the recorder or mixer could not keep (a piece that did not mix, a source that stopped).
    public var warnings: [String]?
    /// The user's own tabs (M17), in their order; each is `tabs/<name>.md`.
    public var tabs: [String]
    /// After this day the audio goes to the Trash (M7).
    public var audioUntil: Date
    public var audioTrashed: Bool

    public init(id: String, started: Date, audioDays: Int = MeetingStore.audioDays) {
        self.id = id
        title = ""
        self.started = started
        duration = 0
        state = .recording
        costUSD = 0
        speakers = [:]
        segments = []
        transcribedChunks = 0
        tabs = []
        audioUntil = Calendar.current.date(byAdding: .day, value: audioDays, to: started) ?? started
        audioTrashed = false
    }

    /// The title, or the start time when the summary has not named it yet.
    public var displayTitle: String {
        title.isEmpty ? "Meeting " + started.formatted(date: .omitted, time: .shortened) : title
    }

    /// The name shown for a speaker key.
    public func speakerName(_ key: String) -> String {
        if let name = speakers[key], !name.isEmpty { return name }
        if key.hasPrefix("S"), let number = Int(key.dropFirst()) { return "Speaker \(number)" }
        if key.hasPrefix("R"), let number = Int(key.dropFirst()) { return "Room \(number)" }
        return key
    }

    /// The speaker keys in the order they first speak.
    public var speakerKeys: [String] {
        var seen: [String] = []
        for segment in segments where !seen.contains(segment.speaker) { seen.append(segment.speaker) }
        return seen
    }
}

/// One line of the transcript: when it starts (seconds from the recording's start), who speaks
/// (`Me`, `S1` …) and what was said.
public struct Segment: Codable, Equatable, Sendable {
    public var start: TimeInterval
    public var speaker: String
    public var text: String

    public init(start: TimeInterval, speaker: String, text: String) {
        self.start = start
        self.speaker = speaker
        self.text = text
    }
}

/// `[mm:ss]`, or `[h:mm:ss]` from one hour on.
public func timestamp(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds.rounded(.down)))
    let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
}

/// `42 min`, `1 h 05 min`.
public func lengthText(_ seconds: TimeInterval) -> String {
    let minutes = Int((seconds / 60).rounded())
    return minutes >= 60 ? String(format: "%d h %02d min", minutes / 60, minutes % 60) : "\(minutes) min"
}

/// The home folder: `$HOME` when set (a made-up home for screenshots), else the user's.
public var userHome: URL {
    if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty { return URL(filePath: home, directoryHint: .isDirectory) }
    return FileManager.default.homeDirectoryForCurrentUser
}
