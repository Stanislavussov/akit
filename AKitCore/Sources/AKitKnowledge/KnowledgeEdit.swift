import AKitFoundation
import Foundation

/// `akit kb edit` (K39, a person only): an existing note changed at once, without a proposal in
/// `inbox/`. The text is what a proposal takes (`## Heading` blocks, or the whole note) and goes
/// through the same checks and the same plan as Accept; the diff is shown before anything is written.
extension KnowledgeBase {
    /// What `edit` would write to the note `name` (nothing is written). Refused: a note that
    /// doesn't exist (create it with `kb new-note` or propose it), a secret, a broken `[[link]]`,
    /// a text that doesn't fit the note.
    public func planEdit(_ name: String, body: String, set: [KnowledgeProposal.Setting]) throws(Failure) -> KnowledgeInbox.Plan {
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, set.isEmpty {
            throw Failure(message: "Nothing to change: give the text (--file F or --stdin) or a property (--set KEY=VALUE).")
        }
        for setting in set where !KnowledgeNote.validKey(setting.key) {
            throw Failure(message: "“\(setting.key)” can't be a property: letters, digits, _, - and . (like repo or owner).")
        }
        let target = try proposalTarget(name)
        guard target.exists else {
            throw Failure(message: "No note “\(name)” in the base. Create it first (akit kb new-note AREA NAME) or propose it (akit kb propose --note AREA/NAME).")
        }
        let draft = Proposal(id: "", kind: .note, target: target.id, reason: nil, created: "", author: nil, set: set, body: body)
        let failed = checks(of: draft).filter { $0.status == .failed }
        if !failed.isEmpty {
            throw Failure(message: "Refused, nothing was written: " + failed.map { $0.message ?? $0.name }.joined(separator: " "))
        }
        return try planAccept(draft)
    }

    /// Writes a planned edit: commits the pending edits first (U2), backs the note up
    /// (`~/.akit/local/backups/knowledge/<world>/<time>/`), writes it and commits it. Refused when
    /// the note changed since the plan; on a commit failure the note is put back. Returns the backup.
    @discardableResult
    public func edit(_ plan: KnowledgeInbox.Plan, env: HarnessEnvironment, now: Date = .now) async throws(Failure) -> URL? {
        guard let original = plan.original else { throw Failure(message: "No note \(plan.note) in the base; nothing was written.") }
        guard plan.changes else { return nil }
        _ = await KnowledgeCommitQueue(base: root, env: env).flush()
        let file = noteFile(plan.note)
        guard (try? Data(contentsOf: file)) == original else {
            throw Failure(message: "\(plan.notePath) changed after the edit was planned; nothing was written. Look at it again.")
        }
        let backup: URL
        do { backup = try backupNote(original, path: plan.notePath, home: env.homeDirectory, now: now) } catch {
            throw Failure(message: "Couldn't back up \(plan.notePath) (\(error.localizedDescription)); nothing was written.")
        }
        do { try Data(plan.planned.utf8).write(to: file, options: .atomic) } catch {
            throw Failure(message: "Couldn't write \(plan.notePath) (\(error.localizedDescription)); the note is as it was.")
        }
        do { try await KnowledgeGit(base: root, env: env).commit(paths: [plan.notePath], message: "Edit \(plan.note)") } catch {
            try? original.write(to: file, options: .atomic)
            throw Failure(message: "Couldn't commit \(plan.notePath) (\(error.message)); the note is as it was.")
        }
        return backup
    }
}
