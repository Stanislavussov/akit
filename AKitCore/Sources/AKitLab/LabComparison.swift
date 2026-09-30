import Foundation

/// Replays of one commit side by side, one row per setup. LLM runs vary, so each number
/// comes as the median and the range, never only a mean.
public struct LabComparison: Sendable, Hashable {
    public struct Spread: Sendable, Hashable {
        public var median: Int
        public var min: Int
        public var max: Int

        init?(_ values: [Int]) {
            guard !values.isEmpty else { return nil }
            let sorted = values.sorted()
            let middle = sorted.count / 2
            median = sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
            min = sorted[0]
            max = sorted[sorted.count - 1]
        }
    }

    public struct Row: Sendable, Hashable, Identifiable {
        public var id: String { setup }
        public var setup: String
        /// Finished runs that count.
        public var runs: Int
        public var passed: Int
        public var freshTokens: Spread?
        public var calls: Spread?
        public var wallSeconds: Spread?
        /// Finished runs left out because they saw the answer.
        public var leaked: Int
        /// Queued or running.
        public var pending: Int
        /// Error or cancelled.
        public var failed: Int
    }

    public var commit: String
    public var rows: [Row]

    /// Rows for the replays of `commit`, in setup order of first appearance.
    public static func compare(commit: String, runs: [LabRun]) -> LabComparison {
        let replays = runs.filter { $0.spec.kind == .replay && $0.spec.commit == commit }
            .sorted { $0.spec.createdAt < $1.spec.createdAt }
        var order: [String] = []
        var groups: [String: [LabRun]] = [:]
        for run in replays {
            let label = run.spec.setup?.label ?? "?"
            if groups[label] == nil { order.append(label) }
            groups[label, default: []].append(run)
        }
        let rows = order.map { label -> Row in
            let group = groups[label] ?? []
            let finished = group.filter { $0.status == .finished }
            let counted = finished.filter { !($0.result?.leaked ?? false) }
            let metrics = counted.compactMap { $0.result?.metrics }
            return Row(setup: label, runs: counted.count,
                       passed: counted.filter { $0.result?.tests?.status == .passed }.count,
                       freshTokens: Spread(metrics.map(\.freshTokens)), calls: Spread(metrics.map(\.calls)),
                       wallSeconds: Spread(metrics.compactMap(\.wallSeconds)),
                       leaked: finished.count - counted.count,
                       pending: group.filter { $0.status == .queued || $0.status == .running }.count,
                       failed: group.filter { $0.status == .error || $0.status == .cancelled }.count)
        }
        return LabComparison(commit: commit, rows: rows)
    }

    /// Plain-text table for `akit lab compare`.
    public var text: String {
        var lines = ["Replays of \(commit.prefix(7))", ""]
        for row in rows {
            var line = "\(row.setup): \(row.passed)/\(row.runs) passed"
            if let fresh = row.freshTokens {
                line += " · fresh \(MetricsText.short(fresh.median)) (\(MetricsText.short(fresh.min))–\(MetricsText.short(fresh.max)))"
            }
            if let calls = row.calls { line += " · calls \(calls.median) (\(calls.min)–\(calls.max))" }
            if let wall = row.wallSeconds { line += " · wall \(MetricsText.duration(wall.median))" }
            var extra: [String] = []
            if row.pending > 0 { extra.append("\(row.pending) to run") }
            if row.failed > 0 { extra.append("\(row.failed) stopped") }
            if row.leaked > 0 { extra.append("\(row.leaked) left out: saw the answer") }
            if !extra.isEmpty { line += " [\(extra.joined(separator: ", "))]" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}
