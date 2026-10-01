import AKitErrorAnalysis
import AKitLab
import SwiftUI

/// `akit analysis control compare`: pass@1 and pass^k per setup with Wilson intervals, and
/// for each variant the paired bootstrap over tasks and its verdict. Flagged cells (dropped or
/// changed tests, a leak) are left out and counted.
struct ControlComparisonView: View {
    @Environment(AppModel.self) private var model
    let tasks: [ControlTask]

    var body: some View {
        let ids = Set(tasks.map(\.id))
        let runs = model.labRuns.filter { $0.spec.kind == .control && $0.spec.controlTask.map(ids.contains) == true }
        let open = runs.filter { $0.status == .queued || $0.status == .running }.count
        let comparison = ControlComparison.compare(ControlComparison.Cell.of(runs))
        VStack(alignment: .leading, spacing: 12) {
            Text(tasks.count == 1 ? "Setups compared" : "Setups compared over \(tasks.count) tasks").font(.title3.bold())
            if comparison.rows.isEmpty {
                Text("No finished cells yet." + (open > 0 ? " \(open) queued or running." : " Run Cells… queues them in the Lab."))
                    .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        Text("Setup")
                        Text("pass@1").help("The chance one run passes: the mean of the tasks' pass rates")
                        Text("pass^k").help("The share of tasks where all k runs passed")
                        Text("Cells")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    Divider()
                    ForEach(comparison.rows, id: \.setup) { row in
                        setupRow(row)
                    }
                }
                .font(.callout)
                ForEach(comparison.paired, id: \.variant) { pair in
                    PairedVerdict(pair: pair)
                }
                if open > 0 {
                    Text("\(open) cells still queued or running.").foregroundStyle(.secondary)
                }
                Text("Helped: at least 95% of the bootstrap over tasks on improvement, with 3+ repeats of every task and 15+ cells a side. Fixed before the run.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func setupRow(_ row: ControlComparison.Row) -> some View {
        GridRow {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.setup.label).fontWeight(.medium)
                ForEach(row.tasks, id: \.task) { rate in
                    Text("\(title(rate.task)): \(rate.passed)/\(rate.total)").font(.caption).foregroundStyle(.secondary)
                }
            }
            rate(row.passAt1, row.passAt1Interval)
            VStack(alignment: .leading, spacing: 2) {
                rate(row.passHatK, row.passHatKInterval)
                Text("k = \(row.k)").font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(row.cells)").monospacedDigit()
                if row.flagged > 0 {
                    Label("\(row.flagged) flagged, left out", systemImage: "flag").font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    private func rate(_ value: Double?, _ interval: Stats.Interval) -> some View {
        HStack(spacing: 8) {
            IntervalBar(value: value, interval: interval, scale: 1).frame(width: 120, height: 14)
            VStack(alignment: .leading, spacing: 0) {
                Text(AnalysisText.percent(value)).fontWeight(.semibold)
                Text("\(AnalysisText.percent(interval.low))–\(AnalysisText.percent(interval.high))").font(.caption).foregroundStyle(.secondary)
            }
            .monospacedDigit()
            .fixedSize()
        }
    }

    private func title(_ id: String) -> String { tasks.first { $0.id == id }?.title ?? id }
}

/// A variant against its baseline: the mean per-task change, the bootstrap share on
/// improvement and the verdict.
private struct PairedVerdict: View {
    let pair: ControlComparison.Paired

    var body: some View {
        let color: Color = switch pair.verdict {
        case .helped: .green
        case .notShown: .orange
        case .noConclusion: .secondary
        }
        HStack(alignment: .top, spacing: 10) {
            Text(pair.verdict.title)
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(color.opacity(0.18), in: Capsule())
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(pair.variant.name) against \(pair.baseline.name): "
                     + (pair.meanChange.map { String(format: "%+.0f points per task", 100 * $0) } ?? "no change measured")
                     + " over \(pair.tasks) tasks · \(AnalysisText.percent(pair.improvementShare)) of the bootstrap mass on improvement")
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(pair.reason) Cells: baseline \(pair.baselineCells), variant \(pair.variantCells).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}
