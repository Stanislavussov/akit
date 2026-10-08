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

    /// Layer cells: per setup once both setups recorded a cost, since the layer's text makes its
    /// cells cost more; else every control cell of the model, with a note why.
    @Test func layerCellsPerSetupOnceEachSetupHasARecord() {
        func setup(_ role: LayerVariant.Role, readOnly: Bool = false, overlay: String? = "h-base", eval: String = "e1") -> ControlSetup {
            ControlSetup(name: role.rawValue, agent: opus, readOnly: readOnly,
                         layer: LayerVariant(layer: "swiftui", role: role, overlayHash: role == .layer ? "h-layer" : overlay, evalID: eval,
                                             brainCommit: "abc"))
        }
        func cell(_ setup: ControlSetup) -> LabRun {
            let spec = RunSpec(id: UUID().uuidString, kind: .control, title: "", createdAt: start, folder: "/", environment: .background,
                               akit: "/akit", controlSetup: setup)
            return LabRun(folder: URL(filePath: "/"), spec: spec, state: nil, launch: nil, result: nil)
        }
        func record(_ run: LabRun, _ cost: Double) -> SendRecord {
            var record = self.record("control", cost)
            record.runID = run.id
            return record
        }
        let base = cell(setup(.requiredOnly)), layer = cell(setup(.layer, eval: "e0")), other = cell(setup(.requiredOnly, overlay: "h-other"))
        let cells = [setup(.requiredOnly), setup(.layer), setup(.requiredOnly), setup(.layer), setup(.requiredOnly, readOnly: true)]

        // Only the baseline recorded one: every control cell of the model, and why.
        let half = ControlRuns.estimate(setups: cells, agent: opus, records: [record(base, 1), record(other, 3)], runs: [base, other])
        #expect(half.source == .control && half.basedOn == 2 && half.total == 10 && half.parts.isEmpty)
        #expect(half.costText.hasSuffix("from 2 recorded control cells of Claude Code · opus (not per setup: the layer setup has no recorded cell yet)"))
        // Both: per setup (another eval's cell with the same overlay counts); read-only cells cost as the baseline's.
        let both = ControlRuns.estimate(setups: cells, agent: opus, records: [record(base, 1), record(base, 2), record(layer, 4), record(other, 9)],
                                        runs: [base, layer, other])
        #expect(both.source == .setups && both.basedOn == 3 && both.parts.map(\.cells) == [2, 2, 1])
        #expect(both.total == 12.5 && both.low == 11 && both.high == 14)
        let text = "≈ $12.50 (range $11.00–$14.00) from the recorded cells of each setup (Claude Code · opus): without swiftui "
            + "2 × $1.50 (2 recorded), layer swiftui 2 × $4.00 (1 recorded), read-only 1 × $1.50 (0 recorded)"
        #expect(both.costText == text)
        // Cells without a layer: as before.
        #expect(ControlRuns.estimate(setups: [ControlSetup(name: "baseline", agent: opus)], agent: opus, records: [record(base, 1)], runs: [base])
                    .source == .control)
        #expect(ControlRuns.estimate(setups: cells, agent: opus, records: [], runs: []).note == nil)
    }

    @Test func durationsOfTheRepositoryFirst() {
        func run(_ minutes: Double, repo: String) -> LabRun {
            let spec = RunSpec(id: UUID().uuidString, kind: .control, title: "", createdAt: start, folder: repo, environment: .background,
                               akit: "/akit", repo: repo)
            return LabRun(folder: URL(filePath: "/"), spec: spec,
                          state: RunState(status: .finished, startedAt: start, updatedAt: start.addingTimeInterval(minutes * 60)), launch: nil, result: nil)
        }
        let runs = [run(10, repo: "/r/akit"), run(50, repo: "/r/other"), run(60, repo: "/r/other")]
        let here = ControlRuns.estimate(cells: 1, agent: opus, repo: URL(filePath: "/r/akit"), records: [], runs: runs)
        #expect(here.seconds == 600 && here.timeText?.hasSuffix("median of 1 control run of this repository)") == true)
        let elsewhere = ControlRuns.estimate(cells: 1, agent: opus, repo: URL(filePath: "/r/new"), records: [], runs: runs)
        #expect(elsewhere.seconds == 3000 && elsewhere.timeText?.hasSuffix("median of 3 control runs of other repositories)") == true)
    }

    @Test func aMonthlyLimitWithAnUnreadableLogRefuses() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "akit-estimate-\(UUID().uuidString)")
        let env = HarnessEnvironment(homeDirectory: home, variables: ["HOME": home.path])
        // A folder where the log should be: it exists, but can't be read as a file.
        try FileManager.default.createDirectory(at: SendLog.file(env: env), withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try SendLog.checkLimit(estimate: 1, settings: LabSettings(monthlyLimit: 100), env: env) }
        try SendLog.checkLimit(estimate: 1, settings: LabSettings(), env: env)
    }

    @Test func timeFromTheMedianRunDuration() {
        // Control runs: 10, 20, 30 and 40 minutes (median 25); an unfinished one and a replay don't count.
        let runs = [run(.control, minutes: 10), run(.control, minutes: 40), run(.control, minutes: 20), run(.control, minutes: 30),
                    run(.control, minutes: 500, status: .error), run(.replay, minutes: 1)]
        let estimate = ControlRuns.estimate(cells: 4, agent: opus, records: [], runs: runs)
        #expect(estimate.seconds == 100 * 60 && estimate.durations == 4)
        #expect(estimate.timeText == "≈ 1.7 h in the Lab queue (one cell at a time, median of 4 control runs)")
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

    /// The arguments the fake `claude` got in a cell: exactly one `--disallowedTools` flag, and its values.
    func disallowed(_ run: LabRun) throws -> [String] {
        let args = try String(contentsOf: home.appending(path: "args-\(run.spec.sessionID).txt"), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(args.filter { $0 == "--disallowedTools" }.count == 1, "\(args)")
        guard let flag = args.firstIndex(of: "--disallowedTools") else { return [] }
        return Array(args[(flag + 1)...].prefix { !$0.hasPrefix("--") })
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
        func queue(_ plan: LayerEvals.EvalPlan, calibrate: Bool, maxCost: Double? = nil) async throws -> (runs: [LabRun], skipped: Int) {
            try await LayerEvals.queue(plan, calibrateOnly: calibrate, maxCost: maxCost, environment: .background, keep: false,
                                       akit: URL(filePath: "/usr/bin/true"), env: env)
        }

        // No recorded cost: no estimate, and only the calibration cells can be queued: one of each setup.
        let first = try await evalPlan(fixture)
        #expect(first.toQueue == 2 * 2 * 2 + 2 && first.skipped == 0 && first.resumable == nil && first.prepared.denied.isEmpty)
        #expect(first.estimate.perCell == nil && first.estimate.cells == 10 && first.calibration == 2)
        #expect(await message { _ = try await queue(first, calibrate: false) }?.hasPrefix("No estimate yet") == true)
        #expect(LabStore.list(env: env).isEmpty && LayerEvalStore.manifest(first.evalID, env: env) == nil)
        let calibration = try await queue(first, calibrate: true).runs
        #expect(calibration.count == 2 && calibration.allSatisfy { $0.spec.controlTask == tasks[0].id && $0.spec.repeatIndex == 1 })
        #expect(calibration.map(\.spec.controlSetup) == first.prepared.setups && LayerEvalStore.manifest(first.evalID, env: env) != nil)
        // While they wait, more calibration cells are refused: a setup would be paid twice.
        let waiting = try await evalPlan(fixture, continuing: first.evalID)
        #expect(waiting.toQueue == 8 && waiting.calibration == 0)
        #expect(await message { _ = try await queue(waiting, calibrate: true) }?.contains("no calibration cell is left to run") == true)
        // The layer's cell is dropped after the plan: queueing now would run more cells than the plan said.
        try await LabStore.cancel(calibration[1], env: env)
        #expect(await message { _ = try await queue(waiting, calibrate: false) }?.contains("The eval changed since the estimate") == true)
        #expect(await message { _ = try await queue(waiting, calibrate: true) }?.contains("1 calibration cells now, not 0") == true)
        // Only the setup without a cell calibrates, on the same task and repeat as the other.
        let missing = try await evalPlan(fixture, continuing: first.evalID)
        #expect(missing.calibration == 1)
        let again = try await queue(missing, calibrate: true).runs
        #expect(again.count == 1 && again[0].spec.controlTask == tasks[0].id && again[0].spec.repeatIndex == 1)
        #expect(again[0].spec.controlSetup == first.prepared.setups[1])
        _ = try await runQueued([calibration[0], again[0]])
        #expect(FileManager.default.fileExists(atPath: home.appending(path: "fake-claude-ran").path))
        // One --disallowedTools flag: only the push rule outside AKit's own repository.
        #expect(try disallowed(again[0]) == ["Bash(git push:*)"])

        // Both setups recorded their cost: the next Evaluate offers to continue that eval, estimated per setup.
        let next = try await evalPlan(fixture)
        let resumable = try #require(next.resumable)
        #expect(next.evalID != first.evalID && resumable.evalID == first.evalID && !resumable.calibrating)
        #expect(resumable.finished == 2 && resumable.open == 0 && resumable.total == 10 && resumable.left == 8)
        let continued = try await evalPlan(fixture, continuing: resumable.evalID)
        #expect(continued.prepared.continuing && continued.evalID == first.evalID && continued.toQueue == 8 && continued.skipped == 2)
        #expect(continued.estimate.source == .setups && continued.estimate.basedOn == 2 && continued.estimate.cells == 8)
        #expect(continued.estimate.parts.map(\.label) == ["without swiftui", "layer swiftui", "read-only"])
        #expect(continued.estimate.parts.map(\.cells) == [3, 3, 2] && continued.estimate.parts.map(\.basedOn) == [1, 1, 0])
        #expect(continued.estimate.total.map { abs($0 - 0.08) < 1e-9 } == true, "\(continued.estimate)")
        #expect(continued.estimate.seconds != nil && continued.estimate.durations == 2)
        #expect(continued.estimate.timeText?.hasSuffix("median of 2 control runs of this repository)") == true, "\(continued.estimate)")
        // More than the user allowed: refused, nothing queued.
        #expect(await message { _ = try await queue(continued, calibrate: false, maxCost: 0.05) }?.contains("A cell recorded a higher cost since the estimate") == true)
        let rest = try await queue(continued, calibrate: false, maxCost: 0.1)
        #expect(rest.runs.count == 8 && rest.skipped == 2)
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

    /// The setup check, end to end with the fake `claude`: a layer skill in the home folder
    /// stops the queue and a baseline cell before its agent; a listing that names it after the
    /// agent leaves the cell out of the comparison and the verdict.
    @Test func everyLayerCellIsCheckedBeforeAndAfterItsAgent() async throws {
        let fixture = LayerFixture(home: home)
        try fixture.fakeClaude()
        #expect(env.findExecutable("claude")?.path == home.appending(path: "bin/claude").path)
        try await fixture.makeBrain()
        let base = try await fixture.makeRepo()
        let task = ControlTask(id: "make-value-2-abcd", title: "Make value 2", repo: fixture.repo.path, base: base, prompt: "Make value 2",
                               source: .reproduction, oracle: .tests(command: #"test "$(cat value.txt)" = 2"#))
        try ControlTasks.save(task, env: env)
        try LayerSets.add([task], to: "swiftui", env: env)
        func calibrate(_ plan: LayerEvals.EvalPlan) async throws -> [LabRun] {
            try await LayerEvals.queue(plan, calibrateOnly: true, environment: .background, keep: false, akit: URL(filePath: "/usr/bin/true"),
                                       env: env).runs
        }
        let homeSkill = home.appending(path: ".claude/skills/swiftui-expert")
        func plantHomeSkill() throws { try fixture.write(".claude/skills/swiftui-expert/SKILL.md", "---\nname: swiftui-expert\n---\n", in: home) }

        // The checks come from the render and go into the manifest.
        let first = try await evalPlan(fixture)
        let checks = first.prepared.checks
        #expect(checks.baseline.absentSkills == ["swiftui-expert"] && checks.layer.skills.map(\.name) == ["swiftui-expert"])
        #expect(checks.baseline.absentTexts.map(\.text) == ["- LAYER-MARKER: check with make snapshot"] && checks.layer.texts == checks.baseline.absentTexts)

        // A skill of the layer in the home folder reaches every baseline cell: shown, and nothing is queued.
        try plantHomeSkill()
        let warned = try await evalPlan(fixture)
        let problem = "The setup without swiftui would see what it must not: \(homeSkill.path) holds the skill swiftui-expert, which this setup must not have"
        #expect(warned.prepared.warnings.contains { $0.hasPrefix(problem) }, "\(warned.prepared.warnings)")
        #expect(await message { _ = try await calibrate(warned) }?.hasPrefix(problem) == true)
        #expect(LabStore.list(env: env).isEmpty)
        try FileManager.default.removeItem(at: homeSkill)

        // Queued while the home folder was clean; the skill shows up before the cell runs: the
        // baseline cell stops before its agent, the layer cell (which may have it) runs.
        let pair = try await calibrate(try await evalPlan(fixture))
        let evalID = try #require(pair.first?.spec.controlSetup?.layer?.evalID)
        #expect(pair.count == 2 && LayerEvalStore.manifest(evalID, env: env)?.checks == checks)
        try plantHomeSkill()
        let output = Output()
        let code = await LabWorker.run(id: pair[0].id, env: env, startNext: false, handleSignals: false, execute: AnalysisRuns.execute,
                                       out: output.add)
        let stopped = try #require(LabStore.load(pair[0].id, env: env))
        #expect(code != 0 && stopped.status != .finished && !FileManager.default.fileExists(atPath: home.appending(path: "fake-claude-ran").path))
        #expect(output.lines.contains { $0.contains("Setup check failed for without swiftui@") && $0.contains("\(homeSkill.path) holds the skill swiftui-expert")
            && $0.contains("the agent didn't start and the cell doesn't count") }, "\(output.lines)")
        let layerCell = try #require(try await runQueued([pair[1]]).first)
        #expect(layerCell.result?.control?.setupCheck?.status == .passed, "\(String(describing: layerCell.result?.control))")
        try FileManager.default.removeItem(at: homeSkill)

        // After the agent, its listing names the layer's skill (from a place the check before
        // couldn't see): the cell finishes, but it is left out and counted.
        try "swiftui-expert\n".write(to: home.appending(path: "also-listed.txt"), atomically: true, encoding: .utf8)
        let again = try await calibrate(try await evalPlan(fixture, continuing: evalID))
        #expect(again.count == 1 && again[0].spec.controlSetup?.layer?.role == .requiredOnly)
        let leaked = try #require(try await runQueued(again).first)
        let check = try #require(leaked.result?.control?.setupCheck)
        #expect(check.status == .failed && check.detail == "Claude Code listed swiftui-expert, which this setup must not have")
        let comparison = ControlComparison.compare(ControlComparison.Cell.of([leaked, layerCell]))
        #expect(comparison.setupCheckFailed == 1 && comparison.leftOut == 0 && comparison.rows.map(\.setup.layer?.role) == [.layer])
    }

    @Test func akitsOwnRepositoryDeniesTheCommandsThatTouchTheRealHome() async throws {
        let fixture = LayerFixture(home: home)
        try fixture.fakeClaude()
        #expect(env.findExecutable("claude")?.path == home.appending(path: "bin/claude").path)
        try await fixture.makeBrain()
        let base = try await fixture.makeRepo(["AKitCore/Package.swift": "// swift-tools-version: 6.0\n"])
        var task = ControlTask(id: "make-value-2-abcd", title: "Make value 2", repo: fixture.repo.path, base: base, prompt: "Make value 2",
                               source: .reproduction, oracle: .tests(command: "true"))
        try ControlTasks.save(task, env: env)
        try LayerSets.add([task], to: "swiftui", env: env)

        let plan = try await evalPlan(fixture)
        #expect(plan.prepared.denied == ControlSetup.akitDenied && ControlSetup.akitDenied.contains("open"))
        // Both setups and the sanity cells get the same list: the comparison stays fair.
        let setups = plan.prepared.setups + [try #require(plan.prepared.sanitySetup)]
        #expect(setups.allSatisfy { $0.denied == ControlSetup.akitDenied })
        // They go into the run's one --disallowedTools flag, not a second one.
        #expect(plan.prepared.setups[0].tools.isEmpty && setups[2].tools == ["--tools", "Read,Grep,Glob"])
        let spec = RunSpec(id: "x", kind: .control, title: "t", folder: "/", environment: .background, akit: "/a", agent: claude)
        let args = AgentRun.arguments(prompt: "Do it", spec: spec, extra: setups[2].tools,
                                      denied: ControlSetup.disallowedTools(setups[2].denied ?? []))
        #expect(args.filter { $0 == "--disallowedTools" }.count == 1)
        // The list is part of what runs, so of the cell key; a setup without one keeps its key.
        var open = plan.prepared.setups[1]
        open.denied = nil
        #expect(ControlRuns.cellKey(task: task, setup: open, repeatIndex: 1) != ControlRuns.cellKey(task: task, setup: plan.prepared.setups[1], repeatIndex: 1))
        open.denied = []
        #expect(ControlRuns.cellKey(task: task, setup: open, repeatIndex: 1)
                == ControlRuns.cellKey(task: task, setup: { var s = open; s.denied = nil; return s }(), repeatIndex: 1))
        // A plain setup naming none gets the repository's default when its cells are queued.
        #expect(ControlRuns.order(tasks: [task], setups: [ControlSetup(name: "baseline", agent: claude)], repeats: 1, sanity: nil)
                    .allSatisfy { $0.setup.denied == ControlSetup.akitDenied })

        #expect(try await evalPlan(fixture, denied: ["swift test", " "]).prepared.denied == ["swift test"])
        for bad in ["Bash(make run:*)", "make *", "rm (x)"] {
            #expect(await message { _ = try await evalPlan(fixture, denied: [bad]) }?.contains("isn't a command prefix") == true)
        }
        // Old run.json files without the key still decode.
        let old = try JSONDecoder().decode(ControlSetup.self, from: Data(#"{"name":"b","agent":{"harness":"claude-code","model":"opus","effort":"high"},"readOnly":false}"#.utf8))
        #expect(old.denied == nil && old.tools.isEmpty)

        func calibrate(_ plan: LayerEvals.EvalPlan) async throws -> [LabRun] {
            try await LayerEvals.queue(plan, calibrateOnly: true, environment: .background, keep: false, akit: URL(filePath: "/usr/bin/true"),
                                       env: env).runs
        }
        // A new eval whose cells can't be queued leaves no folder behind.
        task.referenceGreen = false
        try ControlTasks.save(task, env: env)
        let red = try await evalPlan(fixture)
        #expect(await message { _ = try await calibrate(red) }?.contains("fail on its reference commit") == true)
        #expect(LayerEvalStore.manifest(red.evalID, env: env) == nil
                && !FileManager.default.fileExists(atPath: EvalPaths(env: env).layerEval(red.evalID).path))
        #expect(!FileManager.default.fileExists(atPath: EvalPaths(env: env).layerEvals.appending(path: ".\(red.evalID).lock").path))
        task.referenceGreen = nil
        try ControlTasks.save(task, env: env)

        // An eval that denies nothing here is continued only with a warning.
        let none = try await evalPlan(fixture, denied: [])
        #expect(none.prepared.setups.allSatisfy { $0.denied == [] })
        let unguarded = try await calibrate(none)
        try await LabStore.cancel(unguarded[0], env: env)
        #expect(try await evalPlan(fixture, continuing: none.evalID).prepared.warnings.contains { $0.contains("denies no commands") })

        // End to end: the cell's agent got one flag with the push rule and every denied command.
        let guarded = try await calibrate(try await evalPlan(fixture, continuing: nil))
        _ = try await runQueued(guarded)
        #expect(try disallowed(guarded[0]) == ["Bash(git push:*)"] + ControlSetup.disallowedTools(ControlSetup.akitDenied))

        // A cell an older version queued names no denied commands: it gets the default when it runs.
        let older = try LabStore.create(RunSpec(id: RunSpec.newID(at: .now), kind: .control, title: "older", folder: task.cloneSource.path,
                                                environment: .background, akit: "/usr/bin/true", agent: claude, repo: task.repo,
                                                repeatIndex: 1, repeats: 1, keep: false, controlTask: task.id,
                                                controlSetup: ControlSetup(name: "baseline", agent: claude)), env: env)
        #expect(older.spec.controlSetup?.denied == nil)
        _ = try await runQueued([older])
        #expect(try disallowed(older).contains("Bash(swift run:*)") && ControlSetup.akitDenied.contains("swift run"))
    }

    /// Every Makefile target of AKit that installs AKit or starts it (or another app) is
    /// denied in AKit's own repository.
    @Test func everyMakefileTargetThatLaunchesOrInstallsIsDenied() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let makefile = try String(contentsOf: root.appending(path: "Makefile"), encoding: .utf8)
        var recipes: [String: String] = [:]
        var target: String?
        for line in makefile.split(separator: "\n", omittingEmptySubsequences: false) {
            if let match = line.firstMatch(of: /^([a-z][a-z-]*):/) {
                target = String(match.1)
                recipes[String(match.1), default: ""] = ""
            } else if line.hasPrefix("\t"), let target {
                recipes[target, default: ""] += line + "\n"
            }
        }
        #expect(recipes.count > 5, "\(recipes.keys)")
        let launches = recipes.filter { name, recipe in
            name.firstMatch(of: /^(run|restart|snapshot|install.*|screenshots|open)$/) != nil
                || ["open ", "MacOS/AKit", "/Applications", ".local/bin", "screenshots.sh", "pkill"].contains { recipe.contains($0) }
        }.keys.sorted()
        #expect(Set(launches) == ["install", "install-cli", "open", "restart", "run", "screenshots", "snapshot"], "\(launches)")
        for name in launches { #expect(ControlSetup.akitDenied.contains("make \(name)"), "make \(name)") }
    }
}
