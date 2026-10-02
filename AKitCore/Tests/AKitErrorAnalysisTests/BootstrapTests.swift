import Foundation
import Testing
import AKitFoundation
import AKitInsights
import AKitSessions
@testable import AKitErrorAnalysis
@testable import AKitLab

@Suite(.serialized)
struct BootstrapTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-bootstrap-\(UUID().uuidString)")
        try fm.createDirectory(at: home.appending(path: "bin"), withIntermediateDirectories: true)
    }

    var env: HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home, variables: ["HOME": home.path],
                           executableSearchPaths: [home.appending(path: "bin"), URL(filePath: "/usr/bin"), URL(filePath: "/bin")])
    }

    func session(_ index: Int, project: String) -> IndexedSession {
        IndexedSession(key: "claude:s\(index)", harness: "claude", nativeID: "s\(index)", file: "/f/s\(index).jsonl", cwd: "/w/\(project)",
                       started: nil, lastActivity: nil, requests: 10, model: "claude-opus-5-5", projectID: project)
    }

    @Test func picksClusterRepresentativesAndRandomOnes() {
        // Three projects of 40, 5 and 1 sessions: each gets a representative.
        let sessions = (0..<40).map { session($0, project: "big") } + (40..<45).map { session($0, project: "mid") } + [session(45, project: "tiny")]
        var generator = SeededGenerator(seed: 3)
        let chosen = Bootstrap.choose(sessions, signals: [:], count: 30, using: &generator)
        #expect(chosen.count == 30 && Set(chosen.map(\.key)).count == 30)
        #expect(chosen.contains { $0.projectID == "tiny" } && chosen.contains { $0.projectID == "mid" })
    }

    func label(_ key: String, notes: [Note], outcome: Outcome = .no, decisive: Int? = 3, done: Bool = true) -> Bootstrap.Label {
        Bootstrap.Label(sessionKey: key, transcript: "/t/\(key).jsonl", notes: notes, outcome: outcome,
                        deviation: Deviation(decisiveStep: decisive), labeledAt: done ? .now : nil)
    }

    func note(_ description: String, step: Int) -> Note {
        Note(id: "", source: .human, description: description, step: step, quote: "q")
    }

    @Test func labelsNeedAReservationAndAnOutcome() throws {
        let store = Bootstrap.LabelStore(env: env)
        #expect(throws: Bootstrap.Failure.self) { try store.save(label("claude:a", notes: [])) }
        try BootstrapReservations(env: env).update { $0 += [.init(sessionKey: "claude:a", transcript: "/t/a.jsonl")] }
        #expect(BootstrapReservations(env: env).isReserved("claude:a"))
        var unfinished = label("claude:a", notes: [note("x", step: 1)], done: false)
        unfinished.outcome = nil
        try store.save(unfinished)
        #expect(BootstrapReservations(env: env).isReserved("claude:a"))
        var finished = unfinished
        finished.labeledAt = .now
        #expect(throws: Bootstrap.Failure.self) { try store.save(finished) }
        finished.outcome = .partly
        finished.notes.append(note("y", step: 2))
        try store.save(finished)
        let saved = try #require(store.load("claude:a"))
        #expect(saved.notes.map(\.id) == ["h1", "h2"] && saved.notes.allSatisfy { $0.source == .human })
        // Labeled: models may look at it now, but it never enters a batch.
        #expect(!BootstrapReservations(env: env).isReserved("claude:a"))
        #expect(BootstrapReservations(env: env).keys() == ["claude:a"])
    }

    func review(_ key: String, notes: [Note], outcome: Outcome, decisive: Int?) -> SessionNotes {
        SessionNotes(sessionKey: key, transcript: "", title: nil, project: nil, requirements: [], outcome: outcome, notes: notes,
                     deviation: Deviation(decisiveStep: decisive), paragraph: "", advice: [],
                     notesConfig: StepConfig(step: "notes", harness: "claude-code", model: "opus", promptVersion: 1),
                     verifierConfig: nil, doneKeys: [:], runID: nil)
    }

    func modelNote(_ id: String, step: Int, accepted: Bool) -> Note {
        Note(id: id, source: .model, description: id, step: step, quote: "q", verdict: Verdict(accepted: accepted, reason: "", by: .model))
    }

    @Test func recallPrecisionAndAgreement() {
        var h1 = note("a", step: 3); h1.id = "h1"
        var h2 = note("b", step: 9); h2.id = "h2"
        let labels = [label("claude:a", notes: [h1, h2], outcome: .no, decisive: 3), label("claude:b", notes: [], outcome: .achieved, decisive: nil)]
        let notes = [review("claude:a", notes: [modelNote("n1", step: 3, accepted: true), modelNote("n2", step: 5, accepted: true),
                                                 modelNote("n3", step: 7, accepted: false)], outcome: .no, decisive: 5),
                     review("claude:b", notes: [], outcome: .partly, decisive: nil)]
        let version = "claude-code · opus · notes v1"
        let pairings = [Bootstrap.Pairing(sessionKey: "claude:a", notesVersion: version, proposed: [.init(human: "h1", model: "n1")],
                                          confirmed: [.init(human: "h1", model: "n1")], agreed: ["n1"]),
                        Bootstrap.Pairing(sessionKey: "claude:b", notesVersion: version, proposed: [], confirmed: [], agreed: [])]
        let phases = ["claude:a": [3: Phase.edit, 5: Phase.edit]]
        let metrics = Bootstrap.metrics(labels: labels, notes: notes, pairings: pairings, phases: phases)
        #expect(metrics.count == 1)
        let m = metrics[0]
        #expect(m.notesVersion == version && m.sessions == 2)
        #expect(m.recall == 0.5 && m.precision == 0.5)
        #expect(m.phaseAgreement == 1 && m.stepAgreement == 1)
        #expect(m.outcomeAgreement == 0.5)
        // Unconfirmed pairings don't count.
        let open = Bootstrap.Pairing(sessionKey: "claude:a", notesVersion: version, proposed: [])
        #expect(Bootstrap.metrics(labels: labels, notes: notes, pairings: [open]).isEmpty)
    }

    @Test func recallCountsOnlyNotesTheVerifierAccepted() {
        var h1 = note("a", step: 3); h1.id = "h1"
        var h2 = note("b", step: 7); h2.id = "h2"
        let labels = [label("claude:a", notes: [h1, h2])]
        // h2's model note was rejected by the verifier: it is not in the pool the reports use.
        let notes = [review("claude:a", notes: [modelNote("n1", step: 3, accepted: true), modelNote("n3", step: 7, accepted: false)],
                            outcome: .no, decisive: 3)]
        let pairings = [Bootstrap.Pairing(sessionKey: "claude:a", notesVersion: "claude-code · opus · notes v1", proposed: [],
                                          confirmed: [.init(human: "h1", model: "n1"), .init(human: "h2", model: "n3")], agreed: ["n1", "n3"])]
        let m = Bootstrap.metrics(labels: labels, notes: notes, pairings: pairings)[0]
        #expect(m.recall == 0.5 && m.recallCounts == [1, 2])
        #expect(m.recallBeforeVerifier == 1 && m.recallBeforeVerifierCounts == [2, 2])
        #expect(m.precision == 1 && m.precisionCounts == [1, 1])
    }

    func fakeClaude(_ structured: String) throws {
        let answer = #"{"type":"result","is_error":false,"result":"","structured_output":"# + structured + #","usage":{"input_tokens":1,"output_tokens":1}}"#
        try Data("#!/bin/sh\nif [ \"$1 $2\" = \"auth status\" ]; then echo '{\"loggedIn\":true,\"email\":\"me@example.com\",\"orgName\":\"Me\"}'; exit 0; fi\ncat > /dev/null\necho '\(answer)'\n".utf8)
            .write(to: home.appending(path: "bin/claude"))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.appending(path: "bin/claude").path)
    }

    @Test func pairsAreProposedByTheModelAndChecked() async throws {
        try fakeClaude(#"{"pairs":[{"human":"h1","model":"n1"},{"human":"h1","model":"n2"},{"human":"h9","model":"n1"}]}"#)
        var h1 = note("a", step: 3); h1.id = "h1"
        let agent = LabAgent(harness: .claudeCode, model: "opus", effort: "low")
        let gate = try await SendGate.open(agent: agent, env: env)
        let reviewed = review("claude:a", notes: [modelNote("n1", step: 3, accepted: true), modelNote("n2", step: 4, accepted: true)],
                            outcome: .no, decisive: 3)
        func propose(_ notes: SessionNotes) async throws -> Bootstrap.Pairing {
            try await Bootstrap.proposePairs(label: label("claude:a", notes: [h1]), notes: notes, agent: agent, gate: gate,
                                             origin: .claudeSession, workFolder: home.appending(path: "w"), env: env)
        }
        let pairing = try await propose(reviewed)
        // Each note in at most one pair; unknown ids dropped.
        #expect(pairing.proposed == [.init(human: "h1", model: "n1")])
        #expect(Bootstrap.PairingStore(env: env).load("claude:a") == pairing)

        // Proposing again keeps what the user confirmed and agreed, for notes that still exist.
        var confirmed = pairing
        confirmed.confirmed = [.init(human: "h1", model: "n2")]
        confirmed.agreed = ["n2", "n7"]
        try Bootstrap.PairingStore(env: env).save(confirmed)
        let again = try await propose(reviewed)
        #expect(again.proposed == [.init(human: "h1", model: "n1")])
        #expect(again.confirmed == [.init(human: "h1", model: "n2")] && again.agreed == ["n2"] && again.isConfirmed)
        // Notes of another model or prompt version: the old confirmation is about other notes.
        var newer = reviewed
        newer.notesConfig.promptVersion = 2
        let moved = try await propose(newer)
        #expect(moved.confirmed == nil && moved.agreed == nil)
    }

    @Test func similarCasesLeaveOutNotesThatMayNotBeSent() async throws {
        try fakeClaude(#"{"found":["claude:c#n1"]}"#)
        var h1 = note("a", step: 3); h1.id = "h1"
        var h2 = note("b", step: 4); h2.id = "h2"
        let labels = [label("claude:a", notes: [h1]), label("pi:b", notes: [h2])]
        let book = LabelBook(mapping: ["claude:a#h1": "m", "pi:b#h2": "m"])
        // A Pi session with no recorded provider may not go to Claude Code.
        let pool = [review("claude:c", notes: [modelNote("n1", step: 2, accepted: true)], outcome: .no, decisive: 2),
                    review("pi:d", notes: [modelNote("n1", step: 2, accepted: true), modelNote("n2", step: 3, accepted: true)],
                           outcome: .no, decisive: 2)]
        let agent = LabAgent(harness: .claudeCode, model: "opus", effort: "low")
        let gate = try await SendGate.open(agent: agent, env: env)
        var lines: [String] = []
        let finds = try await Bootstrap.findSimilar(mode: Mode(id: "m", name: "M", definition: "d"), labels: labels, pool: pool, book: book,
                                                    agent: agent, gate: gate, workFolder: home.appending(path: "w"), env: env,
                                                    out: { lines.append($0) })
        #expect(finds.map(\.ref) == [NoteRef(sessionKey: "claude:c", noteID: "n1")])
        #expect(lines.count == 1 && lines[0].hasPrefix("3 notes are left out"))
        #expect(LabelBookStore(env: env).load().finds.count == 1)
    }
}
