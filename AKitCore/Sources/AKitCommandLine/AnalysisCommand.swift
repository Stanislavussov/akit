import AKitErrorAnalysis
import AKitFoundation
import AKitLab
import Foundation

/// `akit analysis …`: failure modes across many sessions (docs/design/error-analysis.md).
extension AKitCLI {
    public static let analysisUsage = """
        akit analysis — failure modes across many sessions; files in ~/.akit/lab/analysis

          akit analysis notes [SESSION] [--json]
                                          A reviewed session's outcome, notes (accepted and rejected
                                          by the verifier), deviation steps and advice. Without
                                          SESSION: every reviewed session. Review one with
                                          akit lab new review SESSION
        """

    static func analysis(_ arguments: [String], env: HarnessEnvironment, cwd: URL,
                         out: (String) -> Void, err: (String) -> Void) async throws -> Int32 {
        var args = Arguments(arguments)
        if args.flag("--help") || args.flag("-h") || args.isEmpty {
            out(analysisUsage)
            return 0
        }
        let json = args.flag("--json")
        switch args.positional() {
        case "notes":
            let session = args.positional()
            try args.finish()
            let store = NotesStore(env: env)
            guard let session else {
                let all = store.all().sorted { $0.createdAt > $1.createdAt }
                if json { out(try labJSON(all)); return 0 }
                out(all.isEmpty ? "No reviewed sessions." : all.map { notes in
                    "\(notes.sessionKey)  \(notes.outcome.title.padding(toLength: 12, withPad: " ", startingAt: 0))  "
                        + "\(notes.accepted.count) notes  \(notes.title ?? "")"
                }.joined(separator: "\n"))
                return 0
            }
            guard let notes = store.load(try sessionKey(session, cwd: cwd, env: env)) else {
                throw Failure(message: "No notes for \(session). Review it first: akit lab new review \(session).")
            }
            out(json ? try labJSON(notes) : notesText(notes))
            return 0
        case let other:
            throw Failure(message: "Unknown “akit analysis \(other ?? "")”. Run akit analysis --help.")
        }
    }

    /// A session key (`claude:<id>`), a transcript path, or a Claude Code session id.
    static func sessionKey(_ text: String, cwd: URL, env: HarnessEnvironment) throws -> String {
        if SessionKey(parsing: text) != nil { return text }
        let file = try transcript(text, cwd: cwd, env: env)
        return "claude:" + file.deletingPathExtension().lastPathComponent
    }

    static func notesText(_ notes: SessionNotes) -> String {
        var lines = ["\(notes.title ?? notes.sessionKey)", "Session  \(notes.sessionKey)", "Outcome  \(notes.outcome.title)",
                     "Notes by \(notes.notesConfig.harness ?? "?") · \(notes.notesConfig.model ?? "?")"]
        if !notes.requirements.isEmpty {
            lines.append("Requirements:")
            lines += notes.requirements.map { "  - \($0)" }
        }
        if let step = notes.deviation.decisiveStep { lines.append("Decided about step #\(step)") }
        if let step = notes.deviation.observedStep { lines.append("Visible about step #\(step)") }
        lines.append("")
        lines.append(notes.paragraph)
        for note in notes.notes {
            let mark = note.isAccepted ? "✓" : "✗"
            lines.append("\(mark) #\(note.step) [\(note.phase?.rawValue ?? "?")] \(note.severity?.rawValue ?? "") \(note.description)")
            lines.append("    “\(note.quote)”")
            if let verdict = note.verdict, !verdict.accepted { lines.append("    rejected: \(verdict.reason)") }
        }
        for (index, advice) in notes.advice.enumerated() { lines.append("\(index + 1). \(advice.title) (\(advice.noteIDs.joined(separator: ", ")))") }
        return lines.joined(separator: "\n")
    }
}
