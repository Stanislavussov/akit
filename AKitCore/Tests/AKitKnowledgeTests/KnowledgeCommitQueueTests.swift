import Foundation
import Testing
import AKitFoundation
@testable import AKitKnowledge

/// The commit queue (U2) on a base in a temporary fake home.
struct KnowledgeCommitQueueTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = URL(filePath: FileWalk.realPath(fm.temporaryDirectory) ?? fm.temporaryDirectory.path)
            .appending(path: "akit-kbq-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    func env() -> HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home,
                           variables: ["HOME": home.path, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"],
                           executableSearchPaths: [URL(filePath: "/usr/bin")])
    }

    func git(_ args: String..., in folder: URL) async throws -> String {
        let result = try #require(await ProcessRunner.run(URL(filePath: "/usr/bin/git"), arguments: args, directory: folder,
                                                           environment: env().variables, timeout: 20))
        #expect(result.succeeded, "git \(args.joined(separator: " ")): \(result.output)")
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func commits(_ base: KnowledgeBase) async throws -> Int {
        Int(try await git("rev-list", "--count", "HEAD", in: base.root)) ?? -1
    }

    /// A base with two committed notes.
    func makeBase() async throws -> KnowledgeBase {
        let base = try await KnowledgeBase.create(world: "work", env: env())
        try await base.newNote(area: "payments", name: "orders-api", kind: "service", env: env())
        try await base.newNote(area: "payments", name: "billing", kind: "service", env: env())
        return base
    }

    func edit(_ base: KnowledgeBase, _ path: String, _ line: String) throws {
        let url = base.root.appending(path: path)
        let text = try String(contentsOf: url, encoding: .utf8)
        try Data((text + line + "\n").utf8).write(to: url, options: .atomic)
    }

    @Test func twoEditsMakeOneCommit() async throws {
        let base = try await makeBase()
        let before = try await commits(base)
        let queue = KnowledgeCommitQueue(base: base.root, env: env())
        try edit(base, "areas/payments/orders-api.md", "One.")
        #expect(queue.enqueue(["areas/payments/orders-api.md"]) == .queued(refused: []))
        try edit(base, "areas/payments/billing.md", "Two.")
        #expect(queue.enqueue(["areas/payments/billing.md", "areas/payments/orders-api.md"]) == .queued(refused: []))
        #expect(queue.pending() == ["areas/payments/billing.md", "areas/payments/orders-api.md"])
        #expect(await queue.flush() == .committed(["areas/payments/billing.md", "areas/payments/orders-api.md"]))
        #expect(try await commits(base) == before + 1)
        #expect(try await git("status", "--porcelain", in: base.root).isEmpty)
        #expect(try await git("log", "-1", "--format=%s", in: base.root) == "Edit 2 notes: payments/billing, payments/orders-api")
        #expect(queue.pending().isEmpty)
    }

    @Test func anEmptyFlushMakesNoCommit() async throws {
        let base = try await makeBase()
        let before = try await commits(base)
        let queue = KnowledgeCommitQueue(base: base.root, env: env())
        #expect(await queue.flush() == .nothing)
        // A pending path that didn't change: no commit either, and the queue is emptied.
        #expect(queue.enqueue(["areas/payments/billing.md"]) == .queued(refused: []))
        #expect(await queue.flush() == .nothing)
        #expect(queue.pending().isEmpty)
        #expect(try await commits(base) == before)
    }

    @Test func leftoversOfADroppedQueueAreCommittedByTheNextOne() async throws {
        let base = try await makeBase()
        let before = try await commits(base)
        do {
            let queue = KnowledgeCommitQueue(base: base.root, env: env())
            try edit(base, "areas/payments/orders-api.md", "Unsaved before quit.")
            queue.enqueue(["areas/payments/orders-api.md"])
        }
        let reopened = KnowledgeCommitQueue(base: base.root, env: env())
        #expect(reopened.pending() == ["areas/payments/orders-api.md"])
        #expect(await reopened.flush() == .committed(["areas/payments/orders-api.md"]))
        #expect(try await commits(base) == before + 1)
        #expect(try await git("log", "-1", "--format=%s", in: base.root) == "Edit payments/orders-api")
    }

    @Test func twoConcurrentFlushesMakeOneCommitAndNoError() async throws {
        let base = try await makeBase()
        let before = try await commits(base)
        try edit(base, "areas/payments/orders-api.md", "Concurrent.")
        let first = KnowledgeCommitQueue(base: base.root, env: env(), lockTimeout: 10)
        let second = KnowledgeCommitQueue(base: base.root, env: env(), lockTimeout: 10)
        first.enqueue(["areas/payments/orders-api.md"])
        async let a = Task.detached { await first.flush() }.value
        async let b = Task.detached { await second.flush() }.value
        let results = await [a, b]
        #expect(results.filter { $0 == .committed(["areas/payments/orders-api.md"]) }.count == 1, "\(results)")
        #expect(results.filter { $0 == .nothing }.count == 1, "\(results)")
        #expect(try await commits(base) == before + 1)
        #expect(try await git("status", "--porcelain", in: base.root).isEmpty)
    }

    @Test func aGitFailureKeepsThePaths() async throws {
        let base = try await makeBase()
        let queue = KnowledgeCommitQueue(base: base.root, env: env())
        try edit(base, "areas/payments/orders-api.md", "Kept.")
        queue.enqueue(["areas/payments/orders-api.md"])
        // A remote makes every commit fail (K11).
        _ = try await git("remote", "add", "origin", "git@example.com:shop/kb.git", in: base.root)
        guard case .failed = await queue.flush() else { Issue.record("the flush didn't fail"); return }
        #expect(queue.pending() == ["areas/payments/orders-api.md"])
        _ = try await git("remote", "remove", "origin", in: base.root)
        #expect(await queue.flush() == .committed(["areas/payments/orders-api.md"]))
    }

    @Test func aHeldLockKeepsThePathsWithoutAnError() async throws {
        let base = try await makeBase()
        let queue = KnowledgeCommitQueue(base: base.root, env: env(), lockTimeout: 0.2)
        try edit(base, "areas/payments/orders-api.md", "Busy.")
        queue.enqueue(["areas/payments/orders-api.md"])
        let held = try #require(try FileLock.acquire(base.root.appending(path: KnowledgeBase.queueLockName)))
        #expect(await queue.flush() == .busy)
        #expect(queue.enqueue(["areas/payments/billing.md"]) == .busy)
        held.release()
        #expect(queue.pending() == ["areas/payments/orders-api.md"])
    }

    @Test func anInboxPathIsNotQueued() async throws {
        let base = try await makeBase()
        let queue = KnowledgeCommitQueue(base: base.root, env: env())
        try Data("proposal\n".utf8).write(to: base.inboxFolder.appending(path: "p.md"))
        #expect(queue.enqueue(["inbox/p.md"]) == .queued(refused: ["inbox/p.md"]))
        #expect(queue.enqueue(["inbox/p.md", "areas/payments/billing.md", "../outside.md"])
            == .queued(refused: ["inbox/p.md", "../outside.md"]))
        #expect(queue.pending() == ["areas/payments/billing.md"])
    }

    @Test func aConcurrentEnqueueAndFlushNeverDropAPath() async throws {
        let base = try await makeBase()
        let queue = KnowledgeCommitQueue(base: base.root, env: env(), lockTimeout: 10)
        let other = KnowledgeCommitQueue(base: base.root, env: env(), lockTimeout: 10)
        let paths = (0..<6).map { "areas/payments/note-\($0).md" }
        for path in paths { try Data("# \(path)\n".utf8).write(to: base.root.appending(path: path)) }
        queue.enqueue([paths[0]])
        // Each round: an enqueue and a flush race; afterwards every path is pending or committed.
        for path in paths.dropFirst() {
            async let flushed = Task.detached { await queue.flush() }.value
            async let queued = Task.detached { other.enqueue([path]) }.value
            let (flush, enqueue) = await (flushed, queued)
            #expect(enqueue == .queued(refused: []))
            if case .failed(let message) = flush { Issue.record("flush failed: \(message)") }
        }
        _ = await queue.flush()
        let tracked = try await git("ls-files", "areas/payments", in: base.root).split(separator: "\n").map(String.init)
        for path in paths {
            #expect(tracked.contains(path) || queue.pending().contains(path), "\(path) was dropped")
        }
        #expect(try await git("status", "--porcelain", in: base.root).isEmpty)
    }

    @Test func aNewNoteCommitHoldsOnlyTheNewFileWhileEditsArePending() async throws {
        let base = try await makeBase()
        let queue = KnowledgeCommitQueue(base: base.root, env: env())
        try edit(base, "areas/payments/orders-api.md", "Pending edit.")
        queue.enqueue(["areas/payments/orders-api.md"])
        try await base.newNote(area: "logistics", name: "warehouse", kind: "service", env: env())
        #expect(try await git("show", "--name-only", "--format=", "HEAD", in: base.root) == "areas/logistics/warehouse.md")
        #expect(queue.pending() == ["areas/payments/orders-api.md"])
        #expect(try await git("status", "--porcelain", in: base.root) == "M areas/payments/orders-api.md")
        #expect(await queue.flush() == .committed(["areas/payments/orders-api.md"]))
    }

    @Test func aBrokenQueueFileIsNeverOverwritten() async throws {
        let base = try await makeBase()
        let file = base.root.appending(path: KnowledgeCommitQueue.fileName)
        try Data("not json".utf8).write(to: file)
        let queue = KnowledgeCommitQueue(base: base.root, env: env())
        guard case .failed = queue.enqueue(["areas/payments/billing.md"]) else { Issue.record("enqueue didn't fail"); return }
        guard case .failed = await queue.flush() else { Issue.record("flush didn't fail"); return }
        #expect(try String(contentsOf: file, encoding: .utf8) == "not json")
    }

    // MARK: - The writes behind the Knowledge screen

    @Test func saveWritesTheTextByteForByteAndQueuesNothingItself() async throws {
        let base = try await makeBase()
        let text = "---\r\nkind: service\r\n---\r\n# orders-api\r\n\r\n## Events\r\nórder créated\r\n"
        #expect(try base.save(note: "payments/orders-api", text: text) == "areas/payments/orders-api.md")
        #expect(try Data(contentsOf: base.noteFile("payments/orders-api")) == Data(text.utf8))
        #expect(KnowledgeCommitQueue(base: base.root, env: env()).pending().isEmpty)
        #expect(throws: KnowledgeBase.Failure.self) { try base.save(note: "payments/missing", text: "x") }
        #expect(throws: KnowledgeBase.Failure.self) { try base.save(note: "../outside", text: "x") }
    }

    @Test func newAreaMakesAFolderAndRefusesBadNames() async throws {
        let base = try await makeBase()
        try base.newArea("logistics")
        #expect(base.areas().map(\.name) == ["logistics", "payments"])
        #expect(throws: KnowledgeBase.Failure.self) { try base.newArea("logistics") }
        #expect(throws: KnowledgeBase.Failure.self) { try base.newArea("a/b") }
        #expect(throws: KnowledgeBase.Failure.self) { try base.newArea(".hidden") }
    }

    @Test func moveToTrashCommitsOnlyTheRemoval() async throws {
        let base = try await makeBase()
        let trashed = home.appending(path: "trash")
        try fm.createDirectory(at: trashed, withIntermediateDirectories: true)
        let trash: (URL) throws -> URL? = { url in
            let target = trashed.appending(path: UUID().uuidString)
            try FileManager.default.moveItem(at: url, to: target)
            return target
        }
        try edit(base, "areas/payments/billing.md", "Pending.")
        try await base.moveToTrash(note: "payments/orders-api", env: env(), trash: trash)
        #expect(try await git("show", "--name-only", "--format=%s", "HEAD", in: base.root) == "Delete note payments/orders-api\n\nareas/payments/orders-api.md")
        #expect(try await git("status", "--porcelain", in: base.root) == "M areas/payments/billing.md")
        try await base.newNote(area: "logistics", name: "warehouse", kind: nil, env: env())
        try await base.moveToTrash(area: "logistics", env: env(), trash: trash)
        #expect(try await git("log", "-1", "--format=%s", in: base.root) == "Delete area logistics")
        #expect(!fm.fileExists(atPath: base.areasFolder.appending(path: "logistics").path))
        await #expect(throws: KnowledgeBase.Failure.self) { try await base.moveToTrash(note: "payments/gone", env: env(), trash: trash) }
    }
}
