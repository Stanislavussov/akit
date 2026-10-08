import AKitFoundation
import AKitLab
import Foundation

/// Control cells per setup and the paired comparison of a fix (`docs/design/error-analysis.md`,
/// "Controlled evals" and "Fixes"). The unit is a task's pass rate over its repeats, so a set
/// of tasks is compared by task, not by pooled cells. A flagged cell (guard, leaks) counts as
/// failed: its pass isn't trusted, and leaving it out (or running it again) would re-roll bad
/// outcomes away.
public struct ControlComparison: Codable, Sendable, Hashable {
    /// One finished cell.
    public struct Cell: Codable, Sendable, Hashable {
        public var task: String
        public var setup: ControlSetup
        public var passed: Bool
        public var flagged: Bool
        /// False for a layer cell whose result has no overlay notes: an older akit ran it and
        /// ignored the layer, so it is left out of the comparison (and counted).
        public var overlayRecorded: Bool
        /// The Claude Code version the cell ran with, when recorded.
        public var harnessVersion: String?

        public init(task: String, setup: ControlSetup, passed: Bool, flagged: Bool = false, overlayRecorded: Bool = true,
                    harnessVersion: String? = nil) {
            self.task = task
            self.setup = setup
            self.passed = passed
            self.flagged = flagged
            self.overlayRecorded = overlayRecorded
            self.harnessVersion = harnessVersion
        }

        /// The finished control runs; queued, failed and cancelled ones have no verdict.
        public static func of(_ runs: [LabRun]) -> [Cell] {
            runs.sorted { $0.spec.createdAt < $1.spec.createdAt }.compactMap { run in
                guard run.spec.kind == .control, run.status == .finished, let task = run.spec.controlTask,
                      let setup = run.spec.controlSetup, let control = run.result?.control else { return nil }
                return Cell(task: task, setup: setup, passed: control.passed, flagged: control.flagged,
                            overlayRecorded: setup.layer == nil || control.overlay != nil, harnessVersion: control.harnessVersion)
            }
        }
    }

    public struct TaskRate: Codable, Sendable, Hashable {
        public var task: String
        public var passed: Int
        public var total: Int
        public var rate: Double { total == 0 ? 0 : Double(passed) / Double(total) }
    }

    public struct Row: Codable, Sendable, Hashable {
        public var setup: ControlSetup
        /// Per task, by task id; flagged cells count as failed.
        public var tasks: [TaskRate]
        public var cells: Int
        /// Cells counted as failed because they are flagged.
        public var flagged: Int
        /// The chance one run passes: the mean of the tasks' pass rates.
        public var passAt1: Double?
        /// Wilson 95% interval of the cells' passes.
        public var passAt1Interval: Stats.Interval
        /// The fewest cells any task has: the k of pass^k.
        public var k: Int
        /// The share of tasks where all k runs passed.
        public var passHatK: Double?
        public var passHatKInterval: Stats.Interval
        /// The Claude Code versions its cells recorded, sorted.
        public var harnessVersions: [String] = []
    }

    public enum Verdict: String, Codable, Sendable {
        /// At least 95% of the bootstrap mass on improvement.
        case helped
        case notShown = "not-shown"
        /// Too few repeats or cells to say.
        case noConclusion = "no-conclusion"

        public var title: String {
            switch self {
            case .helped: "helped"
            case .notShown: "didn't show it helped"
            case .noConclusion: "no conclusion"
            }
        }
    }

    public struct Paired: Codable, Sendable, Hashable {
        public var baseline: ControlSetup
        public var variant: ControlSetup
        /// Tasks both setups have cells of.
        public var tasks: Int
        public var baselineCells: Int
        public var variantCells: Int
        /// The mean per-task change in pass rate, variant minus baseline.
        public var meanChange: Double?
        /// The share of bootstrap means above zero.
        public var improvementShare: Double?
        /// The "not worse in production" guard: P(the mode's failure rate rose after the fix's T)
        /// from its check over indexed sessions, when both sides have enough sessions.
        public var productionHigher: Double?
        public var verdict: Verdict
        public var reason: String
        /// The Claude Code versions of both sides' cells; more than one means the eval mixes them.
        public var harnessVersions: [String] = []
    }

    public static let minimumRepeats = 3
    public static let minimumCells = 15
    public static let helpedShare = 0.95

    public var rows: [Row]
    public var paired: [Paired]
    /// Layer cells left out because an older akit ran them without the layer.
    public var leftOut = 0

    /// Rows per setup in order of first appearance. Each patch variant is paired with the
    /// baseline of the same agent (no patch, no layer, not read-only), else the first such
    /// baseline. A layer setup (`role: layer`) is paired only with the `requiredOnly` setup of
    /// the same layer, eval and agent: never with a plain baseline, and patch variants never
    /// with a layer row. `production` is the fix's production signal (`production(for:env:)`):
    /// "helped" also needs it not worse, so without it there is no conclusion. It is a patch
    /// fix's signal, so layer pairs never get it.
    public static func compare(_ cells: [Cell], production: FixEvaluation? = nil, iterations: Int = 2000,
                               seed: UInt64 = 1) -> ControlComparison {
        let kept = cells.filter(\.overlayRecorded)
        var order: [ControlSetup] = []
        for cell in kept where !order.contains(cell.setup) { order.append(cell.setup) }
        let rows = order.map { setup in row(setup, cells: kept.filter { $0.setup == setup }) }
        let candidates = rows.filter { !$0.setup.readOnly }
        let baselines = candidates.filter { $0.setup.patch == nil && $0.setup.layer == nil }
        let paired = candidates.compactMap { variant -> Paired? in
            if variant.setup.patch != nil {
                guard let baseline = baselines.first(where: { $0.setup.agent == variant.setup.agent }) ?? baselines.first else { return nil }
                return pair(baseline: baseline, variant: variant, production: production, iterations: iterations, seed: seed)
            }
            guard let layer = variant.setup.layer, layer.role == .layer,
                  let baseline = candidates.first(where: { row in
                      guard let other = row.setup.layer else { return false }
                      return other.role == .requiredOnly && other.layer == layer.layer && other.evalID == layer.evalID
                          && row.setup.agent == variant.setup.agent
                  }) else { return nil }
            return pair(baseline: baseline, variant: variant, production: nil, iterations: iterations, seed: seed)
        }
        return ControlComparison(rows: rows, paired: paired, leftOut: cells.count - kept.count)
    }

    /// The production signal of the one mode the tasks are about: its fix judged by the mode's
    /// check before and after T. nil when the tasks name no single mode or its fix isn't applied.
    public static func production(for tasks: [ControlTask], env: HarnessEnvironment) async throws -> FixEvaluation? {
        let modes = Set(tasks.compactMap(\.modeID))
        guard modes.count == 1, let id = modes.first, let mode = try await ModeStore(env: env).mode(id) else { return nil }
        return try Fixes.evaluate(mode, env: env)
    }

    /// A 95% bootstrap interval over tasks of the mean of per-task estimates (seeded), so the
    /// interval is about the same number as the estimate.
    static func interval(ofMean values: [Double], iterations: Int = 2000) -> Stats.Interval {
        guard !values.isEmpty else { return Stats.Interval(low: 0, high: 1) }
        var generator = SeededGenerator(seed: 17)
        var means = (0..<iterations).map { _ in
            (0..<values.count).map { _ in values[Int.random(in: 0..<values.count, using: &generator)] }.reduce(0, +) / Double(values.count)
        }
        means.sort()
        return Stats.Interval(low: means[Int(0.025 * Double(iterations))], high: means[min(iterations - 1, Int(0.975 * Double(iterations)))])
    }

    static func row(_ setup: ControlSetup, cells: [Cell]) -> Row {
        func trusted(_ cell: Cell) -> Bool { cell.passed && !cell.flagged }
        let tasks = Dictionary(grouping: cells, by: \.task).map { task, cells in
            TaskRate(task: task, passed: cells.filter(trusted).count, total: cells.count)
        }.sorted { $0.task < $1.task }
        let passed = cells.filter(trusted).count
        let k = tasks.map(\.total).min() ?? 0
        // pass^k per task, unbiased when a task has more than k cells: C(c, k) / C(n, k).
        let hatK = tasks.map { task in task.passed < k ? 0 : exp(Stats.logChoose(task.passed, k) - Stats.logChoose(task.total, k)) }
        let passHatK = tasks.isEmpty ? nil : hatK.reduce(0, +) / Double(tasks.count)
        return Row(setup: setup, tasks: tasks, cells: cells.count, flagged: cells.filter(\.flagged).count,
                   passAt1: tasks.isEmpty ? nil : tasks.map(\.rate).reduce(0, +) / Double(tasks.count),
                   passAt1Interval: Stats.wilson(passed, cells.count), k: k,
                   passHatK: passHatK,
                   passHatKInterval: interval(ofMean: hatK),
                   harnessVersions: Set(cells.compactMap(\.harnessVersion)).sorted())
    }

    /// The paired bootstrap over tasks of the per-task change in pass rate (seeded, so the
    /// same cells give the same share). "Helped" is fixed before the run: ≥ 95% of the mass
    /// on improvement, with at least 3 repeats of every task and 15 cells on each side, and not
    /// worse in production: at most 50% that the mode's failure rate rose after T, with 15
    /// sessions on each side.
    static func pair(baseline: Row, variant: Row, production: FixEvaluation?, iterations: Int, seed: UInt64) -> Paired {
        let before = Dictionary(uniqueKeysWithValues: baseline.tasks.map { ($0.task, $0) })
        let shared = variant.tasks.compactMap { after in before[after.task].map { (before: $0, after: after) } }
        let baselineCells = shared.map(\.before.total).reduce(0, +)
        let variantCells = shared.map(\.after.total).reduce(0, +)
        let changes = shared.map { $0.after.rate - $0.before.rate }
        var result = Paired(baseline: baseline.setup, variant: variant.setup, tasks: shared.count, baselineCells: baselineCells,
                            variantCells: variantCells, meanChange: changes.isEmpty ? nil : changes.reduce(0, +) / Double(changes.count),
                            improvementShare: nil, verdict: .noConclusion, reason: "",
                            harnessVersions: Set(baseline.harnessVersions + variant.harnessVersions).sorted())
        let measured = production.flatMap { production in
            production.before.sessions >= Fixes.minimumPerSide && production.after.sessions >= Fixes.minimumPerSide ? production : nil
        }
        result.productionHigher = measured?.probabilityHigher
        guard !changes.isEmpty, iterations > 0 else {
            result.reason = "No task has cells of both setups."
            return result
        }
        var generator = SeededGenerator(seed: seed)
        var improved = 0
        for _ in 0..<iterations {
            var sum = 0.0
            for _ in changes.indices { sum += changes[Int.random(in: 0..<changes.count, using: &generator)] }
            if sum > 0 { improved += 1 }
        }
        let share = Double(improved) / Double(iterations)
        result.improvementShare = share
        let percent = String(format: "%.0f%%", 100 * share)
        if shared.contains(where: { $0.before.total < minimumRepeats || $0.after.total < minimumRepeats }) {
            result.reason = "A task has fewer than \(minimumRepeats) repeats on a side."
        } else if baselineCells < minimumCells || variantCells < minimumCells {
            result.reason = "Fewer than \(minimumCells) cells on a side (baseline \(baselineCells), variant \(variantCells))."
        } else if variant.setup.layer != nil {
            // Until layers get their own verdict level (slice 5), every layer pair stays open.
            result.reason = "\(percent) of the bootstrap mass on improvement; a layer eval has no verdict level of its own yet, "
                + "so this pair has no conclusion."
        } else if share >= helpedShare {
            let control = "\(percent) of the bootstrap mass on improvement (needs \(Int(helpedShare * 100))%)"
            if let measured {
                let rose = String(format: "%.0f%%", 100 * measured.probabilityHigher)
                if measured.probabilityHigher <= Fixes.notWorseProbability {
                    result.verdict = .helped
                    result.reason = "\(control), and not worse in production (\(rose) that the mode's failure rate rose after the fix)."
                } else {
                    result.verdict = .notShown
                    result.reason = "\(control), but in production \(rose) that the mode's failure rate rose after the fix (at most 50%)."
                }
            } else if let production {
                result.reason = "\(control); not worse in production needs \(Fixes.minimumPerSide) sessions with the mode's check on each side "
                    + "of the fix (before \(production.before.sessions), after \(production.after.sessions))."
            } else {
                result.reason = "\(control); not worse in production isn't known: the tasks' mode has no applied fix with check results."
            }
        } else {
            result.verdict = .notShown
            result.reason = "Only \(percent) of the bootstrap mass on improvement (needs \(Int(helpedShare * 100))%)."
        }
        return result
    }
}
