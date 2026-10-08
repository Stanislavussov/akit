import AKitBrain
import AKitErrorAnalysis
import AKitFoundation
import AKitLab
import Foundation

/// `akit analysis control evaluate LAYER`: the layer's set as one eval, with the estimate
/// first (`docs/design/layer-evals.md`, "UI"). Queues nothing without `--yes`.
extension AKitCLI {
    static let analysisEvaluateUsage = """
          akit analysis control evaluate LAYER [--model M] [--effort E] [--repeats N] [--no-sanity]
                              [--continue [ID] | --new] [--deny CMD[,CMD…] | --no-deny] [--brain DIR]
                              [--env orca|herdr|background] [--keep] [--calibrate] [--yes [--max-cost USD]]
                              [--no-start] [--json]
                                          The layer's set as one layer eval (Claude Code only): its
                                          tasks, blocked tasks, home overlap, the cells to queue, ≈ cost
                                          (a range, from the recorded cost of earlier control cells of
                                          the model, else replays) and ≈ time in the Lab queue. --yes
                                          --max-cost USD queues them when the estimate's high end is
                                          at most USD, after the monthly limit check. With no recorded
                                          cost there is no estimate: --calibrate --yes queues 1 paid cell
                                          to measure it, and the eval reuses it (an eval whose setups
                                          don't all have a finished cell yet is continued by default;
                                          --new starts another). --continue continues the latest eval of
                                          the layer and agent (or ID) while the layer renders the same
                                          files. 1 read-only cell on each of the first 3 tasks unless
                                          --no-sanity. In AKit's own repository the agent may not run
                                          make snapshot, make run, make restart, make install(-cli),
                                          make screenshots, make open or open (every setup); --deny
                                          sets other commands, --no-deny none
        """

    struct LayerEvaluateReport: Encodable {
        struct Estimate: Encodable {
            let cells: Int
            let perCell: Double?
            let total: Double?
            let low: Double?
            let high: Double?
            let basedOn: Int
            let source: String
            let seconds: Int?
        }
        let eval: String
        let layer: String
        let continuing: Bool
        let brainCommit: String
        let tasks: [String]
        let missing: [String]
        let blocked: [String: String]
        let overlap: [String]
        let denied: [String]
        let repeats: Int
        let toQueue: Int
        let skipped: Int
        let estimate: Estimate
        /// The eval it could continue instead (`--continue`).
        let continuable: String?
        let queued: Int
    }

    /// `--harness`, `--model`, `--effort` and `--yes` were taken out of `args` by `akit analysis`.
    static func evaluateLayer(_ args: inout Arguments, options: AnalysisOptions, env: HarnessEnvironment, cwd: URL, projectsRoot: URL,
                              out: (String) -> Void) async throws -> Int32 {
        guard let layer = args.positional() else { throw Failure(message: "Which layer? akit analysis control evaluate LAYER.") }
        let continueID = args.value("--continue")
        let continueLatest = args.flag("--continue")
        let fresh = args.flag("--new")
        let repeatsText = args.value("--repeats")
        let environmentText = args.value("--env")
        let brainText = args.value("--brain")
        let denyText = args.value("--deny")
        let noDeny = args.flag("--no-deny")
        let noSanity = args.flag("--no-sanity")
        let keep = args.flag("--keep")
        let calibrate = args.flag("--calibrate")
        let maxCost = args.value("--max-cost")
        let noStart = args.flag("--no-start")
        try args.finish()
        guard !fresh || (continueID == nil && !continueLatest) else { throw Failure(message: "--new starts another eval; leave out --continue.") }
        guard denyText == nil || !noDeny else { throw Failure(message: "Give --deny or --no-deny, not both.") }
        guard options.harness == nil || options.harness == LabHarness.claudeCode.rawValue else {
            throw Failure(message: "Layer evals run Claude Code only for now; leave out --harness.")
        }
        var agent = LabRuns.defaultAgent(.claudeCode, env: env)
        if let model = options.model { agent.model = model }
        if let effort = options.effort { agent.effort = effort }
        guard LabHarness.claudeCode.efforts.contains(agent.effort) else {
            throw Failure(message: "--effort for Claude Code is one of \(LabHarness.claudeCode.efforts.joined(separator: ", ")).")
        }
        guard !agent.model.isEmpty else { throw Failure(message: "Which model? --model.") }
        let repeats = try positiveNumber(repeatsText, "--repeats") ?? 3
        let environment = try labEnvironment(environmentText, env: env)
        let denied: [String]? = noDeny ? [] : denyText.map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        if let denied, let problem = ControlSetup.deniedProblem(denied) { throw Failure(message: problem) }
        let brainRoot = brainText.map { resolve($0, cwd: cwd, env: env) } ?? Brain.defaultRoot(home: env.homeDirectory)
        guard Brain.load(from: brainRoot) != nil else {
            throw Failure(message: "No brain repo at \(brainRoot.path). Create it in AKit (Brain → Create Brain Repo) or pass --brain.")
        }
        let homeSkills = claudeHomeSkills(env: env)
        let store = ProjectStore.current(brain: brainRoot, home: env.homeDirectory)
        func makePlan(_ continuing: String?) async throws -> LayerEvals.EvalPlan {
            do {
                return try await LayerEvals.plan(layer: layer, agent: agent, repeats: repeats, sanity: !noSanity, continuing: continuing,
                                                 denied: denied, homeSkills: homeSkills, brain: brainRoot, store: store,
                                                 projectsRoot: projectsRoot, env: env)
            } catch {
                throw Failure(message: error.localizedDescription)
            }
        }

        // Which eval: --continue [ID], --new, else the latest one while not every setup has a
        // finished cell (its calibration cell is reused).
        var plan = try await makePlan(continueID)
        if continueID == nil, let resumable = plan.resumable {
            if continueLatest {
                plan = try await makePlan(resumable.evalID)
            } else if !fresh, resumable.calibrating {
                out("Continuing the eval \(resumable.evalID): not every setup has a finished cell yet, so its cells are reused (--new starts another eval).")
                plan = try await makePlan(resumable.evalID)
            }
        } else if continueLatest, continueID == nil {
            throw Failure(message: "No eval of \(layer) with \(agent.harness.title) · \(agent.model) · \(agent.effort) that renders the same files to continue.")
        }
        if plan.prepared.continuing, repeatsText != nil, repeats != plan.repeats {
            throw Failure(message: "The eval \(plan.evalID) runs \(plan.repeats) repeats; leave out --repeats, or give --repeats \(plan.repeats).")
        }

        let prepared = plan.prepared
        if options.json {
            var queued = 0
            if options.yes, plan.toQueue > 0 || calibrate {
                let allowed = calibrate ? nil : try maxCostAllowing(maxCost, plan.estimate)
                queued = try await queueEval(plan, calibrate: calibrate, maxCost: allowed, environment: environment, keep: keep, noStart: noStart,
                                             env: env, out: { _ in })
            }
            let estimate = plan.estimate
            out(try labJSON(LayerEvaluateReport(
                eval: plan.evalID, layer: layer, continuing: prepared.continuing, brainCommit: prepared.brainCommit,
                tasks: prepared.runnable.map(\.id), missing: plan.missing, blocked: prepared.blocked, overlap: prepared.overlap,
                denied: prepared.denied, repeats: plan.repeats, toQueue: plan.toQueue, skipped: plan.skipped,
                estimate: .init(cells: estimate.cells, perCell: estimate.perCell, total: estimate.total, low: estimate.low, high: estimate.high,
                                basedOn: estimate.basedOn, source: estimate.source.rawValue, seconds: estimate.seconds),
                continuable: plan.resumable?.evalID, queued: queued)))
            return 0
        }

        for line in planLines(plan) { out(line) }
        for (id, reason) in prepared.blocked.sorted(by: { $0.key < $1.key }) { out("Blocked \(id): \(reason)") }
        for (id, notes) in prepared.notes.sorted(by: { $0.key < $1.key }) { notes.forEach { out("Note \(id): \($0)") } }
        prepared.warnings.forEach { out("Warning: \($0)") }
        if let resumable = plan.resumable {
            out("The eval \(resumable.evalID) renders the same files: \(resumable.finished) of \(resumable.total) cells done"
                + (resumable.open > 0 ? ", \(resumable.open) queued or running" : "") + "; --continue continues it.")
        }
        guard !prepared.runnable.isEmpty else { throw Failure(message: "No task of the set can take the layer; see the blocked tasks above.") }
        guard options.yes else {
            if calibrate || (plan.toQueue > 0 && plan.estimate.perCell == nil) {
                out("No paid cell is queued without --yes. Run it again with --calibrate --yes to queue 1 cell that measures the cost; the eval reuses it.")
            } else {
                out("Run it again with --yes --max-cost USD to queue them (USD: the most you allow).")
            }
            return 0
        }
        guard plan.toQueue > 0 || calibrate else {
            out("Nothing to queue. Skipped \(plan.skipped) cells already done or queued.")
            return 0
        }
        if calibrate {
            if let low = plan.estimate.low, let high = plan.estimate.high, plan.estimate.cells > 0 {
                out(String(format: "The calibration cell is expected to cost $%.2f–$%.2f.", low / Double(plan.estimate.cells),
                           high / Double(plan.estimate.cells)))
            }
        } else if plan.estimate.perCell != nil {
            _ = try maxCostAllowing(maxCost, plan.estimate)
        }
        let allowed = calibrate ? nil : Double(maxCost ?? "")
        _ = try await queueEval(plan, calibrate: calibrate, maxCost: allowed, environment: environment, keep: keep, noStart: noStart, env: env,
                                out: out)
        return 0
    }

    /// The plan as the Evaluate sheet shows it.
    static func planLines(_ plan: LayerEvals.EvalPlan) -> [String] {
        let prepared = plan.prepared
        let repository = prepared.runnable.first.map { $0.mainFolder.lastPathComponent }
        var lines = ["Eval \(plan.evalID)\(prepared.continuing ? " (continued)" : "") · brain \(prepared.brainCommit.prefix(7))"]
        lines.append("  Set: \(plan.set.tasks.count) tasks (\(plan.missing.count) missing, \(prepared.blocked.count) blocked)"
                     + (repository.map { " · repository \($0)" } ?? ""))
        var setups = prepared.setups.map { setup in
            "\(setup.layer?.title ?? setup.name) (overlay \(setup.layer?.overlayHash.map { String($0.prefix(12)) } ?? "none"))"
        }
        if prepared.sanitySetup != nil { setups.append("read-only sanity (\(prepared.sanityTasks.count) cells)") }
        lines.append("  Setups: " + setups.joined(separator: " · "))
        if let agent = plan.agent {
            lines.append("  Agent: \(agent.harness.title) · \(agent.model) · \(agent.effort) · \(plan.repeats) repeats")
        }
        lines.append("  The agent may not run: " + (prepared.denied.isEmpty ? "no extra commands (git push never)" : prepared.denied.joined(separator: ", ")))
        lines.append("  \(plan.toQueue) cells to run (\(plan.skipped) already done or queued)")
        let estimate = plan.estimate
        lines.append("  " + estimate.line)
        if let time = estimate.timeText { lines.append("  \(time)") }
        lines.append("  Home overlap: " + (prepared.overlap.isEmpty ? "none" : prepared.overlap.joined(separator: " ")))
        return lines
    }

    /// Queues the eval, or its one calibration cell; returns how many cells were queued.
    private static func queueEval(_ plan: LayerEvals.EvalPlan, calibrate: Bool, maxCost: Double?, environment: LabEnvironment?, keep: Bool,
                                  noStart: Bool, env: HarnessEnvironment, out: (String) -> Void) async throws -> Int {
        let queued: (runs: [LabRun], skipped: Int)
        do {
            queued = try await LayerEvals.queue(plan, calibrateOnly: calibrate, maxCost: maxCost, environment: environment, keep: keep, akit: ownExecutable, env: env)
        } catch {
            throw Failure(message: error.localizedDescription)
        }
        guard let first = queued.runs.first else {
            out("Nothing to queue. Skipped \(queued.skipped) cells already done or queued.")
            return 0
        }
        if calibrate {
            out("Queued 1 calibration cell of eval \(plan.evalID): \(first.spec.controlSetup?.label ?? "") on \(first.spec.controlTask ?? "")"
                + " (\(first.spec.environment.title)). When it finishes, evaluate \(plan.layer) shows the estimate and continues this eval.")
        } else {
            let skipped = queued.skipped > 0 ? " Skipped \(queued.skipped) cells already done or queued." : ""
            out("Queued \(queued.runs.count) cells of eval \(plan.evalID) (\(first.spec.environment.title)).\(skipped)")
        }
        if !noStart { try await startNext(env: env, out: out) }
        return queued.runs.count
    }
}
