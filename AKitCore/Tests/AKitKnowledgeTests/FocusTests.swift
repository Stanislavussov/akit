import Foundation
import Testing
import AKitBrain
import AKitFoundation
@testable import AKitKnowledge

/// Focus (K5, K12, K24), `neighbors` and `context` (3.2b) on the seed's files in a temporary
/// fake home, without git in the base (the index needs only `areas/`).
final class FocusTests {
    deinit { try? FileManager.default.removeItem(at: home) }

    let home: URL
    let fm = FileManager.default

    init() throws {
        home = URL(filePath: FileWalk.realPath(fm.temporaryDirectory) ?? fm.temporaryDirectory.path)
            .appending(path: "akit-kb-focus-\(UUID().uuidString)")
        for file in KnowledgeSeed.files { try write(file.path, file.text) }
    }

    var root: URL { home.appending(path: "kb") }
    var base: KnowledgeBase { KnowledgeBase(root: root) }
    var index: KnowledgeIndex { KnowledgeIndex(base: base) }
    var env: HarnessEnvironment { FakeHome.env(home) }

    func write(_ path: String, _ text: String) throws {
        let url = root.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func folder(_ path: String) throws -> URL {
        let url = home.appending(path: path, directoryHint: .isDirectory)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A map in payments with billing → logistics/courier-api "pays", so billing has a
    /// neighbour in another area and orders-api one at depth 2.
    func addCrossAreaMap() throws {
        let billing = NewMap.Box(id: "blk-b", x: 0, y: 0), courier = NewMap.Box(id: "blk-c", x: 420, y: 0)
        try write("areas/payments/maps/couriers.excalidraw", NewMap.scene(
            elements: NewMap.block(billing, label: "billing", link: "[[billing]]", arrows: ["arr-pays"])
                + NewMap.block(courier, label: "courier-api", link: "[[logistics/courier-api]]", arrows: ["arr-pays"])
                + NewMap.arrow("arr-pays", from: billing, to: courier, label: "pays", link: nil)))
    }

    @Test(arguments: [
        ("git@host:g/r.git", "host/g/r"),
        ("ssh://git@host/g/r", "host/g/r"),
        ("https://host/g/r.git", "host/g/r"),
        ("https://host/g/r", "host/g/r"),
        ("https://host/g/r/", "host/g/r"),
        ("git@example.com:shop/orders-api.git", "example.com/shop/orders-api"),
    ])
    func normalizedRemote(_ remote: String, _ id: String) {
        #expect(ProjectRecords.normalizedRemote(remote) == id)
    }

    @Test func focusByRemoteAreaSettingsFirst() throws {
        let anywhere = try folder("Projects/somewhere")
        // payments/orders-api has the repo, no area.yaml names it.
        #expect(base.focus(remote: "https://example.com/shop/orders-api", folder: anywhere, home: home) == .init(area: "payments", source: .repo))
        // logistics' area.yaml names warehouse's remote (the warehouse note does too): area.yaml wins.
        #expect(base.focus(remote: "ssh://git@example.com/shop/warehouse", folder: anywhere, home: home)
            == .init(area: "logistics", source: .areaSettings))
        // An area.yaml naming billing's remote comes before the billing note's repo:.
        try write("areas/accounting/area.yaml", "projects: [https://example.com/shop/billing.git]\n")
        #expect(base.focus(remote: "git@example.com:shop/billing.git", folder: anywhere, home: home) == .init(area: "accounting", source: .areaSettings))
        #expect(base.focus(remote: "git@example.com:shop/unknown.git", folder: anywhere, home: home) == .none)
        #expect(base.focus(remote: nil, folder: anywhere, home: home) == .none)
    }

    @Test func focusByPathAndGlob() throws {
        // logistics' area.yaml: ~/Projects/shipping-*, for the folder and the folders in it.
        let labels = try folder("Projects/shipping-labels")
        #expect(base.focus(remote: nil, folder: labels, home: home) == .init(area: "logistics", source: .areaSettings))
        #expect(base.focus(remote: nil, folder: try folder("Projects/shipping-labels/src"), home: home).area == "logistics")
        #expect(base.focus(remote: nil, folder: try folder("Projects/shippingx"), home: home) == .none)
        // A note's repo: as a ~/ path.
        try write("areas/legacy/old-shop.md", "---\nkind: service\nrepo: ~/code/old-shop\n---\n# old-shop\n")
        #expect(base.focus(remote: nil, folder: try folder("code/old-shop"), home: home) == .init(area: "legacy", source: .repo))
        // An absolute path in area.yaml.
        try write("areas/tools/area.yaml", "projects: [\(home.path)/tools/]\n")
        #expect(base.focus(remote: nil, folder: try folder("tools/cli"), home: home).area == "tools")
    }

    @Test func focusByOverride() async throws {
        let labels = try folder("Projects/shipping-labels")
        #expect(base.focus(remote: nil, folder: labels, home: home, override: "payments") == .init(area: "payments", source: .override))
        // An override naming an area the base no longer has is ignored.
        #expect(base.focus(remote: nil, folder: labels, home: home, override: "gone").area == "logistics")

        // focus(folder:) reads the remote with git and the override from focus.json.
        let orders = try folder("Projects/orders-api")
        for args in [["init", "-q"], ["remote", "add", "origin", "git@example.com:shop/orders-api.git"]] {
            _ = await ProcessRunner.run(URL(filePath: "/usr/bin/git"), arguments: args, directory: orders, environment: env.variables, timeout: 20)
        }
        let projects = home.appending(path: "Projects")
        let found = await base.focus(folder: orders, env: env, projectsRoot: projects)
        #expect(found.project == "example.com/shop/orders-api" && found.choice == .init(area: "payments", source: .repo))
        try KnowledgeBase.Focus.load(home: home).setting(area: "logistics", project: found.project).save(home: home)
        #expect(await base.focus(folder: orders, env: env, projectsRoot: projects).choice == .init(area: "logistics", source: .override))
        #expect(await base.focus(folder: labels, env: env, projectsRoot: projects).choice.source == .areaSettings)
        // Clearing keeps another project's base choice, and drops an entry with nothing left.
        var focus = KnowledgeBase.Focus.load(home: home)
        focus.projects["local/other"] = .init(base: "work")
        try focus.setting(area: nil, project: found.project).setting(area: nil, project: "local/other").save(home: home)
        #expect(KnowledgeBase.Focus.load(home: home) == .init(projects: ["local/other": .init(base: "work")]))
        #expect(await base.focus(folder: orders, env: env, projectsRoot: projects).choice.source == .repo)
    }

    @Test func neighborsReadTheEdgesOfTheIndex() throws {
        let one = try index.neighbors("orders-api")
        #expect(one.note == "payments/orders-api" && one.stale == false && one.truncated == false)
        #expect(one.edges.map { "\($0.from) \($0.kind ?? "-") \($0.to) \($0.flow ?? "-") \($0.map)" }
            == ["payments/orders-api events payments/billing payments/flows/order-to-billing payments/maps/overview"])
        try addCrossAreaMap()
        // Fresh before the read: the new map is there without kb index.
        #expect(try index.neighbors("orders-api").edges.count == 1)
        let two = try index.neighbors("orders-api", depth: 2)
        #expect(two.edges.map(\.arrow) == ["arr-events", "arr-pays"])
        #expect(try index.neighbors("billing").edges.map(\.arrow) == ["arr-pays", "arr-events"])
        #expect(try index.neighbors("checkout-team").edges.isEmpty)
        #expect(throws: KnowledgeIndex.Failure.self) { try index.neighbors("nope") }
        let cut = try index.neighbors("billing", maxTokens: 60)
        #expect(cut.truncated && cut.tokens <= 60 && cut.edges.count < 2)
    }

    @Test func contextCardOfTheFocusArea() throws {
        try addCrossAreaMap()
        let card = try index.context(focus: "payments")
        #expect(card.base == root.path && card.focus == "payments" && card.stale == false && card.truncated == false)
        #expect(card.systems.map(\.note) == ["payments/billing", "payments/checkout-team", "payments/flows/order-to-billing",
                                             "payments/order-events", "payments/orders-api", "payments/orders-db", "logistics/courier-api"])
        #expect(card.systems[0] == .init(note: "payments/billing", title: "billing", line: "Bills each order once."))
        #expect(card.systems.last?.line == "The courier's booking API that [[shipping]] calls.")
        #expect(card.relations == [.init(from: "payments/billing", kind: "pays", to: "logistics/courier-api"),
                                   .init(from: "payments/orders-api", kind: "events", to: "payments/billing")])
        #expect(card.tokens > 0 && card.tokens <= Budget.defaultTokens)
        // No focus: an empty card.
        let none = try index.context(focus: nil)
        #expect(none.focus == nil && none.systems.isEmpty && none.relations.isEmpty)
    }

    @Test func contextStaysUnderTheCap() throws {
        try addCrossAreaMap()
        let full = try index.context(focus: "payments")
        let cut = try index.context(focus: "payments", maxTokens: full.tokens - 1)
        #expect(cut.truncated && cut.tokens < full.tokens)
        // The other areas' notes go first.
        #expect(!cut.systems.contains { $0.note.hasPrefix("logistics/") } && cut.relations.count == 2)
        let tiny = try index.context(focus: "payments", maxTokens: 200)
        #expect(tiny.truncated && tiny.tokens <= 200 && tiny.relations.isEmpty)
    }

    @Test func aNotesLineIsItsDescriptionElseItsFirstSentence() {
        #expect(KnowledgeIndex.line(of: KnowledgeNote(text: "---\ndescription: Short.\n---\n# a\n\nLong text. More.\n")) == "Short.")
        #expect(KnowledgeIndex.line(of: KnowledgeNote(text: "# a\n\nUses `a.b` here. Then more.\n")) == "Uses `a.b` here.")
        #expect(KnowledgeIndex.line(of: KnowledgeNote(text: "# a\n\nOne line\nwrapped\n\nNext paragraph.\n")) == "One line wrapped")
        #expect(KnowledgeIndex.line(of: KnowledgeNote(text: "# a\n\n## Only\n\nA section. B.\n")) == "A section.")
        #expect(KnowledgeIndex.line(of: KnowledgeNote(text: "# a\n")) == "")
        #expect(KnowledgeIndex.line(of: KnowledgeNote(text: "# a\n\n" + String(repeating: "x", count: 300) + "\n")).count == 200)
    }

    /// The one matcher of `projects:` and `repo:` (Focus and AKit Review's knowledge card): a path
    /// matches the folder, anything else is a remote compared normalized.
    @Test func aProjectNamesTheRepositoryByPathOrRemote() {
        let folder = home.appending(path: "Projects/app")
        let remote = "github.com/me/app"
        #expect(KnowledgeBase.names(project: " git@github.com:me/app.git ", remote: remote, folder: folder, home: home))
        #expect(KnowledgeBase.names(project: "https://github.com/me/app", remote: remote, folder: nil, home: home))
        #expect(!KnowledgeBase.names(project: "github.com/me/other", remote: remote, folder: folder, home: home))
        #expect(!KnowledgeBase.names(project: "github.com/me/app", remote: nil, folder: folder, home: home))
        #expect(KnowledgeBase.names(project: "~/Projects/*", remote: nil, folder: folder, home: home))
        #expect(!KnowledgeBase.names(project: "~/Projects/app", remote: remote, folder: nil, home: home))
    }
}
