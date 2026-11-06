import Foundation

/// The settings both hosts share (AKit's Work → Meetings and `Meetings.app`), kept in
/// `~/Library/Application Support/Meetings/settings.json`. The OpenRouter key is not here: it is
/// in the Keychain (M9).
public struct MeetingsSettings: Codable, Equatable, Sendable {
    public static let defaultModel = "google/gemini-2.5-flash-lite"
    public static let languages = ["Czech", "Russian", "English", "Slovak", "German", "Ukrainian"]

    /// The audio model (M10).
    public var model: String = defaultModel
    /// The summary's model; nil is the audio model.
    public var summaryModel: String?
    /// The language of the summary, decisions and tasks (M14).
    public var language: String = "Czech"
    /// The transcript's likely language, a hint for the model.
    public var spokenHint: String = "Czech, sometimes Russian or English"
    /// New calls stop at this month's cost (M11).
    public var monthlyLimitUSD: Double = 10
    /// The meetings folder; nil is `~/Meetings`.
    public var rootPath: String?
    /// Echo cancellation on the microphone, so sound from the speakers is not recorded twice.
    public var echoCancellation: Bool = true
    /// M20: how the microphone and the system sound go to the model.
    public var tracks: TrackMode = .auto
    /// M22: the template a new meeting takes, and the user's own templates beside the built-in ones.
    public var defaultTemplate: String = MeetingTemplate.generalID
    public var customTemplates: [MeetingTemplate] = []
    /// M22: a clean transcript (no filler words, stutters, repeats) or word for word.
    public var cleanTranscript: Bool = true

    public enum TrackMode: String, Codable, Sendable, CaseIterable {
        /// One mixed track (1×).
        case mixed
        /// Mixed, but a chunk where the room and the call talk at the same time for a while goes as
        /// two tracks.
        case auto
        /// Always two tracks (2×).
        case separate

        public var title: String {
            switch self {
            case .mixed: "Mixed: one track (cheapest)"
            case .auto: "Auto: two tracks where voices overlap"
            case .separate: "Separate: always two tracks (2× cost)"
            }
        }
    }

    public init() {}

    public var templates: [MeetingTemplate] { MeetingTemplate.builtIn + customTemplates }

    /// The template of an id; General for an unknown one (an own template that was removed).
    public func template(_ id: String?) -> MeetingTemplate {
        templates.first { $0.id == (id ?? defaultTemplate) } ?? templates.first { $0.id == defaultTemplate } ?? MeetingTemplate.builtIn[0]
    }

    public var root: URL { rootPath.map { URL(filePath: $0, directoryHint: .isDirectory) } ?? MeetingStore.defaultRoot }

    public static var defaultFile: URL {
        userHome.appending(path: "Library/Application Support/Meetings/settings.json")
    }

    /// Missing keys take their defaults, so an older file still loads.
    public static func load(from url: URL = defaultFile) -> MeetingsSettings {
        guard let data = try? Data(contentsOf: url) else { return MeetingsSettings() }
        return (try? JSONDecoder().decode(MeetingsSettings.self, from: data)) ?? MeetingsSettings()
    }

    public func save(to url: URL = defaultFile) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MeetingsSettings()
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        summaryModel = try c.decodeIfPresent(String.self, forKey: .summaryModel)
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? d.language
        spokenHint = try c.decodeIfPresent(String.self, forKey: .spokenHint) ?? d.spokenHint
        monthlyLimitUSD = try c.decodeIfPresent(Double.self, forKey: .monthlyLimitUSD) ?? d.monthlyLimitUSD
        rootPath = try c.decodeIfPresent(String.self, forKey: .rootPath)
        echoCancellation = try c.decodeIfPresent(Bool.self, forKey: .echoCancellation) ?? d.echoCancellation
        tracks = (try? c.decodeIfPresent(TrackMode.self, forKey: .tracks)) ?? d.tracks
        defaultTemplate = try c.decodeIfPresent(String.self, forKey: .defaultTemplate) ?? d.defaultTemplate
        customTemplates = (try? c.decodeIfPresent([MeetingTemplate].self, forKey: .customTemplates)) ?? d.customTemplates
        cleanTranscript = try c.decodeIfPresent(Bool.self, forKey: .cleanTranscript) ?? d.cleanTranscript
    }
}
