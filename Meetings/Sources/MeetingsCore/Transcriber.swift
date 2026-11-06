import Foundation

/// The two kinds of model calls (M12–M15): a chunk of audio → transcript segments, and the
/// transcript → title, summary, decisions and tasks.
public struct Transcriber: Sendable {
    let client: OpenRouterClient
    let settings: MeetingsSettings

    public init(client: OpenRouterClient, settings: MeetingsSettings) {
        self.client = client
        self.settings = settings
    }

    // MARK: Transcript

    static let transcriptSystem = """
    You transcribe meeting audio word for word. Never summarize, never translate, never invent words. \
    Answer with one JSON object and nothing else.
    """

    /// M22: Clean leaves out what carries no meaning; the words that do stay as spoken.
    static let cleanSystem = """
    You transcribe meeting audio as clean text. Leave out filler sounds and words used only as fillers \
    (eh, ehm, um, ну, типа, jako, prostě, vlastně when they add nothing), stutters, false starts and words said twice. \
    Keep every word that carries meaning, in the order spoken. Never summarize, never translate, never invent words. \
    Answer with one JSON object and nothing else.
    """

    static func system(clean: Bool) -> String { clean ? cleanSystem : transcriptSystem }

    /// What one call hears (M20): the mix of both sources, the user's microphone alone (the user
    /// and the people in the room), or the call's sound alone (the other people).
    public enum Track: String, Sendable { case mixed, mic, system }

    /// The prompt of one chunk: the language hint, who can speak in this track, the spans in which
    /// the user's own microphone carried speech, and the last lines before this chunk, so the
    /// speakers keep their keys.
    static func transcriptPrompt(spokenHint: String, length: TimeInterval, me: [TimeSpan], previous: [Segment], track: Track = .mixed) -> String {
        var lines = ["Transcribe this audio (\(timestamp(length)) long). The language is most likely \(spokenHint); write each line in the language that is spoken."]
        switch track {
        case .mixed:
            lines.append("Speakers: \"Me\" is the user. Other people are \"S1\", \"S2\", … in the order they first speak; keep the same key for the same voice. Where two people talk at the same time, write both lines, each with its own start.")
        case .mic:
            lines.append("This is only the user's own microphone. \"Me\" is the user. Other people heard in the same room are \"R1\", \"R2\", …; keep the same key for the same voice. The call's sound was recorded on its own track: leave out faint voices that come from speakers. Where two people talk at the same time, write both lines.")
        case .system:
            lines.append("This is only the sound of a call or a video on the computer. The user is not in it, so never use \"Me\". The people are \"S1\", \"S2\", … in the order they first speak; keep the same key for the same voice. Where two people talk at the same time, write both lines.")
        }
        if track == .system {
            // No Me hints: the user is not on this track.
        } else if me.isEmpty {
            lines.append("The user's microphone carried no speech in this audio, so \"Me\" probably does not speak.")
        } else {
            let spans = me.prefix(200).map { "\(timestamp($0.start))–\(timestamp($0.end))" }.joined(separator: ", ")
            lines.append("The user's own microphone carried speech in these spans (mm:ss from the start of this audio); speech there is most likely \"Me\", unless it is clearly another voice heard through the room: \(spans).")
        }
        if !previous.isEmpty {
            lines.append("The audio continues an earlier part. Its last lines, for the speaker keys:")
            for segment in previous.suffix(6) { lines.append("  \(segment.speaker): \(segment.text.prefix(160))") }
        }
        lines.append("""
        Answer: {"segments": [{"start": "mm:ss", "speaker": "Me" or "S1"…, "text": "…"}]}. \
        start is the time from the start of this audio. One segment per turn or per long sentence group (at most ~30 s). \
        Leave out silence and noise. If nothing is said, answer {"segments": []}.
        """)
        return lines.joined(separator: "\n")
    }

    /// One chunk of audio → its segments, with times moved by `offset` (the chunk's start in the
    /// whole recording).
    public func transcribe(audio: Data, format: String, length: TimeInterval, offset: TimeInterval, me: [TimeSpan], previous: [Segment],
                           track: Track = .mixed) async throws -> (segments: [Segment], completion: Completion) {
        let prompt = Self.transcriptPrompt(spokenHint: settings.spokenHint, length: length, me: me, previous: previous, track: track)
        let completion = try await client.complete(model: settings.model, system: Self.system(clean: settings.cleanTranscript), text: prompt, audio: (audio, format))
        let segments = try PaidFailure.parse(completion) { try Self.parseSegments(completion.text, offset: offset, length: length) }
        return (segments, completion)
    }

    static func parseSegments(_ text: String, offset: TimeInterval, length: TimeInterval) throws -> [Segment] {
        guard let object = jsonObject(text) else { throw MeetingsError.badAnswer("the transcript is not a JSON object") }
        guard let items = object["segments"] as? [[String: Any]] else { throw MeetingsError.badAnswer("no \"segments\" list") }
        var result: [Segment] = []
        for item in items {
            let words = ((item["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !words.isEmpty else { continue }
            var start = seconds(item["start"]) ?? result.last?.start ?? 0
            start = min(max(0, start), max(0, length))
            result.append(Segment(start: offset + start, speaker: speakerKey(item["speaker"]), text: words))
        }
        return result
    }

    /// `Me`, `S1` …; "Speaker 2", "s2", "2" become `S2`; anything else is kept, trimmed.
    static func speakerKey(_ value: Any?) -> String {
        let text = ((value as? String) ?? (value as? NSNumber)?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "S1" }
        if text.lowercased() == "me" { return "Me" }
        let digits = text.filter(\.isNumber)
        let letters = text.lowercased().filter(\.isLetter)
        if !digits.isEmpty, ["s", "speaker", ""].contains(letters), let n = Int(digits) { return "S\(n)" }
        return String(text.prefix(40))
    }

    /// `"mm:ss"`, `"h:mm:ss"`, `"12.5"` or a number → seconds.
    static func seconds(_ value: Any?) -> TimeInterval? {
        if let number = value as? NSNumber { return number.doubleValue }
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        let parts = text.split(separator: ":").map { Double($0) }
        guard !parts.contains(where: { $0 == nil }) else { return nil }
        return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
    }

    /// The JSON object in a model's answer, also inside a ```json fence or after a line of text.
    static func jsonObject(_ text: String) -> [String: Any]? {
        guard let first = text.firstIndex(of: "{"), let last = text.lastIndex(of: "}"), first < last else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(text[first...last].utf8))) as? [String: Any]
    }

    // MARK: Summary

    public struct Summary: Equatable, Sendable {
        public var title: String
        public var summary: String
        /// M22: the template's sections, headings in the summary's language.
        public var sections: [(heading: String, items: [String])] = []
        public var decisions: [String]
        public var tasks: [(owner: String, text: String)]
        /// M23: 1–3 topic tags the model proposes.
        public var tags: [String] = []

        public init(title: String, summary: String, sections: [(heading: String, items: [String])] = [], decisions: [String],
                    tasks: [(owner: String, text: String)], tags: [String] = []) {
            self.title = title
            self.summary = summary
            self.sections = sections
            self.decisions = decisions
            self.tasks = tasks
            self.tags = tags
        }

        public static func == (a: Summary, b: Summary) -> Bool {
            a.title == b.title && a.summary == b.summary && a.decisions == b.decisions && a.tags == b.tags
                && a.sections.map(\.heading) == b.sections.map(\.heading) && a.sections.map(\.items) == b.sections.map(\.items)
                && a.tasks.map(\.owner) == b.tasks.map(\.owner) && a.tasks.map(\.text) == b.tasks.map(\.text)
        }

        /// `summary.md`.
        public var markdown: String {
            var lines = ["## Summary", "", summary.isEmpty ? "—" : summary]
            for section in sections {
                lines += ["", "## \(section.heading)", ""]
                lines += section.items.isEmpty ? ["—"] : section.items.map { "- \($0)" }
            }
            lines += ["", "## Decisions", ""]
            lines += decisions.isEmpty ? ["—"] : decisions.map { "- \($0)" }
            lines += ["", "## Tasks", ""]
            lines += tasks.isEmpty ? ["—"] : tasks.map { "- [ ] \($0.owner): \($0.text)" }
            return lines.joined(separator: "\n") + "\n"
        }
    }

    static func summaryPrompt(language: String, transcript: String, template: MeetingTemplate = MeetingTemplate.builtIn[0]) -> String {
        var asks = [
            "- title: a short title of the meeting (at most 8 words);",
            "- summary: 3–5 sentences: what it was about and what came out of it;",
        ]
        let sections = template.sectionLines
        if !sections.isEmpty {
            asks.append("- sections: this is a meeting of the kind \"\(template.name)\". One entry per section below, in this order; write the heading in \(language) and the items as short points (an empty list when the transcript has nothing for it):")
            asks += sections.map { "    - \($0)" }
        }
        asks += [
            "- decisions: what was decided (empty list if nothing);",
            "- tasks: who does what next, owner as named in the transcript (\"Me\" for the user);",
            "- tags: 1–3 topics of the meeting for search, one or two lowercase words each, in \(language).",
        ]
        let shape = sections.isEmpty
            ? #"{"title": "…", "summary": "…", "decisions": ["…"], "tasks": [{"owner": "…", "text": "…"}], "tags": ["…"]}"#
            : #"{"title": "…", "summary": "…", "sections": [{"heading": "…", "items": ["…"]}], "decisions": ["…"], "tasks": [{"owner": "…", "text": "…"}], "tags": ["…"]}"#
        return """
        Below is the transcript of a meeting. "Me" is the user. Write in \(language):
        \(asks.joined(separator: "\n"))
        Use only what the transcript says.
        Answer: \(shape)

        Transcript:
        \(transcript)
        """
    }

    /// The transcript in the speakers' names, one line per segment, for the summary call.
    public static func plainTranscript(_ meeting: Meeting) -> String {
        meeting.segments.map { "[\(timestamp($0.start))] \(meeting.speakerName($0.speaker)): \($0.text)" }.joined(separator: "\n")
    }

    public func summarize(_ meeting: Meeting) async throws -> (summary: Summary, completion: Completion) {
        let template = settings.template(meeting.template)
        let completion = try await client.complete(model: settings.summaryModel ?? settings.model,
                                                   system: "You write short, faithful meeting notes. Answer with one JSON object and nothing else.",
                                                   text: Self.summaryPrompt(language: settings.language, transcript: Self.plainTranscript(meeting), template: template))
        return (try PaidFailure.parse(completion) { try Self.parseSummary(completion.text) }, completion)
    }

    static func parseSummary(_ text: String) throws -> Summary {
        guard let object = jsonObject(text) else { throw MeetingsError.badAnswer("the summary is not a JSON object") }
        func strings(_ key: String) -> [String] {
            ((object[key] as? [Any]) ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        let tasks: [(owner: String, text: String)] = ((object["tasks"] as? [Any]) ?? []).compactMap { item in
            if let task = item as? [String: Any], let text = task["text"] as? String, !text.isEmpty {
                return ((task["owner"] as? String) ?? "?", text)
            }
            if let text = item as? String, !text.isEmpty { return ("?", text) }
            return nil
        }
        let sections: [(heading: String, items: [String])] = ((object["sections"] as? [Any]) ?? []).compactMap { item in
            guard let section = item as? [String: Any],
                  let heading = (section["heading"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "#: ")),
                  !heading.isEmpty else { return nil }
            let items = ((section["items"] as? [Any]) ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            return (heading, items)
        }
        return Summary(title: ((object["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                       summary: ((object["summary"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                       sections: sections, decisions: strings("decisions"), tasks: tasks,
                       tags: Array(strings("tags").map(Meeting.cleanTag).filter { !$0.isEmpty }.prefix(3)))
    }
}
