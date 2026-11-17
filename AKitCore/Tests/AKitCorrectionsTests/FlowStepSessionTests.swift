import Foundation
import Testing
import AKitInsights
import AKitLab
import AKitSessions
@testable import AKitCorrections

private let repoRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

/// Runs → a step card's Open in Lab and Corrections, on the fixture runs (D27, F17).
struct FlowStepSessionTests {
    /// `fixtures/flow-runs/sample`: each handoff's `session_file` opens as a `flow` session that
    /// Lab can review and Corrections can count.
    @Test func aSampleStepOpensInLabAndCorrections() throws {
        let file = repoRoot.appending(path: "fixtures/flow-runs/sample/sessions/2026-11-17T12-00-00-000Z_sess-implement-1.jsonl")
        let session = try #require(SessionScanner.flowSession(file))
        #expect(session.origin == SessionSummary.flowOrigin && session.harness == .pi)
        #expect(LabRuns.reviewable.contains(session.harness), "New Lab Run → Review a Session takes it")
        let corrections = try CorrectedSession.of(session)
        #expect(corrections.key == "flow:2026-11-17T12-00-00-000Z_sess-implement-1" && corrections.corrections == 0)
    }

    /// A7 (flows.md Q2): `fixtures/flow-runs/a7` is kept by `make test-flows-e2e` with
    /// AKIT_FLOW_E2E_KEEP: the parent Pi session that ran `/flow` and its two children, on real Pi
    /// 1.0.4. The fake server gives the parent's own prompt 777 + 7 tokens and each child call
    /// 1200 + 30. Answer: the parent session file holds only its own tokens, never the children's,
    /// so step sessions add to a total without double counting.
    @Test func childTokensAreNotInTheParentSessionFile() throws {
        let folder = repoRoot.appending(path: "fixtures/flow-runs/a7")
        let parent = try SessionReader.transcript(of: try #require(SessionScanner.flowSession(folder.appending(path: "parent.jsonl"))))
        #expect(parent.usage.tokens.input == 777 && parent.usage.tokens.output == 7 && parent.usage.requests == 1)
        #expect(parent.usage.subagentModels.isEmpty)
        let children = try FileManager.default.contentsOfDirectory(at: folder.appending(path: "children"), includingPropertiesForKeys: nil)
        #expect(children.count == 2)
        for child in children {
            let usage = try SessionReader.transcript(of: try #require(SessionScanner.flowSession(child))).usage
            #expect(usage.requests > 0 && usage.tokens.input == 1200 * usage.requests, "\(child.lastPathComponent)")
        }
    }
}
