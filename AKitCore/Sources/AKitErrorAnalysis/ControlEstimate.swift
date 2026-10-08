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
        /// Layer cells: each setup's own recorded cells (`parts`), since the layer's context
        /// makes its cells cost differently.
        case setups
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
    /// Which runs those are: "control runs of this repository", "replays of other repositories"…
    public var durationsFrom: String = ""
    /// A per-setup estimate (`setups`): one part per setup of the cells.
    public var parts: [Part] = []
    /// Why layer cells are estimated from all control cells instead of per setup ("not per
    /// setup: the layer setup has no recorded cell yet"); nil otherwise.
    public var note: String?

    /// The cells of one setup in a per-setup estimate.
    public struct Part: Sendable, Hashable {
        /// "without swiftui", "layer swiftui", "read-only".
        public var label: String
        public var cells: Int
        /// The mean, lowest and highest recorded cost of one cell of the setup.
        public var perCell: Double
        public var low: Double
        public var high: Double
        /// Recorded cells of the setup itself (0: a read-only setup estimated from its baseline).
        public var basedOn: Int
    }

    /// The mean cost of all the cells; nil without records.
    public var total: Double? { perCell.map { $0 * Double(cells) } }

    /// "≈ $48.20 (range $30.10–$75.00) from 14 recorded control cells of Claude Code ·
    /// opus", per setup "≈ $9.80 (range $8.00–$12.00) from the recorded cells of each setup
    /// (Claude Code · opus): without swiftui 4 × $0.80 (2 recorded), layer swiftui 4 × $1.65
    /// (1 recorded)", or
    /// "no estimate yet (no recorded control or replay cell of Claude Code · opus)". A `note`
    /// follows in parentheses.
    public var costText: String {
        guard let total, let low, let high else { return "no estimate yet (no recorded control or replay cell of \(agentText))" }
        if source == .setups {
            return String(format: "≈ $%.2f (range $%.2f–$%.2f) from the recorded cells of each setup (%@): ", total, low, high, agentText)
                + parts.map { String(format: "%@ %d × $%.2f (%d recorded)", $0.label, $0.cells, $0.perCell, $0.basedOn) }
                    .joined(separator: ", ")
        }
        let kind = source == .replay ? "replay" : "control"
        return String(format: "≈ $%.2f (range $%.2f–$%.2f) from %d recorded %@ cell%@ of %@", total, low, high, basedOn, kind,
                      basedOn == 1 ? "" : "s", agentText) + (note.map { " (\($0))" } ?? "")
    }

    /// The cost as its own line: `costText`, or "No estimate yet: no recorded control or replay
    /// cell of Claude Code · opus."
    public var line: String { perCell == nil ? "No estimate yet: no recorded control or replay cell of \(agentText)." : costText }

    /// "Claude Code · opus".
    private var agentText: String { "\(agent.harness.title) · \(agent.model.isEmpty ? "default model" : agent.model)" }

    /// "≈ 13 h in the Lab queue (one cell at a time, median of 9 control runs of this
    /// repository)"; nil without recorded durations.
    public var timeText: String? {
        guard let seconds, cells > 0 else { return nil }
        return "≈ \(Self.duration(seconds)) in the Lab queue (one cell at a time, median of \(durations) \(durationsFrom))"
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
    /// right after the first repeat. `of`: the repeats of the cell's setup. A setup that names
    /// no denied commands gets its task repository's default (`ControlSetup.defaultDenied`).
    static func order(tasks: [ControlTask], setups: [ControlSetup], repeats: Int,
                      sanity: (setup: ControlSetup, tasks: [ControlTask], repeats: Int)?)
        -> [(task: ControlTask, setup: ControlSetup, index: Int, of: Int)] {
        var cells: [(task: ControlTask, setup: ControlSetup, index: Int, of: Int)] = []
        guard repeats > 0 else { return cells }
        for index in 1...repeats {
            for task in tasks {
                for setup in setups { cells.append((task, withDefaults(setup, task), index, repeats)) }
            }
            if index == 1, let sanity, sanity.repeats > 0 {
                for sanityIndex in 1...sanity.repeats {
                    for task in sanity.tasks { cells.append((task, withDefaults(sanity.setup, task), sanityIndex, sanity.repeats)) }
                }
            }
        }
        return cells
    }

    /// The setup a cell of `task` runs with: its denied commands, or the repository's default.
    static func withDefaults(_ setup: ControlSetup, _ task: ControlTask) -> ControlSetup {
        guard setup.denied == nil, setup.agent.harness == .claudeCode else { return setup }
        let denied = ControlSetup.defaultDenied(repo: task.mainFolder)
        guard !denied.isEmpty else { return setup }
        var setup = setup
        setup.denied = denied
        return setup
    }

    /// A dry run of `newControlRuns`: how many cells it would queue now, and how many it would
    /// skip as finished, queued or running. Writes nothing.
    public static func plan(tasks: [ControlTask], setups: [ControlSetup], repeats: Int,
                            sanity: (setup: ControlSetup, tasks: [ControlTask], repeats: Int)? = nil,
                            env: HarnessEnvironment) -> (toQueue: Int, skipped: Int) {
        let all = order(tasks: tasks, setups: setups, repeats: repeats, sanity: sanity).count
        let toQueue = pending(tasks: tasks, setups: setups, repeats: repeats, sanity: sanity, env: env).count
        return (toQueue, all - toQueue)
    }

    /// The cells `newControlRuns` would queue now, in queue order (their setups with the
    /// repository's denied commands, `withDefaults`). Writes nothing.
    static func pending(tasks: [ControlTask], setups: [ControlSetup], repeats: Int,
                        sanity: (setup: ControlSetup, tasks: [ControlTask], repeats: Int)? = nil,
                        env: HarnessEnvironment) -> [(task: ControlTask, setup: ControlSetup, index: Int, of: Int)] {
        let done = doneKeys(tasks: tasks + (sanity?.tasks ?? []), env: env)
        return order(tasks: tasks, setups: setups, repeats: repeats, sanity: sanity)
            .filter { !done.contains(cellKey(task: $0.task, setup: $0.setup, repeatIndex: $0.index)) }
    }

    /// The estimate for `cells` new cells of `agent` in `repo`, from this Mac's send log and
    /// Lab runs.
    public static func estimate(cells: Int, agent: LabAgent, repo: URL? = nil, env: HarnessEnvironment) -> CostEstimate {
        estimate(cells: cells, agent: agent, repo: repo, records: SendLog.records(env: env), runs: LabStore.list(env: env))
    }

    /// The recorded cost per cell of earlier control cells of the same harness and model, else
    /// of replays of them (a replay is the same work: an agent in a clone, then tests); the
    /// time from the recorded durations of finished control runs, else replays (clone, agent
    /// and hidden-test build included), of `repo` first (builds differ most by repository),
    /// else of any repository.
    public static func estimate(cells: Int, agent: LabAgent, repo: URL? = nil, records: [SendRecord], runs: [LabRun]) -> CostEstimate {
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
        let path = repo?.standardizedFileURL.path
        func inRepo(_ run: LabRun) -> Bool {
            [run.spec.repo, run.spec.folder].compactMap { $0 }.contains { URL(filePath: $0).standardizedFileURL.path == path }
        }
        func durations(_ kind: RunSpec.Kind, here: Bool) -> [Double] {
            runs.filter { $0.spec.kind == kind && $0.status == .finished && (!here || inRepo($0)) }.compactMap { run in
                guard let state = run.state, let started = state.startedAt else { return nil }
                let seconds = state.updatedAt.timeIntervalSince(started)
                return seconds > 0 ? seconds : nil
            }
        }
        var times: [Double] = []
        var from = ""
        for (kind, here) in (path == nil ? [] : [(RunSpec.Kind.control, true), (.replay, true)]) + [(.control, false), (.replay, false)] {
            times = durations(kind, here: here)
            guard times.isEmpty else {
                from = (kind == .control ? "control run" : "replay") + (times.count == 1 ? "" : "s")
                    + (here ? " of this repository" : path == nil ? "" : " of other repositories")
                break
            }
        }
        let median: Double? = times.isEmpty ? nil : {
            let sorted = times.sorted()
            let middle = sorted.count / 2
            return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
        }()
        let perCell = recorded.isEmpty ? nil : recorded.reduce(0, +) / Double(recorded.count)
        return CostEstimate(cells: cells, agent: agent, perCell: perCell, low: recorded.min().map { $0 * Double(cells) },
                            high: recorded.max().map { $0 * Double(cells) }, basedOn: recorded.count, source: source,
                            seconds: median.map { Int(($0 * Double(cells)).rounded()) }, durations: times.count, durationsFrom: from)
    }

    /// The estimate for layer cells, one setup per cell: per setup when each main setup among
    /// them (`without X`, `layer X`) has recorded control cells of the same harness and model,
    /// since the layer's context makes its cells cost differently. A setup's records are those
    /// of control cells with the same layer, role and overlay (of any eval: the same files cost
    /// the same); a read-only sanity cell takes its own, else its baseline's. Otherwise, and
    /// for cells without a layer, `estimate(cells:…)` over all control cells, with a note that
    /// says why. The time is always `estimate(cells:…)`'s.
    public static func estimate(setups cells: [ControlSetup], agent: LabAgent, repo: URL? = nil, records: [SendRecord],
                                runs: [LabRun]) -> CostEstimate {
        var estimate = estimate(cells: cells.count, agent: agent, repo: repo, records: records, runs: runs)
        guard !cells.isEmpty, cells.allSatisfy({ $0.layer != nil }) else { return estimate }
        struct Group: Hashable {
            let layer: String
            let role: LayerVariant.Role
            let overlay: String?
            let readOnly: Bool
        }
        func group(_ setup: ControlSetup) -> Group? {
            setup.layer.map { Group(layer: $0.layer, role: $0.role, overlay: $0.overlayHash, readOnly: setup.readOnly) }
        }
        let byRun = Dictionary(runs.map { ($0.id, $0) }) { first, _ in first }
        var costs: [Group: [Double]] = [:]
        for record in records where record.purpose == "control" && record.harness == agent.harness && record.model == agent.model {
            guard let cost = record.usage.cost, let id = record.runID, let key = byRun[id]?.spec.controlSetup.flatMap(group) else { continue }
            costs[key, default: []].append(cost)
        }
        var order: [Group] = []
        var counts: [Group: Int] = [:]
        for key in cells.compactMap(group) {
            if counts[key] == nil { order.append(key) }
            counts[key, default: 0] += 1
        }
        let missing = order.filter { !$0.readOnly && costs[$0] == nil }
        if !missing.isEmpty {
            let roles = Set(missing.map(\.role))
            guard estimate.perCell != nil else { return estimate }
            estimate.note = "not per setup: " + (roles.count > 1 ? "no setup of the eval has a recorded cell yet"
                                                 : roles.contains(.layer) ? "the layer setup has no recorded cell yet"
                                                 : "the setup without the layer has no recorded cell yet")
            return estimate
        }
        var parts: [CostEstimate.Part] = []
        for key in order {
            let own = costs[key] ?? []
            // A sanity cell without records of its own: as much as a baseline cell, at most.
            let recorded = own.isEmpty ? costs[Group(layer: key.layer, role: .requiredOnly, overlay: key.overlay, readOnly: false)] ?? [] : own
            guard let low = recorded.min(), let high = recorded.max() else {
                estimate.note = "not per setup: the setup without the layer has no recorded cell yet"
                return estimate
            }
            let label = key.readOnly ? "read-only" : (key.role == .layer ? "layer " : "without ") + key.layer
            parts.append(CostEstimate.Part(label: label, cells: counts[key] ?? 0, perCell: recorded.reduce(0, +) / Double(recorded.count),
                                           low: low, high: high, basedOn: own.count))
        }
        estimate.source = .setups
        estimate.parts = parts
        estimate.basedOn = parts.reduce(0) { $0 + $1.basedOn }
        estimate.perCell = parts.reduce(0) { $0 + $1.perCell * Double($1.cells) } / Double(cells.count)
        estimate.low = parts.reduce(0) { $0 + $1.low * Double($1.cells) }
        estimate.high = parts.reduce(0) { $0 + $1.high * Double($1.cells) }
        return estimate
    }
}
