import AKitBrain
import AKitFoundation
import AKitLab
import Foundation

/// Brain → layer → Evaluate… and `akit analysis control evaluate`
/// (`docs/design/layer-evals.md`, "UI"): the layer's set as one eval, planned and estimated before anything is queued. Paid
/// cells are queued only after the user saw the estimate; with no recorded cost the only
/// paid step is calibration, one cell of each setup on the same task, which the eval then
/// reuses.
public enum LayerEvals {
    /// The newest eval of the layer and agent that renders the same files now: Continue
    /// reuses its finished cells.
    public struct Resumable: Sendable, Hashable {
        public var evalID: String
        public var createdAt: Date
        /// Its cells: repeats × tasks × setups, plus the read-only ones.
        public var total: Int
        public var finished: Int
        /// Queued or running.
        public var open: Int
        /// Cells Continue would queue now.
        public var left: Int
        /// Not every setup has a finished cell yet (a calibration cell, say): Evaluate continues
        /// it by default, so the paid cells are reused.
        public var calibrating: Bool
    }

    /// What Evaluate would queue, with the estimate; nothing is written.
    public struct EvalPlan: Sendable {
        public var set: LayerSet
        /// Task ids of the set that are gone (skipped).
        public var missing: [String]
        public var prepared: LayerSetups.Prepared
        public var repeats: Int
        /// Cells to queue now, and cells skipped as finished, queued or running.
        public var toQueue: Int
        public var skipped: Int
        public var estimate: CostEstimate
        /// For a new eval: the latest eval it could continue instead.
        public var resumable: Resumable?
        /// The calibration cells Calibrate would queue now: one of each setup that has no
        /// recorded, queued or running cell in the eval (normally 2, 0 when none is left).
        public var calibration: Int = 0
        /// Their estimate (no records: none).
        public var calibrationEstimate: CostEstimate?

        public var layer: String { prepared.layer }
        public var evalID: String { prepared.evalID }
        /// The eval's agent (a continued eval keeps its own).
        public var agent: LabAgent? { prepared.setups.first?.agent }
        var sanity: (setup: ControlSetup, tasks: [ControlTask], repeats: Int)? { prepared.sanitySetup.map { ($0, prepared.sanityTasks, 1) } }
    }

    /// Plans an eval of the layer's set: renders the layer (`LayerSetups.prepare`), counts the
    /// cells to queue and estimates their cost and time. `continuing`: an eval id; its tasks,
    /// setups and repeats are reused while the layer renders the same files. `denied`: shell
    /// commands no cell may run (nil: the default for the set's repository).
    public static func plan(layer: String, agent: LabAgent, repeats: Int, sanity: Bool, continuing: String? = nil, denied: [String]? = nil,
                            homeSkills: Set<String>, brain: URL, store: ProjectStore, projectsRoot: URL, now: Date = .now,
                            env: HarnessEnvironment) async throws -> EvalPlan {
        guard let set = LayerSets.load(layer, env: env) else {
            throw LayerSetups.Failure(message: LayerSets.problem(layer, env: env)
                                          ?? "\(layer) has no layer set: make one and add tasks first (Evals → Add to Layer Set…, "
                                          + "or akit analysis control layer-set \(layer) add TASK).")
        }
        let (found, missing) = LayerSets.tasks(of: set, env: env)
        var repeats = repeats
        if let continuing {
            guard let manifest = LayerEvalStore.manifest(continuing, env: env) else {
                throw LayerSetups.Failure(message: LayerEvalStore.problem(continuing, env: env) ?? "No eval \(continuing).")
            }
            repeats = manifest.repeats
        } else if found.isEmpty {
            throw LayerSetups.Failure(message: "The \(layer) set has no tasks" + (missing.isEmpty ? "" : " that still exist")
                                          + ": add some first (Evals → Add to Layer Set…).")
        }
        guard repeats > 0 else { throw LayerSetups.Failure(message: "Pick at least one repeat.") }
        let prepared = try await LayerSetups.prepare(layer: layer, tasks: found, answers: set.answers, agent: agent, sanity: sanity,
                                                     continuing: continuing, denied: denied, homeSkills: homeSkills, brain: brain, store: store,
                                                     projectsRoot: projectsRoot, now: now, env: env)
        let records = SendLog.records(env: env), runs = LabStore.list(env: env)
        let counts = estimate(prepared, repeats: repeats, records: records, runs: runs, env: env)
        let calibration = calibrationCells(prepared, runs: runs, env: env)
        var resumable: Resumable?
        if !prepared.continuing, let latest = LayerEvalStore.latest(of: layer, agent: agent, env: env),
           overlays(of: latest.setups) == overlays(of: prepared.setups) {
            resumable = self.resumable(latest, env: env)
        }
        return EvalPlan(set: set, missing: missing, prepared: prepared, repeats: repeats, toQueue: counts.toQueue, skipped: counts.skipped,
                        estimate: counts.estimate, resumable: resumable, calibration: calibration.count,
                        calibrationEstimate: calibration.isEmpty ? nil
                            : ControlRuns.estimate(setups: calibration.map(\.setup), agent: prepared.setups.first?.agent ?? agent,
                                                   repo: prepared.runnable.first?.mainFolder, records: records, runs: runs))
    }

    /// The cells of prepared layer setups still to run and their estimate: per setup once each
    /// setup has a recorded cell (`ControlRuns.estimate(setups:…)`), else from all control cells.
    /// Evaluate, Run Cells… with a brain layer and `run --layer` show it; `queue` counts again.
    public static func estimate(_ prepared: LayerSetups.Prepared, repeats: Int, env: HarnessEnvironment)
        -> (toQueue: Int, skipped: Int, estimate: CostEstimate) {
        estimate(prepared, repeats: repeats, records: SendLog.records(env: env), runs: LabStore.list(env: env), env: env)
    }

    static func estimate(_ prepared: LayerSetups.Prepared, repeats: Int, records: [SendRecord], runs: [LabRun],
                         env: HarnessEnvironment) -> (toQueue: Int, skipped: Int, estimate: CostEstimate) {
        let sanity = prepared.sanitySetup.map { ($0, prepared.sanityTasks, 1) }
        let all = ControlRuns.order(tasks: prepared.runnable, setups: prepared.setups, repeats: repeats, sanity: sanity).count
        let pending = ControlRuns.pending(tasks: prepared.runnable, setups: prepared.setups, repeats: repeats, sanity: sanity, env: env)
        let agent = prepared.setups.first?.agent ?? LabAgent(harness: .claudeCode, model: "", effort: "")
        return (pending.count, all - pending.count,
                ControlRuns.estimate(setups: pending.map(\.setup), agent: agent, repo: prepared.runnable.first?.mainFolder, records: records,
                                     runs: runs))
    }

    /// The eval's calibration cells: for each setup (not the read-only one) that has no cell in
    /// the eval yet (finished with the layer, queued or running), its first cell not yet done
    /// in queue order, so both setups calibrate on the same task and repeat (repeat 1 of the
    /// first task in a new eval). At most one per setup.
    static func calibrationCells(_ prepared: LayerSetups.Prepared, runs: [LabRun], env: HarnessEnvironment)
        -> [(task: ControlTask, setup: ControlSetup)] {
        let mine = runs.filter { $0.spec.kind == .control && $0.spec.controlSetup?.layer?.evalID == prepared.evalID }
        let done = ControlRuns.doneKeys(tasks: prepared.runnable, env: env)
        return prepared.setups.compactMap { setup in
            let started = mine.contains { run in
                guard let other = run.spec.controlSetup, !other.readOnly, other.layer?.role == setup.layer?.role else { return false }
                return run.status == .queued || run.status == .running || (run.status == .finished && run.result?.control?.overlay != nil)
            }
            guard !started else { return nil }
            return ControlRuns.order(tasks: prepared.runnable, setups: [setup], repeats: 1, sanity: nil)
                .first { !done.contains(ControlRuns.cellKey(task: $0.task, setup: $0.setup, repeatIndex: $0.index)) }
                .map { ($0.task, $0.setup) }
        }
    }

    /// The overlay hashes of an eval's two setups, by role.
    private static func overlays(of setups: [ControlSetup]) -> [String: String] {
        Dictionary(setups.compactMap { setup in setup.layer.map { ($0.role.rawValue, $0.overlayHash ?? "") } }) { first, _ in first }
    }

    /// An eval's progress from its Lab runs.
    public static func resumable(_ manifest: LayerEvalManifest, env: HarnessEnvironment) -> Resumable {
        let runs = LabStore.list(env: env).filter { $0.spec.kind == .control && $0.spec.controlSetup?.layer?.evalID == manifest.id }
        let finished = runs.filter { $0.status == .finished && $0.result?.control?.overlay != nil }
        let tasks = manifest.tasks.compactMap { ControlTasks.load($0, env: env) }
        let sanityTasks = manifest.sanityTasks.compactMap { id in tasks.first { $0.id == id } }
        let left = ControlRuns.plan(tasks: tasks, setups: manifest.setups, repeats: manifest.repeats,
                                    sanity: manifest.sanity.map { ($0, sanityTasks, 1) }, env: env).toQueue
        return Resumable(evalID: manifest.id, createdAt: manifest.createdAt,
                         total: manifest.repeats * manifest.tasks.count * manifest.setups.count + (manifest.sanity == nil ? 0 : manifest.sanityTasks.count),
                         finished: finished.count, open: runs.filter { $0.status == .queued || $0.status == .running }.count, left: left,
                         calibrating: manifest.setups.contains { setup in !finished.contains { $0.spec.controlSetup == setup } })
    }

    /// Queues prepared layer setups that weren't planned from a set (Run Cells… with a brain
    /// layer, `run --layer`) the same way: `toQueue` and `maxCost` are what the user confirmed.
    public static func queue(_ prepared: LayerSetups.Prepared, repeats: Int, toQueue: Int, maxCost: Double, environment: LabEnvironment?,
                             keep: Bool, akit: URL, env: HarnessEnvironment) async throws -> (runs: [LabRun], skipped: Int) {
        let agent = prepared.setups.first?.agent ?? LabAgent(harness: .claudeCode, model: "", effort: "")
        let plan = EvalPlan(set: LayerSet(layer: prepared.layer), missing: [], prepared: prepared, repeats: repeats, toQueue: toQueue, skipped: 0,
                            estimate: CostEstimate(cells: toQueue, agent: agent, basedOn: 0, source: .none, durations: 0), resumable: nil)
        return try await queue(plan, calibrateOnly: false, maxCost: maxCost, environment: environment, keep: keep, akit: akit, env: env)
    }

    /// Queues a planned eval: the cells counted and estimated again (refused when more would
    /// be queued than the plan said, or the estimate's high end is above `maxCost`), the monthly
    /// limit with that estimate, then the eval folder (a cell must find its overlay), then the
    /// cells. `calibrateOnly`: the calibration cells (`calibrationCells`: one of each setup
    /// that has no cell in the eval yet, on the same task and repeat), at most as many as the
    /// plan said (the user confirmed that count), to measure the cost of each setup; the eval
    /// keeps them. Without a recorded cost only they are queued. One queue at a time per eval
    /// (a file lock), so two calibrations can't both pass the check. A new eval's folder is
    /// removed again when none of its cells could be queued.
    public static func queue(_ plan: EvalPlan, calibrateOnly: Bool, maxCost: Double? = nil, environment: LabEnvironment?, keep: Bool,
                             akit: URL, env: HarnessEnvironment) async throws -> (runs: [LabRun], skipped: Int) {
        let prepared = plan.prepared
        guard !prepared.runnable.isEmpty else {
            throw LayerSetups.Failure(message: "No task of the \(plan.layer) set can take the layer; see the blocked tasks.")
        }
        let paths = EvalPaths(env: env)
        try FileManager.default.createDirectory(at: paths.layerEvals, withIntermediateDirectories: true)
        let lock = paths.layerEvals.appending(path: ".\(AnalysisPaths.fileName(prepared.evalID)).lock")
        return try await FileLock.holding(lock) {
            let runs = LabStore.list(env: env), records = SendLog.records(env: env)
            // Counted again: a cell that failed or was cancelled since the plan would run again.
            let counts = LayerEvals.estimate(prepared, repeats: plan.repeats, records: records, runs: runs, env: env)
            var calibration: [(task: ControlTask, setup: ControlSetup)] = []
            let estimate: CostEstimate
            if calibrateOnly {
                calibration = calibrationCells(prepared, runs: runs, env: env)
                guard !calibration.isEmpty else {
                    throw LayerSetups.Failure(message: "Every setup of the eval \(prepared.evalID) has a finished, queued or running cell: "
                                                  + "no calibration cell is left to run.")
                }
                // Calibration is confirmed by its count: never more cells than the user saw.
                if calibration.count > plan.calibration {
                    throw LayerSetups.Failure(message: "The eval changed since the estimate (\(calibration.count) calibration cells now, not "
                                                  + "\(plan.calibration)); check it again.")
                }
                estimate = ControlRuns.estimate(setups: calibration.map(\.setup), agent: plan.agent ?? plan.estimate.agent,
                                                repo: prepared.runnable.first?.mainFolder, records: records, runs: runs)
            } else {
                estimate = counts.estimate
                if counts.toQueue > plan.toQueue {
                    throw LayerSetups.Failure(message: "The eval changed since the estimate (\(counts.toQueue) cells to run now, not "
                                                  + "\(plan.toQueue)); check it again.")
                }
                if counts.toQueue > 0, estimate.perCell == nil {
                    throw LayerSetups.Failure(message: "No estimate yet: " + estimate.costText + ". Queue the calibration cells first, one of "
                                                  + "each setup (akit analysis control evaluate \(plan.layer) --calibrate --yes); the eval reuses them.")
                }
                // Paid cells only up to an amount the user confirmed.
                guard let maxCost else {
                    if counts.toQueue == 0 { return ([], counts.skipped) }
                    throw LayerSetups.Failure(message: "Paid cells are queued only up to an amount you confirmed; none was given.")
                }
                if let high = estimate.high, high > maxCost {
                    throw LayerSetups.Failure(message: String(format: "A cell recorded a higher cost since the estimate: its high end is now $%.2f, "
                                                                 + "above the $%.2f you allowed; check it again.", high, maxCost))
                }
            }
            try SendLog.checkLimit(estimate: estimate.total, settings: LabSettings.loadForSending(env: env), env: env)
            let isNew = LayerEvalStore.manifest(prepared.evalID, env: env) == nil
            try LayerEvalStore.create(prepared, repeats: plan.repeats, env: env)
            do {
                if !calibration.isEmpty {
                    // Normally one task (repeat 1 of the first): one call keeps the queue order.
                    if Set(calibration.map(\.task.id)).count == 1 {
                        return try await ControlRuns.newControlRuns(tasks: [calibration[0].task], setups: calibration.map(\.setup), repeats: 1,
                                                                    environment: environment, keep: keep, akit: akit, env: env)
                    }
                    var queued: (runs: [LabRun], skipped: Int) = ([], 0)
                    for cell in calibration {
                        let one = try await ControlRuns.newControlRuns(tasks: [cell.task], setups: [cell.setup], repeats: 1,
                                                                       environment: environment, keep: keep, akit: akit, env: env)
                        queued = (queued.runs + one.runs, queued.skipped + one.skipped)
                    }
                    return queued
                }
                return try await ControlRuns.newControlRuns(tasks: prepared.runnable, setups: prepared.setups, repeats: plan.repeats,
                                                            sanity: plan.sanity, environment: environment, keep: keep, akit: akit, env: env)
            } catch {
                // A new eval with no cell is no eval: its folder goes, so no plan offers to continue it.
                let queued = LabStore.list(env: env).contains { $0.spec.controlSetup?.layer?.evalID == prepared.evalID }
                if isNew, !queued {
                    try? FileManager.default.removeItem(at: paths.layerEval(prepared.evalID))
                    try? FileManager.default.removeItem(at: lock)
                }
                throw error
            }
        }
    }
}
