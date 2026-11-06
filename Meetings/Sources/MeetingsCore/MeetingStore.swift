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
    public func create(started: Date = Date()) throws -> Meeting {
        let day = Self.dayFormatter.string(from: started)
        let base = "\(day)/\(Self.timeFormatter.string(from: started))"
        var id = base
        var n = 2
        while FileManager.default.fileExists(atPath: folder(id).path) {
            id = "\(base)-\(n)"
            n += 1
        }
        try FileManager.default.createDirectory(at: audioFolder(id), withIntermediateDirectories: true)
        let meeting = Meeting(id: id, started: started)
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
            if text.contains(old) { try writeSummary(meeting.id, text.replacingOccurrences(of: old, with: new)) }
        }
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

    /// A piece's facts written by the mixer: its length and when the microphone carried speech.
    public func pieceInfo(_ piece: URL) -> PieceInfo? {
        guard let data = try? Data(contentsOf: piece.deletingPathExtension().appendingPathExtension("json")) else { return nil }
        return try? JSONDecoder().decode(PieceInfo.self, from: data)
    }

    /// M7: the audio of meetings past their `audioUntil` goes to the Trash. Not while a meeting
    /// records or waits for its transcript. Returns how many meetings lost their audio.
    @discardableResult
    public func trashExpiredAudio(now: Date = Date()) -> Int {
        var count = 0
        for var meeting in list() where !meeting.audioTrashed && meeting.audioUntil < now
            && (meeting.state == .done || meeting.state == .failed) {
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

    /// What OpenRouter cost in the calendar month of `date`.
    public func monthCost(of date: Date = Date()) -> Double {
        let calendar = Calendar.current
        return list().filter { calendar.isDate($0.started, equalTo: date, toGranularity: .month) }.reduce(0) { $0 + $1.costUSD }
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

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// `piece-NNN.json`: the piece's length in seconds and the spans (seconds from the piece's start)
/// in which the microphone carried speech (M12).
public struct PieceInfo: Codable, Equatable, Sendable {
    public var duration: TimeInterval
    public var me: [TimeSpan]

    public init(duration: TimeInterval, me: [TimeSpan]) {
        self.duration = duration
        self.me = me
    }
}

public struct TimeSpan: Codable, Equatable, Sendable {
    public var start: TimeInterval
    public var end: TimeInterval

    public init(start: TimeInterval, end: TimeInterval) {
        self.start = start
        self.end = end
    }
}

public enum MeetingsError: Error, LocalizedError, Equatable {
    case badTabName(String)
    case noKey
    case monthlyLimit(Double)
    case http(Int, String)
    case badAnswer(String)
    case noAudio
    case busy

    public var errorDescription: String? {
        switch self {
        case .badTabName(let name): "“\(name)” cannot be a tab name: it is empty, taken, or has a / or :."
        case .noKey: "No OpenRouter key. Add it in Meetings Settings."
        case .monthlyLimit(let limit): String(format: "This month's limit of $%.2f is reached. Raise it in Meetings Settings.", limit)
        case .http(let code, let message): "OpenRouter answered \(code): \(message)"
        case .badAnswer(let detail): "The model's answer could not be read: \(detail)"
        case .noAudio: "This meeting has no audio left to transcribe."
        case .busy: "This meeting is being transcribed already (here or in the other Meetings app)."
        }
    }
}
