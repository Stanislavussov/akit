import AKitErrorAnalysis
import AKitFoundation
import AKitLab
import SwiftUI

/// `akit analysis control compare`: pass@1 and pass^k per setup with Wilson intervals, and
/// for each variant the paired bootstrap over tasks and its verdict, guarded by the fix's
/// production signal. Flagged cells (dropped or changed tests, a leak) count as failed.
struct ControlComparisonView: View {
    @Environment(AppModel.self) private var model
    let tasks: [ControlTask]
    /// What a comparison is computed from: the finished cells of the tasks, and the state of
    /// every cell of the layer evals among them (the verdict waits for all of an eval's cells).
    private struct Inputs: Hashable {
        var cells: [ControlComparison.Cell]
        var evalRuns: [String]
    }
    /// The comparison of the inputs it was computed for: the bootstrap, the production signal
    /// (the mode's check before and after the fix) and the layer evals' verdicts run off the
    /// main thread, once per change of the inputs.
    @State private var computed: (inputs: Inputs, comparison: ControlComparison, verdicts: [String: LayerVerdict])?
    /// Why the production signal couldn't be read; the comparison then has none.
    @State private var productionError: String?
    /// Why a layer verdict couldn't be saved.
    @State private var verdictError: String?

    var body: some View {
        let ids = Set(tasks.map(\.id))
        let runs = model.labRuns.filter { $0.spec.kind == .control && $0.spec.controlTask.map(ids.contains) == true }
        let open = runs.filter { $0.status == .queued || $0.status == .running }.count
        let cells = ControlComparison.Cell.of(runs)
        let evals = Set(cells.compactMap { $0.setup.layer?.evalID })
        let evalRuns = model.labRuns.filter { run in
            run.spec.kind == .control && run.spec.controlSetup?.layer.map { evals.contains($0.evalID) } == true
        }
        let inputs = Inputs(cells: cells, evalRuns: evalRuns.map { "\($0.id) \($0.status.rawValue)" })
        VStack(alignment: .leading, spacing: 12) {
            Text(tasks.count == 1 ? "Setups compared" : "Setups compared over \(tasks.count) tasks").font(.title3.bold())
            if let computed, computed.inputs == inputs {
                results(computed.comparison, verdicts: computed.verdicts, evalRuns: evalRuns, open: open)
            } else if cells.isEmpty {
                Text("No finished cells yet." + (open > 0 ? " \(open) queued or running." : " Run Cells… queues them in the Lab."))
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: inputs) {
            guard computed?.inputs != inputs else { return }
            let tasks = tasks
            let result = await Task.detached { () -> (ControlComparison, String?, [String: LayerVerdict], String?) in
                var production: FixEvaluation?
                var failure: String?
                do { production = try await ControlComparison.production(for: tasks, env: .current) } catch { failure = error.localizedDescription }
                // A finished layer eval's verdict is saved as the layer's last one for its agent.
                var verdicts: [String: LayerVerdict] = [:]
                var saveFailure: String?
                let costs = evals.isEmpty ? [:] : SendLog.runCosts(SendLog.records(env: .current))
                for id in evals {
                    guard let manifest = LayerEvalStore.manifest(id, env: .current),
                          let verdict = LayerVerdicts.verdict(of: manifest, runs: evalRuns, costs: costs) else { continue }
                    verdicts[id] = verdict
                    do { try LayerVerdicts.save(verdict, env: .current) } catch { saveFailure = error.localizedDescription }
                }
                return (ControlComparison.compare(cells, production: production), failure, verdicts, saveFailure)
            }.value
            computed = (inputs, result.0, result.2)
            productionError = result.1
            verdictError = result.3
        }
    }

    @ViewBuilder private func results(_ comparison: ControlComparison, verdicts: [String: LayerVerdict], evalRuns: [LabRun],
                                      open: Int) -> some View {
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
                let eval = pair.variant.layer?.evalID
                PairedVerdict(pair: pair, verdict: eval.flatMap { verdicts[$0] },
                              waiting: evalRuns.filter { run in
                                  run.spec.controlSetup?.layer?.evalID == eval && (run.status == .queued || run.status == .running)
                              }.count)
            }
            if open > 0 {
                Text("\(open) cells still queued or running.").foregroundStyle(.secondary)
            }
            if comparison.leftOut > 0 {
                Label("\(comparison.leftOut) cells run by an older akit, left out: it ignored the layer. Install the app and akit together.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let productionError {
                Label("The production signal couldn't be read: \(productionError)", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let verdictError {
                Label("The layer's verdict couldn't be saved: \(verdictError)", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Helped: at least 95% of the bootstrap over tasks on improvement, with 3+ repeats of every task and 15+ cells a side, "
                 + "and not worse in production: at most 50% that the mode's failure rate rose after the fix was applied, with 15+ checked sessions on each side. "
                 + "Without production data (no applied fix yet) there is no conclusion. Fixed before the run. "
                 + "A brain layer is compared only with its own eval's required layers and has its own level, helps (offline): the same 95% "
                 + "without production data, unless a read-only cell of its eval passed. A fix never gets it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
                    Label("\(row.flagged) flagged, counted as failed", systemImage: "flag").font(.caption).foregroundStyle(.orange)
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
/// improvement and the verdict. A layer pair also shows the share on worse and its eval's
/// result lines once no cell of the eval is queued or running.
private struct PairedVerdict: View {
    let pair: ControlComparison.Paired
    let verdict: LayerVerdict?
    /// Cells of the layer pair's eval still queued or running.
    let waiting: Int

    var body: some View {
        let color: Color = switch pair.verdict {
        case .helped, .helpsOffline: .green
        case .notShown: .orange
        case .noConclusion: .secondary
        }
        let worse = pair.variant.layer != nil ? ", \(AnalysisText.percent(pair.worseShare)) on worse" : ""
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
                     + " over \(pair.tasks) tasks · \(AnalysisText.percent(pair.improvementShare)) of the bootstrap mass on improvement\(worse)")
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(pair.reason) Cells: baseline \(pair.baselineCells), variant \(pair.variantCells).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if pair.harnessVersions.count > 1 {
                    Label("The cells mix Claude Code versions: \(pair.harnessVersions.joined(separator: ", ")).", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let verdict {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Verdict of the eval (all its tasks), saved for the layer:").font(.caption.weight(.semibold))
                        ForEach(LayerVerdicts.lines(verdict), id: \.self) { line in
                            Text(line).font(.caption.monospaced()).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .textSelection(.enabled)
                    .padding(.top, 4)
                } else if pair.variant.layer != nil, waiting > 0 {
                    Text("The eval's verdict waits for \(waiting) cells still queued or running.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}
