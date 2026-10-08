import Foundation
import Testing
import AKitFoundation
import AKitLab
@testable import AKitErrorAnalysis

/// A finished layer eval's verdict, the result lines and `verdicts/<layer>.json`.
struct LayerVerdictsTests {
    let home: URL
    var env: HarnessEnvironment { HarnessEnvironment(homeDirectory: home, variables: ["HOME": home.path]) }
    let opus = LabAgent(harness: .claudeCode, model: "opus", effort: "high")
    /// Noon UTC, so the eval's date is the same day in any time zone of the tests.
    let created = Date(timeIntervalSince1970: 1_791_806_400)

    init() throws {
        home = FileManager.default.temporaryDirectory.appending(path: "akit-layerverdicts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    func setup(_ role: LayerVariant.Role, eval: String = "swiftui-1", agent: LabAgent? = nil, readOnly: Bool = false) -> ControlSetup {
        ControlSetup(name: readOnly ? "read-only" : role == .layer ? "layer swiftui" : "without swiftui", agent: agent ?? opus, readOnly: readOnly,
                     layer: LayerVariant(layer: "swiftui", role: role, overlayHash: role == .layer ? "layerhash" : nil, evalID: eval,
                                         brainCommit: "a1b2c3d4e5"))
    }

    func manifest(_ id: String = "swiftui-1", agent: LabAgent? = nil, created: Date? = nil) -> LayerEvalManifest {
        LayerEvalManifest(id: id, layer: "swiftui", createdAt: created ?? self.created, brainCommit: "a1b2c3d4e5",
                          setups: [setup(.requiredOnly, eval: id, agent: agent), setup(.layer, eval: id, agent: agent)],
                          sanity: setup(.requiredOnly, eval: id, agent: agent, readOnly: true), tasks: (0..<5).map { "t\($0)" },
                          sanityTasks: ["t0", "t1", "t2"], repeats: 3, blocked: ["t9": "The project has its own .claude/skills folder."],
                          notes: [:], overlap: [], ownFiles: ["t0": "CLAUDE.md", "t1": "CLAUDE.md"])
    }

    /// `passes[t]` of 3 cells of task t pass; the run ids say the setup, task and repeat.
    func runs(_ setup: ControlSetup, passes: [Int], status: RunState.Status = .finished, version: String = "2.1.290") -> [LabRun] {
        passes.enumerated().flatMap { task, passed in
            (0..<3).map { index in
                let id = "\(setup.name)-\(setup.layer?.evalID ?? "")-t\(task)-\(index)"
                let spec = RunSpec(id: id, kind: .control, title: "", createdAt: created.addingTimeInterval(Double(task * 3 + index)), folder: "/",
                                   environment: .background, akit: "/akit", controlTask: "t\(task)", controlSetup: setup)
                let control = ControlOutcome(key: id, passed: index < passed, oracle: "", overlay: [], harnessVersion: version)
                return LabRun(folder: URL(filePath: "/"), spec: spec,
                              state: RunState(status: status, updatedAt: created.addingTimeInterval(3600 + Double(task))), launch: nil,
                              result: status == .finished ? RunResult(control: control) : nil)
            }
        }
    }

    func cost(_ dollars: Double) -> RunCost {
        var cost = RunCost()
        cost.calls = 1
        cost.priced = 1
        cost.usage = SendUsage(cost: dollars)
        return cost
    }

    @Test func noVerdictWhileACellIsQueuedOrRunning() throws {
        let manifest = manifest()
        let done = runs(manifest.setups[0], passes: [1, 1, 1, 1, 1]) + runs(manifest.setups[1], passes: [3, 3, 3, 3, 3])
        #expect(LayerVerdicts.verdict(of: manifest, runs: [], costs: [:]) == nil)
        #expect(LayerVerdicts.verdict(of: manifest, runs: done + runs(manifest.sanity!, passes: [0], status: .queued), costs: [:]) == nil)
        // Another eval's open cells don't hold this one back.
        let other = runs(setup(.layer, eval: "swiftui-2"), passes: [0], status: .queued)
        #expect(LayerVerdicts.verdict(of: manifest, runs: done + other, costs: [:])?.verdict == .helpsOffline)
        // Every cell of one side cancelled: no task to compare, so no verdict to replace a stored one.
        let cancelled = runs(manifest.setups[0], passes: [1, 1, 1, 1, 1], status: .cancelled) + runs(manifest.setups[1], passes: [3, 3, 3, 3, 3])
        #expect(LayerVerdicts.verdict(of: manifest, runs: cancelled, costs: [:]) == nil)
    }

    /// A cell whose transcript listed the wrong skills is left out of the verdict and counted.
    @Test func cellsThatFailedTheSetupCheckAreLeftOut() throws {
        let manifest = manifest()
        func failing(_ runs: [LabRun], where pick: (LabRun) -> Bool) -> [LabRun] {
            runs.map { run in
                guard pick(run), var result = run.result else { return run }
                result.control?.setupCheck = SetupCheckResult(status: .failed, detail: "Claude Code listed swiftui-expert, which this setup must not have")
                return LabRun(folder: run.folder, spec: run.spec, state: run.state, launch: run.launch, result: result)
            }
        }
        // Every baseline cell of t0 "passed", but its setup leaked the layer: left out.
        let baseline = failing(runs(manifest.setups[0], passes: [3, 1, 1, 1, 1, 1])) { $0.spec.controlTask == "t0" }
        let all = baseline + runs(manifest.setups[1], passes: [3, 3, 3, 3, 3, 3]) + runs(manifest.sanity!, passes: [0])
        let verdict = try #require(LayerVerdicts.verdict(of: manifest, runs: all, costs: [:]))
        #expect(verdict.setupCheckFailed == 3 && verdict.leftOut == 0 && verdict.baselineCells == 15 && verdict.tasks == 5)
        #expect(verdict.verdict == .helpsOffline && verdict.baselineRate.map { abs($0 - 1.0 / 3) < 1e-9 } == true)
        #expect(LayerVerdicts.lines(verdict)[2].contains("3 cells failed the setup check, left out"), "\(LayerVerdicts.lines(verdict))")
        // A read-only cell that failed its check doesn't decide the sanity rule either.
        let sanity = failing(runs(manifest.sanity!, passes: [3])) { _ in true }
        let checked = try #require(LayerVerdicts.verdict(of: manifest, runs: baseline + runs(manifest.setups[1], passes: [3, 3, 3, 3, 3, 3]) + sanity,
                                                         costs: [:]))
        #expect(checked.sanity == .none && checked.setupCheckFailed == 6 && checked.verdict == .helpsOffline)
    }

    @Test func aFinishedEvalGetsItsVerdictAndLines() throws {
        let manifest = manifest()
        let all = runs(manifest.setups[0], passes: [1, 1, 1, 1, 1]) + runs(manifest.setups[1], passes: [3, 3, 3, 3, 3])
            + runs(manifest.sanity!, passes: [0], version: "2.1.291")
        let costs = Dictionary(uniqueKeysWithValues: all.map { ($0.id, cost(0.5)) })
        let verdict = try #require(LayerVerdicts.verdict(of: manifest, runs: all, costs: costs))
        #expect(verdict.verdict == .helpsOffline && verdict.tasks == 5 && verdict.baselineCells == 15 && verdict.layerCells == 15)
        #expect(abs(try #require(verdict.baselineRate) - 1.0 / 3) < 1e-9 && verdict.layerRate == 1 && verdict.worseShare == 0)
        #expect(verdict.sanity == .passed && verdict.sanityCells == 3 && verdict.sanityPassed == 0)
        #expect(verdict.overlay == "layerhash" && verdict.baselineOverlay == nil && verdict.blocked == 1 && verdict.projectOwnContext == 2)
        #expect(verdict.cost == 16.5 && verdict.harnessVersions == ["2.1.290", "2.1.291"] && verdict.agent == opus)
        #expect(verdict.decidedAt == created.addingTimeInterval(3604))
        #expect(LayerVerdicts.lines(verdict, calendar: utc) == [
            "swiftui · Claude Code · opus · high · 5 tasks × 3 · eval 2026-10-12 · brain a1b2c3d",
            "success: 33% → 100%, helps (offline) (100% of the bootstrap mass on improvement, 0% on worse; needs 95%)",
            "read-only sanity: 0 of 3 passed · 1 blocked task · Claude Code 2.1.290, 2.1.291 (mixed versions)",
            "home overlap: none · 2 tasks with the project's own CLAUDE.md or AGENTS.md (the project gets the layer's text only by accepting the suggestion) · $16.50",
        ])

        // A read-only cell that passed: no conclusion, and the lines say why.
        let broken = all.filter { !$0.spec.controlSetup!.readOnly } + runs(manifest.sanity!, passes: [1])
        let open = try #require(LayerVerdicts.verdict(of: manifest, runs: broken, costs: [:]))
        #expect(open.verdict == .noConclusion && open.sanity == .failed && open.sanityPassed == 1 && open.cost == nil)
        // Task ids come from prompts: the stored reason names none.
        #expect(open.reason.hasPrefix("A read-only agent passed a task:") && !open.reason.contains("t0"))
        let lines = LayerVerdicts.lines(open, calendar: utc)
        #expect(lines[1].hasPrefix("success: 33% → 100%, no conclusion: A read-only agent passed a task: its oracle"))
        #expect(lines[2].hasPrefix("read-only sanity: 1 of 3 passed"))
        #expect(lines[3] == "home overlap: none · 2 tasks with the project's own CLAUDE.md or AGENTS.md (the project gets the layer's text only by accepting the suggestion)")

        // Too few cells: no conclusion. An eval written before slice 5 has no own-file count.
        var old = manifest
        old.ownFiles = nil
        let few = try #require(LayerVerdicts.verdict(of: old, runs: runs(manifest.setups[0], passes: [1, 1]) + runs(manifest.setups[1], passes: [3, 3]),
                                                     costs: [:]))
        #expect(few.verdict == .noConclusion && few.reason.contains("Fewer than 15 cells") && few.sanity == .none && few.projectOwnContext == nil)
        #expect(LayerVerdicts.lines(few, calendar: utc)[2] == "read-only sanity: not run · 1 blocked task · Claude Code 2.1.290")
    }

    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func verdict(_ eval: String, agent: LabAgent? = nil, created: Date? = nil, layerPasses: [Int] = [3, 3, 3, 3, 3]) throws -> LayerVerdict {
        let manifest = manifest(eval, agent: agent, created: created)
        return try #require(LayerVerdicts.verdict(of: manifest, runs: runs(manifest.setups[0], passes: [1, 1, 1, 1, 1])
                                                  + runs(manifest.setups[1], passes: layerPasses), costs: [:]))
    }

    @Test func savedPerAgentAndOnlyANewerEvalReplacesIt() throws {
        #expect(LayerVerdicts.load(layer: "swiftui", env: env) == nil)
        let first = try verdict("swiftui-1")
        #expect(try LayerVerdicts.save(first, env: env))
        // The same verdict again changes nothing.
        #expect(try !LayerVerdicts.save(first, env: env))
        // Another model is another entry.
        let sonnet = try verdict("swiftui-s", agent: LabAgent(harness: .claudeCode, model: "sonnet", effort: "high"))
        #expect(try LayerVerdicts.save(sonnet, env: env))
        // A newer eval of opus replaces opus's verdict; an older one never does.
        let newer = try verdict("swiftui-2", created: created.addingTimeInterval(86_400), layerPasses: [1, 1, 1, 1, 1])
        #expect(try LayerVerdicts.save(newer, env: env))
        let older = try verdict("swiftui-0", created: created.addingTimeInterval(-86_400))
        #expect(try !LayerVerdicts.save(older, env: env))
        let file = try #require(LayerVerdicts.load(layer: "swiftui", env: env))
        #expect(file.schema == 1 && file.layer == "swiftui" && file.verdicts.map(\.evalID) == ["swiftui-2", "swiftui-s"])
        #expect(file.verdicts[0].verdict == .notShown)
        // Numbers only: no task prompts, no repository paths.
        let text = try String(contentsOf: EvalPaths(env: env).verdict("swiftui"), encoding: .utf8)
        #expect(text.contains("\"verdict\" : \"not-shown\"") && !text.contains("/"))

        // Two evals created in the same second: the larger id is the newer one.
        let sameSecond = try verdict("swiftui-3", created: created.addingTimeInterval(86_400))
        #expect(try LayerVerdicts.save(sameSecond, env: env))
        #expect(try !LayerVerdicts.save(try verdict("swiftui-2", created: created.addingTimeInterval(86_400), layerPasses: [3, 3, 3, 3, 0]), env: env))
        #expect(LayerVerdicts.load(layer: "swiftui", env: env)?.verdicts.first?.evalID == "swiftui-3")
    }

    @Test func aFileThatCantBeReadOrIsAnotherLayersIsNeverReplaced() throws {
        let url = EvalPaths(env: env).verdict("swiftui")
        // A folder where the file should be: it exists but can't be read.
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try LayerVerdicts.save(try verdict("swiftui-1"), env: env) }
        try FileManager.default.removeItem(at: url)
        let other = #"{"schema": 1, "layer": "other", "verdicts": []}"#
        try Data(other.utf8).write(to: url)
        let error = #expect(throws: (any Error).self) { try LayerVerdicts.save(try verdict("swiftui-1"), env: env) }
        #expect(error?.localizedDescription.contains("holds the verdicts of other") == true)
        #expect(try String(contentsOf: url, encoding: .utf8) == other)
    }

    @Test func aNewerAKitsFileIsSkippedAndKept() throws {
        let url = EvalPaths(env: env).verdict("swiftui")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let newer = #"{"schema": 2, "layer": "swiftui", "verdicts": []}"#
        try Data(newer.utf8).write(to: url)
        #expect(LayerVerdicts.load(layer: "swiftui", env: env) == nil)
        let error = #expect(throws: (any Error).self) { try LayerVerdicts.save(try verdict("swiftui-1"), env: env) }
        #expect(error?.localizedDescription.contains("written by a newer AKit") == true)
        #expect(try String(contentsOf: url, encoding: .utf8) == newer)
    }
}
