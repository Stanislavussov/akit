import Foundation
import Testing
import AKitInsights
import AKitLab
@testable import AKitErrorAnalysis

struct SamplingTests {
    func session(_ index: Int, requests: Int = 10, harness: String = "claude", model: String = "claude-opus-5-5",
                 project: String? = "p1", cwd: String = "/work/app", started: Date = Date(timeIntervalSince1970: 1_790_000_000)) -> IndexedSession {
        IndexedSession(key: "\(harness):s\(index)", harness: harness, nativeID: "s\(index)", file: "/f/s\(index).jsonl", cwd: cwd,
                       started: started, lastActivity: started, requests: requests, model: model, projectID: project)
    }

    @Test func populationFilters() {
        let sessions = [session(1), session(2, requests: 3), session(3, project: nil, cwd: "/work/app/sub"), session(4, project: "p2", cwd: "/x"),
                        session(5, started: Date(timeIntervalSince1970: 1_700_000_000)), session(6)]
        let filter = Sampling.Filter(project: "p1", from: Date(timeIntervalSince1970: 1_780_000_000))
        let population = Sampling.population(sessions, filter: filter, reserved: ["claude:s6"])
        #expect(population.map(\.key) == ["claude:s1"])
        let byFolder = Sampling.population(sessions, filter: Sampling.Filter(project: "/work/app"), reserved: [])
        #expect(Set(byFolder.map(\.key)) == ["claude:s1", "claude:s3", "claude:s5", "claude:s6"])
    }

    @Test func stratifiedSampleWithARandomShare() {
        // 90 quiet sessions and 10 with pushback: the rare stratum is oversampled.
        let sessions = (0..<100).map { session($0) }
        var signals: [String: SessionSignals] = [:]
        for index in 0..<100 { signals["claude:s\(index)"] = SessionSignals(pushbacks: index < 10 ? 1 : 0) }
        var generator = SeededGenerator(seed: 7)
        let picks = Sampling.sample(sessions, signals: signals, size: 20, using: &generator)
        #expect(picks.count == 20)
        #expect(picks.filter { $0.sampling == "random" }.count == 5)
        let pushback = picks.filter { $0.stratum.hasSuffix("|pushback") }
        #expect(pushback.count >= 7)
        // A pushback session is far more likely to be picked than a quiet one, and the weights say so.
        let quiet = picks.first { $0.stratum.hasSuffix("|quiet") }!
        #expect(pushback[0].inclusion > quiet.inclusion * 3)
        #expect(picks.allSatisfy { $0.inclusion > 0 && $0.inclusion <= 1 })
        // The same seed gives the same sample.
        var again = SeededGenerator(seed: 7)
        #expect(Sampling.sample(sessions, signals: signals, size: 20, using: &again) == picks)
        #expect(Sampling.stratum(sessions[0], nil) == "claude|claude-opus|no-signals")
        #expect(Sampling.family("github-copilot/gpt-6.1-sol") == "gpt")
    }

    @Test func smallPopulationsAreTakenWhole() {
        var generator = SeededGenerator(seed: 1)
        let picks = Sampling.sample((0..<4).map { session($0) }, signals: [:], size: 20, using: &generator)
        #expect(picks.count == 4)
    }

    @Test func weightedSharesAndCorrection() {
        // Two positives picked with probability 1/2, three negatives with probability 1/10:
        // weighted, positives count 2 × 2 = 4 against 3 × 10 = 30.
        let observations = [Stats.Observation(positive: true, inclusion: 0.5, group: "a"), .init(positive: true, inclusion: 0.5, group: "a"),
                            .init(positive: false, inclusion: 0.1, group: "b"), .init(positive: false, inclusion: 0.1, group: "b"),
                            .init(positive: false, inclusion: 0.1, group: "b")]
        #expect(abs(Stats.weightedShare(observations)! - 4.0 / 34.0) < 1e-12)
        #expect(Stats.unweightedShare(observations) == 0.4)
        #expect(Stats.weightedShare([]) == nil)

        #expect(abs(Stats.roganGladen(observed: 0.3, tpr: 0.9, tnr: 0.95)! - 0.25 / 0.85) < 1e-12)
        #expect(Stats.roganGladen(observed: 0.01, tpr: 0.9, tnr: 0.9) == 0)
        #expect(Stats.roganGladen(observed: 0.5, tpr: 0.5, tnr: 0.5) == nil)
        #expect(Stats.belowDetectionThreshold(observed: 0.04, tnr: 0.95))
        #expect(!Stats.belowDetectionThreshold(observed: 0.06, tnr: 0.95))
    }

    @Test func bootstrapIntervalsCoverTheEstimate() throws {
        let observations = (0..<40).map { Stats.Observation(positive: $0 % 4 == 0, inclusion: 0.5, group: $0 < 10 ? "random" : "stratum:x") }
        let plain = try #require(Stats.bootstrapInterval(observations, iterations: 1000))
        #expect(plain.low < 0.25 && plain.high > 0.25 && plain.low > 0.05 && plain.high < 0.5)
        // Uncertain TPR/TNR widen the interval.
        let labels = Stats.CheckLabels(onPositives: Array(repeating: true, count: 27) + [false, false, false],
                                       onNegatives: Array(repeating: false, count: 28) + [true, true])
        let corrected = try #require(Stats.bootstrapInterval(observations, labels: labels, iterations: 1000))
        #expect(corrected.high - corrected.low > plain.high - plain.low)
        #expect(Stats.bootstrapInterval(observations, iterations: 1000) == plain)
    }

    @Test func singletonStrataAreCollapsedSoTheyVary() throws {
        // 20 stratified picks, one per stratum: resampled within their own strata they would
        // never vary and the interval would be a point.
        let observations = (0..<20).map { Stats.Observation(positive: $0 % 2 == 0, inclusion: 0.5, group: "stratum:\($0)") }
        let groups = Stats.resamplingGroups(observations)
        #expect(groups.count == 1 && groups[0].count == 20)
        let interval = try #require(Stats.bootstrapInterval(observations, iterations: 1000))
        #expect(interval.low < 0.4 && interval.high > 0.6)
        // Groups of 2 or more stay; a lone leftover joins the smallest of them.
        let mixed = (0..<6).map { _ in Stats.Observation(positive: false, inclusion: 1, group: "random") }
            + (0..<3).map { _ in Stats.Observation(positive: true, inclusion: 1, group: "stratum:a") }
            + [Stats.Observation(positive: true, inclusion: 1, group: "stratum:b")]
        #expect(Stats.resamplingGroups(mixed).map(\.count) == [6, 4])
        let two = mixed + [Stats.Observation(positive: false, inclusion: 1, group: "stratum:c")]
        #expect(Stats.resamplingGroups(two).map(\.count) == [6, 3, 2])
    }

    @Test func adHocReviewsHintTheNextSample() {
        let sessions = (0..<40).map { session($0) } + (40..<50).map { session($0, harness: "pi", model: "gpt-6") }
        var generator = SeededGenerator(seed: 2)
        // Without a hint the small pi stratum may get nothing beyond its even share; with one it gets a pick first.
        let picks = Sampling.sample(sessions, signals: [:], size: 4, hinted: ["pi|gpt|no-signals"], using: &generator)
        #expect(picks.contains { $0.stratum == "pi|gpt|no-signals" && $0.sampling.hasPrefix("stratum:") })
        let agent = LabAgent(harness: .claudeCode, model: "opus", effort: "low")
        var flagged = SessionNotes(sessionKey: "pi:s41", transcript: "/t", title: nil, project: nil, requirements: [], outcome: .no,
                                   notes: [Note(id: "n1", source: .model, description: "d", step: 0, quote: "a long quote",
                                                verdict: Verdict(accepted: true, reason: "", by: .model))],
                                   deviation: Deviation(), paragraph: "", advice: [], notesConfig: StepConfig(step: "notes"),
                                   verifierConfig: nil, doneKeys: [:], runID: "review-run")
        let batch = Batch(runID: "batch-run", filter: Sampling.Filter(), size: 1, seed: 1, notesAgent: agent, matchingAgent: agent,
                          language: .english, sessions: [])
        #expect(Sampling.hintedStrata(pool: [flagged], batches: [batch], sessions: sessions, signals: [:]) == ["pi|gpt|no-signals"])
        flagged.runID = "batch-run"
        #expect(Sampling.hintedStrata(pool: [flagged], batches: [batch], sessions: sessions, signals: [:]).isEmpty)
    }

    @Test func reviewersOfAnotherFamily() {
        #expect(Batches.vendor("opus") == "anthropic" && Batches.vendor("claude-sonnet-5-5") == "anthropic")
        #expect(Batches.vendor("github-copilot/gpt-6.1-sol") == "openai" && Batches.vendor("gemini-3-pro") == "google")
        #expect(Batches.vendor("opencode-go/qwen3.6-plus") == "qwen")
        // On top of the sampling family: `claude-opus` and `claude-haiku` strata, one vendor.
        #expect(Batches.vendor("o4-mini") == "openai" && Batches.vendor("github-copilot/claude-haiku-5") == "anthropic")
    }
}
