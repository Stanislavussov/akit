import Foundation
import Testing
import AKitFoundation
@testable import AKitKnowledge

/// The watcher's filter and the own-write rule (3.3), on bases in a temporary fake home.
final class WatchFilterTests {
    deinit { try? FileManager.default.removeItem(at: home) }

    let home: URL
    let fm = FileManager.default

    init() throws {
        home = try FakeHome.make("akit-kbw")
    }

    func env() -> HarnessEnvironment { FakeHome.env(home) }

    func git(_ args: String..., in folder: URL) async throws -> String {
        try await FakeHome.git(args, in: folder, env: env())
    }

    func write(_ root: URL, _ path: String, _ text: String) throws {
        let url = root.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    @Test(arguments: [
        (".git/index", WatchFilter.Change.ignore),
        (".git", .ignore),
        (".obsidian/workspace.json", .ignore),
        (".akit-index.sqlite", .ignore),
        (".akit-index.sqlite-wal", .ignore),
        (".akit-index.sqlite-shm", .ignore),
        (".akit-index.lock", .ignore),
        (".akit-queue.lock", .ignore),
        (".akit-pending.json", .ignore),
        (".akit-misses.log", .ignore),
        ("areas/payments/.DS_Store", .ignore),
        ("areas/payments/.orders-api.md.swp", .ignore),
        (".akit-seed.json", .other(".akit-seed.json")),
        ("README.md", .other("README.md")),
        ("areas", .other("areas")),
        ("inbox", .other("inbox")),
        ("areas/payments/orders-api.md", .area("areas/payments/orders-api.md")),
        ("areas/payments/maps/overview.excalidraw", .area("areas/payments/maps/overview.excalidraw")),
        ("areas/payments/area.yaml", .area("areas/payments/area.yaml")),
        ("inbox/2026-10-24-orders.md", .inbox("inbox/2026-10-24-orders.md")),
        ("kb.yaml", .baseConfig("kb.yaml")),
    ])
    func classify(_ path: String, _ expected: WatchFilter.Change) {
        #expect(WatchFilter.classify(path) == expected)
    }

    @Test func pathsAreMadeRelativeToTheBase() {
        #expect(WatchFilter.relative("/b/work/areas/x.md", root: "/b/work") == "areas/x.md")
        #expect(WatchFilter.relative("/b/work/areas/x.md", root: "/b/work/") == "areas/x.md")
        #expect(WatchFilter.relative("/b/work", root: "/b/work") == nil)
        #expect(WatchFilter.relative("/b/workshop/x.md", root: "/b/work") == nil)
        // NFD from the disk becomes NFC, as ids are.
        #expect(WatchFilter.classify("areas/cafe\u{301}/menu.md") == .area("areas/caf\u{E9}/menu.md"))
    }

    @Test func ownWritesAreReindexedButNeitherQueuedNorPrompted() {
        let disk = ["areas/p/a.md": "h1", "areas/p/b.md": "h2", "kb.yaml": "k1"]
        let own = ["areas/p/a.md": "h1", "areas/p/b.md": "old", "kb.yaml": "k1"]
        let batch = WatchFilter.batch(["areas/p/a.md"], own: own) { disk[$0] }
        #expect(batch.reindex)
        #expect(batch.enqueue.isEmpty && batch.outside.isEmpty)

        let outside = WatchFilter.batch(["areas/p/a.md", "areas/p/b.md", "areas/p/c.md", ".git/index", "areas/p/b.md"], own: own) { disk[$0] }
        #expect(outside.reindex)
        // b changed after AKit's last write; c was never read by AKit; both are outside changes.
        #expect(outside.enqueue == ["areas/p/b.md", "areas/p/c.md"])
        #expect(outside.outside == ["areas/p/b.md", "areas/p/c.md"])
        #expect(!outside.reloadKinds && !outside.inbox)

        // A removed file has no disk hash: an outside change.
        #expect(WatchFilter.batch(["areas/p/a.md"], own: own) { _ in nil }.enqueue == ["areas/p/a.md"])

        let kinds = WatchFilter.batch(["kb.yaml"], own: [:]) { disk[$0] }
        #expect(kinds.reloadKinds && kinds.reindex && kinds.enqueue == ["kb.yaml"])
        let ownKinds = WatchFilter.batch(["kb.yaml"], own: own) { disk[$0] }
        #expect(ownKinds.reloadKinds && ownKinds.enqueue.isEmpty)

        let nothing = WatchFilter.batch([".akit-pending.json", ".akit-seed.json", ".obsidian/app.json"], own: [:]) { _ in "x" }
        #expect(nothing == WatchFilter.Batch())
    }

    @Test func anInboxChangeIsNeverQueued() {
        let batch = WatchFilter.batch(["inbox/proposal.md", "inbox/maps/routes.excalidraw"], own: [:]) { _ in "x" }
        #expect(batch.inbox)
        #expect(!batch.reindex)
        #expect(batch.enqueue.isEmpty && batch.outside.isEmpty)
    }

    @Test func aChangedHashIsReindexed() throws {
        let root = home.appending(path: "base")
        for file in KnowledgeSeed.files { try write(root, file.path, file.text) }
        let index = KnowledgeIndex(base: KnowledgeBase(root: root))
        _ = try index.refresh()
        #expect(try index.search("zanzibar").results.isEmpty)
        let path = "areas/payments/orders-api.md"
        let ownHash = try #require(KnowledgeWrite.hash(of: root.appending(path: path)))
        let text = try String(contentsOf: root.appending(path: path), encoding: .utf8)
        try write(root, path, text + "\n## Zanzibar\n\nOrders shipped to zanzibar retry twice.\n")
        let batch = WatchFilter.batch([path], own: [path: ownHash]) { KnowledgeWrite.hash(of: root.appending(path: $0)) }
        #expect(batch.reindex && batch.outside == [path])
        _ = try index.refresh()
        let hit = try #require(try index.search("zanzibar").results.first)
        #expect(hit.note == "payments/orders-api" && hit.heading == "Zanzibar")

        // AKit's own write (its hash recorded) is reindexed as well.
        let mine = text + "\n## Kalahari\n\nKalahari text.\n"
        try write(root, path, mine)
        let own = WatchFilter.batch([path], own: [path: KnowledgeWrite.hash(Data(mine.utf8))]) {
            KnowledgeWrite.hash(of: root.appending(path: $0))
        }
        #expect(own.reindex && own.outside.isEmpty)
        _ = try index.refresh()
        #expect(try index.search("kalahari").results.first?.note == "payments/orders-api")
    }

    @Test func aProposalWrittenWhileEditsArePendingStaysUntrackedAfterTheFlush() async throws {
        let base = try await TemplateBase.base(home: home)
        try await base.newNote(area: "payments", name: "orders-api", kind: "service", env: env())
        let queue = KnowledgeCommitQueue(base: base.root, env: env())
        // An outside edit of a note is pending…
        let note = "areas/payments/orders-api.md"
        let text = try String(contentsOf: base.root.appending(path: note), encoding: .utf8)
        try write(base.root, note, text + "Edited in Obsidian.\n")
        let first = WatchFilter.batch([note], own: [:]) { KnowledgeWrite.hash(of: base.root.appending(path: $0)) }
        #expect(queue.enqueue(first.enqueue) == .queued(refused: []))
        // …when an agent's proposal lands in inbox/ (written by hand here, as any file in inbox/).
        try write(base.root, "inbox/2026-10-24-orders-api.md", "# Proposal\n\nAdd the refund flow.\n")
        let second = WatchFilter.batch(["inbox/2026-10-24-orders-api.md", note], own: [:]) {
            KnowledgeWrite.hash(of: base.root.appending(path: $0))
        }
        #expect(second.inbox)
        #expect(!second.enqueue.contains { $0.hasPrefix("inbox/") })
        #expect(queue.enqueue(second.enqueue) == .queued(refused: []))
        #expect(queue.pending() == [note])
        #expect(await queue.flush() == .committed([note]))
        // inbox/ is tracked (inbox/.gitkeep, P3), so git names the proposal file itself.
        #expect(try await git("status", "--porcelain", in: base.root) == "?? inbox/2026-10-24-orders-api.md")
        #expect(try await git("status", "--porcelain", "--untracked-files=all", in: base.root) == "?? inbox/2026-10-24-orders-api.md")
        #expect(WatchFilter.inboxCount(base.root) == 1)
    }

    @Test func theInboxCountSkipsHiddenFiles() throws {
        let root = home.appending(path: "base")
        #expect(WatchFilter.inboxCount(root) == 0)
        try write(root, "inbox/a.md", "a")
        try write(root, "inbox/maps/b.excalidraw", "{}")
        try write(root, "inbox/.DS_Store", "")
        // A map proposal's draft goes with its proposal (5.4): not counted apart.
        try write(root, "inbox/c.md", "c")
        try write(root, "inbox/c.excalidraw", "{}")
        #expect(WatchFilter.inboxCount(root) == 2)
    }
}
