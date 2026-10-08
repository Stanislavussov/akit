import Foundation
import Testing
import AKitBrain
import AKitFoundation
@testable import AKitLab
@testable import AKitErrorAnalysis

/// `ControlRuns.estimate`: recorded costs per cell and run durations, nothing else.
struct ControlEstimateTests {
    let opus = LabAgent(harness: .claudeCode, model: "opus", effort: "high")
    let start = Date(timeIntervalSince1970: 1_791_806_400)

    func record(_ purpose: String, _ cost: Double?, model: String = "opus", harness: LabHarness = .claudeCode) -> SendRecord {
        SendRecord(purpose: purpose, session: nil, runID: UUID().uuidString,
                   destination: SendDestination(harness: harness, provider: "anthropic", account: "me", org: "me"), model: model,
                   inputCharacters: 10, usage: SendUsage(cost: cost))
    }

    func run(_ kind: RunSpec.Kind, minutes: Double, status: RunState.Status = .finished) -> LabRun {
        let spec = RunSpec(id: UUID().uuidString, kind: kind, title: "", createdAt: start, folder: "/", environment: .background, akit: "/akit")
        return LabRun(folder: URL(filePath: "/"), spec: spec,
                      state: RunState(status: status, startedAt: start, updatedAt: start.addingTimeInterval(minutes * 60)), launch: nil, result: nil)
    }

    @Test func controlRecordsFirstThenReplaysThenNone() {
        let records = [record("control", 0.5), record("control", 1.5), record("control", nil), record("replay", 9),
                       record("control", 7, model: "sonnet"), record("control", 7, harness: .pi), record("review", 7)]
        let estimate = ControlRuns.estimate(cells: 10, agent: opus, records: records, runs: [])
        #expect(estimate.source == .control && estimate.basedOn == 2 && estimate.perCell == 1)
        #expect(estimate.total == 10 && estimate.low == 5 && estimate.high == 15)
        #expect(estimate.costText == "≈ $10.00 (range $5.00–$15.00) from 2 recorded control cells of Claude Code · opus")
        #expect(estimate.line == estimate.costText && estimate.seconds == nil && estimate.timeText == nil)

        let replays = ControlRuns.estimate(cells: 2, agent: opus, records: [record("replay", 2), record("control", 1, model: "sonnet")], runs: [])
        #expect(replays.source == .replay && replays.basedOn == 1 && replays.total == 4 && replays.low == 4 && replays.high == 4)
        #expect(replays.costText.hasSuffix("from 1 recorded replay cell of Claude Code · opus"))

        let none = ControlRuns.estimate(cells: 51, agent: opus, records: [record("control", 1, model: "sonnet")], runs: [])
        #expect(none.source == .none && none.basedOn == 0 && none.perCell == nil && none.total == nil && none.low == nil)
        #expect(none.costText == "no estimate yet (no recorded control or replay cell of Claude Code · opus)")
        #expect(none.line == "No estimate yet: no recorded control or replay cell of Claude Code · opus.")
    }

    @Test func timeFromTheMedianRunDuration() {
        // Control runs: 10, 20, 30 and 40 minutes (median 25); an unfinished one and a replay don't count.
        let runs = [run(.control, minutes: 10), run(.control, minutes: 40), run(.control, minutes: 20), run(.control, minutes: 30),
                    run(.control, minutes: 500, status: .error), run(.replay, minutes: 1)]
        let estimate = ControlRuns.estimate(cells: 4, agent: opus, records: [], runs: runs)
        #expect(estimate.seconds == 100 * 60 && estimate.durations == 4)
        #expect(estimate.timeText == "≈ 1.7 h in the Lab queue (one cell at a time, from 4 recorded run durations)")
        // No finished control run: replays.
        let replays = ControlRuns.estimate(cells: 3, agent: opus, records: [], runs: [run(.replay, minutes: 2), run(.review, minutes: 9)])
        #expect(replays.seconds == 360 && replays.timeText?.hasPrefix("≈ 6 min in the Lab queue") == true)
        #expect(ControlRuns.estimate(cells: 0, agent: opus, records: [], runs: runs).timeText == nil)
    }
}

/// Brain → layer → Evaluate… end to end with the fake `claude` (no tokens): no estimate, one
/// calibration cell, then the estimate and the rest of the same eval. Part of the serialized
/// `ControlRunsTests`: the worker's cancellation state is process-wide.
extension ControlRunsTests {
    func evalPlan(_ fixture: LayerFixture, continuing: String? = nil, denied: [String]? = nil) async throws -> LayerEvals.EvalPlan {
        try await LayerEvals.plan(layer: "swiftui", agent: claude, repeats: 2, sanity: true, continuing: continuing, denied: denied,
                                  homeSkills: [], brain: fixture.brain, store: .local(home: home), projectsRoot: home, env: env)
    }

    func runQueued(_ runs: [LabRun]) async throws -> [LabRun] {
        var done: [LabRun] = []
        for run in runs {
            let output = Output()
            let code = await LabWorker.run(id: run.id, env: env, startNext: false, handleSignals: false, execute: AnalysisRuns.execute,
                                           out: output.add)
            #expect(code == 0, "\(output.lines)")
            done.append(try #require(LabStore.load(run.id, env: env)))
        }
        return done
    }

    func message(_ body: () async throws -> Void) async -> String? {
        do {
            try await body()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    @Test func layerEvalCalibratesThenEstimatesThenQueuesTheSameEval() async throws {
        let fixture = LayerFixture(home: home)
        try fixture.fakeClaude()
        // The fake, not a real Claude Code, is what runs.
        #expect(env.findExecutable("claude")?.path == home.appending(path: "bin/claude").path)
        try await fixture.makeBrain()
        let base = try await fixture.makeRepo()
        let brainHead = await fixture.git("rev-parse", "HEAD", in: fixture.brain)
        #expect(await message { _ = try await evalPlan(fixture) }?.contains("swiftui has no layer set") == true)
        let tasks = ["make-value-2-abcd", "make-value-2-ef01"].map { id in
            ControlTask(id: id, title: "Make value 2", repo: fixture.repo.path, base: base, prompt: "Make value 2 (\(id))",
                        source: .reproduction, oracle: .tests(command: #"test "$(cat value.txt)" = 2"#))
        }
        for task in tasks { try ControlTasks.save(task, env: env) }
        try LayerSets.add(tasks, to: "swiftui", env: env)

        // No recorded cost: no estimate, and only the calibration cell can be queued.
        let first = try await evalPlan(fixture)
        #expect(first.toQueue == 2 * 2 * 2 + 2 && first.skipped == 0 && first.resumable == nil && first.prepared.denied.isEmpty)
        #expect(first.estimate.perCell == nil && first.estimate.cells == 10)
        #expect(await message {
            _ = try await LayerEvals.queue(first, calibrateOnly: false, environment: .background, keep: false, akit: URL(filePath: "/usr/bin/true"), env: env)
        }?.hasPrefix("No estimate yet") == true)
        #expect(LabStore.list(env: env).isEmpty && LayerEvalStore.manifest(first.evalID, env: env) == nil)
        let calibration = try await LayerEvals.queue(first, calibrateOnly: true, environment: .background, keep: false,
                                                     akit: URL(filePath: "/usr/bin/true"), env: env).runs
        #expect(calibration.count == 1 && calibration[0].spec.controlTask == tasks[0].id && calibration[0].spec.repeatIndex == 1)
        #expect(calibration[0].spec.controlSetup == first.prepared.setups[0] && LayerEvalStore.manifest(first.evalID, env: env) != nil)
        // While it waits, a second calibration cell is refused: it would be paid twice.
        let waiting = try await evalPlan(fixture, continuing: first.evalID)
        #expect(await message {
            _ = try await LayerEvals.queue(waiting, calibrateOnly: true, environment: .background, keep: false, akit: URL(filePath: "/usr/bin/true"), env: env)
        }?.contains("is queued or running") == true)
        _ = try await runQueued(calibration)
        #expect(FileManager.default.fileExists(atPath: home.appending(path: "fake-claude-ran").path))

        // The calibration cell recorded its cost: the next Evaluate offers to continue that eval.
        let next = try await evalPlan(fixture)
        let resumable = try #require(next.resumable)
        #expect(next.evalID != first.evalID && resumable.evalID == first.evalID && resumable.calibrating)
        #expect(resumable.finished == 1 && resumable.open == 0 && resumable.total == 10 && resumable.left == 9)
        let continued = try await evalPlan(fixture, continuing: resumable.evalID)
        #expect(continued.prepared.continuing && continued.evalID == first.evalID && continued.toQueue == 9 && continued.skipped == 1)
        #expect(continued.estimate.source == .control && continued.estimate.basedOn == 1 && continued.estimate.cells == 9)
        #expect(continued.estimate.total.map { abs($0 - 0.09) < 1e-9 } == true, "\(continued.estimate)")
        #expect(continued.estimate.seconds != nil && continued.estimate.durations == 1)
        let rest = try await LayerEvals.queue(continued, calibrateOnly: false, environment: .background, keep: false,
                                              akit: URL(filePath: "/usr/bin/true"), env: env)
        #expect(rest.runs.count == 9 && rest.skipped == 1)
        #expect(rest.runs.allSatisfy { $0.spec.controlSetup?.layer?.evalID == first.evalID })
        #expect(ControlRuns.plan(tasks: continued.prepared.runnable, setups: continued.prepared.setups, repeats: 2,
                                 sanity: continued.prepared.sanitySetup.map { ($0, continued.prepared.sanityTasks, 1) }, env: env) == (0, 10))

        // A changed layer can't continue the eval; the brain itself was never written.
        #expect(await fixture.git("rev-parse", "HEAD", in: fixture.brain) == brainHead)
        #expect(await fixture.git("status", "--porcelain", in: fixture.brain) == "")
        try fixture.write("layers/swiftui/templates/swiftui.md", "- LAYER-MARKER changed\n", in: fixture.brain)
        await fixture.commitAll(fixture.brain)
        #expect(await message { _ = try await evalPlan(fixture, continuing: first.evalID) }?.contains("The layer changed since the eval") == true)
        #expect(try await evalPlan(fixture).resumable == nil)
    }

    @Test func akitsOwnRepositoryDeniesTheCommandsThatTouchTheRealHome() async throws {
        let fixture = LayerFixture(home: home)
        try await fixture.makeBrain()
        let base = try await fixture.makeRepo(["AKitCore/Package.swift": "// swift-tools-version: 6.0\n"])
        let task = ControlTask(id: "make-value-2-abcd", title: "Make value 2", repo: fixture.repo.path, base: base, prompt: "Make value 2",
                               source: .reproduction, oracle: .tests(command: "true"))
        try ControlTasks.save(task, env: env)
        try LayerSets.add([task], to: "swiftui", env: env)

        let plan = try await evalPlan(fixture)
        #expect(plan.prepared.denied == ["make snapshot", "make run", "make install"])
        // Both setups and the sanity cells get the same list: the comparison stays fair.
        let setups = plan.prepared.setups + [try #require(plan.prepared.sanitySetup)]
        #expect(setups.allSatisfy { $0.denied == LayerSetups.akitDenied })
        #expect(plan.prepared.setups[0].tools == ["--disallowedTools", "Bash(make snapshot:*)", "Bash(make run:*)", "Bash(make install:*)"])
        #expect(setups[2].tools == ["--tools", "Read,Grep,Glob", "--disallowedTools", "Bash(make snapshot:*)", "Bash(make run:*)",
                                    "Bash(make install:*)"])
        // The list is part of what runs, so of the cell key; a setup without one keeps its key.
        var open = plan.prepared.setups[1]
        open.denied = nil
        #expect(ControlRuns.cellKey(task: task, setup: open, repeatIndex: 1) != ControlRuns.cellKey(task: task, setup: plan.prepared.setups[1], repeatIndex: 1))
        open.denied = []
        #expect(ControlRuns.cellKey(task: task, setup: open, repeatIndex: 1)
                == ControlRuns.cellKey(task: task, setup: { var s = open; s.denied = nil; return s }(), repeatIndex: 1))

        #expect(try await evalPlan(fixture, denied: []).prepared.setups.allSatisfy { $0.denied == nil })
        #expect(try await evalPlan(fixture, denied: ["swift test", " "]).prepared.denied == ["swift test"])
        // Old run.json files without the key still decode.
        let old = try JSONDecoder().decode(ControlSetup.self, from: Data(#"{"name":"b","agent":{"harness":"claude-code","model":"opus","effort":"high"},"readOnly":false}"#.utf8))
        #expect(old.denied == nil && old.tools.isEmpty)
    }
}
