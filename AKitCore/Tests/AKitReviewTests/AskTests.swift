@testable import AKitReview
import Foundation
import Testing

extension ReviewProcessTests {
    /// Ask… and Add Note… (2026-10-25): a one-shot Pi forks the conversation's latest session
    /// (at first the verifier's); a note's akit_submit_findings becomes a new version of the findings.
    struct AskTests {
        @Test func questionsAndNotesKeepAThreadAndANoteChangesTheFindings() async throws {
            let run = try await ReviewRunFixture.make()
            run.playTypicalRun()
            _ = try await ReviewPasses.run(folder: run.folder, env: run.home.env)
            let verifier = try #require(ReviewJSON.read(ReviewPassLog.self, from: run.folder.appending(path: "passes.json"))?.verifierSessionFile)

            let question = try await ReviewAsk.ask(run.folder, finding: "f1", kind: .question, text: "  Is line 3 reached in production? ",
                                                   env: run.home.env)
            #expect(question.id == "a1" && question.finding == "f1" && question.text == "Is line 3 reached in production?")
            #expect(question.answer == "Intent: log less." && question.error == nil && question.version == nil)
            let first = run.args("discuss")
            #expect(first.contains("-p") && first.contains("--fork") && first[first.firstIndex(of: "--fork")! + 1] == verifier)
            let prompt = first.joined(separator: "\n")
            #expect(prompt.contains("about finding f1 (“") && prompt.contains("Is line 3 reached in production?") && prompt.contains("Change no finding"))

            run.fake("discuss", #"{"verdicts":[{"id":"f1","verdict":"rejected","note":"The developer: this logger is off in production."}]}"#)
            let note = try await ReviewAsk.ask(run.folder, finding: nil, kind: .note, text: "The debug logger is off in production.",
                                               env: run.home.env)
            #expect(note.id == "a2" && note.finding == nil && note.version == 2 && note.changes == ["f1: confirmed → rejected"])
            let second = run.args("discuss")
            #expect(second[second.firstIndex(of: "--fork")! + 1].hasSuffix("_fork-0001.jsonl"), "the thread goes on from the last answer")
            #expect(second.joined(separator: "\n").contains("about the review as a whole"))
            let findings = try #require(ReviewJSON.read(ReviewFindingsFile.self, from: run.folder.appending(path: "findings.json")))
            #expect(findings.version == 2 && findings.findings.first { $0.id == "f1" }?.verifier?.verdict == .rejected)
            #expect(ReviewAsk.entries(run.folder).map(\.id) == ["a1", "a2"])

            await #expect(throws: ReviewAsk.Failure.self) { try await ReviewAsk.ask(run.folder, finding: "f9", kind: .question, text: "x", env: run.home.env) }
            await #expect(throws: ReviewAsk.Failure.self) { try await ReviewAsk.ask(run.folder, finding: nil, kind: .note, text: "  ", env: run.home.env) }
        }
    }
}
