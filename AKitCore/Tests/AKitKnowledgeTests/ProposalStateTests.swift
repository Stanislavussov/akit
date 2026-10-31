import Foundation
import Testing
import AKitFoundation
@testable import AKitKnowledge

/// The state of a proposal for its Ask Pi card (K32, review round 2): ids are reused once a
/// proposal has left `inbox/`, so the state follows the proposal made at its `created` time.
final class ProposalStateTests {
    deinit { try? FileManager.default.removeItem(at: home) }

    let home: URL
    init() throws { home = try FakeHome.make("akit-kb-proposal-state") }
    var env: HarnessEnvironment { FakeHome.env(home) }

    func base() async throws -> KnowledgeBase {
        let base = try await TemplateBase.base(home: home)
        try await base.newNote(area: "payments", name: "billing", kind: nil, env: env)
        return base
    }

    func propose(_ base: KnowledgeBase, _ text: String, at offset: TimeInterval) throws -> KnowledgeProposal {
        try base.propose(.init(.note("payments/billing", body: "## Owners\n\(text)\n", set: []), reason: text, author: "pi"),
                         now: Date().addingTimeInterval(offset)).proposal
    }

    func trash(_ url: URL) throws -> URL? {
        let target = home.appending(path: "trash/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }

    @Test func acceptedThenTheSameIdProposedAgainAndRejected() async throws {
        let base = try await base()
        let first = try propose(base, "Team A.", at: -5)
        _ = try await base.accept(try base.planAccept(first), env: env)
        let second = try propose(base, "Team B.", at: 5)
        #expect(second.id == first.id, "the id is reused once the first left inbox/")
        #expect(await base.state(ofProposal: first.id, created: first.created, before: second.created, env: env) == .accepted)
        #expect(await base.state(ofProposal: second.id, created: second.created, env: env) == .pending)
        #expect(await base.state(ofProposal: first.id, created: first.created, env: env) == .accepted, "the inbox file is the later one")
        _ = try await base.reject(second, env: env, trash: trash)
        #expect(await base.state(ofProposal: second.id, created: second.created, env: env) == .closed)
        #expect(await base.state(ofProposal: first.id, created: first.created, before: second.created, env: env) == .accepted)
    }

    @Test func rejectedThenTheSameIdProposedAgainAndAccepted() async throws {
        let base = try await base()
        let first = try propose(base, "Team A.", at: -10)
        _ = try await base.reject(first, env: env, trash: trash)
        let second = try propose(base, "Team B.", at: -5)
        #expect(second.id == first.id)
        _ = try await base.accept(try base.planAccept(second), env: env)
        #expect(await base.state(ofProposal: first.id, created: first.created, before: second.created, env: env) == .closed,
                "the accept came after the second was made: it is the second's")
        #expect(await base.state(ofProposal: second.id, created: second.created, env: env) == .accepted)
    }
}
