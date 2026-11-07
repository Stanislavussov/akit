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
    /// M30: the project's words for a prompt; nil without any.
    static func vocabularyLine(_ vocabulary: [String], for use: String) -> String? {
        let terms = vocabulary.prefix(MeetingsSettings.vocabularyLimit)
        guard !terms.isEmpty else { return nil }
        return "Words of the user's project (names, services, products, terms; a dash or colon gives a hint). \(use) Never put one in where it was not said:\n" + terms.map { "- \($0)" }.joined(separator: "\n")
    }

    static func transcriptPrompt(spokenHint: String, length: TimeInterval, me: [TimeSpan], previous: [Segment], track: Track = .mixed,
                                 vocabulary: [String] = []) -> String {
        var lines = ["Transcribe this audio (\(timestamp(length)) long). The language is most likely \(spokenHint); write each line in the language that is spoken."]
        if let words = vocabularyLine(vocabulary, for: "When you hear one of them, or a word that sounds close and fits the meaning better than a common word, write it exactly as listed.") {
            lines.append(words)
        }
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
        let prompt = Self.transcriptPrompt(spokenHint: settings.spokenHint, length: length, me: me, previous: previous, track: track,
                                           vocabulary: settings.vocabulary)
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
        /// The course of the talk: one entry per topic in the order it came up.
        public var flow: [Topic] = []
        /// Numbers, dates, deadlines, names and versions that were said.
        public var facts: [String] = []
        /// Questions raised and left without an answer.
        public var openQuestions: [String] = []
        /// A Mermaid diagram (timeline, flow, gantt…), or empty when none helps.
        public var diagram: String = ""

        public struct Topic: Equatable, Sendable {
            public var time: String
            public var topic: String
            public var points: [String]
            public init(time: String, topic: String, points: [String]) {
                self.time = time
                self.topic = topic
                self.points = points
            }
        }

        public init(title: String, summary: String, sections: [(heading: String, items: [String])] = [], decisions: [String],
                    tasks: [(owner: String, text: String)], tags: [String] = [], flow: [Topic] = [], facts: [String] = [],
                    openQuestions: [String] = [], diagram: String = "") {
            self.title = title
            self.summary = summary
            self.sections = sections
            self.decisions = decisions
            self.tasks = tasks
            self.tags = tags
            self.flow = flow
            self.facts = facts
            self.openQuestions = openQuestions
            self.diagram = diagram
        }

        public static func == (a: Summary, b: Summary) -> Bool {
            a.title == b.title && a.summary == b.summary && a.decisions == b.decisions && a.tags == b.tags
                && a.sections.map(\.heading) == b.sections.map(\.heading) && a.sections.map(\.items) == b.sections.map(\.items)
                && a.tasks.map(\.owner) == b.tasks.map(\.owner) && a.tasks.map(\.text) == b.tasks.map(\.text)
                && a.flow == b.flow && a.facts == b.facts && a.openQuestions == b.openQuestions && a.diagram == b.diagram
        }

        /// `summary.md`.
        public var markdown: String {
            var lines = ["## Summary", "", summary.isEmpty ? "—" : summary]
            if !flow.isEmpty {
                lines += ["", "## Course of the Meeting"]
                for topic in flow {
                    lines += ["", "### " + (topic.time.isEmpty ? "" : "[\(topic.time)] ") + topic.topic, ""]
                    lines += topic.points.map { "- \($0)" }
                }
            }
            for section in sections {
                lines += ["", "## \(section.heading)", ""]
                lines += section.items.isEmpty ? ["—"] : section.items.map { "- \($0)" }
            }
            if !facts.isEmpty {
                lines += ["", "## Key Facts and Dates", ""] + facts.map { "- \($0)" }
            }
            if !diagram.isEmpty {
                lines += ["", "## Diagram", "", "```mermaid", diagram, "```"]
            }
            lines += ["", "## Decisions", ""]
            lines += decisions.isEmpty ? ["—"] : decisions.map { "- \($0)" }
            if !openQuestions.isEmpty {
                lines += ["", "## Open Questions", ""] + openQuestions.map { "- \($0)" }
            }
            lines += ["", "## Tasks", ""]
            lines += tasks.isEmpty ? ["—"] : tasks.map { "- [ ] \($0.owner): \($0.text)" }
            return lines.joined(separator: "\n") + "\n"
        }
    }

    static func summaryPrompt(language: String, transcript: String, template: MeetingTemplate = MeetingTemplate.builtIn[0], vocabulary: [String] = []) -> String {
        var asks = [
            "- title: a short title of the meeting (at most 8 words);",
            "- summary: one paragraph of 4–8 sentences: why the meeting happened, what was discussed, what came out of it;",
            "- flow: the course of the whole talk, one entry per topic in the order it came up, so a reader who missed the meeting can follow it. time: the start of the topic as in the transcript (mm:ss); topic: a short name; points: 2–8 short points: what was said, by whom when it matters, the arguments for and against, the examples, the numbers. Cover every topic, small ones too; skip only greetings and small talk;",
        ]
        let sections = template.sectionLines
        if !sections.isEmpty {
            asks.append("- sections: this is a meeting of the kind \"\(template.name)\". One entry per section below, in this order; write the heading in \(language) and the items as short points (an empty list when the transcript has nothing for it):")
            asks += sections.map { "    - \($0)" }
        }
        asks += [
            "- facts: every number, date, deadline, amount, version, name of a system or person's role that was said, each with what it is about (empty list if none);",
            "- diagram: a Mermaid diagram when one makes the meeting clearer: `timeline` or `gantt` for dates and plans, `flowchart LR` for a process or how systems talk, `sequenceDiagram` for who does what in order. Only what the transcript says; quote labels with special characters (\"…\"); no styling. An empty string when no diagram helps;",
            "- decisions: what was decided (empty list if nothing);",
            "- open_questions: questions raised and left without an answer (empty list if none);",
            "- tasks: who does what next, owner as named in the transcript (\"Me\" for the user);",
            "- tags: 1–3 topics of the meeting for search, one or two lowercase words each, in \(language).",
        ]
        let shape = sections.isEmpty
            ? #"{"title": "…", "summary": "…", "flow": [{"time": "mm:ss", "topic": "…", "points": ["…"]}], "facts": ["…"], "diagram": "…", "decisions": ["…"], "open_questions": ["…"], "tasks": [{"owner": "…", "text": "…"}], "tags": ["…"]}"#
            : #"{"title": "…", "summary": "…", "flow": [{"time": "mm:ss", "topic": "…", "points": ["…"]}], "sections": [{"heading": "…", "items": ["…"]}], "facts": ["…"], "diagram": "…", "decisions": ["…"], "open_questions": ["…"], "tasks": [{"owner": "…", "text": "…"}], "tags": ["…"]}"#
        return """
        Below is the transcript of a meeting. "Me" is the user. Write in \(language):
        \(asks.joined(separator: "\n"))
        Be thorough: the notes replace listening to the recording. Use only what the transcript says; never invent a fact, date or name.\(vocabularyLine(vocabulary, for: "Where the transcript has a word that sounds like one of them, it is that word: write it exactly as listed.").map { "\n" + $0 } ?? "")
        Answer: \(shape)

        Transcript:
        \(transcript)
        """
    }

    /// The transcript in the speakers' names, one line per segment, for the summary call.
    public static func plainTranscript(_ meeting: Meeting) -> String {
        meeting.segments.map { "[\(timestamp($0.start))] \(meeting.speakerName($0.speaker)): \($0.text)" }.joined(separator: "\n")
    }

    /// The transcript as plain text for the clipboard: with speakers one line per segment, without
    /// them one paragraph per run of the same speaker.
    public static func copyText(_ meeting: Meeting, speakers: Bool) -> String {
        if speakers { return meeting.segments.map { "\(meeting.speakerName($0.speaker)): \($0.text)" }.joined(separator: "\n") }
        var paragraphs: [String] = []
        var last: String?
        for segment in meeting.segments {
            if segment.speaker == last, !paragraphs.isEmpty { paragraphs[paragraphs.count - 1] += " " + segment.text }
            else { paragraphs.append(segment.text) }
            last = segment.speaker
        }
        return paragraphs.joined(separator: "\n\n")
    }

    public func summarize(_ meeting: Meeting) async throws -> (summary: Summary, completion: Completion) {
        let template = settings.template(meeting.template)
        let completion = try await client.complete(model: settings.summaryModel ?? settings.model,
                                                   system: "You write detailed, well-structured, faithful meeting notes. Answer with one JSON object and nothing else.",
                                                   text: Self.summaryPrompt(language: settings.language, transcript: Self.plainTranscript(meeting), template: template,
                                                                            vocabulary: settings.vocabulary))
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
        let flow: [Summary.Topic] = ((object["flow"] as? [Any]) ?? []).compactMap { item in
            guard let entry = item as? [String: Any],
                  let topic = (entry["topic"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !topic.isEmpty else { return nil }
            let points = ((entry["points"] as? [Any]) ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            return Summary.Topic(time: ((entry["time"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines), topic: topic, points: points)
        }
        return Summary(title: ((object["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                       summary: ((object["summary"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                       sections: sections, decisions: strings("decisions"), tasks: tasks,
                       tags: Array(strings("tags").map(Meeting.cleanTag).filter { !$0.isEmpty }.prefix(3)),
                       flow: flow, facts: strings("facts"), openQuestions: strings("open_questions"),
                       diagram: Self.cleanDiagram(object["diagram"] as? String))
    }

    /// The diagram without a ``` fence the model may have added.
    static func cleanDiagram(_ text: String?) -> String {
        var lines = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        if lines.first?.hasPrefix("```") == true { lines.removeFirst() }
        if lines.last?.hasPrefix("```") == true { lines.removeLast() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
