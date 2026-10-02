import Foundation
import Testing
@testable import AKitErrorAnalysis
import AKitLab

/// `akit analysis route|queue` against a temporary home. No model is called: there is no
/// `claude` on the search path, so a call that got past the cost prompt would fail.
extension AKitCLITests {
    func reviewedSession(_ key: String) throws {
        let note = Note(id: "n1", source: .model, description: "Read a 40 KB file whole", step: 3, quote: "cat big.json",
                        verdict: Verdict(accepted: true, reason: "", by: .model))
        try NotesStore(env: env).saveReview(SessionNotes(sessionKey: key, transcript: "/t/x.jsonl", title: nil, project: nil, requirements: [],
                                                         outcome: .no, notes: [note], deviation: Deviation(), paragraph: "", advice: [],
                                                         notesConfig: StepConfig(step: "notes", harness: "claude-code", model: "opus", promptVersion: 1),
                                                         verifierConfig: nil, doneKeys: [:], runID: nil))
    }

    @Test func routeAsksForTheCostBeforeSending() async throws {
        let key = "claude:00000000-0000-4000-8000-000000000001"
        try reviewedSession(key)
        let asked = await akit("analysis", "route", key)
        #expect(asked.code == 0 && asked.out.contains("Routing 1 notes of \(key): about"), "\(asked)")
        #expect(asked.out.hasSuffix("Run it again with --yes to send."), "\(asked)")
        #expect(NotesStore(env: env).load(key)?.routes == nil)
    }

    @Test func queueShowsAJudgesToughCalls() async throws {
        let key = "claude:00000000-0000-4000-8000-000000000002"
        try CheckStore(env: env).update(Judges.resultsID("false-premise")) {
            $0.verdicts[key] = CheckVerdict(positive: true, toughCall: true, by: .judge, version: 1)
        }
        try ValidationStore(env: env).setJudge(LabAgent(harness: .claudeCode, model: "opus", effort: "low", mode: .call), for: "false-premise")
        let queue = await akit("analysis", "queue")
        #expect(queue.out.contains("Tough call false-premise in \(key) — akit analysis tough false-premise \(key) present|absent"), "\(queue)")
        #expect(await akit("analysis", "tough", "false-premise", key, "absent").code == 0)
        #expect(!(await akit("analysis", "queue")).out.contains("Tough call"))
    }
}
