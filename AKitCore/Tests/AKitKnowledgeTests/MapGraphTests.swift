import Foundation
import Testing
import AKitBrain
import AKitFoundation
@testable import AKitKnowledge

/// `.excalidraw` reading and the map graph, on the 0.17.6 fixtures of spike 2.0 (read in place by
/// #filePath; the fixture base has no git) and on fresh bases in a temporary fake home.
final class MapGraphTests {
    deinit { try? FileManager.default.removeItem(at: home) }

    static let fixtures = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures")
    static let fixtureBase = KnowledgeBase(root: fixtures.appending(path: "base"))

    let home: URL
    let fm = FileManager.default

    init() throws {
        home = try FakeHome.make("akit-kb-maps")
    }

    var env: HarnessEnvironment { FakeHome.env(home) }

    func git(_ args: String..., in folder: URL) async throws -> String {
        try await FakeHome.git(args, in: folder, env: env)
    }

    func scene(_ url: URL) throws -> ExcalidrawFile {
        switch ExcalidrawFile.load(url) {
        case .success(let scene): return scene
        case .failure(let failure): Issue.record("\(url.lastPathComponent): \(failure.message)"); throw failure
        }
    }

    @Test func everyFixtureParses() throws {
        let files = [
            Self.fixtures.appending(path: "cli-draft.excalidraw"),
            Self.fixtures.appending(path: "base/areas/payments/maps/overview.excalidraw"),
            Self.fixtures.appending(path: "base/areas/payments/maps/billing-detail.excalidraw"),
        ]
        for file in files {
            let read = try scene(file)
            #expect(read.version == 2, "\(file.lastPathComponent)")
            #expect(!read.live.isEmpty, "\(file.lastPathComponent)")
        }
        let overview = try scene(files[1])
        #expect(overview.source == "akit-web://app")
        let events = try #require(overview.elements.first { $0.id == "arr-events" })
        #expect(events.startBinding == "blk-orders" && events.endBinding == "blk-billing" && events.link == "[[order-to-billing]]")
        // The draft's newer fields (index, fontFamily 5, binding mode/fixedPoint) don't get in the way.
        let draft = try scene(files[0])
        #expect(draft.source == "https://github.com/swiftlysingh/excalidraw-cli")
        let arrow = try #require(draft.elements.first { $0.type == "arrow" })
        #expect(arrow.startBinding == "blk-orders" && arrow.endBinding == "blk-billing")
    }

    @Test func aFileThatIsNoSceneIsAnErrorValue() {
        for text in ["", "not json", "[1, 2]", #"{"type": "excalidraw"}"#, #"{"type": "other", "elements": []}"#, #"{"elements": [1, 2"#] {
            guard case .failure = ExcalidrawFile.parse(Data(text.utf8)) else { Issue.record("“\(text)” parsed"); continue }
        }
        // Odd values read as absent; elements without an id are skipped.
        let odd = #"{"elements": [{"id": "a", "type": "rectangle", "x": "far", "link": 3, "startBinding": {"elementId": 7}}, {"type": "text"}, 5]}"#
        guard case .success(let read) = ExcalidrawFile.parse(Data(odd.utf8)) else { Issue.record("odd values refused"); return }
        #expect(read.elements == [ExcalidrawFile.Element(id: "a", type: "rectangle")])
        #expect(read.version == nil)
    }

    @Test func freeTextInsideABlockLabelsIt() throws {
        let labels = MapGraph.labels(in: try scene(Self.fixtures.appending(path: "cli-draft.excalidraw")))
        #expect(labels["blk-orders"] == "orders-api")
        #expect(labels["blk-billing"] == "billing")
        #expect(labels["JIKhfxTmJq"] == "events")
        // Linked, the draft's blocks are notes and its arrow an edge.
        var draft = try String(contentsOf: Self.fixtures.appending(path: "cli-draft.excalidraw"), encoding: .utf8)
        var linked = 0
        for (id, link) in [("blk-orders", "[[orders-api]]"), ("blk-billing", "[[billing]]")] {
            let marker = "\"id\": \"\(id)\""
            let range = try #require(draft.range(of: marker))
            let tail = draft[range.upperBound...]
            let null = try #require(tail.range(of: "\"link\": null"))
            draft.replaceSubrange(null, with: "\"link\": \"\(link)\"")
            linked += 1
        }
        #expect(linked == 2)
        let map = MapGraph.map(id: "payments/maps/draft", file: ExcalidrawFile.parse(Data(draft.utf8)), targets: Self.fixtureBase.linkTargets())
        #expect(map.blocks == [.init(element: "blk-orders", note: "payments/orders-api", label: "orders-api"),
                               .init(element: "blk-billing", note: "payments/billing", label: "billing")])
        #expect(map.edges.map { "\($0.from) \($0.kind ?? "-") \($0.to)" } == ["payments/orders-api events payments/billing"])
    }

    @Test func theOverviewFixtureGivesBlocksAnEdgeAJumpAndAnUnboundArrow() throws {
        let graph = try Self.fixtureBase.mapGraph(area: "payments")
        let overview = try #require(graph.maps.first { $0.id == "payments/maps/overview" })
        #expect(overview.area == "payments" && overview.path == "areas/payments/maps/overview.excalidraw" && overview.error == nil)
        #expect(overview.blocks == [.init(element: "blk-orders", note: "payments/orders-api", label: "orders-api"),
                                    .init(element: "blk-billing", note: "payments/billing", label: "billing")])
        #expect(overview.edges == [.init(from: "payments/orders-api", to: "payments/billing", kind: "events",
                                         flow: "payments/flows/order-to-billing", map: "payments/maps/overview", arrow: "arr-events")])
        #expect(overview.unbound == [.init(arrow: "arr-loose", label: nil, start: nil, end: nil)])
        #expect(overview.jumps == [.init(element: "blk-detail", map: "payments/maps/billing-detail", label: "billing detail")])

        let detail = try #require(graph.maps.first { $0.id == "payments/maps/billing-detail" })
        #expect(detail.edges.map(\.kind) == ["invoice requests"])
        #expect(detail.edges.first?.flow == nil)
        // billing → ledger: the ledger shape links no note, so the arrow is listed apart.
        #expect(detail.unbound == [.init(arrow: "arr-ledger", label: nil, start: "blk-billing", end: "blk-ledger")])
        #expect(detail.jumps.map(\.map) == ["payments/maps/overview"])
    }

    @Test func twoMapsJoinIntoOneGraph() throws {
        let graph = try Self.fixtureBase.mapGraph()
        #expect(graph.maps.map(\.id) == ["payments/maps/billing-detail", "payments/maps/overview"])
        let relations = graph.relations(of: "payments/orders-api")
        #expect(relations.filter { $0.to == "payments/billing" }.map(\.map) == ["payments/maps/billing-detail", "payments/maps/overview"])
        #expect(graph.relations(of: "payments/billing").count == 2)
        #expect(graph.relations(of: "payments/flows/order-to-billing").isEmpty)
    }

    @Test func aBrokenMapIsListedWithItsError() throws {
        let base = KnowledgeBase(root: home)
        try fm.createDirectory(at: base.areasFolder.appending(path: "a/maps"), withIntermediateDirectories: true)
        try Data("{ broken".utf8).write(to: base.areasFolder.appending(path: "a/maps/x.excalidraw"))
        let map = try #require(try base.mapGraph().maps.first)
        #expect(map.id == "a/maps/x" && map.error?.hasPrefix("not valid JSON") == true && map.blocks.isEmpty)
        #expect(throws: KnowledgeBase.Failure.self) { try base.mapGraph(area: "nothing") }
    }

    @Test func aNewSceneParsesEmpty() throws {
        guard case .success(let read) = ExcalidrawFile.parse(Data(NewMap.scene().utf8)) else { Issue.record("the new scene doesn't parse"); return }
        #expect(read.elements.isEmpty && read.version == 2 && read.source == NewMap.source)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(NewMap.scene().utf8)) as? [String: Any])
        #expect(json["type"] as? String == "excalidraw")
        #expect((json["appState"] as? [String: Any])?["viewBackgroundColor"] as? String == "#ffffff")
        #expect((json["files"] as? [String: Any])?.isEmpty == true)
    }

    @Test func newMapWritesAnEmptySceneInOneCommit() async throws {
        let base = try await TemplateBase.base(home: home)
        let path = try await base.newMap(area: "payments", name: "flows-overview", env: env)
        #expect(path == "areas/payments/maps/flows-overview.excalidraw")
        #expect(try await git("log", "--format=%s", in: base.root) == "Add map payments/maps/flows-overview\nCreate the knowledge base")
        #expect(try await git("status", "--porcelain", in: base.root).isEmpty)
        let map = try #require(try base.mapGraph(area: "payments").maps.first)
        #expect(map.id == "payments/maps/flows-overview" && map.error == nil && map.elements == 0)
        await #expect(throws: KnowledgeBase.Failure.self) { try await base.newMap(area: "payments", name: "flows-overview", env: env) }
        await #expect(throws: KnowledgeBase.Failure.self) { try await base.newMap(area: "../x", name: "y", env: env) }
    }

    @Test func aFolderWithAreasButNoGitIsReadableNotABase() async throws {
        #expect(KnowledgeBase.isReadable(Self.fixtureBase.root))
        #expect(!KnowledgeBase.isBase(Self.fixtureBase.root))
        let option = Self.fixtureBase.root.path
        let read = try await KnowledgeBase.choose(option: option, folder: home, env: env, projectsRoot: home, forReading: true)
        #expect(read?.root == Self.fixtureBase.root.standardized)
        await #expect(throws: KnowledgeBase.Failure.self) {
            try await KnowledgeBase.choose(option: option, folder: home, env: env, projectsRoot: home)
        }
        // A folder without areas/ is refused for reading too.
        await #expect(throws: KnowledgeBase.Failure.self) {
            try await KnowledgeBase.choose(option: home.path, folder: home, env: env, projectsRoot: home, forReading: true)
        }
    }
}
