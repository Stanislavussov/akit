import Foundation
import Testing
import AKitFoundation
@testable import AKitKnowledge

/// K40: a note's or a map's history from the base's git, renames followed, and Restore as a new
/// commit with a backup, in a temporary fake home.
final class KnowledgeHistoryTests {
    deinit { try? FileManager.default.removeItem(at: home) }

    let home: URL
    let fm = FileManager.default

    init() throws {
        home = try FakeHome.make("akit-kb-history")
    }

    var env: HarnessEnvironment { FakeHome.env(home) }

    func git(_ args: String..., in folder: URL) async throws -> String {
        try await FakeHome.git(args, in: folder, env: env)
    }

    /// payments/billing: created, edited twice (one through the commit queue).
    func makeBase() async throws -> KnowledgeBase {
        let base = try await TemplateBase.base(home: home)
        try await base.newNote(area: "payments", name: "billing", kind: "service", env: env)
        try base.save(note: "payments/billing", text: "# billing\n\nOne invoice per order.\n")
        try await base.commit(["areas/payments/billing.md"], message: "Edit billing", env: env)
        try base.save(note: "payments/billing", text: "# billing\n\nTwo invoices per order.\n")
        #expect(KnowledgeCommitQueue(base: base.root, env: env).enqueue(["areas/payments/billing.md"]) == .queued(refused: []))
        _ = await KnowledgeCommitQueue(base: base.root, env: env).flush()
        return base
    }

    @Test func theHistoryListsEveryCommitNewestFirst() async throws {
        let base = try await makeBase()
        let history = try await base.history("billing", env: env)
        #expect(history.kind == .note && history.id == "payments/billing" && history.path == "areas/payments/billing.md")
        #expect(history.exists && !history.pending)
        #expect(history.versions.map(\.change) == [.changed, .changed, .added])
        #expect(history.versions[1].message == "Edit billing")
        #expect(history.created == history.versions.last?.date && history.changed == history.versions.first?.date)
        #expect(try await base.history("billing", limit: 1, env: env).versions.count == 1)
        // An edit not committed yet.
        try base.save(note: "payments/billing", text: "# billing\n\nThree.\n")
        #expect(try await base.history("billing", env: env).pending)
        // A version's text, by a short hash.
        let first = history.versions[1]
        #expect(String(decoding: try await base.contents(of: try history.version(first.short), env: env), as: UTF8.self)
            == "# billing\n\nOne invoice per order.\n")
        #expect(throws: KnowledgeBase.Failure.self) { try history.version("zzzz") }
        #expect(throws: KnowledgeBase.Failure.self) { try history.version("ab") }
        await #expect(throws: KnowledgeBase.Failure.self) { try await base.history("payments", env: env) }
        await #expect(throws: KnowledgeBase.Failure.self) { try await base.history("nowhere", env: env) }
    }

    @Test func restoreIsANewCommitWithABackup() async throws {
        let base = try await makeBase()
        let history = try await base.history("billing", env: env)
        let now = try Data(contentsOf: base.noteFile("payments/billing"))
        let plan = try await base.planRestore("billing", to: history.versions[1].short, env: env)
        #expect(plan.changes && plan.diff.contains("- Two invoices per order.") && plan.diff.contains("+ One invoice per order."))
        let backup = try #require(try await base.restore(plan, env: env))
        #expect(try Data(contentsOf: backup) == now)
        #expect(try String(contentsOf: base.noteFile("payments/billing"), encoding: .utf8) == "# billing\n\nOne invoice per order.\n")
        #expect(try await git("status", "--porcelain", in: base.root).isEmpty)
        #expect(try await git("log", "-1", "--format=%s", in: base.root).hasPrefix("Restore payments/billing to \(history.versions[1].short) ("))
        // Nothing is lost: the version before the restore is in the history and comes back too.
        let after = try await base.history("billing", env: env)
        #expect(after.versions.count == history.versions.count + 1)
        try await base.restore(try await base.planRestore("billing", to: history.versions[0].short, env: env), env: env)
        #expect(try Data(contentsOf: base.noteFile("payments/billing")) == now)
        // The same version again changes nothing.
        let same = try await base.planRestore("billing", to: history.versions[0].short, env: env)
        #expect(!same.changes)
        #expect(try await base.restore(same, env: env) == nil)
        // A file changed since the plan is never overwritten.
        let stale = try await base.planRestore("billing", to: history.versions[1].short, env: env)
        try base.save(note: "payments/billing", text: "# billing\n\nElsewhere.\n")
        await #expect(throws: KnowledgeBase.Failure.self) { try await base.restore(stale, env: env) }
        #expect(try String(contentsOf: base.noteFile("payments/billing"), encoding: .utf8) == "# billing\n\nElsewhere.\n")
    }

    @Test func aRenamedNoteKeepsItsHistoryAndARemovedOneComesBack() async throws {
        let base = try await makeBase()
        try await base.apply(try base.planRename("payments/billing", to: "invoices"), env: env)
        let renamed = try await base.history("invoices", env: env)
        #expect(renamed.id == "payments/invoices" && renamed.versions.first?.change == .renamed)
        #expect(renamed.versions.first?.from == "areas/payments/billing.md" && renamed.versions.count == 4)

        try await base.moveToTrash(base.item("invoices"), env: env, trash: { url in
            let place = self.home.appending(path: "Trash-\(UUID().uuidString)")
            try self.fm.moveItem(at: url, to: place)
            return place
        })
        let removed = try await base.history("payments/invoices", env: env)
        #expect(!removed.exists && removed.versions.first?.change == .deleted)
        await #expect(throws: KnowledgeBase.Failure.self) { try await base.contents(of: removed.versions[0], env: env) }
        let plan = try await base.planRestore("areas/payments/invoices.md", to: removed.versions[1].short, env: env)
        #expect(plan.original == nil && plan.diff.hasPrefix("areas/payments/invoices.md (removed now)"))
        #expect(try await base.restore(plan, env: env) == nil) // nothing to back up
        #expect(try String(contentsOf: base.noteFile("payments/invoices"), encoding: .utf8) == "# billing\n\nTwo invoices per order.\n")
        #expect(try await git("status", "--porcelain", in: base.root).isEmpty)
    }

    @Test func parsesTheLog() {
        let log = "\u{1e}aaaa111\u{1f}2026-11-22T16:32:00+01:00\u{1f}Rename x\n\nR100\tareas/p/a.md\tareas/p/b.md\n"
            + "\u{1e}bbbb222\u{1f}2026-11-21T10:00:00+01:00\u{1f}Add note p/a\n\nA\tareas/p/a.md\n"
        let versions = KnowledgeHistory.parse(log: log)
        #expect(versions.map(\.change) == [.renamed, .added])
        #expect(versions[0].path == "areas/p/b.md" && versions[0].from == "areas/p/a.md" && versions[1].path == "areas/p/a.md")
    }
}
