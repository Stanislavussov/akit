import Foundation
import Testing
@testable import AKitCommandLine
@testable import AKitErrorAnalysis
@testable import AKitLab

/// The text of `akit analysis report`.
struct AnalysisReportCLITests {
    @Test func everyModeShowsCheckedOfNAndTheNotesDenominators() {
        let agent = LabAgent(harness: .claudeCode, model: "opus", effort: "low", mode: .call)
        let batch = Batch(runID: "b", createdAt: Date(timeIntervalSince1970: 0), filter: Sampling.Filter(), size: 3, seed: 1,
                          notesAgent: agent, matchingAgent: agent, language: .english,
                          sessions: ["a", "b", "c"].map {
                              Batch.Session(pick: Sampling.Pick(sessionKey: $0, file: "/f", inclusion: 1, sampling: "random", stratum: "s",
                                                                projectID: "p"), status: .done)
                          })
        let pool = ["a", "b", "c"].map { key in
            SessionNotes(sessionKey: key, transcript: "/t", title: nil, project: nil, requirements: [], outcome: .no,
                         notes: [Note(id: "n0", source: .model, description: "d", step: 1, quote: "q",
                                      verdict: Verdict(accepted: key != "c", reason: "", by: .model))],
                         deviation: Deviation(), paragraph: "", advice: [],
                         notesConfig: StepConfig(step: "notes", harness: "claude-code", model: "opus", promptVersion: 1),
                         verifierConfig: nil, doneKeys: [:], runID: nil)
        }
        var exact = Mode(id: "large-file-read-whole", name: "Large file read whole", definition: "d", origin: .seedPrior)
        exact.status = .active
        var seen = Mode(id: "repeated-steps", name: "Repeated steps", definition: "d", origin: .seedPrior)
        seen.status = .active
        // The code check ran on 2 of the 3 sessions.
        let check = CheckResults(modeID: exact.id, verdicts: ["a": CheckVerdict(positive: true, version: 1),
                                                              "b": CheckVerdict(positive: false, version: 1)])
        let metrics = Bootstrap.Metrics(notesVersion: "claude-code · opus · notes v1", sessions: 30, recall: 0.8, recallCounts: [8, 10],
                                        precision: 0.9, precisionCounts: [9, 10], phaseAgreement: 0.8, stepAgreement: 0.5,
                                        deviationCounts: [8, 5, 10], outcomeAgreement: 1, outcomeCounts: [1, 1])
        let report = Reports.build(batch, modes: [exact, seen], pool: pool, checks: [check], trust: [:], bootstrap: [metrics],
                                   acceptance: (1, 2), allBatches: [batch], phases: [:], spotChecks: ["a#n0": true, "b#n0": false])
        let text = AKitCLI.reportText(report)
        #expect(text.contains("bootstrap recall 80% (8/10)"))
        #expect(text.contains("verifier rejected 33% (1/3)"))
        #expect(text.contains("Spot checks: precision 50% (1/2)"))
        let lines = text.split(separator: "\n")
        #expect(lines.contains { $0.hasPrefix("Large file read whole: 50%") && $0.contains("checked 2/3") })
        #expect(lines.contains { $0.hasPrefix("Repeated steps: seen in 0 notes") && $0.contains("checked 0/3") })
        #expect(!text.contains("too long") && !text.contains("left out before sampling"))
    }

    @Test func sessionsTooLongOrLeftOutBeforeSamplingAreNamed() {
        let agent = LabAgent(harness: .claudeCode, model: "opus", effort: "low", mode: .call)
        var batch = Batch(runID: "b", createdAt: Date(timeIntervalSince1970: 0), filter: Sampling.Filter(), size: 2, seed: 1,
                          notesAgent: agent, matchingAgent: agent, language: .english,
                          sessions: [("a", Batch.Status.done), ("b", .tooLong)].map {
                              Batch.Session(pick: Sampling.Pick(sessionKey: $0.0, file: "/f", inclusion: 1, sampling: "random", stratum: "s",
                                                                projectID: "p"), status: $0.1)
                          })
        batch.leftOut = 4
        batch.leftOutReason = "Pi may not get Claude Code sessions"
        let report = Reports.build(batch, modes: [], pool: [], checks: [], trust: [:], bootstrap: [], acceptance: (0, 0),
                                   allBatches: [batch], phases: [:])
        let text = AKitCLI.reportText(report)
        #expect(text.contains("1 of 2 sessions (coverage 1/2) · 1 too long for a digest (left out of the frequencies)"), "\(text)")
        #expect(text.contains("4 sessions of the filter were left out before sampling: Pi may not get Claude Code sessions"), "\(text)")
    }
}
