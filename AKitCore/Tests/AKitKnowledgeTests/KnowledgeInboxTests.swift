import Foundation
import Testing
import AKitBrain
import AKitFoundation
@testable import AKitKnowledge

/// Proposals (5.1, K14, P3) in a temporary fake home: propose writes only `inbox/`, the checks
/// without a model block, Accept is one commit with a backup, Reject goes to a fake Trash, an
/// arrow is never written.
final class KnowledgeInboxTests {
    deinit { try? FileManager.default.removeItem(at: home) }

    let home: URL
    let fm = FileManager.default
    /// 2026-10-25 12:00 UTC.
    let now = Date(timeIntervalSince1970: 1_792_929_600)

    init() throws {
        home = try FakeHome.make("akit-kb-inbox")
    }

    var env: HarnessEnvironment { FakeHome.env(home) }

    func git(_ args: String..., in folder: URL) async throws -> String {
        try await FakeHome.git(args, in: folder, env: env)
    }

    func fakeTrash(_ url: URL) throws -> URL? {
        let trash = home.appending(path: "Trash-\(UUID().uuidString)")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let place = trash.appending(path: url.lastPathComponent)
        try fm.moveItem(at: url, to: place)
        return place
    }

    /// A base with payments/billing (a ## Invoices section) and payments/orders-api.
    func makeBase() async throws -> KnowledgeBase {
        let base = try await TemplateBase.base(home: home)
        try await base.newNote(area: "payments", name: "billing", kind: "service", env: env)
        try base.save(note: "payments/billing", text: "---\nkind: service\n---\n# billing\n\n## Invoices\n\nOne per order.\n")
        try await base.newNote(area: "payments", name: "orders-api", kind: "service", env: env)
        try await base.commit(["areas/payments/billing.md"], message: "Edit billing", env: env)
        return base
    }

    func note(_ id: String, body: String, set: [KnowledgeProposal.Setting] = []) -> KnowledgeInbox.Draft {
        .init(.note(id, body: body, set: set), reason: "seen in the code", author: "pi")
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

    @Test func createTracksTheInboxFolder() async throws {
        let base = try await TemplateBase.base(home: home)
        #expect(try await git("ls-files", "inbox", in: base.root) == KnowledgeInbox.keepFile)
        #expect(base.proposals().isEmpty)
    }

    @Test func proposeWritesOnlyItsInboxFile() async throws {
        let base = try await makeBase()
        let before = try snapshot(base)
        let (proposal, checks) = try base.propose(note("payments/billing", body: "## Retries\nThree tries with backoff.\n"), now: now)
        #expect(proposal.id == "2026-10-25-payments-billing")
        #expect(proposal.path == "inbox/2026-10-25-payments-billing.md")
        #expect(checks.map(\.name) == ["secret", "target", "links"] && checks.allSatisfy { $0.status == .passed })
        #expect(try snapshot(base) == before)
        #expect(try await git("status", "--porcelain", in: base.root) == "?? inbox/2026-10-25-payments-billing.md")
        // The inbox is never indexed.
        #expect(try KnowledgeIndex(base: base).search("three tries").results.isEmpty)
        // A second proposal for the same note gets its own file.
        #expect(try base.propose(note("payments/billing", body: "## Owners\nTeam A.\n"), now: now).proposal.id == "2026-10-25-payments-billing-2")
        // The file reads back as it was written.
        let entry = try #require(base.proposals().first)
        #expect(entry.proposal == proposal && entry.reason == "seen in the code" && entry.author == "pi")
        #expect(try base.proposal("inbox/\(proposal.id).md") == proposal)
    }

    @Test func theChecksWithoutAModelBlockAtOnce() async throws {
        let base = try await makeBase()
        let refused: [(KnowledgeInbox.Draft, String)] = [
            (note("payments/billing", body: "## Keys\nGITHUB_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123456789\n"), "secret"),
            (note("payments/billing", body: "## Keys\n-----BEGIN RSA PRIVATE KEY-----\n"), "secret"),
            (.init(.note("payments/billing", body: "## A\nx\n", set: [.init(key: "token", value: "sk-ant-abcdefghijklmnopqrstuvwxyz")])), "secret"),
            (note("payments/billing", body: "## Links\nSee [[nowhere]].\n"), "Broken link"),
            (note("../kb", body: "x"), "never a path that leaves it"),
            (note("payments/../../x", body: "x"), "never a path that leaves it"),
            (note("/etc/hosts", body: "x"), "never a path that leaves it"),
            (note("inbox/payments/x", body: "x"), "under areas/"),
            (note("payments/.hidden", body: "x"), "not hidden"),
            (note("payments/maps/x", body: "x"), "maps/ folder"),
            (note("helpdesk", body: "x"), "Name the area"),
            (note("payments/billing", body: ""), "Nothing to propose"),
            (note("payments/billing", body: "# billing\n\n## New\nx\n"), "## Heading blocks"),
            (note("payments/billing", body: "Loose text.\n## New\nx\n"), "## Heading blocks"),
            (.init(.arrow("orders-api -events-> nowhere", map: nil)), "is no note"),
            (.init(.arrow("orders-api events billing", map: nil)), "not an arrow"),
            (.init(.arrow("orders-api -events-> billing", map: "nope")), "no map"),
        ]
        for (draft, reason) in refused {
            #expect(throws: KnowledgeBase.Failure.self) { try base.propose(draft, now: now) }
            do { _ = try base.propose(draft, now: now) } catch { #expect(error.message.contains(reason), "\(draft): \(error.message)") }
        }
        #expect(base.proposals().isEmpty)
        #expect(try await git("status", "--porcelain", in: base.root).isEmpty)
    }

    @Test func aNewNoteMayLinkItselfAndOpensANewArea() async throws {
        let base = try await makeBase()
        let (proposal, checks) = try base.propose(note("support/helpdesk", body: "Tickets by email; this is [[helpdesk]], see [[billing]].\n",
                                                       set: [.init(key: "kind", value: "service")]), now: now)
        #expect(checks.first { $0.name == "target" }?.message?.contains("new area support") == true)
        let plan = try base.planAccept(proposal)
        #expect(plan.newArea && plan.original == nil)
        #expect(plan.planned == "---\nkind: service\n---\n# helpdesk\n\nTickets by email; this is [[helpdesk]], see [[billing]].\n")
        #expect(!fm.fileExists(atPath: base.areasFolder.appending(path: "support").path))
        let accepted = try await base.accept(plan, env: env)
        #expect(accepted.backup == nil && accepted.paths == ["areas/support/helpdesk.md"])
        #expect(base.areas().map(\.name) == ["payments", "support"])
        #expect(try await git("status", "--porcelain", in: base.root).isEmpty)
        #expect(try await git("log", "-1", "--format=%s", in: base.root) == "Add note support/helpdesk (accept proposal \(proposal.id))")
    }

    @Test func acceptIsOneCommitWithABackupAndRemovesTheProposal() async throws {
        let base = try await makeBase()
        // A pending in-app edit is committed first, on its own.
        try base.save(note: "payments/orders-api", text: "---\nkind: service\n---\n# orders-api\n\nEdited in the app.\n")
        #expect(KnowledgeCommitQueue(base: base.root, env: env).enqueue(["areas/payments/orders-api.md"]) == .queued(refused: []))
        let original = try Data(contentsOf: base.noteFile("payments/billing"))
        let (proposal, _) = try base.propose(note("payments/billing", body: "## Invoices\nTwo per order.\n\n## Retries\nThree tries.\n",
                                                  set: [.init(key: "owner", value: "checkout-team")]), now: now)
        let plan = try base.planAccept(proposal)
        #expect(plan.diff.hasPrefix("areas/payments/billing.md\n"))
        #expect(plan.diff.contains("- One per order.") && plan.diff.contains("+ Two per order.") && plan.diff.contains("+ owner: checkout-team"))
        let commits = Int(try await git("rev-list", "--count", "HEAD", in: base.root))!
        let accepted = try await base.accept(plan, env: env, now: now)

        #expect(try String(contentsOf: base.noteFile("payments/billing"), encoding: .utf8)
            == "---\nkind: service\nowner: checkout-team\n---\n# billing\n\n## Invoices\n\nTwo per order.\n\n## Retries\nThree tries.\n")
        #expect(!fm.fileExists(atPath: base.root.appending(path: proposal.path).path))
        #expect(base.proposals().isEmpty)
        #expect(try await git("status", "--porcelain", in: base.root).isEmpty)
        #expect(Int(try await git("rev-list", "--count", "HEAD", in: base.root))! == commits + 2)
        #expect(try await git("log", "-2", "--format=%s", in: base.root)
            == "Edit payments/billing (accept proposal \(proposal.id))\nEdit payments/orders-api")
        #expect(try await git("show", "--name-only", "--format=", "HEAD", in: base.root) == "areas/payments/billing.md")
        let backup = try #require(accepted.backup)
        #expect(backup.path.hasPrefix(home.appending(path: ".akit/local/backups/knowledge/work/").path))
        #expect(backup.path.hasSuffix("/areas/payments/billing.md"))
        #expect(try Data(contentsOf: backup) == original)
        #expect(try fm.attributesOfItem(atPath: backup.path)[.posixPermissions] as? Int == 0o600)
    }

    @Test func acceptRefusesANoteChangedSinceThePlan() async throws {
        let base = try await makeBase()
        let (proposal, _) = try base.propose(note("payments/billing", body: "## Retries\nThree.\n"), now: now)
        let plan = try base.planAccept(proposal)
        try base.save(note: "payments/billing", text: "# billing\n\nChanged.\n")
        await #expect(throws: KnowledgeBase.Failure.self) { try await base.accept(plan, env: env) }
        #expect(fm.fileExists(atPath: base.root.appending(path: proposal.path).path))
        #expect(try String(contentsOf: base.noteFile("payments/billing"), encoding: .utf8) == "# billing\n\nChanged.\n")
    }

    @Test func rejectMovesTheProposalToTheTrashWithoutACommit() async throws {
        let base = try await makeBase()
        let (proposal, _) = try base.propose(note("payments/billing", body: "## Retries\nThree.\n"), now: now)
        let commits = try await git("rev-list", "--count", "HEAD", in: base.root)
        let place = try #require(try await base.reject(proposal, env: env, trash: fakeTrash))
        #expect(fm.fileExists(atPath: place.path))
        #expect(!fm.fileExists(atPath: base.root.appending(path: proposal.path).path))
        #expect(try await git("rev-list", "--count", "HEAD", in: base.root) == commits)
        #expect(try await git("status", "--porcelain", in: base.root).isEmpty)
    }

    @Test func anArrowProposalIsNeverWritten() async throws {
        let base = try await makeBase()
        _ = try await base.newMap(area: "payments", name: "overview", env: env)
        let before = try snapshot(base)
        let (proposal, checks) = try base.propose(.init(.arrow("orders-api -order created-> billing", map: "overview")), now: now)
        #expect(proposal.id == "2026-10-25-arrow-orders-api-billing" && proposal.target == "payments/maps/overview")
        #expect(proposal.arrow == .init(from: "payments/orders-api", kind: "order created", to: "payments/billing", map: "payments/maps/overview"))
        #expect(checks.map(\.name) == ["secret", "arrow"])
        #expect(throws: KnowledgeBase.Failure.self) { try base.planAccept(proposal) }
        #expect(KnowledgeInbox.arrowMessage(proposal)
            == "Add the arrow payments/orders-api -order created-> payments/billing on map payments/maps/overview in the app (Knowledge → Inbox).")
        #expect(try snapshot(base) == before)
        #expect(try base.proposal(proposal.id) == proposal)
        // A bare arrow on no named map.
        let bare = try base.propose(.init(.arrow("orders-api -> billing", map: nil)), now: now).proposal
        #expect(bare.arrow?.kind == nil && bare.target == nil)
        #expect(KnowledgeInbox.arrowMessage(bare).contains("-> payments/billing on a map of payments"))
    }

    /// 5.3: Accept of an arrow in the app: the plan finds each end's block (or a new block's link
    /// and label), the proposal closes only once the map on disk has the arrow, and nothing is committed.
    @Test func anArrowProposalClosesOnlyOnceTheMapHasTheArrow() async throws {
        let base = try await makeBase()
        _ = try await base.newMap(area: "payments", name: "overview", env: env)
        let orders = NewMap.Box(id: "blk-o", x: 0, y: 0), billing = NewMap.Box(id: "blk-b", x: 420, y: 0)
        try Data(NewMap.scene(elements: NewMap.block(orders, label: "orders-api", link: "[[orders-api]]")).utf8)
            .write(to: base.mapFile("payments/maps/overview"))
        let proposal = try base.propose(.init(.arrow("orders-api -order created-> billing", map: "overview")), now: now).proposal
        let bare = try base.propose(.init(.arrow("billing -> orders-api", map: nil)), now: now).proposal
        #expect(base.arrowMaps(for: proposal) == ["payments/maps/overview"])
        #expect(base.arrowMaps(for: bare) == ["payments/maps/overview"])
        let plan = try base.planArrow(proposal, on: "payments/maps/overview")
        #expect(plan.from == .init(note: "payments/orders-api", element: "blk-o", link: "[[orders-api]]", label: "orders-api"))
        #expect(plan.to == .init(note: "payments/billing", element: nil, link: "[[billing]]", label: "billing"))
        #expect(plan.kind == "order created" && !plan.exists)
        #expect(plan.text == "payments/orders-api -order created-> payments/billing")
        #expect(throws: KnowledgeBase.Failure.self) { try base.planArrow(proposal, on: "payments/maps/none") }
        let noteProposal = try base.propose(note("payments/billing", body: "## Retries\nThree.\n"), now: now).proposal
        #expect(throws: KnowledgeBase.Failure.self) { try base.planArrow(noteProposal, on: "payments/maps/overview") }
        _ = try base.saveCheck([], of: proposal, model: "test")
        let commits = try await git("rev-list", "--count", "HEAD", in: base.root)

        // Not drawn yet: refused, the proposal stays.
        await #expect(throws: KnowledgeBase.Failure.self) { try await base.closeArrow(proposal, on: "payments/maps/overview", env: env) }
        #expect(fm.fileExists(atPath: base.root.appending(path: proposal.path).path))
        // Drawn (an arrow with another label doesn't count), then closed.
        func draw(_ label: String) throws {
            let elements = NewMap.block(orders, label: "orders-api", link: "[[orders-api]]", arrows: ["arr"])
                + NewMap.block(billing, label: "billing", link: "[[billing]]", arrows: ["arr"])
                + NewMap.arrow("arr", from: orders, to: billing, label: label, link: nil)
            try Data(NewMap.scene(elements: elements).utf8).write(to: base.mapFile("payments/maps/overview"))
        }
        try draw("events")
        await #expect(throws: KnowledgeBase.Failure.self) { try await base.closeArrow(proposal, on: "payments/maps/overview", env: env) }
        try draw("order created")
        #expect(try base.planArrow(proposal, on: "payments/maps/overview").exists)
        try await base.closeArrow(proposal, on: "payments/maps/overview", env: env)
        #expect(!fm.fileExists(atPath: base.root.appending(path: proposal.path).path))
        #expect(!fm.fileExists(atPath: base.root.appending(path: KnowledgeCheck.path(of: proposal.id)).path))
        #expect(try await git("rev-list", "--count", "HEAD", in: base.root) == commits)
        #expect(Set(try await git("status", "--porcelain", "--", "inbox", in: base.root).split(separator: "\n").map(String.init))
            == ["?? inbox/\(bare.id).md", "?? inbox/\(noteProposal.id).md"])
        await #expect(throws: KnowledgeBase.Failure.self) { try await base.closeArrow(noteProposal, on: "payments/maps/overview", env: env) }
    }

    @Test func theListedChecksAreRunAgainstTheBaseAsItIsNow() async throws {
        let base = try await makeBase()
        try await base.newNote(area: "payments", name: "refunds", kind: nil, env: env)
        _ = try base.propose(note("payments/billing", body: "## Refunds\nSee [[refunds]].\n"), now: now)
        try await base.moveToTrash(note: "payments/refunds", env: env, trash: fakeTrash)
        try Data("no frontmatter\n".utf8).write(to: base.root.appending(path: "inbox/2026-10-25-broken.md"))
        let entries = base.proposals()
        #expect(entries.map(\.id) == ["2026-10-25-broken", "2026-10-25-payments-billing"])
        #expect(entries[0].kind == nil && entries[0].checks.map(\.status) == [.failed])
        #expect(entries[1].checks.first { $0.name == "links" }?.status == .failed)
        #expect(throws: KnowledgeBase.Failure.self) { try base.planAccept(try #require(entries[1].proposal)) }
    }

    @Test func aProposalFileRoundTrips() throws {
        let proposal = KnowledgeProposal(id: "2026-10-25-x", kind: .note, target: "payments/x", reason: "a \"quoted\": reason\nwith a line",
                                         created: "2026-10-25T12:00:00Z", author: nil, set: [.init(key: "files", value: "[a.ts, b.ts]")],
                                         body: "## A\n---\nnot frontmatter\n")
        #expect(KnowledgeProposal.parse(proposal.text) == proposal)
        let arrow = KnowledgeProposal(id: "a", kind: .arrow, target: nil, reason: nil, created: "now", author: "claude",
                                      arrow: .init(from: "a/b", kind: nil, to: "c/d", map: nil))
        #expect(KnowledgeProposal.parse(arrow.text) == arrow)
        #expect(KnowledgeProposal.parse("---\nid: x\nkind: drawing\ncreated: now\n---\n") == nil)
        let map = KnowledgeProposal(id: "m", kind: .map, target: "payments/maps/flow", reason: nil, created: "now", author: "pi",
                                    body: "Blocks: a, b\nArrows: a -> b\n")
        #expect(KnowledgeProposal.parse(map.text) == map)
        #expect(KnowledgeInbox.parseArrow("orders-api -ships to-> billing")! == ("orders-api", "ships to", "billing"))
        #expect(KnowledgeInbox.parseArrow("orders-api -> billing")! == ("orders-api", nil, "billing"))
        #expect(KnowledgeInbox.parseArrow("orders-api billing") == nil)
    }
}
