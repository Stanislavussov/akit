import Foundation

extension SessionNotes {
    /// The problems the review screen leads with: those with at least one accepted note.
    /// Reviews from notes prompt 3 on have their own; an older review's advice stands in, its
    /// advice text doubling as the prompt.
    public var shownProblems: [Problem] {
        let accepted = Set(self.accepted.map(\.id))
        if let problems { return problems.filter { !Set($0.noteIDs).isDisjoint(with: accepted) } }
        return advice.map { advice in
            let cause = advice.noteIDs.lazy.compactMap { id in self.notes.first { $0.id == id }?.cause }.first
            return Problem(title: advice.title, cause: cause, why: advice.detail, prompt: advice.title, noteIDs: advice.noteIDs)
        }
    }

    /// The note that proves a problem: the first accepted one it names.
    public func evidence(of problem: Problem) -> Note? {
        problem.noteIDs.lazy.compactMap { id in self.accepted.first { $0.id == id } }.first
    }

    /// The user's own reactions a problem explains, in the session's order.
    public func reactions(of problem: Problem) -> [UserReaction] {
        (reactions ?? []).filter { problem.reactionIDs.contains($0.id) }
    }

    /// Accepted notes no shown problem names: the screen folds them away.
    public var otherNotes: [Note] {
        let named = Set(shownProblems.flatMap(\.noteIDs))
        return accepted.filter { !named.contains($0.id) }
    }

    /// Every problem's prompt, ready to paste into AGENTS.md or CLAUDE.md or to send to an agent.
    public var promptsText: String {
        shownProblems.map(\.prompt).filter { !$0.isEmpty }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: "\n\n") + "\n"
    }

    /// The review in short, as Markdown: the main problem, then each problem with its cause, why,
    /// the user's words, the quote from the session and the prompt.
    public var briefMarkdown: String {
        var lines = ["# \(title ?? "Session review")", ""]
        let outcome = "Outcome: \(self.outcome.title)."
        if let diagnosis {
            lines += ["**\(diagnosis.headline)**", "", outcome]
        } else if let conclusion {
            lines += [conclusion, "", outcome]
        } else {
            lines.append(outcome)
        }
        for (index, problem) in shownProblems.enumerated() {
            lines += ["", "## \(index + 1). \(problem.title)", ""]
            if let cause = problem.cause { lines.append("Cause: \(cause.title).") }
            if !problem.why.isEmpty { lines.append(problem.why) }
            for reaction in reactions(of: problem) {
                lines += ["", "You said (step #\(reaction.step)):", "> " + reaction.text.replacingOccurrences(of: "\n", with: "\n> ")]
            }
            if let note = evidence(of: problem), !note.quote.isEmpty {
                lines += ["", "In the session (step #\(note.step)):", "> " + note.quote.replacingOccurrences(of: "\n", with: "\n> ")]
            }
            if !problem.prompt.isEmpty {
                let prompt = problem.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                // A fence longer than any run of backticks in the prompt, so the prompt can't close it.
                var longest = 0, run = 0
                for character in prompt { run = character == "`" ? run + 1 : 0; longest = max(longest, run) }
                let fence = String(repeating: "`", count: max(3, longest + 1))
                lines += ["", "Prompt:", "", fence, prompt, fence]
            }
        }
        if shownProblems.isEmpty { lines += ["", accepted.isEmpty ? "No problems found." : "No problem worth a prompt."] }
        return lines.joined(separator: "\n") + "\n"
    }
}
