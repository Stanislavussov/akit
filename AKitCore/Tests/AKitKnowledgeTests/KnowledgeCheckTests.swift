import Foundation
import Testing
import AKitBrain
import AKitFoundation
@testable import AKitKnowledge

/// The check model's prompt, candidates and parser (5.2), on the sample base in a temporary
/// fake home; no model is called here (AKitKnowledge makes no calls, C1).
final class KnowledgeCheckTests {
    deinit { try? FileManager.default.removeItem(at: home) }

    let home: URL
    let fm = FileManager.default

    init() throws {
        home = URL(filePath: FileWalk.realPath(fm.temporaryDirectory) ?? fm.temporaryDirectory.path)
            .appending(path: "akit-kb-check-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var env: HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home, variables: ["HOME": home.path, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"],
                           executableSearchPaths: [URL(filePath: "/usr/bin")])
    }

    func git(_ args: String..., in folder: URL) async throws -> String {
        let result = try #require(await ProcessRunner.run(URL(filePath: "/usr/bin/git"), arguments: args, directory: folder,
                                                           environment: env.variables, timeout: 20))
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test func theParserTakesValidMarksIgnoresExtraFieldsAndRefusesOtherText() throws {
        let marks = try KnowledgeCheck.marks(fromAnswer: """
            Here you go: {"marks": [
              {"kind": "duplicate", "note": "payments/billing", "message": "Invoices says this.", "confidence": 0.9},
              {"kind": "contradiction", "edge": "orders-api -events-> billing", "message": "The map says events go the other way."},
              {"kind": "broken-link", "link": "[[refunds]]", "message": "No note refunds."},
              {"kind": "accept", "message": "Looks good, accept it."},
              {"kind": "duplicate"}
            ], "decision": "accept"}
            """)
        #expect(marks == [
            .init(kind: .duplicate, note: "payments/billing", message: "Invoices says this."),
            .init(kind: .contradiction, edge: "orders-api -events-> billing", message: "The map says events go the other way."),
            .init(kind: .brokenLink, link: "[[refunds]]", message: "No note refunds."),
        ])
        #expect(try KnowledgeCheck.marks(fromAnswer: #"{"marks": []}"#).isEmpty)
        for invalid in ["", "No problems.", #"{"ok": true}"#, #"{"marks": "none"}"#, "{broken"] {
            #expect(throws: KnowledgeCheck.Failure.self, "\(invalid)") { try KnowledgeCheck.marks(fromAnswer: invalid) }
        }
        // A secret in a message is masked; a long one is cut.
        let masked = try KnowledgeCheck.marks(fromAnswer: #"{"marks": [{"kind": "duplicate", "message": "token ghp_abcdefghijklmnopqrstuvwxyz0123456789 \#(String(repeating: "x", count: 400))"}]}"#)
        #expect(masked[0].message.contains(SecretFilter.mask) && masked[0].message.count == 300)
    }

    @Test func theCandidatesAreTheSearchSectionsAndOneHopArrowsUnder1500Tokens() async throws {
        let base = try await TemplateBase.seeded(world: "work", home: home)
        let proposal = try base.proposal("2026-10-24-payments-billing")
        let candidates = base.checkCandidates(for: proposal)
        #expect(!candidates.sections.isEmpty && candidates.sections.count <= KnowledgeCheck.sectionCount)
        #expect(candidates.sections.contains { $0.note == "payments/billing" })
        #expect(candidates.edges == ["payments/orders-api -events-> payments/billing (payments/maps/overview)"])
        #expect(candidates.tokens <= KnowledgeCheck.candidateTokens)
        // A long proposal with many matching words still gets at most 1500 tokens of candidates.
        let words = "billing invoice order orders shipping warehouse stock refund events retry courier checkout team"
        let (big, _) = try base.propose(.init(.note("payments/billing", body: "## Notes\n" + String(repeating: words + "\n", count: 50), set: [])))
        let many = base.checkCandidates(for: big)
        #expect(many.tokens <= KnowledgeCheck.candidateTokens)
        // The input carries the proposal and the candidates as JSON; the schema names the three marks.
        let input = KnowledgeCheck.input(proposal, candidates: candidates)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any])
        #expect(Set(object.keys) == ["proposal", "candidates"])
        #expect((object["proposal"] as? [String: Any])?["text"] as? String == proposal.body)
        #expect(KnowledgeCheck.schema.contains(#""enum":["duplicate","contradiction","broken-link"]"#))
        #expect(KnowledgeCheck.system.contains("never accept or reject"))
        // An arrow's candidates are its two ends' arrows.
        let arrow = try base.proposal("2026-10-24-arrow-billing-warehouse")
        #expect(base.checkCandidates(for: arrow).edges.contains("logistics/warehouse -ships to-> logistics/shipping (logistics/maps/routes)"))
    }

    @Test func aModelAnswerOnlyMarksAndNeverAccepts() async throws {
        let base = try await TemplateBase.seeded(world: "work", home: home)
        let proposal = try base.proposal("2026-10-24-arrow-billing-warehouse")
        let before = try await git("status", "--porcelain", in: base.root)
        let head = try await git("rev-parse", "HEAD", in: base.root)
        let marks = try KnowledgeCheck.marks(fromAnswer: #"{"marks": [{"kind": "duplicate", "note": "payments/billing", "message": "Seen."}], "accept": true}"#)
        let stored = try base.saveCheck(marks, of: proposal, model: "Pi · test")
        // Only the hidden check file is new: the proposal stays open, nothing is committed.
        #expect(try await git("status", "--porcelain", in: base.root) == (before + "\n?? inbox/.\(proposal.id).check.json")
            .split(separator: "\n").sorted().joined(separator: "\n"))
        #expect(try await git("rev-parse", "HEAD", in: base.root) == head)
        #expect(try base.proposal(proposal.id) == proposal)
        #expect(base.check(of: proposal) == stored)
        let entry = try #require(base.proposals().first { $0.id == proposal.id })
        #expect(entry.modelCheck?.marks == marks && entry.modelCheck?.stale == false)
        // The check file is no proposal: not listed, not counted.
        #expect(base.proposals().count == KnowledgeSeed.proposals.count && WatchFilter.inboxCount(base.root) == KnowledgeSeed.proposals.count)
        #expect(WatchFilter.classify(KnowledgeCheck.path(of: proposal.id)) == .inbox(KnowledgeCheck.path(of: proposal.id)))
        // A changed proposal shows its marks as stale.
        try Data((proposal.text + "More.\n").utf8).write(to: base.root.appending(path: proposal.path))
        #expect(base.proposals().first { $0.id == proposal.id }?.modelCheck?.stale == true)
    }

    @Test func acceptAndRejectTakeTheMarksWithThem() async throws {
        let base = try await TemplateBase.seeded(world: "work", home: home)
        let note = try base.proposal("2026-10-24-payments-billing")
        #expect(base.check(of: note)?.marks == KnowledgeSeed.checkMarks[note.id])
        try await base.accept(try base.planAccept(note), env: env)
        #expect(!fm.fileExists(atPath: base.root.appending(path: KnowledgeCheck.path(of: note.id)).path))
        let arrow = try base.proposal("2026-10-24-arrow-billing-warehouse")
        try base.saveCheck([], of: arrow, model: "Pi · test")
        try await base.reject(arrow, env: env) { url in
            let place = home.appending(path: "Trash-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: place.appending(path: url.lastPathComponent))
            return place
        }
        #expect(!fm.fileExists(atPath: base.root.appending(path: KnowledgeCheck.path(of: arrow.id)).path))
        // Only the seed's map proposal and its draft are left.
        let map = "2026-10-24-payments-maps-order-flow"
        #expect(try await git("status", "--porcelain", in: base.root) == "?? \(KnowledgeInbox.draftPath(of: map))\n?? \(KnowledgeInbox.path(of: map))")
    }
}
