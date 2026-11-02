import AKitErrorAnalysis
import AKitFoundation
import AKitInsights
import AKitLab
import AKitSessions
import Foundation

/// One correction the model may group: the user's words verbatim, from the session log, and the
/// agent steps just before them, each cut short (`docs/design/corrections.md`, C2).
public struct CorrectionExcerpt: Codable, Hashable, Sendable, Identifiable {
    public struct Step: Codable, Hashable, Sendable {
        /// `agent`, `tool Edit`, `result`, `error`.
        public let label: String
        public let text: String
    }

    /// `s1.r2`: the session's place in the pick and the reaction's id in that session.
    public let id: String
    public let sessionKey: String
    /// The session's log file (local only, for Show).
    public let file: String?
    public let project: String?
    /// The transcript item of the reaction.
    public let step: Int
    public let kind: UserReaction.Kind
    /// The user's words as the log has them (cut to `wordsLimit`). For an interrupt, the turn
    /// the user wrote right after it.
    public let words: String
    /// The agent's steps before the reaction, oldest first.
    public let before: [Step]
    public let started: Date?
}

/// What Find Pattern… would send: the picked sessions' excerpts, before any model call.
public struct CorrectionPick: Sendable, Equatable {
    public let excerpts: [CorrectionExcerpt]
    /// Sessions the excerpts come from.
    public let sessions: Int
    /// The input as it would be sent, before scrubbing.
    public let input: String
    /// Sessions left out because the hard cap was reached.
    public let cut: Int

    /// ≈ tokens of the input (4 characters a token), the prompt not counted.
    public var approxTokens: Int { input.count / 4 }
}

public enum CorrectionExcerpts {
    /// Step 0 on this Mac's index (2026-11-02): 3–7 corrected sessions a week, 8 picks cover two
    /// weeks; a reaction and 3 steps of 240 characters are about 1–1.5k characters.
    public static let maxSessions = 8
    public static let maxPerSession = 3
    static let stepsBefore = 3
    static let stepLimit = 240
    static let wordsLimit = 600
    /// The whole input's hard cap: about 15k tokens.
    public static let inputLimit = 60_000

    /// The sessions with the most corrections first (up to `maxSessions` with a readable log), up
    /// to `maxPerSession` corrections each. Reads only the picked logs.
    public static func pick(_ report: CorrectionsReport, env: HarnessEnvironment) -> CorrectionPick {
        var excerpts: [CorrectionExcerpt] = []
        var blocks: [String] = []
        var size = 0, sessions = 0, cut = 0
        for session in report.sessions {
            guard sessions < maxSessions else { break }
            guard let path = session.file, FileManager.default.fileExists(atPath: path) else { continue }
            let file = URL(filePath: path)
            let info = JSONLines.fileInfo(file)
            let summary = SessionSummary(harness: SessionKey.harness(of: session.key), file: file, title: "",
                                         project: session.cwd.map { URL(filePath: $0, directoryHint: .isDirectory) },
                                         started: session.started, modified: info.modified, size: info.size)
            guard let transcript = try? SessionReader.transcript(of: summary) else { continue }
            let ratings = UserReactions.ratings(of: transcript, file: file, env: env)
            let found = Self.excerpts(of: transcript.items, ratings: ratings, session: session, prefix: "s\(sessions + 1)")
            guard !found.isEmpty else { continue }
            let block = text(found, session: session, number: sessions + 1)
            guard size + block.count <= inputLimit else {
                cut += 1
                continue
            }
            size += block.count
            blocks.append(block)
            excerpts += found
            sessions += 1
        }
        return CorrectionPick(excerpts: excerpts, sessions: sessions, input: blocks.joined(separator: "\n\n"), cut: cut)
    }

    /// The first `maxPerSession` negative reactions of a session as excerpts.
    static func excerpts(of items: [TranscriptItem], ratings: [RunRating], session: CorrectedSession, prefix: String) -> [CorrectionExcerpt] {
        let reactions = UserReactions.of(items, ratings: ratings)
        var result: [CorrectionExcerpt] = []
        for (index, reaction) in reactions.enumerated() where reaction.kind.isNegative {
            guard result.count < maxPerSession else { break }
            let next = index + 1 < reactions.count ? reactions[index + 1] : nil
            // Esc and then "no, …": the pushback carries the words, one excerpt is enough.
            if reaction.kind == .interrupt, next?.kind == .pushback { continue }
            var words = full(reaction, in: items)
            if reaction.kind == .rejected {
                // Only the user's own refusal; Esc at the permission prompt is the interrupt after it.
                let item = items.first(where: { $0.id == reaction.step })
                guard item?.resultOutcome?.userRefusal == true, next?.kind != .interrupt else { continue }
                if case .toolResult(let name, _)? = item?.kind, SignalScanner.isQuestion(name) { continue }
                words = said(in: words)
                if words.isEmpty, let next, next.kind == .followUp { words = full(next, in: items) }
            }
            // Esc has no words of its own: the user says what was wrong in the next turn.
            if reaction.kind == .interrupt, let next, next.kind == .followUp { words = full(next, in: items) }
            if reaction.kind == .interrupt, FailureSignals.isInterrupt(words) { words = "" }
            result.append(CorrectionExcerpt(id: "\(prefix).\(reaction.id)", sessionKey: session.key, file: session.file,
                                            project: session.project, step: reaction.step, kind: reaction.kind,
                                            words: cut(words, wordsLimit), before: steps(before: reaction.step, in: items),
                                            started: items.first(where: { $0.id == reaction.step })?.timestamp ?? session.started))
        }
        return result
    }

    /// The user's words in Claude Code's refusal text ("…the user said:\n<words>"); "" when there are none.
    static func said(in refusal: String) -> String {
        guard let range = refusal.range(of: "the user said:", options: .caseInsensitive) else { return "" }
        return refusal[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The reaction's own item text (the reactions list cuts it to 300).
    static func full(_ reaction: UserReaction, in items: [TranscriptItem]) -> String {
        if reaction.kind == .badRating { return reaction.text }
        return items.first(where: { $0.id == reaction.step })?.text ?? reaction.text
    }

    /// The last `stepsBefore` agent steps before `step`: its text, tool calls and their results.
    static func steps(before step: Int, in items: [TranscriptItem]) -> [CorrectionExcerpt.Step] {
        var found: [CorrectionExcerpt.Step] = []
        for item in items.reversed() where item.id < step {
            if case .user = item.kind { if !found.isEmpty { break } else { continue } }
            let label: String? = switch item.kind {
            case .assistant: "agent"
            case .toolCall(let name): "tool \(name)"
            case .toolResult(_, let isError): isError ? "error" : "result"
            default: nil
            }
            guard let label else { continue }
            found.append(.init(label: label, text: cut(item.text, stepLimit)))
            if found.count == stepsBefore { break }
        }
        return found.reversed()
    }

    /// One session's block of the input.
    static func text(_ excerpts: [CorrectionExcerpt], session: CorrectedSession, number: Int) -> String {
        var lines = ["## Session s\(number) · \(session.harness) · project \(session.project ?? "none")"]
        for excerpt in excerpts {
            lines.append("")
            for step in excerpt.before { lines.append("  [\(step.label)] \(oneLine(step.text))") }
            let words = excerpt.words.isEmpty ? "(no words)" : "\"\(oneLine(excerpt.words))\""
            lines.append("> \(excerpt.id) · \(excerpt.kind.rawValue) · user: \(words)")
        }
        return lines.joined(separator: "\n")
    }

    static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ⏎ ")
    }

    static func cut(_ text: String, _ limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > limit ? String(trimmed.prefix(limit)) + "…" : trimmed
    }
}
