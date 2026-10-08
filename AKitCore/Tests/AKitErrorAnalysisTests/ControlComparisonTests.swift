import Foundation
import Testing
import AKitLab
@testable import AKitErrorAnalysis

/// pass@1, pass^k and the paired bootstrap over tasks.
struct ControlComparisonTests {
    let agent = LabAgent(harness: .claudeCode, model: "opus", effort: "high")
    var baseline: ControlSetup { ControlSetup(name: "baseline", agent: agent) }
    var variant: ControlSetup { ControlSetup(name: "variant", agent: agent, patch: ControlPatch(file: "CLAUDE.md", text: "Run the tests")) }

    /// `passes[t]` of `repeats` cells of task t pass.
    func cells(_ setup: ControlSetup, passes: [Int], repeats: Int = 3) -> [ControlComparison.Cell] {
        passes.enumerated().flatMap { task, passed in
            (0..<repeats).map { ControlComparison.Cell(task: "t\(task)", setup: setup, passed: $0 < passed) }
        }
    }

    @Test func passAt1AndPassHatK() throws {
        let row = ControlComparison.row(baseline, cells: cells(baseline, passes: [3, 3, 1, 0, 2]))
        #expect(row.cells == 15 && row.k == 3 && row.tasks.map(\.passed) == [3, 3, 1, 0, 2])
        // Mean single-run pass rate: (1 + 1 + 1/3 + 0 + 2/3) / 5.
        #expect(abs(try #require(row.passAt1) - 3.0 / 5.0) < 1e-9)
        #expect(row.passAt1Interval == Stats.wilson(9, 15))
        // All 3 runs passed in 2 of 5 tasks.
        #expect(row.passHatK == 0.4)
    }

    /// The mode's check in production before and after the fix: fewer failures after T.
    let notWorse = Fixes.evaluate(modeID: "m", appliedAt: .now, before: (10, 20, "opus"), after: (4, 20, "opus"), trust: .exact)

    @Test func helpedNeedsMostOfTheBootstrapMassOnImprovement() throws {
        let all = cells(baseline, passes: [1, 1, 1, 1, 1]) + cells(variant, passes: [3, 3, 3, 3, 3])
        let comparison = ControlComparison.compare(all, production: notWorse)
        #expect(comparison.rows.map(\.setup) == [baseline, variant])
        let pair = try #require(comparison.paired.first)
        #expect(pair.baseline == baseline && pair.variant == variant && pair.tasks == 5)
        #expect(pair.baselineCells == 15 && pair.variantCells == 15)
        #expect(abs(try #require(pair.meanChange) - 2.0 / 3.0) < 1e-9)
        #expect(pair.improvementShare == 1 && pair.verdict == .helped && pair.productionHigher == notWorse.probabilityHigher)

        // The same pass rates: no mass on improvement.
        let same = ControlComparison.compare(cells(baseline, passes: [2, 1, 3, 0, 2]) + cells(variant, passes: [2, 1, 3, 0, 2]))
        #expect(same.paired.first?.improvementShare == 0 && same.paired.first?.verdict == .notShown)

        // Mixed changes: a share between, the same for the same seed.
        let mixedCells = cells(baseline, passes: [1, 1, 2, 3, 0, 2]) + cells(variant, passes: [3, 2, 1, 3, 1, 2])
        let mixed = try #require(ControlComparison.compare(mixedCells).paired.first)
        let share = try #require(mixed.improvementShare)
        #expect(share > 0.5 && share < 1)
        #expect(ControlComparison.compare(mixedCells).paired.first?.improvementShare == share)
        #expect(ControlComparison.compare(mixedCells, seed: 7).paired.first?.improvementShare != nil)
    }

    @Test func helpedAlsoNeedsTheFixNotWorseInProduction() throws {
        let all = cells(baseline, passes: [1, 1, 1, 1, 1]) + cells(variant, passes: [3, 3, 3, 3, 3])
        // No production signal yet (the fix isn't applied): no conclusion, though the control set shows it.
        let unknown = try #require(ControlComparison.compare(all).paired.first)
        #expect(unknown.verdict == .noConclusion && unknown.improvementShare == 1 && unknown.productionHigher == nil)
        #expect(unknown.reason.contains("not worse in production isn't known"))
        // Too few sessions after T.
        let early = Fixes.evaluate(modeID: "m", appliedAt: .now, before: (10, 20, nil), after: (1, 5, nil), trust: .exact)
        let few = try #require(ControlComparison.compare(all, production: early).paired.first)
        #expect(few.verdict == .noConclusion && few.reason.contains("before 20, after 5") && few.productionHigher == nil)
        // The mode's failure rate rose in production: not shown, however the control set looks.
        let worse = Fixes.evaluate(modeID: "m", appliedAt: .now, before: (4, 20, nil), after: (10, 20, nil), trust: .exact)
        let rose = try #require(ControlComparison.compare(all, production: worse).paired.first)
        #expect(rose.verdict == .notShown && rose.reason.contains("in production") && rose.productionHigher == worse.probabilityHigher)
        #expect(worse.probabilityHigher > Fixes.notWorseProbability)
    }

    @Test func tooFewRepeatsOrCellsGiveNoConclusion() throws {
        let twoRepeats = ControlComparison.compare(cells(baseline, passes: Array(repeating: 0, count: 8), repeats: 2)
                                                   + cells(variant, passes: Array(repeating: 2, count: 8), repeats: 2))
        let few = try #require(twoRepeats.paired.first)
        #expect(few.verdict == .noConclusion && few.reason.contains("fewer than 3 repeats") && few.improvementShare == 1)

        let fourTasks = ControlComparison.compare(cells(baseline, passes: [0, 0, 0, 0]) + cells(variant, passes: [3, 3, 3, 3]))
        #expect(fourTasks.paired.first?.verdict == .noConclusion && fourTasks.paired.first?.reason.contains("Fewer than 15 cells") == true)

        // No shared task.
        let apart = ControlComparison.compare([ControlComparison.Cell(task: "a", setup: baseline, passed: true),
                                               ControlComparison.Cell(task: "b", setup: variant, passed: true)])
        #expect(apart.paired.first?.verdict == .noConclusion && apart.paired.first?.meanChange == nil)
    }

    @Test func flaggedCellsCountAsFailedAndReadOnlySetupsAreLeftOut() throws {
        var all = cells(baseline, passes: [1, 1, 1, 1, 1]) + cells(variant, passes: [3, 3, 3, 3, 3])
        // Passing variant cells that weakened tests stay in, as failures: no re-roll makes them go away.
        all += (0..<5).map { ControlComparison.Cell(task: "t\($0)", setup: variant, passed: true, flagged: true) }
        let broken = ControlSetup(name: "read-only", agent: agent, readOnly: true)
        all += cells(broken, passes: [0, 0, 0, 0, 0])
        let comparison = ControlComparison.compare(all, production: notWorse)
        let row = try #require(comparison.rows.first { $0.setup == variant })
        #expect(row.cells == 20 && row.flagged == 5 && row.k == 4 && row.tasks.allSatisfy { $0.passed == 3 && $0.total == 4 })
        #expect(abs(try #require(row.passAt1) - 0.75) < 1e-9 && row.passAt1Interval == Stats.wilson(15, 20))
        #expect(comparison.paired.count == 1 && comparison.paired[0].variantCells == 20)
        #expect(comparison.rows.first { $0.setup == broken }?.passAt1 == 0)
    }

    @Test func cellsComeFromFinishedControlRuns() {
        func run(_ id: String, kind: RunSpec.Kind = .control, status: RunState.Status, passed: Bool, flagged: Bool = false) -> LabRun {
            let spec = RunSpec(id: id, kind: kind, title: "", createdAt: Date(timeIntervalSince1970: Double(id.count)), folder: "/",
                               environment: .background, akit: "/akit", controlTask: "t1", controlSetup: baseline)
            let control = ControlOutcome(key: id, passed: passed, oracle: "", changedTestFiles: flagged ? ["Tests/A.swift"] : [])
            return LabRun(folder: URL(filePath: "/"), spec: spec, state: RunState(status: status), launch: nil,
                          result: status == .finished ? RunResult(control: control) : nil)
        }
        let cells = ControlComparison.Cell.of([run("a", status: .finished, passed: true), run("bb", status: .queued, passed: true),
                                               run("ccc", status: .finished, passed: false, flagged: true),
                                               run("dddd", kind: .replay, status: .finished, passed: true)])
        #expect(cells == [ControlComparison.Cell(task: "t1", setup: baseline, passed: true),
                          ControlComparison.Cell(task: "t1", setup: baseline, passed: false, flagged: true)])
    }

    func layerSetup(_ role: LayerVariant.Role, eval: String = "swiftui-1", layer: String = "swiftui", readOnly: Bool = false,
                    agent: LabAgent? = nil) -> ControlSetup {
        ControlSetup(name: role == .layer ? "layer \(layer)" : "without \(layer)", agent: agent ?? self.agent, readOnly: readOnly,
                     layer: LayerVariant(layer: layer, role: role, overlayHash: role == .layer ? "h" : nil, evalID: eval, brainCommit: "c"))
    }

    @Test func layerRowsPairOnlyWithinTheirEval() throws {
        let one = cells(layerSetup(.requiredOnly), passes: [1, 1, 1, 1, 1]) + cells(layerSetup(.layer), passes: [3, 3, 3, 3, 3])
        let two = cells(layerSetup(.requiredOnly, eval: "swiftui-2"), passes: [0, 0, 0, 0, 0])
            + cells(layerSetup(.layer, eval: "swiftui-2"), passes: [2, 2, 2, 2, 2])
        let all = cells(baseline, passes: [3, 3, 3, 3, 3]) + one + two + cells(layerSetup(.requiredOnly, readOnly: true), passes: [0, 0, 0])
        let comparison = ControlComparison.compare(all, production: notWorse)
        #expect(comparison.paired.count == 2)
        // Two evals of one layer: two pairs, each with its own eval's required layers.
        #expect(comparison.paired[0].baseline == layerSetup(.requiredOnly) && comparison.paired[0].variant == layerSetup(.layer))
        #expect(comparison.paired[1].baseline == layerSetup(.requiredOnly, eval: "swiftui-2"))
        // A layer pair never takes the fix's production signal; it is judged offline. Its eval's read-only cells all failed.
        #expect(comparison.paired[0].improvementShare == 1 && comparison.paired[0].verdict == .helpsOffline)
        #expect(comparison.paired[0].productionHigher == nil && comparison.paired[0].reason.contains("offline"))

        // A layer row never pairs with a plain baseline, nor with another agent's or layer's baseline.
        let lonely = ControlComparison.compare(cells(baseline, passes: [1, 1, 1]) + cells(layerSetup(.layer), passes: [3, 3, 3])
                                               + cells(layerSetup(.requiredOnly, agent: LabAgent(harness: .claudeCode, model: "sonnet", effort: "high")), passes: [1, 1, 1])
                                               + cells(layerSetup(.requiredOnly, layer: "other"), passes: [1, 1, 1]))
        #expect(lonely.paired.isEmpty)
        // A patch variant never pairs with a layer row.
        let patchOnly = ControlComparison.compare(cells(layerSetup(.requiredOnly), passes: [1, 1, 1]) + cells(variant, passes: [3, 3, 3]))
        #expect(patchOnly.paired.isEmpty)
        let both = ControlComparison.compare(cells(layerSetup(.requiredOnly), passes: [1, 1, 1]) + cells(baseline, passes: [1, 1, 1])
                                             + cells(variant, passes: [3, 3, 3]))
        #expect(both.paired.count == 1 && both.paired[0].baseline == baseline)
    }

    /// D4 (2026-10-08): "helps (offline)" is a layer's own level; a patch fix never gets it.
    @Test func onlyLayerPairsGetHelpsOffline() throws {
        let before = [1, 1, 1, 1, 1], after = [3, 3, 3, 3, 3]
        let layer = try #require(ControlComparison.compare(cells(layerSetup(.requiredOnly), passes: before)
                                                           + cells(layerSetup(.layer), passes: after)).paired.first)
        #expect(layer.verdict == .helpsOffline && layer.improvementShare == 1 && layer.worseShare == 0 && layer.productionHigher == nil)
        #expect(layer.verdict.title == "helps (offline)" && layer.verdict.rawValue == "helps-offline")
        // The same cells as a patch pair: no conclusion without production, never "helps (offline)" whatever production says.
        let patchCells = cells(baseline, passes: before) + cells(variant, passes: after)
        let early = Fixes.evaluate(modeID: "m", appliedAt: .now, before: (10, 20, nil), after: (1, 5, nil), trust: .exact)
        let worse = Fixes.evaluate(modeID: "m", appliedAt: .now, before: (4, 20, nil), after: (10, 20, nil), trust: .exact)
        let patch = try #require(ControlComparison.compare(patchCells).paired.first)
        #expect(patch.verdict == .noConclusion && patch.improvementShare == layer.improvementShare)
        for production in [nil, notWorse, early, worse] {
            let verdict = try #require(ControlComparison.compare(patchCells, production: production).paired.first).verdict
            #expect(verdict != .helpsOffline)
        }

        // Enough cells and repeats, below 95%: both say "didn't show it helped", with the same share.
        let baseCells = [1, 1, 2, 3, 0, 2], variantCells = [3, 2, 1, 3, 1, 2]
        let patchBelow = try #require(ControlComparison.compare(cells(baseline, passes: baseCells) + cells(variant, passes: variantCells)).paired.first)
        let layerBelow = try #require(ControlComparison.compare(cells(layerSetup(.requiredOnly), passes: baseCells)
                                                                + cells(layerSetup(.layer), passes: variantCells)).paired.first)
        #expect(patchBelow.verdict == .notShown && layerBelow.verdict == .notShown)
        #expect(layerBelow.improvementShare == patchBelow.improvementShare && (layerBelow.improvementShare ?? 1) < ControlComparison.helpedShare)
        #expect(layerBelow.reason.contains("on worse"))
    }

    @Test func layerPairsWithTooFewRepeatsOrCellsHaveNoConclusion() throws {
        let twoRepeats = try #require(ControlComparison.compare(cells(layerSetup(.requiredOnly), passes: Array(repeating: 0, count: 8), repeats: 2)
                                                                + cells(layerSetup(.layer), passes: Array(repeating: 2, count: 8), repeats: 2)).paired.first)
        #expect(twoRepeats.verdict == .noConclusion && twoRepeats.improvementShare == 1 && twoRepeats.reason.contains("fewer than 3 repeats"))
        let fourTasks = try #require(ControlComparison.compare(cells(layerSetup(.requiredOnly), passes: [0, 0, 0, 0])
                                                               + cells(layerSetup(.layer), passes: [3, 3, 3, 3])).paired.first)
        #expect(fourTasks.verdict == .noConclusion && fourTasks.reason.contains("Fewer than 15 cells"))
    }

    @Test func aReadOnlyCellThatPassedLeavesTheLayerPairOpen() throws {
        let main = cells(layerSetup(.requiredOnly), passes: [1, 1, 1, 1, 1]) + cells(layerSetup(.layer), passes: [3, 3, 3, 3, 3])
        let sanity = layerSetup(.requiredOnly, readOnly: true)
        let passed = [ControlComparison.Cell(task: "t0", setup: sanity, passed: false), ControlComparison.Cell(task: "t2", setup: sanity, passed: true)]
        let open = try #require(ControlComparison.compare(main + passed).paired.first)
        #expect(open.verdict == .noConclusion && open.improvementShare == 1)
        #expect(open.reason.hasPrefix("A read-only agent passed t2: its oracle can't tell work from no work"))
        // A read-only pass of another eval doesn't count here.
        let other = [ControlComparison.Cell(task: "t2", setup: layerSetup(.requiredOnly, eval: "swiftui-2", readOnly: true), passed: true)]
        #expect(ControlComparison.compare(main + other).paired.first?.verdict == .helpsOffline)
    }

    @Test func worseShareCountsSumsBelowZeroAndNotTies() throws {
        // All tasks the same: every bootstrap sum is zero, so neither share has any mass.
        let same = try #require(ControlComparison.compare(cells(baseline, passes: [2, 1, 3, 0, 2]) + cells(variant, passes: [2, 1, 3, 0, 2])).paired.first)
        #expect(same.improvementShare == 0 && same.worseShare == 0)
        // One task better, the rest tied: the sums are zero or above, never below.
        let one = try #require(ControlComparison.compare(cells(baseline, passes: [1, 1, 1, 1, 0]) + cells(variant, passes: [1, 1, 1, 1, 3])).paired.first)
        let up = try #require(one.improvementShare)
        #expect(one.worseShare == 0 && up > 0.5 && up < 1)
        // Every task worse: all the mass below zero.
        let down = try #require(ControlComparison.compare(cells(baseline, passes: [3, 3, 3, 3, 3]) + cells(variant, passes: [1, 1, 1, 1, 1])).paired.first)
        #expect(down.worseShare == 1 && down.improvementShare == 0)
        // Mixed: both shares, which add up to at most 1.
        let mixed = try #require(ControlComparison.compare(cells(baseline, passes: [1, 1, 2, 3, 0, 2]) + cells(variant, passes: [3, 2, 1, 3, 1, 2])).paired.first)
        let (improved, worsened) = (try #require(mixed.improvementShare), try #require(mixed.worseShare))
        #expect(worsened > 0 && improved + worsened <= 1)
    }

    @Test func layerCellsRunWithoutTheLayerAreLeftOut() {
        func run(_ id: String, setup: ControlSetup, overlay: [String]?, version: String? = nil) -> LabRun {
            let spec = RunSpec(id: id, kind: .control, title: "", createdAt: Date(timeIntervalSince1970: Double(id.count)), folder: "/",
                               environment: .background, akit: "/akit", controlTask: "t1", controlSetup: setup)
            let control = ControlOutcome(key: id, passed: true, oracle: "", overlay: overlay, harnessVersion: version)
            return LabRun(folder: URL(filePath: "/"), spec: spec, state: RunState(status: .finished), launch: nil, result: RunResult(control: control))
        }
        let cells = ControlComparison.Cell.of([run("a", setup: layerSetup(.layer), overlay: [], version: "2.1.290"),
                                               run("bb", setup: layerSetup(.layer), overlay: nil),
                                               run("ccc", setup: layerSetup(.requiredOnly), overlay: [], version: "2.1.291"),
                                               run("dddd", setup: baseline, overlay: nil)])
        #expect(cells.map(\.overlayRecorded) == [true, false, true, true])
        let comparison = ControlComparison.compare(cells)
        #expect(comparison.leftOut == 1 && comparison.rows.map(\.cells) == [1, 1, 1])
        // Both versions show on the pair: the eval mixes them.
        #expect(comparison.paired.first?.harnessVersions == ["2.1.290", "2.1.291"])
    }

    @Test func passHatKSitsInsideItsInterval() throws {
        let setup = ControlSetup(name: "baseline", agent: LabAgent(harness: .claudeCode, model: "opus", effort: "low"))
        // Tasks with more cells than k: the unbiased estimate is not the share of all-pass tasks.
        let cells = (0..<6).flatMap { task in (0..<(task % 2 == 0 ? 3 : 5)).map { ControlComparison.Cell(task: "t\(task)", setup: setup, passed: $0 < 3) } }
        let row = try #require(ControlComparison.compare(cells).rows.first)
        let estimate = try #require(row.passHatK)
        #expect(row.passHatKInterval.low <= estimate && estimate <= row.passHatKInterval.high)
    }
}
