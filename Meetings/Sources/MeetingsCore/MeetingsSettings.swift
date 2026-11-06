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

    public init() {}

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
    }
}
