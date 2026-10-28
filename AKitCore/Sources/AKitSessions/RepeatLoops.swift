import Foundation

/// A stuck loop: the user asked the same thing 3 or more times in a row and the agent answered
/// almost the same way each time (`docs/design/repeat-loops.md`). Found by code, no model call:
/// texts are compared in memory and only the steps, counts, model and thinking level are kept.
public struct RepeatLoop: Codable, Sendable, Hashable {
    /// The item of the first ask (the one the repeats go back to).
    public let firstStep: Int
    /// The item of the last repeated ask.
    public let lastStep: Int
    /// How many times the user asked: the first ask and its repeats (3 or more).
    public let asks: Int
    /// The model when the last repeat was sent, when the log says it: Pi's model change, Claude
    /// Code's `/model`, else the session's last model.
    public let model: String?
    /// The thinking level (Pi) or effort (Claude Code's `/effort`) at the last repeat; nil when
    /// the log doesn't record it.
    public let thinking: String?
    /// When the first ask was sent.
    public let started: Date?

    public init(firstStep: Int, lastStep: Int, asks: Int, model: String?, thinking: String?, started: Date?) {
        (self.firstStep, self.lastStep, self.asks, self.model, self.thinking, self.started) =
            (firstStep, lastStep, asks, model, thinking, started)
    }
}

/// Finds `RepeatLoop`s in the main conversation of a transcript.
public enum RepeatLoops {
    /// Word overlap from which two asks, or two answers, count as the same.
    public static let sameText = 0.5
    /// How many earlier asks a new ask is compared with.
    public static let lookBack = 3
    /// Repeats in a row that make a loop: 2, so the user asked 3 times.
    public static let loopRepeats = 2

    /// One user turn: the ask and what the agent did until the next one.
    struct Turn {
        let step: Int
        let ask: String
        let started: Date?
        var answer = ""
        var edits: Set<String> = []
        /// The model and thinking level when the ask was sent.
        let model: String?
        let thinking: String?
    }

    /// The loops of a transcript, in order. `fallbackModel`: the model when the log has no
    /// model change (Claude Code: the session's last model).
    public static func find(_ items: [TranscriptItem], fallbackModel: String? = nil) -> [RepeatLoop] {
        let turns = self.turns(items, fallbackModel: fallbackModel)
        var loops: [RepeatLoop] = []
        var run: [Int] = []
        func close() {
            defer { run = [] }
            guard run.count >= loopRepeats, let first = run.first, let last = run.last else { return }
            let start = turns[first - 1]
            let end = turns[last]
            loops.append(RepeatLoop(firstStep: start.step, lastStep: end.step, asks: run.count + 1, model: end.model,
                                    thinking: end.thinking, started: start.started))
        }
        for index in turns.indices.dropFirst() {
            if isRepeat(index, in: turns) { run.append(index) } else { close() }
        }
        close()
        return loops
    }

    /// The loop that the transcript ends in, if any: what a live warning shows.
    public static func ongoing(_ items: [TranscriptItem], fallbackModel: String? = nil) -> RepeatLoop? {
        guard let last = find(items, fallbackModel: fallbackModel).last else { return nil }
        let lastAsk = items.last { if case .user = $0.kind { isAsk($0.text) } else { false } }
        return lastAsk?.id == last.lastStep ? last : nil
    }

    static func isRepeat(_ index: Int, in turns: [Turn]) -> Bool {
        let turn = turns[index]
        let before = turns[index - 1]
        // An empty answer (an error, a stop) is the harness, not the model answering the same.
        guard !turn.answer.isEmpty || !turn.edits.isEmpty else { return false }
        let asked = isRetry(turn.ask)
            || turns[max(0, index - lookBack)..<index].contains { similarity(turn.ask, $0.ask) >= sameText }
        guard asked else { return false }
        return similarity(turn.answer, before.answer) >= sameText || (!turn.edits.isEmpty && turn.edits == before.edits)
    }

    static func turns(_ items: [TranscriptItem], fallbackModel: String?) -> [Turn] {
        var turns: [Turn] = []
        var model = fallbackModel
        var thinking: String?
        for item in items {
            switch item.kind {
            case .user:
                guard isAsk(item.text) else { continue }
                turns.append(Turn(step: item.id, ask: cleaned(item.text), started: item.timestamp, model: model, thinking: thinking))
            case .assistant:
                if !turns.isEmpty { turns[turns.count - 1].answer = item.text }
            case .toolCall(let name):
                guard !turns.isEmpty, editTools.contains(name), let path = editedPath(item.text) else { continue }
                turns[turns.count - 1].edits.insert(path)
            case .event(let title):
                switch title {
                case "Model": model = item.text
                case "Thinking level": thinking = item.text
                case "Command":
                    // Claude Code: `/model opus`, `/effort high`.
                    let words = item.text.split(separator: " ").map(String.init)
                    guard words.count >= 2 else { break }
                    if words[0] == "/model" { model = words[1] } else if words[0] == "/effort" { thinking = words[1] }
                default: break
                }
            default:
                break
            }
        }
        return turns
    }

    /// A user text that is an ask: not an interrupt, not a slash command, not empty.
    static func isAsk(_ text: String) -> Bool {
        let start = text.drop { $0.isWhitespace }
        return !start.isEmpty && !FailureSignals.isInterrupt(text) && !start.hasPrefix("/")
    }

    /// Skill text the harness put in front of the ask (Pi's `<skill …>…</skill>`) is left out:
    /// two asks with the same skill are not the same ask.
    static func cleaned(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?s)<skill\b[^>]*>.*?</skill>"#, with: " ", options: .regularExpression)
    }

    static let editTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit", "edit", "write"]

    static func editedPath(_ input: String) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(input.utf8))) as? [String: Any] else { return nil }
        return (object["file_path"] ?? object["path"] ?? object["notebook_path"]) as? String
    }

    /// "still", "again", "doesn't work", "same error"; the Russian and Czech forms the user writes too.
    static func isRetry(_ text: String) -> Bool {
        let start = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
        let patterns = [
            #"(?i)\b(still|again|once more|try again|nothing changed|not working)\b"#,
            #"(?i)\bsame (error|problem|issue|result|thing)\b"#,
            #"(?i)\b(doesn'?t|does not|didn'?t|did not|not) (work|help|fix|change)\b"#,
            #"(?i)вс[её] ещ[её]|опять|снова|не работает|не помогло|то же самое|та же ошибка|ничего не изменилось"#,
            #"(?i)pořád|znovu|nefunguje"#,
        ]
        return patterns.contains { start.range(of: $0, options: .regularExpression) != nil }
    }

    /// Jaccard overlap of the two texts' words and word pairs (lower case, words of 2+ letters
    /// or digits): 1 for the same words in the same order, 0 for nothing in common.
    public static func similarity(_ a: String, _ b: String) -> Double {
        let left = shingles(a)
        let right = shingles(b)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        return Double(left.intersection(right).count) / Double(left.union(right).count)
    }

    /// Only the first 4000 characters: a pasted log longer than that says nothing more.
    static func shingles(_ text: String) -> Set<String> {
        let words = text.prefix(4000).lowercased()
            .split { !($0.isLetter || $0.isNumber) }
            .filter { $0.count > 1 }
            .map(String.init)
        var result = Set(words)
        for (first, second) in zip(words, words.dropFirst()) { result.insert(first + " " + second) }
        return result
    }
}
