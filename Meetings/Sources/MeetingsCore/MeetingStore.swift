import Foundation

/// The meetings folder (M5): `<root>/YYYY-MM-DD/HHmm/` with `meeting.json`, `summary.md`,
/// `transcript.md`, `tabs/<name>.md` and `audio/`. Deleting moves things to the Trash; tests pass
/// their own `trash`.
public struct MeetingStore: Sendable {
    public static let audioDays = 14
    public let root: URL
    let trash: @Sendable (URL) throws -> Void

    public init(root: URL, trash: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        self.root = root
        self.trash = trash
    }

    /// `~/Meetings`.
    public static var defaultRoot: URL { userHome.appending(path: "Meetings") }

    public func folder(_ id: String) -> URL { root.appending(path: id, directoryHint: .isDirectory) }
    public func audioFolder(_ id: String) -> URL { folder(id).appending(path: "audio", directoryHint: .isDirectory) }
    func file(_ id: String, _ name: String) -> URL { folder(id).appending(path: name) }

    // MARK: Meetings

    /// A new meeting folder for a recording that starts now.
    public func create(started: Date = Date(), template: String? = nil) throws -> Meeting {
        let day = Self.dayFormatter.string(from: started)
        let base = "\(day)/\(Self.timeFormatter.string(from: started))"
        var id = base
        var n = 2
        while FileManager.default.fileExists(atPath: folder(id).path) {
            id = "\(base)-\(n)"
            n += 1
        }
        try FileManager.default.createDirectory(at: audioFolder(id), withIntermediateDirectories: true)
        var meeting = Meeting(id: id, started: started)
        meeting.template = template
        try save(meeting)
        return meeting
    }

    /// Every meeting, newest first. A folder whose `meeting.json` cannot be read is left out.
    public func list() -> [Meeting] {
        let fm = FileManager.default
        guard let days = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        var meetings: [Meeting] = []
        for day in days where day.count == 10 && day.first?.isNumber == true {
            guard let times = try? fm.contentsOfDirectory(atPath: root.appending(path: day).path) else { continue }
            for time in times where !time.hasPrefix(".") {
                if let meeting = load("\(day)/\(time)") { meetings.append(meeting) }
            }
        }
        return meetings.sorted { $0.started > $1.started }
    }

    public func load(_ id: String) -> Meeting? {
        guard let data = try? Data(contentsOf: file(id, "meeting.json")) else { return nil }
        return try? Self.decoder.decode(Meeting.self, from: data)
    }

    /// Writes `meeting.json` and the transcript page made from it.
    public func save(_ meeting: Meeting) throws {
        try FileManager.default.createDirectory(at: folder(meeting.id), withIntermediateDirectories: true)
        try Self.encoder.encode(meeting).write(to: file(meeting.id, "meeting.json"), options: .atomic)
        try Data(Self.transcriptMarkdown(meeting).utf8).write(to: file(meeting.id, "transcript.md"), options: .atomic)
    }

    /// The whole meeting folder, audio and pages, to the Trash.
    public func moveToTrash(_ id: String) throws {
        try trash(folder(id))
        let day = folder(id).deletingLastPathComponent()
        if (try? FileManager.default.contentsOfDirectory(atPath: day.path))?.isEmpty == true { try? FileManager.default.removeItem(at: day) }
    }

    // MARK: Pages

    public static func transcriptMarkdown(_ meeting: Meeting) -> String {
        var lines = ["# \(meeting.displayTitle)", ""]
        for segment in meeting.segments {
            lines.append("[\(timestamp(segment.start))] **\(meeting.speakerName(segment.speaker))**: \(segment.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    public func summary(_ id: String) -> String {
        (try? String(contentsOf: file(id, "summary.md"), encoding: .utf8)) ?? ""
    }

    public func writeSummary(_ id: String, _ text: String) throws {
        try Data(text.utf8).write(to: file(id, "summary.md"), options: .atomic)
    }

    /// Renames a speaker: `meeting.json`, the transcript page, and the old name in the summary.
    public func renameSpeaker(_ meeting: inout Meeting, key: String, to name: String) throws {
        let old = meeting.speakerName(key)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        meeting.speakers[key] = trimmed.isEmpty ? nil : trimmed
        let new = meeting.speakerName(key)
        try save(meeting)
        if old != new {
            let text = summary(meeting.id)
            if text.contains(old) {
                let renamed = text.replacingOccurrences(of: old, with: new)
                try writeSummary(meeting.id, renamed)
                // Still the model's summary, only with the name: not a user edit to keep later.
                if MeetingProcessor.hash(text) == meeting.summaryHash {
                    meeting.summaryHash = MeetingProcessor.hash(renamed)
                    try save(meeting)
                }
            }
        }
    }

    /// M22: the meeting's template (the summary is written again by the caller).
    public func setTemplate(_ meeting: inout Meeting, _ id: String) throws {
        meeting.template = id
        try save(meeting)
    }

    /// M23: the meeting's tags, cleaned, without repeats; an empty list stays empty.
    public func setTags(_ meeting: inout Meeting, _ tags: [String]) throws {
        var kept: [String] = []
        for tag in tags.map(Meeting.cleanTag) where !tag.isEmpty && !kept.contains(tag) { kept.append(tag) }
        meeting.tags = kept
        try save(meeting)
    }

    /// M25: when the host took the meeting somewhere (`worklog`, `notebook`, `knowledge`).
    public func markExport(_ meeting: inout Meeting, _ place: String, at date: Date = Date()) throws {
        var exports = meeting.exports ?? [:]
        exports[place] = date
        meeting.exports = exports
        try save(meeting)
    }

    /// M25: a cost of a call made for the meeting after its run (facts for the knowledge base).
    public func addCost(_ meeting: inout Meeting, _ cost: Double) throws {
        meeting.costUSD += cost
        try save(meeting)
    }

    // MARK: Own tabs (M17)

    public func tabFile(_ id: String, _ name: String) -> URL {
        folder(id).appending(path: "tabs/\(name).md")
    }

    public func tab(_ id: String, _ name: String) -> String {
        (try? String(contentsOf: tabFile(id, name), encoding: .utf8)) ?? ""
    }

    public func writeTab(_ id: String, _ name: String, _ text: String) throws {
        let url = tabFile(id, name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    /// A tab name that can be a file name: no slashes, no leading dot, not empty, not taken.
    public static func validTabName(_ name: String, taken: [String]) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("."), !trimmed.contains("/"), !trimmed.contains(":"),
              trimmed != "Summary", trimmed != "Transcript",
              !taken.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return nil }
        return trimmed
    }

    public func addTab(_ meeting: inout Meeting, name: String) throws {
        guard let name = Self.validTabName(name, taken: meeting.tabs) else { throw MeetingsError.badTabName(name) }
        try writeTab(meeting.id, name, "")
        meeting.tabs.append(name)
        try save(meeting)
    }

    public func renameTab(_ meeting: inout Meeting, from old: String, to name: String) throws {
        guard let index = meeting.tabs.firstIndex(of: old) else { return }
        guard let name = Self.validTabName(name, taken: meeting.tabs.filter { $0 != old }) else { throw MeetingsError.badTabName(name) }
        let from = tabFile(meeting.id, old)
        if FileManager.default.fileExists(atPath: from.path) {
            try FileManager.default.moveItem(at: from, to: tabFile(meeting.id, name))
        }
        meeting.tabs[index] = name
        try save(meeting)
    }

    public func removeTab(_ meeting: inout Meeting, name: String) throws {
        let url = tabFile(meeting.id, name)
        if FileManager.default.fileExists(atPath: url.path) { try trash(url) }
        meeting.tabs.removeAll { $0 == name }
        try save(meeting)
    }

    /// A picture pasted into a tab: `tabs/assets/<time>.<ext>`; the tab links it as `assets/…`.
    public func saveTabImage(_ id: String, data: Data, ext: String) throws -> String {
        try Self.saveImage(in: folder(id).appending(path: "tabs", directoryHint: .isDirectory), data: data, ext: ext)
    }

    /// The file of a tab's `assets/…` link; nil for anything else (no `..`).
    public func tabImage(_ id: String, link: String) -> URL? {
        Self.image(in: folder(id).appending(path: "tabs", directoryHint: .isDirectory), link: link)
    }

    /// The same for an editor that knows only the tabs folder (`MeetingsPage.folder`).
    public static func saveImage(in tabs: URL, data: Data, ext: String) throws -> String {
        let safe = ext.lowercased().filter { $0.isLetter || $0.isNumber }
        let name = "\(Int(Date().timeIntervalSince1970 * 1000)).\(safe.isEmpty ? "png" : safe)"
        let folder = tabs.appending(path: "assets", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appending(path: name), options: .atomic)
        return "assets/\(name)"
    }

    public static func image(in tabs: URL, link: String) -> URL? {
        guard link.hasPrefix("assets/"), !link.contains(".."), !link.dropFirst(7).contains("/") else { return nil }
        let url = tabs.appending(path: link)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: Audio

    /// The mixed pieces (`piece-001.aac` …) in order.
    public func pieces(_ id: String) -> [URL] {
        let folder = audioFolder(id)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasPrefix("piece-") && $0.hasSuffix(".aac") }.sorted().map { folder.appending(path: $0) }
    }

    /// How many pieces from the first are whole: the mixer writes a piece's `.json` last, so a
    /// piece without it is still being written (while it records).
    public func readyPieceCount(_ id: String) -> Int {
        var count = 0
        for piece in pieces(id) {
            guard FileManager.default.fileExists(atPath: piece.deletingPathExtension().appendingPathExtension("json").path) else { break }
            count += 1
        }
        return count
    }

    /// The number the next recorded piece gets (Record More): one after the highest piece.
    public func nextPieceNumber(_ id: String) -> Int {
        let numbers = pieces(id).compactMap { Int($0.deletingPathExtension().lastPathComponent.dropFirst("piece-".count)) }
        return (numbers.max() ?? 0) + 1
    }

    /// A piece's facts written by the mixer: its length and when the microphone carried speech.
    public func pieceInfo(_ piece: URL) -> PieceInfo? {
        guard let data = try? Data(contentsOf: piece.deletingPathExtension().appendingPathExtension("json")) else { return nil }
        return try? JSONDecoder().decode(PieceInfo.self, from: data)
    }

    /// M7: the audio of meetings past their `audioUntil` goes to the Trash (recoverable there).
    /// M29: only a done meeting whose transcript covers every piece; a failed, waiting or
    /// recording one keeps its audio until it is transcribed. Returns how many lost their audio.
    @discardableResult
    public func trashExpiredAudio(now: Date = Date()) -> Int {
        var count = 0
        for var meeting in list() where !meeting.audioTrashed && meeting.audioUntil < now && isFullyTranscribed(meeting) {
            let folder = audioFolder(meeting.id)
            if FileManager.default.fileExists(atPath: folder.path) {
                guard (try? trash(folder)) != nil else { continue }
            }
            meeting.audioTrashed = true
            try? save(meeting)
            count += 1
        }
        return count
    }

    /// Done, and every mixed piece is in the transcript (older files without `transcribedPieces`:
    /// done is enough, as before).
    public func isFullyTranscribed(_ meeting: Meeting) -> Bool {
        guard meeting.state == .done else { return false }
        guard let done = meeting.transcribedPieces else { return true }
        return done >= pieces(meeting.id).count
    }

    /// What OpenRouter cost in the calendar month of `date`: the meetings' calls and the
    /// questions (M24).
    public func monthCost(of date: Date = Date()) -> Double {
        let calendar = Calendar.current
        let meetings = list().filter { calendar.isDate($0.started, equalTo: date, toGranularity: .month) }.reduce(0) { $0 + $1.costUSD }
        let asks = AskLog(root: root).entries().filter { calendar.isDate($0.date, equalTo: date, toGranularity: .month) }.reduce(0) { $0 + $1.costUSD }
        return meetings + asks
    }

    // MARK: Formats

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HHmm"
        return f
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    /// One JSON line (`.asks.jsonl`).
    static let encoderLine: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// `piece-NNN.json`: the piece's length in seconds and the spans (seconds from the piece's start)
/// in which the microphone carried speech (M12) and in which the system sound did (`others`, M20;
/// nil in pieces mixed before it).
public struct PieceInfo: Codable, Equatable, Sendable {
    public var duration: TimeInterval
    public var me: [TimeSpan]
    public var others: [TimeSpan]?

    public init(duration: TimeInterval, me: [TimeSpan], others: [TimeSpan]? = nil) {
        self.duration = duration
        self.me = me
        self.others = others
    }
}

/// M20: one source's own track of a piece, beside the mix (`mic-003.aac`, `sys-003.aac`); nil
/// when the piece has none (an older piece, a silent source).
public enum TrackSource: String, Sendable { case mic, sys }

extension MeetingStore {
    public func track(_ piece: URL, _ source: TrackSource) -> URL? {
        let name = piece.lastPathComponent.replacingOccurrences(of: "piece-", with: "\(source.rawValue)-")
        let url = piece.deletingLastPathComponent().appending(path: name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

/// Seconds in which both lists of spans overlap.
public func overlapSeconds(_ a: [TimeSpan], _ b: [TimeSpan]) -> TimeInterval {
    var total: TimeInterval = 0
    for x in a {
        for y in b {
            let start = max(x.start, y.start), end = min(x.end, y.end)
            if end > start { total += end - start }
        }
    }
    return total
}

public struct TimeSpan: Codable, Equatable, Sendable {
    public var start: TimeInterval
    public var end: TimeInterval

    public init(start: TimeInterval, end: TimeInterval) {
        self.start = start
        self.end = end
    }
}

/// A call OpenRouter answered (and charged) whose answer could not be read: the cost still
/// counts (review 2026-11-06).
public struct PaidFailure: Error, LocalizedError {
    public let cost: Double
    public let underlying: Error
    public var errorDescription: String? { (underlying as? LocalizedError)?.errorDescription ?? underlying.localizedDescription }

    /// Runs `parse`; a failure carries the completion's cost.
    public static func parse<T>(_ completion: Completion, _ parse: () throws -> T) throws -> T {
        do { return try parse() } catch {
            // Only sizes and shape, never the answer's text.
            let text = completion.text
            let shape = "\(text.count) chars, \(text.filter { $0 == "{" }.count) '{' / \(text.filter { $0 == "}" }.count) '}', starts with JSON: \(text.drop(while: \.isWhitespace).first == "{" || text.hasPrefix("```"))"
            let cutOff = completion.finishReason == "length" ? " The answer was cut off at the model's output limit." : ""
            MeetingsLog.error(.openrouter, "answer not readable: \((error as? LocalizedError)?.errorDescription ?? "\(error)"); finish reason \(completion.finishReason ?? "none"), \(completion.completionTokens) output tokens, $\(completion.cost), \(shape).\(cutOff)")
            throw PaidFailure(cost: completion.cost, underlying: error)
        }
    }

    /// The cost a thrown error carries; 0 for others.
    public static func cost(of error: Error) -> Double { (error as? PaidFailure)?.cost ?? 0 }
}

public enum MeetingsError: Error, LocalizedError, Equatable {
    case badTabName(String)
    case noKey
    case monthlyLimit(Double)
    case http(Int, String)
    case badAnswer(String)
    case noAudio
    case noTranscript
    case notTranscribed
    case busy
    /// M27: the user clicked Stop on a local run.
    case stopped
    /// M27: the Mac got critically hot during a local run.
    case tooHot
    /// M26: whisper.cpp or afconvert failed, or is missing.
    case local(String)
    /// M28: Pi failed or is missing.
    case pi(String)

    public var errorDescription: String? {
        switch self {
        case .badTabName(let name): "“\(name)” cannot be a tab name: it is empty, taken, or has a / or :."
        case .noKey: "No OpenRouter key. Add it in Meetings Settings."
        case .monthlyLimit(let limit): String(format: "This month's limit of $%.2f is reached. Raise it in Meetings Settings.", limit)
        case .http(401, _): "OpenRouter does not accept the key (401). Paste a key from openrouter.ai/keys in Meetings Settings, then Try Again."
        case .http(let code, let message): "OpenRouter answered \(code): \(message)"
        case .badAnswer(let detail): "The model's answer could not be read: \(detail)"
        case .noAudio: "This meeting has no audio left to transcribe."
        case .noTranscript: "This meeting has no transcript to summarize yet."
        case .notTranscribed: "Part of this meeting is not transcribed yet. Try Again first, then the summary is written from the whole transcript."
        case .busy: "This meeting is being transcribed already (here or in the other Meetings app)."
        case .stopped: "Stopped by you. Try Again goes on from the next piece."
        case .tooHot: "Stopped: the Mac got critically hot. Try Again goes on from the next piece."
        case .local(let detail): "Local transcription failed: \(detail)"
        case .pi(let detail): "Pi could not write the summary: \(detail)"
        }
    }
}
