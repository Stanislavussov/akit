import Foundation

/// M22: transcription on this Mac with whisper.cpp (`brew install whisper-cpp`) and the
/// large-v3-turbo model. Each 5-minute piece goes alone, each source's track on its own: the
/// microphone is "Me", the system sound is "Others" (whisper does not tell voices apart). Lines
/// outside the spans in which a source carried speech are dropped: whisper makes up words in
/// silence.
public enum LocalWhisper {
    public static let modelName = "ggml-large-v3-turbo-q5_0.bin"
    public static let modelTitle = "whisper large-v3-turbo"
    public static let modelURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(modelName)")!
    /// About 574 MB; a smaller file is a broken download.
    public static let modelBytes: Int64 = 574_041_195
    public static let me = "Me"
    public static let others = "Others"
    /// whisper's language codes for the Picker; `auto` detects per piece.
    public static let languages: [(code: String, name: String)] = [
        ("auto", "Detect"), ("cs", "Czech"), ("ru", "Russian"), ("en", "English"), ("sk", "Slovak"), ("de", "German"), ("uk", "Ukrainian"),
    ]

    /// The programs and the model file a local run uses.
    public struct Tools: Sendable {
        public var cli: URL
        public var model: URL
        public var converter: URL

        public init(cli: URL, model: URL = LocalWhisper.modelFile, converter: URL = URL(filePath: "/usr/bin/afconvert")) {
            self.cli = cli
            self.model = model
            self.converter = converter
        }
    }

    public static var modelFile: URL {
        MeetingsSettings.defaultFile.deletingLastPathComponent().appending(path: "models/\(modelName)")
    }

    public static func hasModel(_ file: URL = modelFile) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        return size >= modelBytes * 9 / 10
    }

    /// `whisper-cli` in Homebrew's folders or on `PATH`.
    public static func findCLI(path: String? = ProcessInfo.processInfo.environment["PATH"]) -> URL? {
        let folders = ["/opt/homebrew/bin", "/usr/local/bin"] + (path ?? "").split(separator: ":").map(String.init)
        for folder in folders {
            let file = URL(filePath: folder).appending(path: "whisper-cli")
            if FileManager.default.isExecutableFile(atPath: file.path) { return file }
        }
        return nil
    }

    /// Threads for CPU-only work: the efficiency cores but one (at least 2).
    static var cpuThreads: Int {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.perflevel1.physicalcpu", &count, &size, nil, 0) == 0, count > 0 else { return 2 }
        return max(2, Int(count) - 1)
    }

    static func arguments(model: URL, wav: URL, out: URL, language: String, gpu: Bool, threads: Int) -> [String] {
        var arguments = ["-m", model.path, "-f", wav.path, "-l", language.isEmpty ? "auto" : language,
                         "-t", "\(threads)", "-oj", "-of", out.path, "-np"]
        if !gpu { arguments.append("-ng") }
        return arguments
    }

    struct Line: Equatable {
        var from: TimeInterval
        var to: TimeInterval
        var text: String
    }

    /// whisper-cli's `-oj` file: `{"transcription": [{"offsets": {"from": ms, "to": ms}, "text": "…"}]}`.
    static func parse(_ data: Data) throws -> [Line] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = object["transcription"] as? [[String: Any]] else {
            throw MeetingsError.local("whisper wrote no transcription")
        }
        return items.compactMap { item in
            let offsets = item["offsets"] as? [String: Any]
            let from = (offsets?["from"] as? NSNumber)?.doubleValue ?? 0
            let to = (offsets?["to"] as? NSNumber)?.doubleValue ?? from
            let text = ((item["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !isNoise(text) else { return nil }
            return Line(from: from / 1000, to: to / 1000, text: text)
        }
    }

    /// `[BLANK_AUDIO]`, `(music)`, `*laughs*`, `♪`: not words.
    static func isNoise(_ text: String) -> Bool {
        let pairs: [(Character, Character)] = [("[", "]"), ("(", ")"), ("*", "*")]
        if let first = text.first, let last = text.last, pairs.contains(where: { $0.0 == first && $0.1 == last }) { return true }
        return text.allSatisfy { !$0.isLetter && !$0.isNumber }
    }

    /// The lines that overlap the source's speech spans by at least 0.3 s or a third of their
    /// length, each starting no earlier than its first span: whisper often starts a line at the
    /// beginning of the silence before it. nil spans (pieces recorded before M20 kept them) keep
    /// every line as it is.
    static func keep(_ lines: [Line], spans: [TimeSpan]?) -> [Line] {
        guard let spans else { return lines }
        return lines.compactMap { line in
            let length = max(0.01, line.to - line.from)
            let touching = spans.filter { min($0.end, line.to) > max($0.start, line.from) }
            let overlap = touching.reduce(0.0) { $0 + min($1.end, line.to) - max($1.start, line.from) }
            guard overlap >= 0.3 || overlap / length >= 0.33 else { return nil }
            var kept = line
            if let first = touching.map(\.start).min(), first > line.from { kept.from = min(first, line.to) }
            return kept
        }
    }

    /// For the mix of an older piece without tracks: "Me" where the user's mic spans cover most
    /// of the line.
    static func speaker(_ line: Line, me: [TimeSpan]) -> String {
        let length = max(0.01, line.to - line.from)
        let overlap = me.reduce(0.0) { $0 + max(0, min($1.end, line.to) - max($1.start, line.from)) }
        return overlap / length >= 0.5 ? self.me : others
    }
}

/// Runs whisper on one piece's tracks. A piece's audio goes through `afconvert` to a 16 kHz mono
/// WAV in a temporary folder, then through `whisper-cli`, both at background priority.
public struct LocalTranscriber: Sendable {
    let tools: LocalWhisper.Tools
    let settings: MeetingsSettings
    let local: LocalEnvironment

    public init(tools: LocalWhisper.Tools, settings: MeetingsSettings, local: LocalEnvironment) {
        self.tools = tools
        self.settings = settings
        self.local = local
    }

    /// One piece → its lines, with times moved by `offset`. A source without speech spans in this
    /// piece is not run at all (nothing to hear, nothing for whisper to make up).
    public func transcribe(piece: URL, info: PieceInfo, store: MeetingStore, offset: TimeInterval, phase: LocalStatus) async throws -> [Segment] {
        var jobs: [(file: URL, speaker: String?, spans: [TimeSpan]?)] = []
        let mic = store.track(piece, .mic), sys = store.track(piece, .sys)
        if mic != nil || sys != nil {
            if let mic, !info.me.isEmpty { jobs.append((mic, LocalWhisper.me, info.me)) }
            if let sys, info.others.map({ !$0.isEmpty }) ?? true { jobs.append((sys, LocalWhisper.others, info.others)) }
        } else {
            jobs.append((piece, nil, nil))
        }
        var segments: [Segment] = []
        for job in jobs {
            let lines = try await run(job.file, phase: phase)
            for line in LocalWhisper.keep(lines, spans: job.spans) {
                let speaker = job.speaker ?? LocalWhisper.speaker(line, me: info.me)
                segments.append(Segment(start: offset + line.from, speaker: speaker, text: line.text))
            }
        }
        return segments.sorted { $0.start < $1.start }
    }

    func run(_ audio: URL, phase: LocalStatus) async throws -> [LocalWhisper.Line] {
        let folder = FileManager.default.temporaryDirectory.appending(path: "meetings-whisper-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let wav = folder.appending(path: "audio.wav"), out = folder.appending(path: "out")
        let started = Date()
        let convert = try await ChildRun.run(tools.converter, ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", audio.path, wav.path],
                                             timeout: 600, local: local, resume: phase)
        guard convert.status == 0 else { throw MeetingsError.local("afconvert could not read \(audio.lastPathComponent): \(Self.tail(convert.errors))") }
        let threads = settings.localGPU ? 4 : LocalWhisper.cpuThreads
        let whisper = try await ChildRun.run(tools.cli, LocalWhisper.arguments(model: tools.model, wav: wav, out: out, language: settings.localLanguage,
                                                                         gpu: settings.localGPU, threads: threads),
                                             timeout: 3600, local: local, resume: phase)
        guard whisper.status == 0, let data = try? Data(contentsOf: out.appendingPathExtension("json")) else {
            throw MeetingsError.local("whisper-cli stopped (\(whisper.status)): \(Self.tail(whisper.errors))")
        }
        let lines = try LocalWhisper.parse(data)
        MeetingsLog.info(.local, "\(audio.lastPathComponent): \(lines.count) lines in \(Int(Date().timeIntervalSince(started))) s (\(settings.localGPU ? "GPU" : "CPU \(threads) threads"), language \(settings.localLanguage))")
        return lines
    }

    /// The last line of a tool's error output that is not a warning, for the failure line
    /// (never audio or text).
    static func tail(_ data: Data) -> String {
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let line = lines.last { !$0.isEmpty && !$0.hasPrefix("Warning:") } ?? ""
        return line.isEmpty ? "no message" : String(line.prefix(300))
    }
}
