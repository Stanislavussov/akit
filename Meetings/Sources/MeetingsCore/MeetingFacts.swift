import Foundation

/// M25: facts of a meeting worth keeping in a knowledge base of systems (services, events,
/// repositories, owners), each aimed at one note. The package knows only note ids and titles the
/// host gives; the host turns the facts into its own proposals.
public struct MeetingFact: Sendable, Equatable, Identifiable {
    /// An existing note's id, or a new one (`area/name`).
    public var note: String
    public var heading: String
    public var text: String
    public var reason: String
    public var id: String { note + "#" + heading }

    public init(note: String, heading: String, text: String, reason: String) {
        self.note = note
        self.heading = heading
        self.text = text
        self.reason = reason
    }

    /// The proposal's body: one `## heading` block.
    public var body: String { "## \(heading)\n\n\(text)\n" }
}

public struct FactFinder: Sendable {
    public static let maxFacts = 8
    public static let maxNotes = 1_500

    public struct Note: Sendable, Equatable {
        public var id: String
        public var title: String

        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    let client: OpenRouterClient
    let model: String

    public init(client: OpenRouterClient, settings: MeetingsSettings) {
        self.client = client
        model = settings.summaryModel ?? settings.model
    }

    static let system = """
    You keep a knowledge base of software systems up to date from meeting notes. \
    You write only facts the notes state, never guesses. Answer with one JSON object and nothing else.
    """

    static func prompt(summary: String, transcript: String, notes: [Note]) -> String {
        let list = notes.prefix(maxNotes).map { "- \($0.id): \($0.title)" }.joined(separator: "\n")
        return """
        From this meeting, list the facts worth keeping in the knowledge base: what a service, event, \
        repository or team does, who owns what, which system talks to which and how, decisions about \
        systems. Not tasks, not who said what, not passing talk. At most \(maxFacts); none is fine.
        Each fact goes to one note: the id of a note below when one fits, else a new id "area/name" \
        (lowercase, dashes) beside the notes of the same area. heading names the topic (a few words); \
        text is Markdown, one to four sentences or a short list, in the language of the note titles \
        (English when there are none). reason says in one sentence what in the meeting shows it.
        Answer: {"facts": [{"note": "…", "heading": "…", "text": "…", "reason": "…"}]}

        Notes of the knowledge base:
        \(list.isEmpty ? "(none yet)" : list)

        Meeting summary:
        \(summary)

        Transcript:
        \(transcript.prefix(MeetingAsk.budget))
        """
    }

    public func find(_ meeting: Meeting, summary: String, notes: [Note]) async throws -> (facts: [MeetingFact], completion: Completion) {
        let completion = try await client.complete(model: model, system: Self.system,
                                                   text: Self.prompt(summary: summary, transcript: Transcriber.plainTranscript(meeting), notes: notes))
        return (try Self.parse(completion.text), completion)
    }

    static func parse(_ text: String) throws -> [MeetingFact] {
        guard let object = Transcriber.jsonObject(text), let items = object["facts"] as? [Any] else {
            throw MeetingsError.badAnswer("no \"facts\" list")
        }
        var facts: [MeetingFact] = []
        for case let item as [String: Any] in items {
            func field(_ key: String) -> String { ((item[key] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            let note = field("note").trimmingCharacters(in: CharacterSet(charactersIn: "/ ")).lowercased()
            let heading = field("heading").trimmingCharacters(in: CharacterSet(charactersIn: "#: "))
            let body = field("text")
            // A note id is path-like: no dots, no spaces, no leading slash.
            guard !note.isEmpty, !heading.isEmpty, !body.isEmpty, !note.contains(".."), !note.contains(" "),
                  !facts.contains(where: { $0.note == note && $0.heading == heading }) else { continue }
            facts.append(MeetingFact(note: note, heading: heading, text: body, reason: field("reason")))
        }
        return Array(facts.prefix(maxFacts))
    }
}
