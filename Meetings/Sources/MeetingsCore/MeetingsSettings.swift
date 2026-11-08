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
    /// M26: who turns the audio into text: OpenRouter or whisper on this Mac.
    public var transcription: Engine = .cloud
    /// M28: who writes the summary: OpenRouter or Pi.
    public var summarizer: Summarizer = .openRouter
    /// Pi's model (`provider/id`); nil is Pi's own default.
    public var piModel: String?
    /// M37: after Pi wrote the summary, Pi looks in Azure DevOps (read only) for related work
    /// items, rules, wiki pages, history and artifacts, into the tab "Azure DevOps".
    public var piDevOps: Bool = false
    /// The Pi MCP server for that; nil is the first whose name says Azure DevOps.
    public var piDevOpsServer: String?
    /// M37: the same run also reads GitLab: the repositories' tags and how their code does it.
    public var piGitLab: Bool = false
    /// The Pi MCP server for GitLab; nil is the first whose name says GitLab.
    public var piGitLabServer: String?
    /// The GitLab repositories to search (`col-fe`, `col-be`, `shell-fe` …); empty = the ones the
    /// meeting or the work items name.
    public var piRepositories: [String] = []
    /// whisper's language code, `auto` to detect per piece.
    public var localLanguage: String = "auto"
    /// M27: whisper on the GPU at background priority (fast, little CPU); off is the efficiency
    /// cores only (about 4× slower than the meeting).
    public var localGPU: Bool = true

    public enum Engine: String, Codable, Sendable, CaseIterable {
        case cloud, local

        public var title: String {
            switch self {
            case .cloud: "Cloud: OpenRouter"
            case .local: "Local: whisper on this Mac (free)"
            }
        }
    }

    public enum Summarizer: String, Codable, Sendable, CaseIterable {
        case openRouter, pi

        public var title: String {
            switch self {
            case .openRouter: "OpenRouter"
            case .pi: "Pi (your coding agent)"
            }
        }
    }

    /// Whether any step calls OpenRouter, so the key is needed.
    public var needsKey: Bool { transcription == .cloud || summarizer == .openRouter }
    /// M30: the project's own words (names, services, products, terms), one per entry, so the
    /// model writes them right instead of a word that sounds close.
    public var vocabulary: [String] = []
    /// M31: a short sound when the background recorder starts and stops (nothing on screen).
    public var backgroundSounds: Bool = true
    /// M35: while it records, each finished 5-minute piece is transcribed at once (cloud only), so
    /// after Stop only the last piece and the summary are left.
    public var transcribeWhileRecording: Bool = true

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

    /// At most this many terms go into a prompt (about 6,000 tokens at most).
    public static let vocabularyLimit = 1_500

    /// The terms of a text or a file: one per line, or separated by commas or semicolons; a line
    /// may be `term — hint` or `term: hint` (the hint stays, it helps the model). Lines starting
    /// with `#` and repeats (case ignored) are left out.
    public static func vocabulary(from text: String) -> [String] {
        var seen = Set<String>()
        var terms: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            // A line with a hint is one term; a plain line may list several.
            let hasHint = trimmed.contains(" — ") || trimmed.contains(" - ") || trimmed.contains(": ")
            let parts = hasHint ? [Substring(trimmed)] : trimmed.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\t" })
            for part in parts {
                let term = part.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'-*•")))
                guard !term.isEmpty, term.count <= 200, seen.insert(term.lowercased()).inserted else { continue }
                terms.append(term)
            }
        }
        return terms
    }

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
        transcription = (try? c.decodeIfPresent(Engine.self, forKey: .transcription)) ?? d.transcription
        summarizer = (try? c.decodeIfPresent(Summarizer.self, forKey: .summarizer)) ?? d.summarizer
        piModel = try c.decodeIfPresent(String.self, forKey: .piModel)
        piDevOps = try c.decodeIfPresent(Bool.self, forKey: .piDevOps) ?? d.piDevOps
        piDevOpsServer = try c.decodeIfPresent(String.self, forKey: .piDevOpsServer)
        piGitLab = try c.decodeIfPresent(Bool.self, forKey: .piGitLab) ?? d.piGitLab
        piGitLabServer = try c.decodeIfPresent(String.self, forKey: .piGitLabServer)
        piRepositories = (try? c.decodeIfPresent([String].self, forKey: .piRepositories)) ?? d.piRepositories
        localLanguage = try c.decodeIfPresent(String.self, forKey: .localLanguage) ?? d.localLanguage
        localGPU = try c.decodeIfPresent(Bool.self, forKey: .localGPU) ?? d.localGPU
        vocabulary = (try? c.decodeIfPresent([String].self, forKey: .vocabulary)) ?? d.vocabulary
        backgroundSounds = try c.decodeIfPresent(Bool.self, forKey: .backgroundSounds) ?? d.backgroundSounds
        transcribeWhileRecording = try c.decodeIfPresent(Bool.self, forKey: .transcribeWhileRecording) ?? d.transcribeWhileRecording
    }
}
