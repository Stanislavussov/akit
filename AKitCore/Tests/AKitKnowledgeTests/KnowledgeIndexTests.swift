import Foundation
import Testing
import AKitFoundation
@testable import AKitKnowledge

/// The search index (3.2a) on a base folder in a temporary directory: the seed's files, written
/// without git (the index needs only `areas/`).
final class KnowledgeIndexTests {
    deinit { try? FileManager.default.removeItem(at: root) }

    let root: URL
    let fm = FileManager.default

    init() throws {
        root = URL(filePath: FileWalk.realPath(fm.temporaryDirectory) ?? fm.temporaryDirectory.path)
            .appending(path: "akit-kb-index-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appending(path: "areas"), withIntermediateDirectories: true)
        for file in KnowledgeSeed.files { try write(file.path, file.text) }
    }

    var base: KnowledgeBase { KnowledgeBase(root: root) }
    var index: KnowledgeIndex { KnowledgeIndex(base: base) }

    func write(_ path: String, _ text: String) throws {
        let url = root.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func append(_ path: String, _ text: String) throws {
        let handle = try FileHandle(forWritingTo: root.appending(path: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    func notes(_ answer: KnowledgeIndex.SearchAnswer) -> [String] { answer.results.map(\.note) }

    @Test func theRightChunkIsHit() throws {
        let retry = try index.search("retry")
        #expect(retry.stale == false)
        #expect(retry.results.first?.note == "payments/orders-api")
        #expect(retry.results.first?.heading == "Events")
        #expect(retry.results.first?.snippet.contains("retry") == true)
        #expect(retry.results.first?.neighbors == ["payments/billing"])
        let limits = try index.search("bookings minute")
        #expect(limits.results.map { "\($0.note) \($0.heading ?? "-")" } == ["logistics/courier-api Limits"])
        // The title chunk: the text before the first ##.
        #expect(try index.search("Bills each order").results.first.map { "\($0.note) \($0.heading ?? "-")" } == "payments/billing -")
        #expect(try index.search("order", area: "logistics").results.allSatisfy { $0.note.hasPrefix("logistics/") })
        #expect(throws: KnowledgeIndex.Failure.self) { try index.search("order", area: "nowhere") }
        #expect(try index.search("order", limit: 2).results.count == 2)
    }

    @Test func showReadsTheNoteAndItsSections() throws {
        let note = try index.show("orders-api")
        #expect(note.note == "payments/orders-api" && note.title == "orders-api")
        #expect(note.frontmatter == .init(kind: "service", repo: "git@example.com:shop/orders-api.git", files: ["src/events/order-created.ts"], path: "~/Projects/orders-api"))
        #expect(note.sections.map(\.heading) == [nil, "Events", "Owners"])
        #expect(note.sections[2].text == "The checkout team.")
        #expect(note.truncated == false && note.stale == false)
        #expect(try index.show("payments/orders-api", section: "Events").sections.map(\.heading) == ["Events"])
        #expect(throws: KnowledgeIndex.Failure.self) { try index.show("orders-api", section: "Nope") }
        #expect(throws: KnowledgeIndex.Failure.self) { try index.show("no-such-note") }
    }

    @Test(arguments: [200, 1000, 4000])
    func answersStayUnderTheCap(_ cap: Int) throws {
        // A long note: 40 sections of 400 bytes each that all match "payload".
        let long = (1...40).map { "## Part \($0)\n\n" + String(repeating: "payload word \($0) ", count: 25) }.joined(separator: "\n\n")
        try write("areas/payments/long.md", "# long\n\n" + long + "\n")
        let search = try index.search("payload", limit: 40, maxTokens: cap)
        #expect(search.tokens <= cap)
        #expect(Budget.tokens(Budget.json(search)) == search.tokens)
        #expect(!search.results.isEmpty)
        let show = try index.show("long", maxTokens: cap)
        #expect(show.tokens <= cap)
        #expect(Budget.tokens(Budget.json(show)) == show.tokens)
        #expect(show.truncated)
        #expect(try index.show("long", maxTokens: 100_000).truncated == false)
    }

    @Test func dropAndRebuildGiveTheSameResults() throws {
        let queries = ["order created", "retry", "courier", "invoice"]
        let before = try queries.map { try index.search($0) }
        let dump = try index.dump()
        #expect(try index.refresh(rebuild: true).rebuilt)
        #expect(try queries.map { try index.search($0) } == before)
        try fm.removeItem(at: index.file)
        #expect(try queries.map { try index.search($0) } == before)
        #expect(try index.dump() == dump)
        let status = try index.refresh()
        #expect(status == .init(notes: 17, maps: 4, chunks: 28, rebuilt: false, stale: false, tokens: status.tokens))
    }

    @Test func anOlderSchemaIsRebuiltANewerOneNeverWritten() throws {
        _ = try index.refresh()
        do {
            let database = try SQLiteDatabase(url: index.file, privateFolder: false)
            try database.setMeta("schema", "0")
        }
        #expect(try index.refresh().rebuilt)
        #expect(try SQLiteDatabase(url: index.file, readOnly: true).meta("schema") == String(KnowledgeIndex.schema))

        // Newer, still readable by this akit: read, stale, never written.
        do {
            let database = try SQLiteDatabase(url: index.file, privateFolder: false)
            try database.setMeta("schema", String(KnowledgeIndex.schema + 1))
            try database.setMeta("compatible", String(KnowledgeIndex.schema))
        }
        try write("areas/payments/fresh.md", "# fresh\n\nzebrafish\n")
        let newer = try index.search("zebrafish")
        #expect(newer.stale && newer.results.isEmpty)
        #expect(try index.search("retry").results.first?.note == "payments/orders-api")
        #expect(try SQLiteDatabase(url: index.file, readOnly: true).meta("schema") == String(KnowledgeIndex.schema + 1))
        #expect(try !index.dump().contains { $0.contains("fresh") })
        #expect(throws: KnowledgeIndex.Failure.self) { try index.refresh(rebuild: true) }

        // Newer and not readable: "Update akit".
        do {
            let database = try SQLiteDatabase(url: index.file, privateFolder: false)
            try database.setMeta("compatible", String(KnowledgeIndex.schema + 1))
        }
        #expect { try index.search("retry") } throws: { ($0 as? KnowledgeIndex.Failure)?.message.hasSuffix("Update akit.") == true }
        #expect(try SQLiteDatabase(url: index.file, readOnly: true).meta("schema") == String(KnowledgeIndex.schema + 1))
    }

    @Test func aBusyLockReadsTheSnapshotAtOnce() throws {
        _ = try index.refresh()
        let lock = try #require(try FileLock.acquire(root.appending(path: KnowledgeIndex.lockName)))
        try write("areas/payments/fresh.md", "# fresh\n\nzebrafish\n")
        let started = Date.now
        let busy = try index.search("retry")
        #expect(Date.now.timeIntervalSince(started) < 2)
        #expect(busy.stale && busy.results.first?.note == "payments/orders-api")
        #expect(try index.search("zebrafish").results.isEmpty)
        #expect(try index.refresh().stale)
        lock.release()
        let free = try index.search("zebrafish")
        #expect(!free.stale && notes(free) == ["payments/fresh"])
    }

    @Test func aBusyLockWithNoIndexFileIsEmptyAndStale() throws {
        let lock = try #require(try FileLock.acquire(root.appending(path: KnowledgeIndex.lockName)))
        let answer = try index.search("retry")
        #expect(answer.stale && answer.results.isEmpty)
        #expect(!fm.fileExists(atPath: index.file.path))
        #expect(try index.refresh() == .init(notes: 0, maps: 0, chunks: 0, rebuilt: false, stale: true, tokens: try index.refresh().tokens))
        lock.release()
    }

    @Test func aFileInTheInboxIsNeverIndexed() throws {
        try write("inbox/2026-10-24-orders-api.md", "# orders-api\n\n## Events\n\nzebrafish retry\n")
        #expect(try index.search("zebrafish").results.isEmpty)
        #expect(try !index.dump().contains { $0.contains("inbox") || $0.contains("zebrafish") })
    }

    /// The 7.0 miss cutoff, against real BM25 values of the demo base.
    @Test func theMissCutoffSeparatesAMatchFromAnUnrelatedQuery() throws {
        let match = try index.search("order created")
        #expect(try #require(match.results.first).score < KnowledgeIndex.missScore)
        let unrelated = try index.search("kubernetes ingress")
        #expect(unrelated.results.isEmpty || unrelated.results[0].score >= KnowledgeIndex.missScore)
    }

    @Test func anIncrementalRefreshEqualsAFullRebuild() throws {
        _ = try index.refresh()
        func check(_ step: String, _ change: () throws -> Void) throws {
            try change()
            _ = try index.refresh()
            let incremental = try index.dump()
            #expect(try index.refresh(rebuild: true).rebuilt)
            #expect(incremental == (try index.dump()), "\(step)")
        }
        try check("add") { try write("areas/payments/refunds.md", "# refunds\n\n## Rules\n\nA refund cancels [[billing]].\n") }
        try check("edit") { try append("areas/payments/refunds.md", "\n## More\n\nwithin 30 days\n") }
        try check("delete") { try fm.removeItem(at: root.appending(path: "areas/payments/refunds.md")) }
        try check("rename") {
            try fm.moveItem(at: root.appending(path: "areas/logistics/shipping.md"), to: root.appending(path: "areas/logistics/delivery.md"))
        }
        try check("a second orders-api.md in another area") { try write("areas/logistics/orders-api.md", "# orders-api\n\nThe pickup side.\n") }
        try check("a map's arrow relabelled") {
            let url = root.appending(path: "areas/payments/maps/overview.excalidraw")
            let text = try String(contentsOf: url, encoding: .utf8)
            try Data(text.replacingOccurrences(of: "\"events\"", with: "\"messages\"").utf8).write(to: url)
        }
        #expect(try index.dump().contains { $0.hasPrefix("edge payments/maps/overview|arr-events|") && $0.contains("|messages|") })
        #expect(try index.dump().contains("node note|logistics/delivery|logistics|shipping"))
    }

    @Test func ftsQueryQuotesEveryWord() throws {
        #expect(KnowledgeIndex.ftsQuery("order-created: retry") == #""order-created:" "retry""#)
        #expect(KnowledgeIndex.ftsQuery(#"say "hi""#) == #""say" """hi""""#)
        #expect(KnowledgeIndex.ftsQuery("order*") == #""order*""#)
        #expect(KnowledgeIndex.ftsQuery("* - : \"") == "")
        #expect(KnowledgeIndex.ftsQuery("заказ создан") == #""заказ" "создан""#)
        #expect(KnowledgeIndex.ftsQuery("   ") == "")
        try write("areas/payments/заказ.md", "# заказ\n\nЗаказ создан и оплачен.\n")
        #expect(notes(try index.search("заказ СОЗДАН")) == ["payments/заказ"])
        for query in ["-", ":", "\"", "*", "order-created", "a\"b", "", "NOT", "AND OR"] {
            _ = try index.search(query) // never an FTS5 syntax error
        }
        #expect(try index.search("").results.isEmpty)
    }

    @Test func aMissWritesOneLine() throws {
        let log = root.appending(path: KnowledgeIndex.missesName)
        func lines() -> [String] { ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
        _ = try index.search("order created")
        #expect(lines().isEmpty)
        _ = try index.search("kubernetes ingress")
        #expect(lines().count == 1)
        let fields = lines()[0].split(separator: "\t").map(String.init)
        #expect(fields.count == 4 && fields[1] == "0" && fields[2] == "-" && fields[3] == "kubernetes ingress")
        _ = try index.search("kubernetes\tingress")
        #expect(lines().count == 2 && lines()[1].hasSuffix("\tkubernetes ingress"))
        // AKit's search field logs no misses.
        _ = try index.search("kubernetes", logMisses: false)
        #expect(lines().count == 2)
    }

    @Test func anEditOnDiskIsFoundByTheNextSearch() throws {
        #expect(try index.search("backoff").results.isEmpty)
        try append("areas/payments/billing.md", "## Retry\nbackoff\n")
        let found = try index.search("backoff")
        #expect(found.results.map { "\($0.note) \($0.heading ?? "-")" } == ["payments/billing Retry"])
    }
}
