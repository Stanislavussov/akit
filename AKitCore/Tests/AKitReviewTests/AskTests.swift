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
    

        /// A fork copies its parent's entries with their ids: each answer's tokens count once.
        @Test func aForkChainCountsEachEntryOnce() async throws {
            let run = try await ReviewRunFixture.make()
            run.playTypicalRun()
            _ = try await ReviewPasses.run(folder: run.folder, env: run.home.env)
            let sessions = run.folder.appending(path: "sessions")
            func entry(_ id: String, _ input: Int) -> String {
                #"{"type":"message","id":"\#(id)","message":{"role":"assistant","usage":{"input":\#(input),"output":0,"cacheRead":0,"cacheWrite":0,"cost":{"total":0.5}}}}"#
            }
            func header(_ id: String, _ time: String) -> String { #"{"type":"session","id":"\#(id)","timestamp":"\#(time)"}"# }
            let base = [entry("v1", 1000)]
            try (["{\"type\":\"session\",\"id\":\"verifier-old\",\"timestamp\":\"2026-10-25T10:00:00Z\"}"] + base).joined(separator: "\n")
                .write(to: sessions.appending(path: "2026-10-25T10-00-00-000Z_verifier-old.jsonl"), atomically: true, encoding: .utf8)
            try ([header("ask-1", "2026-10-25T11:00:00Z")] + base + [entry("q1", 100)]).joined(separator: "\n")
                .write(to: sessions.appending(path: "2026-10-25T11-00-00-000Z_ask-1.jsonl"), atomically: true, encoding: .utf8)
            try ([header("ask-2", "2026-10-25T12:00:00Z")] + base + [entry("q1", 100), entry("q2", 10)]).joined(separator: "\n")
                .write(to: sessions.appending(path: "2026-10-25T12-00-00-000Z_ask-2.jsonl"), atomically: true, encoding: .utf8)
            try ReviewDiscuss.logUsage(run.folder, run: try ReviewWorkflow.load(run.folder), env: run.home.env, only: "ask-2")
            let log = try #require(ReviewJSON.read(ReviewPassLog.self, from: run.folder.appending(path: "passes.json")))
            let asked = log.passes.filter { $0.name == "discuss" }
            #expect(asked.map(\.session) == ["ask-2"] && asked.first?.usage.input == 10 && asked.first?.usage.cost == 0.5,
                    "only q2: the verifier's v1 and ask-1's q1 are copies")
        }

        @Test func onlyThisAsksSubmissionsCount() {
            let folder = URL(filePath: "/tmp/run/passes")
            #expect(ReviewAsk.submitted(folder.appending(path: "discuss-1761400000500.json"), since: 1_761_400_000_000))
            #expect(!ReviewAsk.submitted(folder.appending(path: "discuss-1761399999999.json"), since: 1_761_400_000_000), "an open discussion's")
            #expect(!ReviewAsk.submitted(folder.appending(path: "discuss.json"), since: 0))
        }
    }
}
