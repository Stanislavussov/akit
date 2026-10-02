import Foundation
import Testing
import AKitFoundation
import AKitModel
import AKitSessions
@testable import AKitErrorAnalysis
@testable import AKitLab

/// Blind notes and the verifier with a fake `claude` in a temporary home.
@Suite(.serialized)
struct NotesPipelineTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-notes-\(UUID().uuidString)")
        try fm.createDirectory(at: home.appending(path: "bin"), withIntermediateDirectories: true)
    }

    var env: HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home, variables: ["HOME": home.path],
                           executableSearchPaths: [home.appending(path: "bin"), URL(filePath: "/usr/bin"), URL(filePath: "/bin")])
    }

    func write(_ path: String, _ text: String, executable: Bool = false) throws {
        let url = home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if executable { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
    }

    /// user #0, Bash call #1, failing result #2, the agent's claim #3.
    func session() throws -> URL {
        try write(".claude/projects/-work/0f6c2b1e-1111-4222-8333-944445555666.jsonl", """
            {"type":"user","cwd":"/work","timestamp":"2026-10-01T10:00:00Z","message":{"role":"user","content":"Fix the failing test in Foo."}}
            {"type":"assistant","timestamp":"2026-10-01T10:00:05Z","message":{"id":"m1","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"swift test"}}]}}
            {"type":"user","timestamp":"2026-10-01T10:00:09Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"Exit code 1\\n2 tests failed"}]}}
            {"type":"assistant","timestamp":"2026-10-01T10:00:12Z","message":{"id":"m2","model":"claude-opus-5-5","content":[{"type":"text","text":"Done, all tests pass."}]}}

            """)
        return home.appending(path: ".claude/projects/-work/0f6c2b1e-1111-4222-8333-944445555666.jsonl")
    }

    /// Answers the notes call or the verifier call (its prompt mentions the steelman) from
    /// files, and counts the calls.
    func fakeClaude(notes: [String: Any], verdicts: [String: Any]) throws {
        func result(_ answer: [String: Any]) throws -> String {
            let line: [String: Any] = ["type": "result", "is_error": false, "result": "", "structured_output": answer,
                                       "usage": ["input_tokens": 100, "output_tokens": 20], "total_cost_usd": 0.01]
            return String(decoding: try JSONSerialization.data(withJSONObject: line), as: UTF8.self)
        }
        try write("notes-answer.json", try result(notes) + "\n")
        try write("verifier-answer.json", try result(verdicts) + "\n")
        try write("bin/claude", """
            #!/bin/sh
            if [ "$1 $2" = "auth status" ]; then
              echo '{"loggedIn":true,"apiProvider":"firstParty","email":"me@example.com","orgName":"Me"}'; exit 0
            fi
            cat > /dev/null
            case "$*" in
              *steelman*) echo verifier >> "$HOME/calls.txt"; cat "$HOME/verifier-answer.json" ;;
              *) echo notes >> "$HOME/calls.txt"; cat "$HOME/notes-answer.json" ;;
            esac

            """, executable: true)
    }

    let notesAnswer: [String: Any] = [
        "requirements": ["Fix the failing test in Foo."],
        "outcome": "no",
        "notes": [
            ["id": "n1", "description": "Claimed success although the tests failed.", "step": 3, "quote": "all tests pass",
             "severity": "high", "faultLayer": "agent"],
            ["id": "n2", "description": "Invented quote.", "step": 2, "quote": "everything is fine", "severity": "low",
             "faultLayer": "agent"],
            ["id": "n3", "description": "Ran the whole suite.", "step": 1, "quote": "swift test", "severity": "low",
             "faultLayer": "agent", "phase": "plan"],
        ],
        "decisiveStep": 3, "observedStep": 2,
        "paragraph": "The agent ran the tests, saw them fail and reported success.",
        "advice": [
            ["title": "Report the last test result verbatim.", "evidence": "#2 failed, #3 claims success", "detail": "No false done.",
             "noteIds": ["n1"]],
            ["title": "Rests on a rejected note.", "evidence": "#2", "detail": "x", "noteIds": ["n2"]],
        ],
    ]

    let verdicts: [String: Any] = ["verdicts": [
        ["id": "n1", "steelman": "Maybe the agent saw a later green run.", "supported": true, "reason": "#2 shows 2 failed tests."],
        ["id": "n3", "supported": false, "reason": "Running the suite was what the user asked for."],
    ]]

    func review(_ file: URL, model: String = "opus") async throws -> SessionNotes {
        let agent = LabAgent(harness: .claudeCode, model: model, effort: "high")
        let gate = try await SendGate.open(agent: agent, env: env)
        return try await NotesPipeline.review(NotesPipeline.Target(harness: .claudeCode, file: file, title: "Fix Foo"),
                                              config: NotesPipeline.Config(notes: agent), notesGate: gate, verifierGate: gate,
                                              runID: nil, workFolder: home.appending(path: "work"), env: env, out: { _ in })
    }

    func calls() -> [String] {
        ((try? String(contentsOf: home.appending(path: "calls.txt"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    @Test func notesAreVerifiedInCodeThenByTheModel() async throws {
        try fakeClaude(notes: notesAnswer, verdicts: verdicts)
        let notes = try await review(try session())

        #expect(notes.outcome == .no)
        #expect(notes.requirements == ["Fix the failing test in Foo."])
        #expect(notes.deviation == Deviation(decisiveStep: 3, observedStep: 2))
        let byID = Dictionary(uniqueKeysWithValues: notes.notes.map { ($0.id, $0) })
        #expect(byID["n1"]?.verdict?.accepted == true)
        #expect(byID["n1"]?.verdict?.steelman != nil)
        // The quote of n2 isn't in step #2: rejected in code.
        #expect(byID["n2"]?.verdict == Verdict(accepted: false, reason: "The quote isn't in step #2.", by: .code))
        #expect(byID["n3"]?.verdict?.accepted == false)
        #expect(byID["n3"]?.verdict?.by == .model)
        // Phases come from code; the model may only say understand or plan.
        #expect(byID["n1"]?.phase == .report)
        #expect(byID["n3"]?.phase == .plan)
        #expect(notes.accepted.map(\.id) == ["n1"])
        // Advice resting only on rejected notes is dropped.
        #expect(notes.advice.map(\.title) == ["Report the last test result verbatim."])
        #expect(notes.advice[0].checkedByRepeating == false)

        var saved = try #require(NotesStore(env: env).load(notes.sessionKey))
        // Dates are kept to the millisecond.
        #expect(abs(saved.createdAt.timeIntervalSince(notes.createdAt)) < 0.002)
        saved.createdAt = notes.createdAt
        #expect(saved == notes)
        #expect(calls() == ["notes", "verifier"])
        #expect(SendLog.records(env: env).map(\.purpose) == ["notes", "verifier"])
    }

    @Test func doneKeysSkipStepsThatDidntChange() async throws {
        try fakeClaude(notes: notesAnswer, verdicts: verdicts)
        let file = try session()
        let first = try await review(file)
        let again = try await review(file)
        #expect(calls() == ["notes", "verifier"])
        #expect(again.doneKeys == first.doneKeys)
        // Another model writes new notes, and they are verified again; the old review is replaced.
        let other = try await review(file, model: "sonnet")
        #expect(calls() == ["notes", "verifier", "notes", "verifier"])
        #expect(other.doneKeys["notes"] != first.doneKeys["notes"])
        // A new verifier verdict replaces the old one when only the verifier reruns.
        try fakeClaude(notes: notesAnswer, verdicts: ["verdicts": [["id": "n1", "steelman": "s", "supported": false, "reason": "Now rejected."],
                                                                   ["id": "n3", "supported": true, "reason": "Now accepted."]]])
        var stale = try #require(NotesStore(env: env).load(other.sessionKey))
        stale.doneKeys["verifier"] = "old"
        try NotesStore(env: env).save(stale)
        let reverified = try await review(file, model: "sonnet")
        #expect(reverified.notes.first { $0.id == "n1" }?.verdict?.reason == "Now rejected.")
        #expect(reverified.notes.first { $0.id == "n3" }?.verdict?.accepted == true)
        #expect(NotesStore(env: env).all().count == 1)
    }

    @Test func aSessionWithNoProblemsIsCheckedWithNoFailures() async throws {
        var clean = notesAnswer
        clean["notes"] = [[String: Any]]()
        clean["advice"] = [[String: Any]]()
        clean["outcome"] = "achieved"
        try fakeClaude(notes: clean, verdicts: ["verdicts": [[String: Any]]()])
        let notes = try await review(try session())
        #expect(notes.noFailures)
        // Nothing to verify: no verifier call.
        #expect(calls() == ["notes"])
        #expect(notes.doneKeys["verifier"] != nil)
    }

    @Test func aDigestOverTheBudgetIsNotSent() throws {
        // 130 user turns of 3000 characters: ~390K, over the default budget and never cut.
        let items = (0..<130).map { TranscriptItem(id: $0, kind: .user, text: String(repeating: "u", count: 3000), timestamp: nil) }
        #expect(throws: NotesPipeline.Failure.self) {
            _ = try NotesPipeline.notesInput(title: "t", numbers: nil, items: items, model: "opus")
        }
        // A 1M-token window has room for it.
        #expect(try NotesPipeline.notesInput(title: "t", numbers: nil, items: items, model: "opus[1m]").contains("[#129 user]"))
    }

    @Test func invalidAnswersAreErrors() async throws {
        try fakeClaude(notes: ["nonsense": true], verdicts: verdicts)
        await #expect(throws: NotesPipeline.Failure.self) { _ = try await review(try session()) }
        #expect(NotesStore(env: env).all().isEmpty)
    }

    @Test func highSeverityNeedsASteelman() async throws {
        try fakeClaude(notes: notesAnswer, verdicts: ["verdicts": [["id": "n1", "supported": true, "reason": "ok"]]])
        let notes = try await review(try session())
        let n1 = try #require(notes.notes.first { $0.id == "n1" })
        #expect(n1.verdict?.accepted == false)
        #expect(n1.verdict?.reason == "No steelman for a high-severity note.")
        // n3 got no verdict at all.
        #expect(notes.notes.first { $0.id == "n3" }?.verdict?.reason == "The verifier gave no verdict.")
    }

    @Test func verdictsAreReadFromProse() throws {
        let notes = SessionNotes(sessionKey: "k", transcript: "", title: nil, project: nil, requirements: [], outcome: .no,
                                 notes: [], deviation: Deviation(), paragraph: "", advice: [],
                                 notesConfig: StepConfig(step: "notes"), verifierConfig: nil, doneKeys: [:], runID: nil)
        #expect(notes.noFailures)
        let verdicts = try NotesPipeline.parseVerdicts(#"Sure: {"verdicts":[{"id":"n1","supported":true,"reason":"ok"}]}"#)
        #expect(verdicts["n1"]?.steelman == nil)
    }

    // MARK: As a Lab run

    func queueReview() async throws -> LabRun {
        try await LabRuns.newReview(transcript: try session(), title: "Fix Foo",
                                    agent: LabAgent(harness: .claudeCode, model: "opus", effort: "high", mode: .call),
                                    language: .english, environment: .background, akit: URL(filePath: "/usr/bin/true"), env: env)
    }

    @Test func aOneCallReviewRunWritesNotesAndTheLabFiles() async throws {
        try fakeClaude(notes: notesAnswer, verdicts: verdicts)
        let run = try await queueReview()
        let code = await LabWorker.run(id: run.id, env: env, startNext: false, handleSignals: false, execute: AnalysisRuns.execute,
                                       out: { _ in })
        let done = try #require(LabStore.load(run.id, env: env))
        #expect(code == 0 && done.status == .finished && done.result?.review == .ok)
        #expect(done.summary == "The agent ran the tests, saw them fail and reported success.\n")
        #expect(done.review?.findings.map(\.title) == ["Report the last test result verbatim."])
        let notes = try #require(NotesStore(env: env).all().first)
        #expect(notes.runID == run.id && notes.accepted.count == 1)
        // Without error analysis the worker can't do a one-call review.
        let other = try await queueReview()
        #expect(await LabWorker.run(id: other.id, env: env, startNext: false, handleSignals: false, out: { _ in }) == 1)
        #expect(LabStore.load(other.id, env: env)?.message?.contains("akit command") == true)
    }

    @Test func badAnswersBecomeTheRunsAgentError() async throws {
        try fakeClaude(notes: ["nonsense": true], verdicts: verdicts)
        let run = try await queueReview()
        let code = await LabWorker.run(id: run.id, env: env, startNext: false, handleSignals: false, execute: AnalysisRuns.execute,
                                       out: { _ in })
        let done = try #require(LabStore.load(run.id, env: env))
        #expect(code == 0 && done.result?.review == .invalid)
        #expect(done.result?.agentError == "The notes answer isn't the JSON asked for.")
    }

    @Test func reservedSessionsAreNotReviewed() async throws {
        try fakeClaude(notes: notesAnswer, verdicts: verdicts)
        let file = try session()
        try BootstrapReservations(env: env).update { $0 += [.init(sessionKey: "claude:" + file.deletingPathExtension().lastPathComponent,
                                                         transcript: file.path)] }
        let run = try await queueReview()
        let code = await LabWorker.run(id: run.id, env: env, startNext: false, handleSignals: false, execute: AnalysisRuns.execute,
                                       out: { _ in })
        #expect(code == 1)
        #expect(LabStore.load(run.id, env: env)?.message?.contains("reserved for bootstrap") == true)
        #expect(calls().isEmpty)
    }

    @Test func agentReviewsOfReservedSessionsAreRefusedToo() async throws {
        try fakeClaude(notes: notesAnswer, verdicts: verdicts)
        let file = try session()
        try BootstrapReservations(env: env).update { $0 += [.init(sessionKey: "claude:" + file.deletingPathExtension().lastPathComponent,
                                                         transcript: file.path)] }
        let run = try await LabRuns.newReview(transcript: file, title: "Fix Foo",
                                              agent: LabAgent(harness: .claudeCode, model: "opus", effort: "high", mode: .agent),
                                              language: .english, environment: .background, akit: URL(filePath: "/usr/bin/true"), env: env)
        let code = await LabWorker.run(id: run.id, env: env, startNext: false, handleSignals: false, execute: AnalysisRuns.execute,
                                       out: { _ in })
        #expect(code == 1)
        #expect(LabStore.load(run.id, env: env)?.message?.contains("reserved for bootstrap") == true)
    }
}
