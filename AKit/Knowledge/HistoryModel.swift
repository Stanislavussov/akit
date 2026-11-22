import AKitFoundation
import AKitKnowledge
import Foundation

/// History (K40): a note's or a map's versions from the base's git, the same calls as
/// `akit kb history` and `akit kb restore`. The panel headers show the dates; History… lists the
/// versions, and Restore… writes one back as a new commit, so it can be undone the same way.
extension KnowledgeModel {
    /// The words of a note's text without its frontmatter.
    static func wordCount(_ text: String) -> Int {
        KnowledgeNote(text: text).body.split { $0.isWhitespace || $0.isNewline }.count
    }

    /// Reads the history of `id` again in the background; the header shows it when it comes.
    func refreshHistory(of id: String) {
        guard let base else { return }
        let env = env
        Task {
            let history = try? await base.history(id, env: env)
            guard self.base == base else { return }
            if let history { histories[id] = history } else { histories[id] = nil }
        }
    }

    /// The history for the sheet, read now (after the pending saves are queued).
    func loadHistory(of id: String) async -> Result<KnowledgeHistory, KnowledgeBase.Failure> {
        guard let base else { return .failure(.init(message: "No knowledge base is open.")) }
        await lastEnqueueDone()
        do {
            let history = try await base.history(id, env: env)
            histories[id] = history
            return .success(history)
        } catch {
            return .failure(error)
        }
    }

    /// What Restore of `id` to `version` would write (`kb restore ID REV` without `--yes`).
    func planRestore(_ id: String, to version: KnowledgeHistory.Version) async -> Result<KnowledgeRestorePlan, KnowledgeBase.Failure> {
        guard let base else { return .failure(.init(message: "No knowledge base is open.")) }
        do { return .success(try await base.planRestore(id, to: version.commit, env: env)) } catch { return .failure(error) }
    }

    /// The text of a version, as History… shows it.
    func contents(of version: KnowledgeHistory.Version) async -> String {
        guard let base else { return "" }
        do { return String(decoding: try await base.contents(of: version, env: env), as: UTF8.self) } catch { return error.message }
    }

    /// Restore (confirmed): `kb restore ID REV --yes`. The pending edits are committed first, the
    /// file is backed up, written and committed; the open note or map shows it at once.
    @discardableResult
    func restore(_ plan: KnowledgeRestorePlan) async -> Bool {
        guard let base else { return false }
        let id = plan.history.id
        if plan.history.kind == .map, map == id { await forcePostDirty() }
        await lastEnqueueDone()
        do {
            let backup = try await base.restore(plan, env: env)
            // AKit's own write: the watcher must not take it for an outside edit.
            if plan.history.kind == .note { markOwnWrite(note: id) } else { markOwnWrite(map: id) }
            reload()
            if plan.history.kind == .map, map == id { open(map: id) }
            if plan.history.kind == .note, note == id { show(tab: id) }
            refreshHistory(of: id)
            notice = "Restored \(id) to the version of \(plan.version.date.formatted(date: .abbreviated, time: .shortened)), committed"
                + (backup.map { "; the version before is in the history and in \(FileWalk.tilde($0, home: home))" } ?? "") + "."
            return true
        } catch {
            problem = error.message
            return false
        }
    }
}
