import Foundation
import Testing
import AKitFoundation
@testable import AKitKnowledge

/// Map proposals (5.4, K21) in a temporary fake home, on the excalidraw-cli draft of spike 2.0:
/// propose writes only `inbox/` (the proposal and its draft), a broken or secret draft is refused,
/// labels match notes by the link rules and titles, Accept saves the canvas's bytes in one commit.
struct KnowledgeMapProposalTests {
    static let fixture = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/cli-draft.excalidraw")

    let home: URL
    let fm = FileManager.default
    /// 2026-10-25 12:00 UTC.
    let now = Date(timeIntervalSince1970: 1_792_929_600)

    init() throws {
        home = URL(filePath: FileWalk.realPath(fm.temporaryDirectory) ?? fm.temporaryDirectory.path)
            .appending(path: "akit-kb-map-proposal-\(UUID().uuidString)")
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

    /// A base with payments/billing and payments/orders-api.
    func makeBase() async throws -> KnowledgeBase {
        let base = try await KnowledgeBase.create(world: "work", env: env)
        try await base.newNote(area: "payments", name: "billing", kind: "service", env: env)
        try await base.newNote(area: "payments", name: "orders-api", kind: "service", env: env)
        return base
    }

    func draft() throws -> Data { try Data(contentsOf: Self.fixture) }

    func map(_ name: String, _ data: Data) -> KnowledgeInbox.Draft {
        .init(.map(name, draft: data), reason: "drawn from the code", author: "pi")
    }

    /// Every file under the base except .git/ and inbox/, with its bytes.
    func snapshot(_ base: KnowledgeBase) throws -> [String: Data] {
        var files: [String: Data] = [:]
        let walker = try #require(fm.enumerator(at: base.root, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let url as URL in walker where FileWalk.isRegularFile(url) {
            let path = String(url.standardized.path.dropFirst(base.root.standardized.path.count + 1))
            if path.hasPrefix(".git/") || path.hasPrefix("inbox/") { continue }
            files[path] = try Data(contentsOf: url)
        }
        return files
    }

    /// What the canvas does on Accept, in the test: each planned link set on its element (the
    /// test edits the JSON; the app lets Excalidraw serialize).
    func linked(_ data: Data, _ links: [String: String]) throws -> Data {
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let elements = try #require(object["elements"] as? [[String: Any]])
        object["elements"] = elements.map { element in
            var element = element
            if let id = element["id"] as? String, let link = links[id] { element["link"] = link }
            return element
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    @Test func theCLIMadeDraftParsesAndItsFreeLabelsNameTheirShapes() throws {
        guard case .success(let scene) = ExcalidrawFile.parse(try draft()) else { Issue.record("the draft doesn't parse"); return }
        #expect(scene.live.count == 6 && scene.source == "https://github.com/swiftlysingh/excalidraw-cli")
        #expect(KnowledgeInbox.mapSummary(scene) == "Blocks: orders-api, billing\nArrows: orders-api -events-> billing\n")
    }

    @Test func proposeWritesOnlyTheProposalAndItsDraftIntoInbox() async throws {
        let base = try await makeBase()
        let before = try snapshot(base)
        let (proposal, checks) = try base.propose(map("payments/flow", try draft()), now: now)
        #expect(proposal.id == "2026-10-25-payments-maps-flow" && proposal.kind == .map && proposal.target == "payments/maps/flow")
        #expect(checks.map(\.name) == ["secret", "target", "map"] && checks.allSatisfy { $0.status == .passed })
        #expect(checks[1].message == "A new map.")
        #expect(try snapshot(base) == before)
        #expect(try await git("status", "--porcelain", in: base.root)
            == "?? inbox/2026-10-25-payments-maps-flow.excalidraw\n?? inbox/2026-10-25-payments-maps-flow.md")
        #expect(try Data(contentsOf: base.root.appending(path: KnowledgeInbox.draftPath(of: proposal.id))) == (try draft()))
        // The proposal reads back; the draft isn't counted apart in the Inbox badge.
        #expect(try base.proposal(proposal.id) == proposal)
        #expect(base.proposals().map(\.id) == [proposal.id] && WatchFilter.inboxCount(base.root) == 1)
        #expect(proposal.body.contains("Arrows: orders-api -events-> billing"))
        // Same forms of the name: AREA/maps/NAME, areas/…, .excalidraw.
        for name in ["payments/maps/flow", "areas/payments/flow.excalidraw"] {
            #expect(try base.propose(map(name, try draft()), now: now).proposal.target == "payments/maps/flow")
        }
        #expect(base.proposals().map(\.id) == [proposal.id, proposal.id + "-2", proposal.id + "-3"])
        // A new area is allowed (K23): created on Accept, not now.
        let fresh = try base.propose(map("support/tickets", try draft()), now: now)
        #expect(fresh.checks[1].message == "A new map in a new area support, created on Accept.")
        #expect(!fm.fileExists(atPath: base.areasFolder.appending(path: "support").path))
        // The CLI says the person accepts it in the app; planAccept refuses it.
        #expect(throws: KnowledgeBase.Failure.self) { try base.planAccept(proposal) }
        #expect(KnowledgeInbox.mapMessage == "Open Knowledge → Inbox to accept a map.")
    }

    @Test func aBrokenDraftASecretOrABadPathIsRefusedAndNothingIsWritten() async throws {
        let base = try await makeBase()
        let good = try draft()
        var secret = try #require(String(data: good, encoding: .utf8))
        secret = secret.replacingOccurrences(of: "\"text\": \"billing\"", with: "\"text\": \"ghp_abcdefghijklmnopqrstuvwxyz0123456789\"")
        let refused: [(KnowledgeInbox.Draft, String)] = [
            (map("payments/flow", Data("{not json".utf8)), "not valid JSON"),
            (map("payments/flow", Data(#"{"type": "excalidraw"}"#.utf8)), "no elements array"),
            (map("payments/flow", Data(#"{"type": "excalidraw", "elements": []}"#.utf8)), "no elements"),
            (map("payments/flow", Data(secret.utf8)), "secret"),
            (map("../payments/flow", good), "never a path that leaves it"),
            (map("payments/../../flow", good), "never a path that leaves it"),
            (map("/tmp/flow", good), "never a path that leaves it"),
            (map("inbox/flow", good), "AREA/NAME"),
            (map("payments/sub/flow", good), "AREA/NAME"),
            (map("payments/.flow", good), "AREA/NAME"),
            (map("flow", good), "AREA/NAME"),
        ]
        for (draft, reason) in refused {
            #expect {
                try base.propose(draft, now: now)
            } throws: { error in
                (error as? KnowledgeBase.Failure)?.message.contains(reason) == true
            }
        }
        #expect(try await git("status", "--porcelain", in: base.root).isEmpty)
        #expect(base.proposals().isEmpty)
    }

    @Test func labelsMatchOneNoteByTheLinkRulesOrByTitleElseStayPlain() async throws {
        let base = try await makeBase()
        try await base.newNote(area: "logistics", name: "billing", kind: nil, env: env)
        try await base.newNote(area: "logistics", name: "warehouse", kind: nil, env: env)
        _ = try base.save(note: "logistics/warehouse", text: "# Central Warehouse\n")
        let targets = base.linkTargets()
        let titles = Dictionary(try base.notes().map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        func match(_ label: String, on map: String) -> KnowledgeInbox.LabelMatch {
            KnowledgeInbox.match(label: label, map: map, targets: targets, titles: titles)
        }
        // Unique by name, by path suffix, by title (any case).
        #expect(match("orders-api", on: "support/maps/x") == .note("payments/orders-api"))
        #expect(match("logistics/billing", on: "support/maps/x") == .note("logistics/billing"))
        #expect(match("central warehouse", on: "support/maps/x") == .note("logistics/warehouse"))
        // Two notes named billing: the map's own area wins (P1), another area's map can't tell.
        #expect(match("billing", on: "payments/maps/x") == .note("payments/billing"))
        #expect(match("billing", on: "support/maps/x") == .ambiguous(["logistics/billing", "payments/billing"]))
        // None, and labels that are links or maps.
        #expect(match("Kafka", on: "payments/maps/x") == .none)
        #expect(match("[[billing]]", on: "payments/maps/x") == .none)
        #expect(match("", on: "payments/maps/x") == .none)

        // The plan of a draft on support's map: orders-api linked, billing ambiguous, listed.
        let proposal = try base.propose(map("support/flow", try draft()), now: now).proposal
        let plan = try base.planMap(proposal)
        #expect(plan.links == [.init(element: "blk-orders", label: "orders-api", note: "payments/orders-api", link: "[[orders-api]]")])
        #expect(plan.unlinked == [.init(element: "blk-billing", label: "billing", candidates: ["logistics/billing", "payments/billing"])])
        #expect(plan.newArea && plan.original == nil && plan.map == "support/maps/flow")
        #expect(plan.diff == "areas/support/maps/flow.excalidraw (new, in a new area)\n+ block orders-api\n+ block billing\n+ arrow orders-api -events-> billing")
    }

    @Test func acceptOfANewMapInANewAreaIsOneCommitOfTheMapOnly() async throws {
        let base = try await makeBase()
        let proposal = try base.propose(map("support/flow", try draft()), now: now).proposal
        _ = try base.saveCheck([], of: proposal, model: "test", now: now)
        let plan = try base.planMap(proposal)
        let commits = try await git("rev-list", "--count", "HEAD", in: base.root)
        // A map that isn't a scene, or one with a secret, is refused before anything is written.
        await #expect(throws: KnowledgeBase.Failure.self) { try await base.acceptMap(plan, bytes: Data("{".utf8), env: env) }
        let bytes = try linked(plan.draft, plan.linkMap)
        let accepted = try await base.acceptMap(plan, bytes: bytes, env: env, now: now)
        #expect(accepted.paths == ["areas/support/maps/flow.excalidraw"] && accepted.backup == nil)
        #expect(try Data(contentsOf: base.mapFile("support/maps/flow")) == bytes)
        #expect(Int(try await git("rev-list", "--count", "HEAD", in: base.root)) == Int(commits)! + 1)
        #expect(try await git("show", "--name-only", "--format=%s", "HEAD", in: base.root)
            == "Add map support/maps/flow (accept proposal \(proposal.id))\n\nareas/support/maps/flow.excalidraw")
        #expect(try await git("status", "--porcelain", in: base.root).isEmpty)
        #expect(base.proposals().isEmpty && base.check(of: proposal) == nil)
        // The saved map links its blocks to the notes, and its arrow is a relation.
        let graph = try base.mapGraph(area: "support")
        #expect(graph.maps.first?.blocks.map(\.note) == ["payments/orders-api", "payments/billing"])
        #expect(graph.edges.map { "\($0.from) \($0.kind ?? "") \($0.to)" } == ["payments/orders-api events payments/billing"])
    }

    @Test func acceptReplacesAMapOnlyWhileItIsAsPlannedAndBacksItUp() async throws {
        let base = try await makeBase()
        _ = try await base.newMap(area: "payments", name: "overview", env: env)
        let proposal = try base.propose(map("payments/overview", try draft()), now: now)
        #expect(proposal.checks[1].message == "Replaces the map payments/maps/overview on Accept.")
        let plan = try base.planMap(proposal.proposal)
        #expect(plan.original != nil && !plan.newArea)
        #expect(plan.diff.hasPrefix("areas/payments/maps/overview.excalidraw (replaces the map)\n+ block orders-api"))
        #expect(plan.links.map(\.link) == ["[[orders-api]]", "[[billing]]"] && plan.unlinked.isEmpty)
        let bytes = try linked(plan.draft, plan.linkMap)

        // The map changes on disk after the plan: nothing is written.
        let file = base.mapFile("payments/maps/overview")
        let changed = try Data(contentsOf: file) + Data(" ".utf8)
        try changed.write(to: file)
        await #expect(throws: KnowledgeBase.Failure.self) { try await base.acceptMap(plan, bytes: bytes, env: env) }
        #expect(try Data(contentsOf: file) == changed)
        #expect(base.proposals().map(\.id) == [proposal.proposal.id])

        // Planned again: replaced, backed up, one commit with the queue's pending edit first.
        _ = KnowledgeCommitQueue(base: base.root, env: env).enqueue([base.mapPath("payments/maps/overview")])
        let again = try base.planMap(proposal.proposal)
        let accepted = try await base.acceptMap(again, bytes: bytes, env: env, now: now)
        #expect(try Data(contentsOf: file) == bytes)
        let backup = try #require(accepted.backup)
        #expect(try Data(contentsOf: backup) == changed)
        #expect(backup.path.hasPrefix(home.appending(path: ".akit/local/backups/knowledge/work/").path))
        #expect(try await git("log", "-1", "--format=%s", in: base.root) == "Replace map payments/maps/overview (accept proposal \(proposal.proposal.id))")
        #expect(try await git("status", "--porcelain", in: base.root).isEmpty)
        #expect(try base.mapGraph(area: "payments").edges.map { "\($0.from) \($0.kind ?? "") \($0.to)" } == ["payments/orders-api events payments/billing"])
    }

    @Test func rejectMovesTheProposalAndItsDraftToTheTrash() async throws {
        let base = try await makeBase()
        let proposal = try base.propose(map("payments/flow", try draft()), now: now).proposal
        var moved: [String] = []
        try await base.reject(proposal, env: env) { url in
            moved.append(url.lastPathComponent)
            try FileManager.default.removeItem(at: url)
            return nil
        }
        #expect(moved == ["\(proposal.id).md", "\(proposal.id).excalidraw"])
        #expect(try await git("status", "--porcelain", in: base.root).isEmpty)
    }
}
