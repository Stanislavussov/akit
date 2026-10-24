import Foundation
import Testing
import AKitBrain
import AKitFoundation
@testable import AKitKnowledge

/// The sample base (K26) in a temporary fake home: every seeded feature, idempotence, updates,
/// removal to a fake Trash, `kb rm` items.
struct KnowledgeSeedTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = URL(filePath: FileWalk.realPath(fm.temporaryDirectory) ?? fm.temporaryDirectory.path)
            .appending(path: "akit-kb-seed-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var env: HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home, variables: ["HOME": home.path, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"],
                           executableSearchPaths: [URL(filePath: "/usr/bin")])
    }

    func git(_ args: String..., in folder: URL) async throws -> String {
        let result = try #require(await ProcessRunner.run(URL(filePath: "/usr/bin/git"), arguments: args, directory: folder,
                                                           environment: env.variables, timeout: 20))
        #expect(result.succeeded, "git \(args.joined(separator: " ")): \(result.output)")
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A Trash that moves into a folder of the fake home.
    func fakeTrash(_ url: URL) throws -> URL? {
        let trash = home.appending(path: "Trash-\(UUID().uuidString)")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let place = trash.appending(path: url.lastPathComponent)
        try fm.moveItem(at: url, to: place)
        return place
    }

    /// One row per feature the sample base shows. Each later step appends its rows (K26): maps,
    /// arrows, search text, lint findings, inbox proposals, check marks.
    static let features: [(feature: String, check: @Sendable (KnowledgeBase) throws -> Bool)] = [
        ("two unrelated areas", { base in base.areas().map(\.name) == ["logistics", "payments"] }),
        ("area.yaml with a title in each area", { base in try base.areas().allSatisfy { try base.settings(area: $0.name).title != nil } }),
        ("payments has no projects, so kb area --project adds the first", { base in try base.settings(area: "payments").projects.isEmpty }),
        ("logistics names a remote and a glob", { base in
            try base.settings(area: "logistics").projects == ["git@example.com:shop/warehouse.git", "~/Projects/shipping-*"]
        }),
        ("kb.yaml with the default kinds", { base in try base.kinds() == KnowledgeKinds.defaults }),
        ("a note of every kind in kb.yaml", { base in
            let used = Set(try base.notes().compactMap(\.kind))
            return try base.kinds().names.allSatisfy(used.contains)
        }),
        ("every kind's fields filled in at least one note", { base in
            let notes = try base.notes()
            return try base.kinds().kinds.allSatisfy { kind in
                kind.fields.allSatisfy { field in
                    notes.contains { $0.kind == kind.name && KnowledgeNote.load(base.noteFile($0.id))?.properties[field] != nil }
                }
            }
        }),
        ("a list value (members)", { base in
            if case .list(let members) = KnowledgeNote.load(base.noteFile("payments/checkout-team"))?.properties["members"] { return members.count == 2 }
            return false
        }),
        ("## sections", { base in KnowledgeNote.load(base.noteFile("payments/orders-api"))?.sections.map(\.heading) == ["Events", "Owners"] }),
        ("a flow note in a subfolder of each area", { base in
            try base.notes().filter { $0.kind == "flow" && $0.id.contains("/flows/") }.map(\.area).sorted() == ["logistics", "payments"]
        }),
        ("every [[link]] resolves", { base in
            let targets = base.linkTargets()
            return try base.notes().allSatisfy { note in
                let text = KnowledgeNote.load(base.noteFile(note.id))?.text ?? ""
                return links(in: text).allSatisfy { if case .note = targets.resolve($0, from: note.path) { true } else { false } }
            }
        }),
        ("a link into another area", { base in
            let targets = base.linkTargets()
            return try base.notes().contains { note in
                let text = KnowledgeNote.load(base.noteFile(note.id))?.text ?? ""
                return links(in: text).contains {
                    if case .note(let id) = targets.resolve($0, from: note.path) { !id.hasPrefix(note.area + "/") } else { false }
                }
            }
        }),
        ("the demo texts earlier checks grep", { base in
            let api = KnowledgeNote.load(base.noteFile("payments/orders-api"))?.text ?? ""
            let billing = KnowledgeNote.load(base.noteFile("payments/billing"))?.text ?? ""
            let flow = KnowledgeNote.load(base.noteFile("payments/flows/order-to-billing"))?.text ?? ""
            return api.contains("order created") && api.contains("retry") && api.contains("repo: git@example.com:shop/orders-api.git")
                && api.contains("files: [src/events/order-created.ts]") && billing.contains("## Invoices") && flow.contains("order.created")
                && ["logistics/warehouse", "logistics/shipping", "logistics/flows/pick-and-ship"].allSatisfy { fileExists(base.noteFile($0)) }
        }),
        // Maps (2.1).
        ("a map in each area, every one readable", { base in
            let maps = try base.mapGraph().maps
            return maps.map(\.id) == ["logistics/maps/routes", "payments/maps/overview"] && maps.allSatisfy { $0.error == nil }
        }),
        ("orders-api → billing \"events\" with its flow note, from blk-orders", { base in
            let graph = try base.mapGraph(area: "payments")
            return graph.edges == [MapGraph.Edge(from: "payments/orders-api", to: "payments/billing", kind: "events",
                                                 flow: "payments/flows/order-to-billing", map: "payments/maps/overview", arrow: "arr-events")]
                && graph.maps[0].blocks.contains { $0.element == "blk-orders" && $0.label == "orders-api" }
        }),
        ("warehouse → shipping \"ships to\"", { base in
            try base.mapGraph().relations(of: "logistics/warehouse").map { "\($0.to) \($0.kind ?? "")" } == ["logistics/shipping ships to"]
        }),
        ("jumps between the maps of the two areas, both ways", { base in
            let maps = try base.mapGraph().maps
            return maps.map { $0.jumps.map(\.map) } == [["payments/maps/overview"], ["logistics/maps/routes"]]
        }),
        ("an unbound arrow", { base in try base.mapGraph(area: "logistics").maps[0].unbound.map(\.arrow) == ["arr-loose"] }),
        ("every block and arrow link on a map resolves", { base in
            let targets = base.linkTargets()
            return try base.mapGraph().maps.allSatisfy { map in
                guard case .success(let scene) = ExcalidrawFile.load(base.root.appending(path: map.path)) else { return false }
                return scene.live.compactMap(\.link).allSatisfy {
                    switch targets.resolve($0, from: map.path) { case .note, .map: true; default: false }
                }
            }
        }),
        // Search (3.2a).
        ("kb search finds the Events section of orders-api for retry, with its neighbor", { base in
            let hit = try KnowledgeIndex(base: base).search("retry").results.first
            return hit?.note == "payments/orders-api" && hit?.heading == "Events" && hit?.neighbors == ["payments/billing"]
        }),
        ("\"order created\" scores below the miss cutoff, \"kubernetes ingress\" is a miss", { base in
            let index = KnowledgeIndex(base: base)
            let unrelated = try index.search("kubernetes ingress").results
            return try index.search("order created").results.first.map { $0.score < KnowledgeIndex.missScore } == true
                && (unrelated.isEmpty || unrelated[0].score >= KnowledgeIndex.missScore)
        }),
    ]

    static func links(in text: String) -> [String] {
        text.components(separatedBy: "[[").dropFirst().compactMap { $0.components(separatedBy: "]]").first }
    }

    static func fileExists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    @Test func theSeedShowsEveryFeature() async throws {
        let outcome = try await KnowledgeSeed.seed(env: env)
        #expect(outcome.status == .created)
        #expect(outcome.base.root.path == home.appending(path: ".akit/local/knowledge/sample").path)
        #expect(outcome.base.world == "sample")
        for (feature, check) in Self.features {
            #expect(try check(outcome.base), "\(feature)")
        }
        let marker = try #require(KnowledgeSeed.marker(of: outcome.base))
        #expect(marker == KnowledgeSeed.Marker(seedVersion: KnowledgeSeed.version, files: KnowledgeSeed.files.map(\.path)))
        #expect(try await git("log", "--format=%s", in: outcome.base.root) == "Seed: sample base v\(KnowledgeSeed.version)\nCreate the knowledge base")
        #expect(try await git("status", "--porcelain", in: outcome.base.root).isEmpty)
        #expect(try await git("ls-files", "--", ".akit-seed.json", in: outcome.base.root) == ".akit-seed.json")
        #expect(KnowledgeSeed.bases(home: home) == [outcome.base])
    }

    @Test func seedingAgainChangesNothing() async throws {
        let first = try await KnowledgeSeed.seed(env: env)
        let second = try await KnowledgeSeed.seed(env: env)
        #expect(second.status == .unchanged)
        #expect(try await git("rev-list", "--count", "HEAD", in: first.base.root) == "2")
    }

    @Test func anOlderSeedIsUpdatedUnlessTheUserChangedIt() async throws {
        let base = try await KnowledgeSeed.seed(env: env).base
        // An older seed: v0 with one file this seed no longer has, and an older text.
        let stale = "areas/payments/old.md"
        try Data("# old\n".utf8).write(to: base.root.appending(path: stale))
        try Data("# billing\n".utf8).write(to: base.noteFile("payments/billing"))
        try Data(#"{"seedVersion": 0, "files": ["areas/payments/old.md", "areas/payments/billing.md"]}"#.utf8)
            .write(to: base.root.appending(path: KnowledgeSeed.markerName))
        _ = try await git("add", "-A", in: base.root)
        _ = try await git("commit", "-qm", "Seed: sample base v0", in: base.root)

        let updated = try await KnowledgeSeed.seed(env: env, trash: fakeTrash)
        #expect(updated.status == .updated)
        #expect(!Self.fileExists(base.root.appending(path: stale)))
        #expect(KnowledgeSeed.isCurrent(base))
        #expect(KnowledgeSeed.marker(of: base)?.seedVersion == KnowledgeSeed.version)
        #expect(try await git("status", "--porcelain", in: base.root).isEmpty)

        // A commit of the user: refused, nothing written.
        try await base.newNote(area: "payments", name: "mine", kind: nil, env: env)
        try Data(#"{"seedVersion": 0, "files": []}"#.utf8).write(to: base.root.appending(path: KnowledgeSeed.markerName))
        await #expect(throws: KnowledgeBase.Failure.self) { try await KnowledgeSeed.seed(env: env) }
        do { _ = try await KnowledgeSeed.seed(env: env) } catch { #expect(error.message.contains("Remove it first")) }
    }

    @Test func aBaseOfTheUserIsNeitherSeededNorRemoved() async throws {
        let work = try await KnowledgeBase.create(world: "work", env: env)
        try await work.newNote(area: "orders", name: "api", kind: "service", env: env)
        await #expect(throws: KnowledgeBase.Failure.self) { try await KnowledgeSeed.seed(world: "work", env: env) }
        #expect(throws: KnowledgeBase.Failure.self) { try KnowledgeSeed.remove(work, home: home, trash: fakeTrash) }
        #expect(KnowledgeBase.isBase(work.root))
        #expect(!Self.fileExists(work.root.appending(path: "areas/payments")))
    }

    @Test func removeMovesTheWholeBaseToTheTrashAndForgetsItsFolder() async throws {
        // The world's folder set in Settings → Knowledge (an empty base made there) is seeded too.
        let vault = home.appending(path: "Notes/sample")
        try await KnowledgeBase.setFolder(world: "sample", to: vault, env: env)
        #expect(KnowledgeBase.isBase(vault))
        let base = try await KnowledgeSeed.seed(env: env).base
        #expect(base.root.path == vault.path)
        let place = try #require(try KnowledgeSeed.remove(base, home: home, trash: fakeTrash))
        #expect(!Self.fileExists(vault))
        #expect(Self.fileExists(place.appending(path: KnowledgeSeed.markerName)))
        #expect(try KnowledgeBase.Folders.load(home: home).bases["sample"] == nil)
        #expect(KnowledgeBase.all(home: home).isEmpty)
    }

    @Test func rmFindsNotesMapsAndAreasAndRefusesTheInbox() async throws {
        // The seeded map payments/maps/overview is removed as a map.
        let base = try await KnowledgeSeed.seed(env: env).base

        #expect(try base.item("payments") == .init(kind: .area, id: "payments", path: "areas/payments"))
        #expect(try base.item("areas/logistics/") == .init(kind: .area, id: "logistics", path: "areas/logistics"))
        #expect(try base.item("payments/orders-api") == .init(kind: .note, id: "payments/orders-api", path: "areas/payments/orders-api.md"))
        #expect(try base.item("courier-api").id == "logistics/courier-api")
        #expect(try base.item("payments/maps/overview.excalidraw") == .init(kind: .map, id: "payments/maps/overview", path: "areas/payments/maps/overview.excalidraw"))
        #expect(try base.item("payments/maps/overview").kind == .map)
        #expect(throws: KnowledgeBase.Failure.self) { try base.item("inbox/payments/orders-api.md") }
        #expect(throws: KnowledgeBase.Failure.self) { try base.item("payments/nothing") }

        for (name, path) in [("payments/maps/overview", "areas/payments/maps/overview.excalidraw"),
                             ("payments/orders-db", "areas/payments/orders-db.md"), ("logistics", "areas/logistics")] {
            let before = try await git("rev-list", "--count", "HEAD", in: base.root)
            try await base.moveToTrash(try base.item(name), env: env, trash: fakeTrash)
            #expect(!Self.fileExists(base.root.appending(path: path)), "\(name)")
            #expect(Int(try await git("rev-list", "--count", "HEAD", in: base.root)) == Int(before)! + 1, "\(name)")
            #expect(try await git("status", "--porcelain", in: base.root).isEmpty, "\(name)")
        }
        #expect(base.areas().map(\.name) == ["payments"])
    }
}
