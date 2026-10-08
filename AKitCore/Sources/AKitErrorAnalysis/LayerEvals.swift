import AKitBrain
import AKitFoundation
import AKitLab
import Foundation

/// Brain → layer → Evaluate… and `akit analysis control evaluate`
/// (`docs/design/layer-evals.md`, "UI"): the layer's set as one eval, planned and estimated before anything is queued. Paid
/// cells are queued only after the user saw the estimate; with no recorded cost the only
/// paid step is one calibration cell, which the eval then reuses.
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
        let sanityCells = prepared.sanitySetup.map { ($0, prepared.sanityTasks, 1) }
        let counts = ControlRuns.plan(tasks: prepared.runnable, setups: prepared.setups, repeats: repeats, sanity: sanityCells, env: env)
        let estimate = ControlRuns.estimate(cells: counts.toQueue, agent: prepared.setups.first?.agent ?? agent,
                                            repo: prepared.runnable.first?.mainFolder, env: env)
        var resumable: Resumable?
        if !prepared.continuing, let latest = LayerEvalStore.latest(of: layer, agent: agent, env: env),
           overlays(of: latest.setups) == overlays(of: prepared.setups) {
            resumable = self.resumable(latest, env: env)
        }
        return EvalPlan(set: set, missing: missing, prepared: prepared, repeats: repeats, toQueue: counts.toQueue, skipped: counts.skipped,
                        estimate: estimate, resumable: resumable)
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

    /// Queues a planned eval: the cells counted and estimated again (refused when more would
    /// be queued than the plan said, or the estimate's high end is above `maxCost`), the monthly
    /// limit with that estimate, then the eval folder (a cell must find its overlay), then the
    /// cells. `calibrateOnly`: exactly one cell, the first one not yet done (repeat 1 of the
    /// baseline of the first task in a new eval), to measure the cost; the eval keeps it.
    /// Without a recorded cost only that is queued. One queue at a time per eval (a file lock),
    /// so two calibrations can't both pass the check. A new eval's folder is removed again when
    /// none of its cells could be queued.
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
            let runs = LabStore.list(env: env)
            // Counted again: a cell that failed or was cancelled since the plan would run again.
            let counts = ControlRuns.plan(tasks: prepared.runnable, setups: prepared.setups, repeats: plan.repeats, sanity: plan.sanity, env: env)
            let estimate = ControlRuns.estimate(cells: calibrateOnly ? 1 : counts.toQueue, agent: plan.agent ?? plan.estimate.agent,
                                                repo: prepared.runnable.first?.mainFolder, records: SendLog.records(env: env), runs: runs)
            var calibration: (task: ControlTask, setup: ControlSetup)?
            if calibrateOnly {
                if runs.contains(where: { $0.spec.controlSetup?.layer?.evalID == prepared.evalID && ($0.status == .queued || $0.status == .running) }) {
                    throw LayerSetups.Failure(message: "A cell of the eval \(prepared.evalID) is queued or running: wait for it, it records the cost.")
                }
                let done = ControlRuns.doneKeys(tasks: prepared.runnable, env: env)
                guard let first = ControlRuns.order(tasks: prepared.runnable, setups: prepared.setups, repeats: 1, sanity: nil)
                    .first(where: { !done.contains(ControlRuns.cellKey(task: $0.task, setup: $0.setup, repeatIndex: $0.index)) }) else {
                    throw LayerSetups.Failure(message: "Every first cell of the eval is done or queued: no calibration cell is left to run.")
                }
                calibration = (first.task, first.setup)
            } else {
                if counts.toQueue > plan.toQueue {
                    throw LayerSetups.Failure(message: "The eval changed since the estimate (\(counts.toQueue) cells to run now, not "
                                                  + "\(plan.toQueue)); check it again.")
                }
                if counts.toQueue > 0, estimate.perCell == nil {
                    throw LayerSetups.Failure(message: "No estimate yet: " + estimate.costText + ". Queue 1 calibration cell first "
                                                  + "(akit analysis control evaluate \(plan.layer) --calibrate --yes); the eval reuses it.")
                }
                if let maxCost, let high = estimate.high, high > maxCost {
                    throw LayerSetups.Failure(message: String(format: "The estimate's high end $%.2f is above the most you allowed, $%.2f; "
                                                                 + "check it again.", high, maxCost))
                }
            }
            try SendLog.checkLimit(estimate: calibrateOnly ? estimate.perCell : estimate.total,
                                   settings: LabSettings.loadForSending(env: env), env: env)
            let isNew = LayerEvalStore.manifest(prepared.evalID, env: env) == nil
            try LayerEvalStore.create(prepared, repeats: plan.repeats, env: env)
            do {
                if let calibration {
                    return try await ControlRuns.newControlRuns(tasks: [calibration.task], setups: [calibration.setup], repeats: 1,
                                                                environment: environment, keep: keep, akit: akit, env: env)
                }
                return try await ControlRuns.newControlRuns(tasks: prepared.runnable, setups: prepared.setups, repeats: plan.repeats,
                                                            sanity: plan.sanity, environment: environment, keep: keep, akit: akit, env: env)
            } catch {
                // A new eval with no cell is no eval: its folder goes, so no plan offers to continue it.
                let queued = LabStore.list(env: env).contains { $0.spec.controlSetup?.layer?.evalID == prepared.evalID }
                if isNew, !queued { try? FileManager.default.removeItem(at: paths.layerEval(prepared.evalID)) }
                throw error
            }
        }
    }
}
