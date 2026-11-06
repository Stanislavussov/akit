import Foundation

/// M24: a question over the meetings. Each meeting in scope goes in as `[n]` with its date,
/// title, tags and summary; then transcripts, best keyword match first, while the budget lasts.
/// One call to the summary model; the answer cites `[n]`.
public struct MeetingAsk: Sendable {
    public static let budget = 300_000

    public enum Scope: Hashable, Sendable {
        case meeting(String)
        case days(Int)
        case all

        public var title: String {
            switch self {
            case .meeting: "This meeting"
            case .days(let n): "Last \(n) days"
            case .all: "All meetings"
            }
        }
    }

    /// One earlier question and its answer in the same chat.
    public struct Turn: Sendable, Equatable {
        public var question: String
        public var answer: String

        public init(question: String, answer: String) {
            self.question = question
            self.answer = answer
        }
    }

    public struct Answer: Sendable, Equatable {
        /// Markdown with `[n]` marks.
        public var text: String
        /// `[n]` → meeting id, for the marks the answer uses, in order of n.
        public var sources: [(number: Int, id: String)]
        public var completion: Completion

        public static func == (a: Answer, b: Answer) -> Bool {
            a.text == b.text && a.sources.map(\.number) == b.sources.map(\.number) && a.sources.map(\.id) == b.sources.map(\.id) && a.completion == b.completion
        }
    }

    /// The meetings of a scope, newest first, optionally only with a tag.
    public static func meetings(_ all: [Meeting], scope: Scope, tag: String?, now: Date = Date()) -> [Meeting] {
        let chosen: [Meeting]
        switch scope {
        case .meeting(let id): chosen = all.filter { $0.id == id }
        case .days(let n):
            let start = Calendar.current.date(byAdding: .day, value: -n, to: now) ?? now
            chosen = all.filter { $0.started >= start }
        case .all: chosen = all
        }
        let tagged = tag.map { tag in chosen.filter { $0.tagList.contains(tag) } } ?? chosen
        return tagged.filter { !$0.segments.isEmpty }.sorted { $0.started > $1.started }
    }

    /// The context: `[n]` blocks with the summaries, then transcripts by keyword match while the
    /// budget lasts. Returns the text and `[n]` → id.
    public static func context(_ meetings: [Meeting], documents: [String: MeetingSearch.Document], question: String,
                               budget: Int = budget) -> (text: String, ids: [String]) {
        var ids: [String] = []
        var blocks: [String] = []
        var used = 0
        for meeting in meetings {
            let summary = documents[meeting.id]?.text("Summary") ?? ""
            var block = "[\(ids.count + 1)] \(meeting.started.formatted(.iso8601.year().month().day())) \(meeting.started.formatted(date: .omitted, time: .shortened)) — \(meeting.displayTitle)"
            if !meeting.tagList.isEmpty { block += "\nTags: " + meeting.tagList.joined(separator: ", ") }
            block += "\nSummary:\n" + (summary.isEmpty ? "—" : summary)
            guard used + block.count <= budget else { break }
            used += block.count
            ids.append(meeting.id)
            blocks.append(block)
        }
        // Transcripts: the meetings whose words match the question best first (one meeting: its own).
        let words = Set(MeetingSearch.words([MeetingSearch.fold(question)]).keys)
        let ranked = ids.enumerated().map { index, id -> (Int, Int) in
            let lines = documents[id]?.lines.filter { $0.place == "Transcript" } ?? []
            let hits = lines.reduce(0) { sum, line in sum + words.filter { line.folded.contains($0) }.count }
            return (index, hits)
        }
        .filter { ids.count == 1 || $0.1 > 0 }
        .sorted { $0.1 > $1.1 }
        for (index, _) in ranked {
            let transcript = documents[ids[index]]?.text("Transcript") ?? ""
            guard !transcript.isEmpty else { continue }
            let block = "\nTranscript of [\(index + 1)]:\n" + transcript
            if used + block.count > budget {
                // The start of a long transcript still helps when it is the only one.
                let room = budget - used - 40
                if room > 2_000 { blocks[index] += String(block.prefix(room)) + "\n(transcript cut)" ; used = budget }
                break
            }
            used += block.count
            blocks[index] += block
        }
        return (blocks.joined(separator: "\n\n"), ids)
    }

    static let system = """
    You answer questions about the user's meetings from the notes given, and only from them. \
    "Me" in the notes is the user. Cite the meetings you use as [n]. If the notes do not say, answer so. \
    Answer with one JSON object and nothing else.
    """

    static func prompt(question: String, context: String, history: [Turn]) -> String {
        var lines = ["Meetings:", context, ""]
        if !history.isEmpty {
            lines.append("Earlier in this chat:")
            for turn in history.suffix(6) { lines += ["Q: \(turn.question)", "A: \(turn.answer)"] }
            lines.append("")
        }
        lines += [
            "Question: \(question)",
            "",
            #"Answer in the language of the question, short, in Markdown (lists where they help), each fact with its [n]. Answer: {"answer": "…"}"#,
        ]
        return lines.joined(separator: "\n")
    }

    let client: OpenRouterClient
    let model: String

    public init(client: OpenRouterClient, settings: MeetingsSettings) {
        self.client = client
        model = settings.summaryModel ?? settings.model
    }

    public func ask(_ question: String, context: (text: String, ids: [String]), history: [Turn] = []) async throws -> Answer {
        let completion = try await client.complete(model: model, system: Self.system, text: Self.prompt(question: question, context: context.text, history: history))
        guard let object = Transcriber.jsonObject(completion.text), let text = (object["answer"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { throw MeetingsError.badAnswer("no \"answer\" in the reply") }
        return Answer(text: text, sources: Self.sources(text, ids: context.ids), completion: completion)
    }

    /// The `[n]` marks of a text (also `[1, 3]`) that name a meeting, each once, by n.
    static func sources(_ text: String, ids: [String]) -> [(number: Int, id: String)] {
        var numbers = Set<Int>()
        let pattern = /\[(\d+(?:\s*,\s*\d+)*)\]/
        for match in text.matches(of: pattern) {
            for part in match.1.split(separator: ",") {
                if let n = Int(part.trimmingCharacters(in: .whitespaces)), n >= 1, n <= ids.count { numbers.insert(n) }
            }
        }
        return numbers.sorted().map { ($0, ids[$0 - 1]) }
    }
}

/// M24: each question's cost (not its text), one JSON line per call in `<root>/.asks.jsonl`, for
/// the monthly limit and Costs.
public struct AskLog: Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var date: Date
        public var model: String
        public var promptTokens: Int
        public var completionTokens: Int
        public var costUSD: Double

        public init(date: Date, model: String, promptTokens: Int, completionTokens: Int, costUSD: Double) {
            self.date = date
            self.model = model
            self.promptTokens = promptTokens
            self.completionTokens = completionTokens
            self.costUSD = costUSD
        }
    }

    public let file: URL

    public init(root: URL) { file = root.appending(path: ".asks.jsonl") }

    public func append(_ entry: Entry) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let line = try MeetingStore.encoderLine.encode(entry) + Data("\n".utf8)
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: file, options: .atomic)
        }
    }

    /// Every entry; a line that cannot be read is left out.
    public func entries() -> [Entry] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap { try? MeetingStore.decoder.decode(Entry.self, from: Data($0.utf8)) }
    }
}
