import AKitFoundation
import AKitInsights
import AKitSessions
import Foundation

/// One moment where the user reacted to the agent's work: an interrupt, a refused tool call, a
/// rating of a run, a correction or another later turn. Found by code, not by a model: these are
/// the review's checkpoints, the places where the user showed what they wanted
/// (`docs/design/error-analysis.md`, "Checkpoints").
public struct UserReaction: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// Esc: the user stopped the agent.
        case interrupt
        /// The user (or a rule) refused a tool call.
        case rejected
        case badRating = "bad-rating"
        case goodRating = "good-rating"
        /// A later turn that starts with "no", "not that", "I asked for"…
        case pushback
        /// Any other later turn: a new step, more detail, or a quiet correction.
        case followUp = "follow-up"

        public var title: String {
            switch self {
            case .interrupt: "Interrupted"
            case .rejected: "Refused a tool call"
            case .badRating: "Rated bad"
            case .goodRating: "Rated good"
            case .pushback: "Pushed back"
            case .followUp: "Next message"
            }
        }

        /// The user was unhappy here: the review must explain why.
        public var isNegative: Bool { [.interrupt, .rejected, .badRating, .pushback].contains(self) }
    }

    /// `r1`, `r2`, … in the order of the session.
    public var id: String
    public var kind: Kind
    /// The transcript item: the user's turn, the refused call's result, or the item that ends a
    /// rated run.
    public var step: Int
    /// The user's words: the turn, the refusal, or the rating's comment; cut to `textLimit`.
    public var text: String

    public init(id: String, kind: Kind, step: Int, text: String) {
        self.id = id
        self.kind = kind
        self.step = step
        self.text = text
    }
}

public enum UserReactions {
    /// The prompt's list shows this much of each reaction; the digest has the full user turn.
    static let textLimit = 300

    /// The reactions of a session in order. The first user turn is the task, not a reaction.
    /// `ratings` are the runs' ratings: from the session log (Pi) and from AKit's spool.
    public static func of(_ items: [TranscriptItem], ratings: [RunRating]) -> [UserReaction] {
        var found: [(step: Int, order: Int, kind: UserReaction.Kind, text: String)] = []
        var seenTask = false
        for item in items {
            switch item.kind {
            case .user:
                guard seenTask else {
                    seenTask = !FailureSignals.isInterrupt(item.text)
                    continue
                }
                let kind: UserReaction.Kind = FailureSignals.isInterrupt(item.text) ? .interrupt
                    : SignalScanner.isPushback(item.text) ? .pushback : .followUp
                found.append((item.id, 0, kind, item.text))
            case .toolResult:
                if item.resultOutcome?.outcome == .rejected { found.append((item.id, 0, .rejected, item.text)) }
            default:
                break
            }
        }
        // A rating comes after the run it rates: after the item that ends it.
        for rating in ratings {
            guard let step = rating.afterItem else { continue }
            found.append((step, 1, rating.isGood ? .goodRating : .badRating, rating.comment ?? ""))
        }
        return found.sorted { ($0.step, $0.order) < ($1.step, $1.order) }.enumerated().map { index, reaction in
            UserReaction(id: "r\(index + 1)", kind: reaction.kind, step: reaction.step, text: cut(reaction.text))
        }
    }

    /// The ratings of the session file: those in the log (Pi's extension writes them there), then
    /// those only in AKit's spool and index (other harnesses), placed by their anchor or time.
    /// A spool rating whose run the log already rated is left out.
    public static func ratings(of transcript: SessionTranscript, file: URL, env: HarnessEnvironment) -> [RunRating] {
        var result = transcript.ratings
        let logged = Set(transcript.ratings.compactMap(\.anchor))
        for rating in Ratings.byTranscript(env: env)[file.path] ?? [] where !(rating.anchor.map(logged.contains) ?? false) {
            let step = Ratings.place(of: rating, in: transcript)
            // Only the log's own copy of a run's rating is a duplicate; two spool ratings stay two.
            guard !transcript.ratings.contains(where: { $0.afterItem == step && $0.rating == rating.rating }) else { continue }
            result.append(RunRating(rating: rating.rating, comment: rating.text.map(SecretFilter.masked), anchor: rating.anchor,
                                    timestamp: rating.firstDate, afterItem: step))
        }
        return result
    }

    /// The list the notes call answers, one line per reaction:
    /// `- r2 · #57 · interrupt · "…"`.
    public static func text(_ reactions: [UserReaction]) -> String {
        reactions.map { reaction in
            let words = reaction.text.isEmpty ? "(no words)" : "\"\(reaction.text.replacingOccurrences(of: "\n", with: " "))\""
            return "- \(reaction.id) · #\(reaction.step) · \(reaction.kind.rawValue) · \(words)"
        }
        .joined(separator: "\n")
    }

    private static func cut(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > textLimit ? String(trimmed.prefix(textLimit)) + "…" : trimmed
    }
}
