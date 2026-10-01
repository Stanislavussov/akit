import Foundation
import Testing
@testable import AKitErrorAnalysis
@testable import AKitLab

struct ReportTests {
    let agent = LabAgent(harness: .claudeCode, model: "opus", effort: "low", mode: .call)

    func notes(_ key: String, outcome: Outcome, decisive: Int?, routes: [String?]) -> SessionNotes {
        var session = SessionNotes(sessionKey: key, transcript: "/t", title: nil, project: nil, requirements: [], outcome: outcome,
                                   notes: routes.indices.map { Note(id: "n\($0)", source: .model, description: "d", step: decisive ?? 0, quote: "q",
                                                                    verdict: Verdict(accepted: true, reason: "", by: .model)) },
                                   deviation: Deviation(decisiveStep: decisive), paragraph: "", advice: [],
                                   notesConfig: StepConfig(step: "notes", harness: "claude-code", model: "opus", promptVersion: 1),
                                   verifierConfig: nil, doneKeys: [:], runID: nil)
        session.routes = routes.enumerated().map { Route(noteID: "n\($0.offset)", modeID: $0.element, confidence: 0.9, by: .matching) }
        return session
    }

    func batch(_ inclusions: [(String, Double, String)]) -> Batch {
        Batch(runID: "b", createdAt: Date(timeIntervalSince1970: 0), filter: Sampling.Filter(), size: inclusions.count, seed: 1,
              notesAgent: agent, matchingAgent: agent, language: .english,
              sessions: inclusions.map {
                  Batch.Session(pick: Sampling.Pick(sessionKey: $0.0, file: "/f", inclusion: $0.1, sampling: $0.2, stratum: $0.2, projectID: "p"),
                                status: .done)
              })
    }

    func mode(_ id: String) -> Mode {
        var mode = Mode(id: id, name: id, definition: "d", origin: .seedPrior)
        mode.status = .active
        return mode
    }

    @Test func frequenciesComeFromChecksWeightedAndByOutcome() {
        let b = batch([("a", 0.5, "stratum:x"), ("b", 0.5, "stratum:x"), ("c", 0.1, "random"), ("d", 0.1, "random")])
        let pool = [notes("a", outcome: .no, decisive: 2, routes: ["large-file-read-whole"]),
                    notes("b", outcome: .achieved, decisive: nil, routes: []),
                    notes("c", outcome: .achieved, decisive: nil, routes: [nil]),
                    notes("d", outcome: .partly, decisive: 1, routes: ["large-file-read-whole"])]
        let check = CheckResults(modeID: "large-file-read-whole", verdicts: [
            "a": CheckVerdict(positive: true, version: 1), "b": CheckVerdict(positive: false, version: 1),
            "c": CheckVerdict(positive: false, version: 1), "d": CheckVerdict(positive: true, version: 1)])
        let heuristic = mode("repeated-steps")
        let report = Reports.build(b, modes: [mode("large-file-read-whole"), heuristic], pool: pool, checks: [check], trust: [:],
                                   bootstrap: [], acceptance: (3, 4), allBatches: [b], phases: [:])
        let exact = report.modes.first { $0.modeID == "large-file-read-whole" }!
        #expect(exact.trust == .exact && exact.hasFrequency)
        // Weighted: positives 2 + 10 = 12 of 2 + 2 + 10 + 10 = 24.
        #expect(abs(exact.weighted! - 0.5) < 1e-12 && exact.unweighted == 0.5)
        #expect(exact.seenInNotes == 2 && exact.checked == 4)
        #expect(exact.achieved == 0 && exact.notAchieved == 1)
        #expect(exact.interval != nil)
        // A heuristic check without validation: "seen in k notes", no frequency.
        let seen = report.modes.first { $0.modeID == "repeated-steps" }!
        #expect(!seen.hasFrequency && seen.interval == nil)
        #expect(report.coverage == [4, 4] && report.routeAcceptance == [3, 4])
        #expect(abs(report.unmatchedShare! - 1.0 / 3.0) < 1e-12)
        // No bootstrap phase agreement yet: the matrix is hidden, with the reason.
        #expect(report.matrixHidden?.contains("no bootstrap phase agreement") == true)
        #expect(report.showFunnel)
        #expect(report.rebuild?.contains("more than 15%") == true)
    }

    @Test func validatedChecksAreCorrected() {
        let b = batch((0..<20).map { ("s\($0)", 1, "random") })
        let pool = (0..<20).map { notes("s\($0)", outcome: .no, decisive: nil, routes: []) }
        var verdicts: [String: CheckVerdict] = [:]
        for index in 0..<20 { verdicts["s\(index)"] = CheckVerdict(positive: index < 6, version: 1) }
        let labels = Stats.CheckLabels(onPositives: Array(repeating: true, count: 29) + [false],
                                       onNegatives: Array(repeating: false, count: 28) + [true, true])
        let report = Reports.build(b, modes: [mode("x")], pool: pool, checks: [CheckResults(modeID: "x", verdicts: verdicts)],
                                   trust: ["x": CheckTrust(level: .validated, labels: labels)], bootstrap: [], acceptance: (0, 0),
                                   allBatches: [b], phases: [:])
        let x = report.modes[0]
        // (0.3 + 28/30 − 1) / (29/30 + 28/30 − 1)
        let expected = (0.3 + 28.0 / 30 - 1) / (29.0 / 30 + 28.0 / 30 - 1)
        #expect(abs(x.corrected! - expected) < 1e-12)
        #expect(x.interval != nil && !x.belowDetectionThreshold)
    }

    @Test func matrixRowsColumnsAndDifference() {
        let pool = [notes("a", outcome: .no, decisive: 5, routes: ["m"]), notes("b", outcome: .no, decisive: 3, routes: ["m"]),
                    notes("c", outcome: .achieved, decisive: nil, routes: [])]
        let phases: [String: [Int: Phase]] = ["a": [4: .edit, 5: .verify], "b": [1: .explore, 3: .edit]]
        let matrix = TransitionMatrix.build(pool, phases: phases)
        #expect(matrix.count(.edit, "verify") == 1 && matrix.count(.explore, "edit") == 1)
        #expect(matrix.count(.report, TransitionMatrix.noFailures) == 1)
        #expect(matrix.funnel["verify"] == 1 && matrix.funnel["edit"] == 1)
        #expect(matrix.sessions(.edit, "verify") == ["a"])

        let after = TransitionMatrix.build([notes("a", outcome: .no, decisive: 5, routes: ["m"])], phases: ["a": [4: .verify, 5: .report]])
        let difference = TransitionMatrix.difference(before: matrix, after: after)
        #expect(difference["edit|verify"]?.change ?? 0 < 0)
        #expect(difference["edit|verify"]?.withinNoise == true && difference["edit|verify"]?.dimmed == true)

        let metrics = Bootstrap.Metrics(notesVersion: "claude-code · opus · notes v1", sessions: 30, recall: 0.8, recallCounts: [8, 10],
                                        precision: 0.9, precisionCounts: [9, 10], phaseAgreement: 0.6, stepAgreement: 0.5,
                                        deviationCounts: [6, 5, 10], outcomeAgreement: 1, outcomeCounts: [1, 1])
        let b = batch([("a", 1, "random"), ("b", 1, "random"), ("c", 1, "random")])
        let low = Reports.build(b, modes: [], pool: pool, checks: [], trust: [:], bootstrap: [metrics], acceptance: (0, 0), allBatches: [b],
                                phases: phases)
        #expect(low.matrixHidden?.contains("below 70%") == true && low.notesRecall == 0.8)
        var good = metrics
        good.phaseAgreement = 0.75
        #expect(Reports.build(b, modes: [], pool: pool, checks: [], trust: [:], bootstrap: [good], acceptance: (0, 0), allBatches: [b],
                              phases: phases).matrixHidden == nil)
    }
}
