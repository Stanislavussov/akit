import Foundation
import Testing
import AKitFoundation
@testable import AKitKnowledge

/// K44: the board of a folder's task notes, its card fields, moving a card (one `status:` line),
/// the Inbox's `task` check and the status a proposal can't take back.
final class KnowledgeBoardTests {
    deinit { try? FileManager.default.removeItem(at: home) }

    let home: URL
    let fm = FileManager.default
    /// 2026-11-26 12:00 UTC.
    let now = Date(timeIntervalSince1970: 1_795_694_400)

    init() throws {
        home = try FakeHome.make("akit-kb-board")
    }

    var env: HarnessEnvironment { FakeHome.env(home) }

    func write(_ text: String, note id: String, in base: KnowledgeBase) throws {
        let url = base.noteFile(id)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func task(_ title: String, ado: String, status: String, depends: String? = nil) -> String {
        "---\nkind: task\nado: \(ado)\nstatus: \(status)\n" + (depends.map { "depends: \($0)\n" } ?? "") + "---\n# \(title)\n\n## Plan\n\nSteps.\n"
    }

    /// shop/refunds: (2) waits for (1), which is doing; (1) waits for 700 (no note); a note
    /// without kind task; a task without a status. Another folder's task 800 is done.
    func makeBase() async throws -> KnowledgeBase {
        let base = try await TemplateBase.base(home: home)
        try write(task("(2) SHOP-602 — Form", ado: "602", status: "todo", depends: "[601, 800]"), note: "shop/refunds/602 form", in: base)
        try write(task("(1) SHOP-601 — API", ado: "601", status: "doing", depends: "[700]"), note: "shop/refunds/601 api", in: base)
        try write("---\nkind: task\nado: 603\n---\n# (3) SHOP-603 — E-mail\n", note: "shop/refunds/603 email", in: base)
        try write("---\nkind: flow\n---\n# Refund flow\n", note: "shop/refunds/flow", in: base)
        try write(task("SHOP-800 — Billing", ado: "800", status: "done"), note: "shop/billing/800 billing", in: base)
        return base
    }

    @Test func theProblemsSayWhatTheBoardNeeds() {
        #expect(KnowledgeTask.problems(KnowledgeNote(text: task("A", ado: "1", status: "review", depends: "[2, 3]"))).isEmpty)
        #expect(KnowledgeTask.problems(KnowledgeNote(text: "---\nkind: task\n---\n# A\n")) == [
            "ado: missing; the Azure DevOps work item ID, like ado: 321325",
            "status: missing; one of todo, doing, review, done",
        ])
        #expect(KnowledgeTask.problems(KnowledgeNote(text: task("A", ado: "COL-1", status: "Done", depends: "[2, the api]"))) == [
            "ado: “COL-1” is not a work item ID (digits only)",
            "status: “Done” is not one of todo, doing, review, done",
            "depends: “the api” is not a work item ID (digits, like depends: [321318])",
        ])
        // One value counts as a list of one.
        #expect(KnowledgeTask.problems(KnowledgeNote(text: task("A", ado: "1", status: "todo", depends: "2"))).isEmpty)
    }

    @Test func theBoardHasTheFoldersTaskNotesInColumns() async throws {
        let base = try await makeBase()
        let board = try base.board(folder: "shop/refunds")
        #expect(board.folder == "shop/refunds")
        #expect(board.columns.map(\.status) == [.todo, .doing, .review, .done])
        #expect(board.columns.map { $0.cards.map(\.note) } == [["shop/refunds/602 form"], ["shop/refunds/601 api"], [], []])
        #expect(board.unsorted.map(\.note) == ["shop/refunds/603 email"])
        #expect(board.unsorted[0].problems == ["status: missing; one of todo, doing, review, done"])
        let form = try #require(board.cards.first { $0.ado == "602" })
        #expect(form.number == 2 && form.title == "(2) SHOP-602 — Form")
        // 601 is in the folder and doing, 800 in another folder and done: the form waits for 601.
        #expect(form.depends == [.init(ado: "601", note: "shop/refunds/601 api", number: 1, status: .doing),
                                 .init(ado: "800", note: "shop/billing/800 billing", number: nil, status: .done)])
        #expect(form.blocked)
        // 700 has no note: listed, but nothing to wait for on the board.
        let api = try #require(board.cards.first { $0.ado == "601" })
        #expect(api.depends == [.init(ado: "700", note: nil, number: nil, status: nil)] && !api.blocked)
        // The area's board has the other folder's card too.
        #expect(try base.board(folder: "areas/shop/").cards.map(\.note).sorted()
            == ["shop/billing/800 billing", "shop/refunds/601 api", "shop/refunds/602 form", "shop/refunds/603 email"])
    }

    @Test func aColumnIsInTheOrderOfTheTitlesNumbers() {
        func card(_ note: String, _ number: Int?, _ ado: String?) -> KnowledgeTask.Card {
            .init(note: note, title: note, number: number, ado: ado, status: .todo, depends: [], rule: [], problems: [])
        }
        let cards = [card("c", nil, "5"), card("b", 10, "1"), card("a", 2, "9"), card("d", nil, "3"), card("e", nil, nil)]
        #expect(KnowledgeTask.ordered(cards).map(\.note) == ["a", "b", "d", "c", "e"])
    }

    @Test func anUnknownFolderIsRefused() async throws {
        let base = try await makeBase()
        for name in ["", "nowhere", "shop/../shop", "shop/refunds/602 form.md"] {
            #expect(throws: KnowledgeBase.Failure.self) { try base.board(folder: name) }
        }
        #expect(try base.board(folder: "shop/billing").columns[3].cards.map(\.ado) == ["800"])
    }

    @Test func movingACardWritesOnlyItsStatusLine() async throws {
        let base = try await makeBase()
        let before = try String(contentsOf: base.noteFile("shop/refunds/602 form"), encoding: .utf8)
        let moved = try base.move(task: "shop/refunds/602 form", to: .review)
        #expect(moved.changed && moved.path == "areas/shop/refunds/602 form.md")
        let after = try String(contentsOf: base.noteFile("shop/refunds/602 form"), encoding: .utf8)
        #expect(after == before.replacingOccurrences(of: "status: todo", with: "status: review"))
        #expect(try base.board(folder: "shop/refunds").columns[2].cards.map(\.ado) == ["602"])
        // The same status again changes nothing; a note of another kind is no card.
        #expect(try base.move(task: "shop/refunds/602 form", to: .review).changed == false)
        #expect(throws: KnowledgeBase.Failure.self) { try base.move(task: "shop/refunds/flow", to: .done) }
        // A card without a status gets one.
        try base.move(task: "shop/refunds/603 email", to: .todo)
        #expect(try base.board(folder: "shop/refunds").unsorted.isEmpty)
    }

    // MARK: - Inbox

    func note(_ id: String, body: String, set: [KnowledgeProposal.Setting] = []) -> KnowledgeInbox.Draft {
        .init(.note(id, body: body, set: set), reason: "the delivery map", author: "pi")
    }

    @Test func aTaskNoteProposalNeedsTheBoardsFields() async throws {
        let base = try await makeBase()
        // A new task note without status: refused, the message names what is missing.
        do {
            _ = try base.propose(note("shop/refunds/604 retry", body: "---\nkind: task\nado: 604\n---\n# (4) SHOP-604 — Retry\n"), now: now)
            Issue.record("A task note without status was proposed")
        } catch {
            #expect(error.message.contains("task check") || error.message.contains("status: missing"), "\(error.message)")
        }
        // With --set it passes.
        let (proposal, checks) = try base.propose(note("shop/refunds/604 retry", body: "# (4) SHOP-604 — Retry\n",
                                                       set: [.init(key: "kind", value: "task"), .init(key: "ado", value: "604"),
                                                             .init(key: "status", value: "todo")]), now: now)
        #expect(checks.first { $0.name == "task" }?.status == .passed)
        #expect(try base.planAccept(proposal).planned.contains("status: todo"))
        // A section of a note that isn't a task note gets no task check.
        let (flow, flowChecks) = try base.propose(note("shop/refunds/flow", body: "## Steps\nOne.\n"), now: now)
        #expect(flow.target == "shop/refunds/flow" && !flowChecks.contains { $0.name == "task" })
    }

    @Test func aProposalKeepsTheStatusMovedOnTheBoard() async throws {
        let base = try await makeBase()
        // An agent's whole note, written when 601 was todo; the person has moved it to doing since.
        let stale = "---\nkind: task\nado: 601\nstatus: todo\ndepends: [700]\n---\n# (1) SHOP-601 — API\n\n## Plan\n\nNew steps.\n"
        let (proposal, _) = try base.propose(note("shop/refunds/601 api", body: stale), now: now)
        let planned = try base.planAccept(proposal).planned
        #expect(planned.contains("status: doing") && !planned.contains("status: todo") && planned.contains("New steps."))
        // Only --set status changes it.
        let (explicit, _) = try base.propose(note("shop/refunds/601 api", body: stale, set: [.init(key: "status", value: "done")]), now: now)
        #expect(try base.planAccept(explicit).planned.contains("status: done"))
        // Sections leave the frontmatter as it is anyway.
        let (section, _) = try base.propose(note("shop/refunds/601 api", body: "## Plan\n\nOther steps.\n"), now: now)
        #expect(try base.planAccept(section).planned.contains("status: doing"))
    }

    @Test func lintNamesTheMissingFieldsAndATwin() async throws {
        let base = try await makeBase()
        try write(task("(9) SHOP-601 — Copy", ado: "601", status: "todo"), note: "shop/billing/601 copy", in: base)
        let findings = KnowledgeLint.run(base, projects: .init(), home: home).filter { $0.rule.rawValue.hasPrefix("task-") }
        #expect(findings.map { "\($0.rule.rawValue) \($0.file) \($0.link ?? "-")" } == [
            "task-duplicate-ado areas/shop/refunds/601 api.md 601",
            "task-field areas/shop/refunds/603 email.md -",
        ])
        #expect(findings[1].message.contains("status: missing"))
    }
}
