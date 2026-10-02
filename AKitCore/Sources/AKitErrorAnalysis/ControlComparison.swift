import AKitLab
import Foundation

/// Control cells per setup and the paired comparison of a fix (`docs/design/error-analysis.md`,
/// "Controlled evals" and "Fixes"). The unit is a task's pass rate over its repeats, so a set
/// of tasks is compared by task, not by pooled cells. Flagged cells (guard, leaks) are left out.
public struct ControlComparison: Codable, Sendable, Hashable {
    /// One finished cell.
    public struct Cell: Codable, Sendable, Hashable {
        public var task: String
        public var setup: ControlSetup
        public var passed: Bool
        public var flagged: Bool

        public init(task: String, setup: ControlSetup, passed: Bool, flagged: Bool = false) {
            self.task = task
            self.setup = setup
            self.passed = passed
            self.flagged = flagged
        }

        /// The finished control runs; queued, failed and cancelled ones have no verdict.
        public static func of(_ runs: [LabRun]) -> [Cell] {
            runs.sorted { $0.spec.createdAt < $1.spec.createdAt }.compactMap { run in
                guard run.spec.kind == .control, run.status == .finished, let task = run.spec.controlTask,
                      let setup = run.spec.controlSetup, let control = run.result?.control else { return nil }
                return Cell(task: task, setup: setup, passed: control.passed, flagged: control.flagged)
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
        /// Per task, unflagged cells only, by task id.
        public var tasks: [TaskRate]
        public var cells: Int
        public var flagged: Int
        /// The chance one run passes: the mean of the tasks' pass rates.
        public var passAt1: Double?
        /// Wilson 95% interval of the unflagged cells' passes.
        public var passAt1Interval: Stats.Interval
        /// The fewest cells any task has: the k of pass^k.
        public var k: Int
        /// The share of tasks where all k runs passed.
        public var passHatK: Double?
        public var passHatKInterval: Stats.Interval
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
        public var verdict: Verdict
        public var reason: String
    }

    public static let minimumRepeats = 3
    public static let minimumCells = 15
    public static let helpedShare = 0.95

    public var rows: [Row]
    public var paired: [Paired]

    /// Rows per setup in order of first appearance; each variant (a setup with a patch) is
    /// paired with the baseline of the same agent (no patch, not read-only), else the first one.
    public static func compare(_ cells: [Cell], iterations: Int = 2000, seed: UInt64 = 1) -> ControlComparison {
        var order: [ControlSetup] = []
        for cell in cells where !order.contains(cell.setup) { order.append(cell.setup) }
        let rows = order.map { setup in row(setup, cells: cells.filter { $0.setup == setup }) }
        let baselines = rows.filter { $0.setup.patch == nil && !$0.setup.readOnly }
        let paired = rows.filter { $0.setup.patch != nil && !$0.setup.readOnly }.compactMap { variant -> Paired? in
            guard let baseline = baselines.first(where: { $0.setup.agent == variant.setup.agent }) ?? baselines.first else { return nil }
            return pair(baseline: baseline, variant: variant, iterations: iterations, seed: seed)
        }
        return ControlComparison(rows: rows, paired: paired)
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
        let counted = cells.filter { !$0.flagged }
        let tasks = Dictionary(grouping: counted, by: \.task).map { task, cells in
            TaskRate(task: task, passed: cells.filter(\.passed).count, total: cells.count)
        }.sorted { $0.task < $1.task }
        let passed = counted.filter(\.passed).count
        let k = tasks.map(\.total).min() ?? 0
        // pass^k per task, unbiased when a task has more than k cells: C(c, k) / C(n, k).
        let hatK = tasks.map { task in task.passed < k ? 0 : exp(Stats.logChoose(task.passed, k) - Stats.logChoose(task.total, k)) }
        let passHatK = tasks.isEmpty ? nil : hatK.reduce(0, +) / Double(tasks.count)
        return Row(setup: setup, tasks: tasks, cells: counted.count, flagged: cells.count - counted.count,
                   passAt1: tasks.isEmpty ? nil : tasks.map(\.rate).reduce(0, +) / Double(tasks.count),
                   passAt1Interval: Stats.wilson(passed, counted.count), k: k,
                   passHatK: passHatK,
                   passHatKInterval: interval(ofMean: hatK))
    }

    /// The paired bootstrap over tasks of the per-task change in pass rate (seeded, so the
    /// same cells give the same share). "Helped" is fixed before the run: ≥ 95% of the mass
    /// on improvement, with at least 3 repeats of every task and 15 cells on each side.
    static func pair(baseline: Row, variant: Row, iterations: Int, seed: UInt64) -> Paired {
        let before = Dictionary(uniqueKeysWithValues: baseline.tasks.map { ($0.task, $0) })
        let shared = variant.tasks.compactMap { after in before[after.task].map { (before: $0, after: after) } }
        let baselineCells = shared.map(\.before.total).reduce(0, +)
        let variantCells = shared.map(\.after.total).reduce(0, +)
        let changes = shared.map { $0.after.rate - $0.before.rate }
        var result = Paired(baseline: baseline.setup, variant: variant.setup, tasks: shared.count, baselineCells: baselineCells,
                            variantCells: variantCells, meanChange: changes.isEmpty ? nil : changes.reduce(0, +) / Double(changes.count),
                            improvementShare: nil, verdict: .noConclusion, reason: "")
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
        } else if share >= helpedShare {
            result.verdict = .helped
            result.reason = "\(percent) of the bootstrap mass on improvement (needs \(Int(helpedShare * 100))%)."
        } else {
            result.verdict = .notShown
            result.reason = "Only \(percent) of the bootstrap mass on improvement (needs \(Int(helpedShare * 100))%)."
        }
        return result
    }
}
