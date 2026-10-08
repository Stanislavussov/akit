import AKitFoundation
import AKitLab
import Foundation

/// What queued cells will cost, from what earlier cells recorded (no price tables): the one
/// estimate the app's sheets and `akit analysis control` show before anything is queued.
public struct CostEstimate: Sendable, Hashable {
    public enum Source: String, Sendable {
        /// Earlier control cells of the same harness and model.
        case control
        /// No control cell recorded a cost: earlier replays of the same harness and model.
        case replay
        /// Nothing recorded: no estimate.
        case none
    }

    /// Cells to queue.
    public var cells: Int
    public var agent: LabAgent
    /// The mean recorded cost of one cell, US dollars; nil without records.
    public var perCell: Double?
    /// The lowest and highest recorded cost of one cell, times the cells.
    public var low: Double?
    public var high: Double?
    /// Recorded cells the estimate comes from.
    public var basedOn: Int
    public var source: Source
    /// The Lab runs one cell at a time: the median recorded duration of a finished run times
    /// the cells; nil without recorded durations.
    public var seconds: Int?
    /// Finished runs the time comes from.
    public var durations: Int

    /// The mean cost of all the cells; nil without records.
    public var total: Double? { perCell.map { $0 * Double(cells) } }

    /// "≈ $48.20 (range $30.10–$75.00) from 14 recorded control cells of Claude Code · opus", or
    /// "no estimate yet (no recorded control or replay cell of Claude Code · opus)".
    public var costText: String {
        let agentText = "\(agent.harness.title) · \(agent.model.isEmpty ? "default model" : agent.model)"
        guard let total, let low, let high else { return "no estimate yet (no recorded control or replay cell of \(agentText))" }
        let kind = source == .replay ? "replay" : "control"
        return String(format: "≈ $%.2f (range $%.2f–$%.2f) from %d recorded %@ cell%@ of %@", total, low, high, basedOn, kind,
                      basedOn == 1 ? "" : "s", agentText)
    }

    /// The cost as its own line: `costText`, or "No estimate yet: no recorded control or replay
    /// cell of Claude Code · opus."
    public var line: String {
        perCell == nil ? "No estimate yet: no recorded control or replay cell of \(agent.harness.title) · "
            + "\(agent.model.isEmpty ? "default model" : agent.model)." : costText
    }

    /// "≈ 13 h in the Lab queue (one cell at a time, from 9 recorded run durations)"; nil
    /// without recorded durations.
    public var timeText: String? {
        guard let seconds, cells > 0 else { return nil }
        return "≈ \(Self.duration(seconds)) in the Lab queue (one cell at a time, from \(durations) recorded run duration\(durations == 1 ? "" : "s"))"
    }

    static func duration(_ seconds: Int) -> String {
        if seconds < 90 { return "\(max(seconds, 1)) s" }
        if seconds < 90 * 60 { return "\((seconds + 30) / 60) min" }
        let hours = Double(seconds) / 3600
        return hours < 10 ? String(format: "%.1f h", hours) : "\(Int(hours.rounded())) h"
    }
}

extension ControlRuns {
    /// The keys of control cells that need no new cell: finished ones (except a layer cell an
    /// older akit ran without the layer: comparisons leave it out, so it runs again) and queued
    /// or running ones of these tasks.
    static func doneKeys(tasks: [ControlTask], env: HarnessEnvironment) -> Set<String> {
        let existing = LabStore.list(env: env).filter { $0.spec.kind == .control }
        var done = Set(existing.compactMap { run -> String? in
            guard run.status == .finished, let control = run.result?.control else { return nil }
            return run.spec.controlSetup?.layer != nil && control.overlay == nil ? nil : control.key
        })
        let byID = Dictionary(tasks.map { ($0.id, $0) }) { first, _ in first }
        for run in existing where run.status == .queued || run.status == .running {
            guard let task = run.spec.controlTask.flatMap({ byID[$0] }), let setup = run.spec.controlSetup else { continue }
            done.insert(cellKey(task: task, setup: setup, repeatIndex: run.spec.repeatIndex ?? 1))
        }
        return done
    }

    /// The cells in queue order: 1 of each task and setup, then 2 of each…; the sanity cells
    /// right after the first repeat. `of`: the repeats of the cell's setup.
    static func order(tasks: [ControlTask], setups: [ControlSetup], repeats: Int,
                      sanity: (setup: ControlSetup, tasks: [ControlTask], repeats: Int)?)
        -> [(task: ControlTask, setup: ControlSetup, index: Int, of: Int)] {
        var cells: [(task: ControlTask, setup: ControlSetup, index: Int, of: Int)] = []
        guard repeats > 0 else { return cells }
        for index in 1...repeats {
            for task in tasks {
                for setup in setups { cells.append((task, setup, index, repeats)) }
            }
            if index == 1, let sanity, sanity.repeats > 0 {
                for sanityIndex in 1...sanity.repeats {
                    for task in sanity.tasks { cells.append((task, sanity.setup, sanityIndex, sanity.repeats)) }
                }
            }
        }
        return cells
    }

    /// A dry run of `newControlRuns`: how many cells it would queue now, and how many it would
    /// skip as finished, queued or running. Writes nothing.
    public static func plan(tasks: [ControlTask], setups: [ControlSetup], repeats: Int,
                            sanity: (setup: ControlSetup, tasks: [ControlTask], repeats: Int)? = nil,
                            env: HarnessEnvironment) -> (toQueue: Int, skipped: Int) {
        let done = doneKeys(tasks: tasks + (sanity?.tasks ?? []), env: env)
        let keys = order(tasks: tasks, setups: setups, repeats: repeats, sanity: sanity)
            .map { cellKey(task: $0.task, setup: $0.setup, repeatIndex: $0.index) }
        let skipped = keys.filter(done.contains).count
        return (keys.count - skipped, skipped)
    }

    /// The estimate for `cells` new cells of `agent`, from this Mac's send log and Lab runs.
    public static func estimate(cells: Int, agent: LabAgent, env: HarnessEnvironment) -> CostEstimate {
        estimate(cells: cells, agent: agent, records: SendLog.records(env: env), runs: LabStore.list(env: env))
    }

    /// The recorded cost per cell of earlier control cells of the same harness and model, else
    /// of replays of them (a replay is the same work: an agent in a clone, then tests); the
    /// time from the recorded durations of finished control runs, else replays (clone, agent
    /// and hidden-test build included).
    public static func estimate(cells: Int, agent: LabAgent, records: [SendRecord], runs: [LabRun]) -> CostEstimate {
        func costs(_ purpose: String) -> [Double] {
            records.filter { $0.purpose == purpose && $0.harness == agent.harness && $0.model == agent.model }.compactMap(\.usage.cost)
        }
        var source = CostEstimate.Source.control
        var recorded = costs("control")
        if recorded.isEmpty {
            source = .replay
            recorded = costs("replay")
        }
        if recorded.isEmpty { source = .none }
        func durations(_ kind: RunSpec.Kind) -> [Double] {
            runs.filter { $0.spec.kind == kind && $0.status == .finished }.compactMap { run in
                guard let state = run.state, let started = state.startedAt else { return nil }
                let seconds = state.updatedAt.timeIntervalSince(started)
                return seconds > 0 ? seconds : nil
            }
        }
        var times = durations(.control)
        if times.isEmpty { times = durations(.replay) }
        let median: Double? = times.isEmpty ? nil : {
            let sorted = times.sorted()
            let middle = sorted.count / 2
            return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
        }()
        let perCell = recorded.isEmpty ? nil : recorded.reduce(0, +) / Double(recorded.count)
        return CostEstimate(cells: cells, agent: agent, perCell: perCell, low: recorded.min().map { $0 * Double(cells) },
                            high: recorded.max().map { $0 * Double(cells) }, basedOn: recorded.count, source: source,
                            seconds: median.map { Int(($0 * Double(cells)).rounded()) }, durations: times.count)
    }
}
