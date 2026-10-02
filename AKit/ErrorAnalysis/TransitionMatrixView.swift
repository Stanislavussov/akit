import AKitErrorAnalysis
import SwiftUI

/// The transition matrix of a report (`docs/design/error-analysis.md`, "Transition matrix"):
/// rows are the phase of the step before the decisive one, columns the decisive step's phase
/// and "no failures". Hidden with the reason when the bootstrap's phase agreement is too low; a
/// funnel for small N; side by side or as a difference against a second batch.
struct TransitionMatrixSection: View {
    enum Normalisation: String, CaseIterable {
        case batch, row
        var title: String { self == .batch ? "Share of the batch" : "Share of the row" }
    }

    enum Comparison: String, CaseIterable {
        case sideBySide, difference
        var title: String { self == .sideBySide ? "Side by side" : "Difference" }
    }

    let report: BatchReport
    let other: BatchReport?
    @State private var normalisation = Normalisation.batch
    /// Snapshots: `--tab reports --query <batch> --capture` shows the difference.
    @State private var comparison = DebugSnapshot.options?.capture == true ? Comparison.difference : .sideBySide
    @State private var drill: MatrixCell?

    static let columns = Phase.allCases.map(\.rawValue) + [TransitionMatrix.noFailures]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(report.showFunnel ? "Deviations per phase" : "Transition matrix").font(.title3.bold())
                Spacer()
                if report.matrixHidden == nil, !report.showFunnel {
                    if other != nil {
                        Picker("Compare", selection: $comparison) {
                            ForEach(Comparison.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    if other == nil || comparison == .sideBySide {
                        Picker("Normalise", selection: $normalisation) {
                            ForEach(Normalisation.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        .help("Batch: where it is hot. Row: where the agent slips after this phase.")
                    }
                }
            }
            if let hidden = report.matrixHidden {
                Label(hidden, systemImage: "eye.slash")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if report.showFunnel {
                Text("Fewer than \(Reports.funnelBelow) sessions of this project in batches: the decisive step's phase only, not the 6×7 matrix.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: 32) {
                    FunnelView(matrix: report.matrix, title: other == nil ? nil : "This batch")
                    if let other { FunnelView(matrix: other.matrix, title: "Compared batch") }
                }
            } else if let other, comparison == .difference {
                DifferenceGrid(before: other.matrix, after: report.matrix)
            } else {
                Text("Row: the phase of the step before the decisive one. Column: the phase of the decisive step. Click a cell for its sessions.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let other {
                    let scale = max(MatrixGrid.maxShare(report.matrix, normalisation), MatrixGrid.maxShare(other.matrix, normalisation))
                    HStack(alignment: .top, spacing: 24) {
                        MatrixGrid(matrix: report.matrix, title: "This batch · N \(report.matrix.sessions)", normalisation: normalisation,
                                   scale: scale) { drill = MatrixCell(row: $0, column: $1, sessions: report.matrix.sessions($0, $1)) }
                        MatrixGrid(matrix: other.matrix, title: "Compared batch · N \(other.matrix.sessions)", normalisation: normalisation,
                                   scale: scale) { drill = MatrixCell(row: $0, column: $1, sessions: other.matrix.sessions($0, $1)) }
                    }
                    Text("One colour scale for both.").font(.caption).foregroundStyle(.secondary)
                } else {
                    MatrixGrid(matrix: report.matrix, title: "N \(report.matrix.sessions)", normalisation: normalisation,
                               scale: MatrixGrid.maxShare(report.matrix, normalisation)) {
                        drill = MatrixCell(row: $0, column: $1, sessions: report.matrix.sessions($0, $1))
                    }
                }
            }
            if report.matrixHidden == nil, !report.matrix.unlocated.isEmpty || !(other?.matrix.unlocated.isEmpty ?? true) {
                Text("\(report.matrix.unlocated.count) sessions with failures but no decisive step are left out"
                     + (other.map { " (\($0.matrix.unlocated.count) in the compared batch)" } ?? "") + ".")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(item: $drill) { MatrixDrillSheet(cell: $0) }
    }
}

/// A clicked cell: its sessions.
struct MatrixCell: Identifiable {
    let row: Phase
    let column: String
    let sessions: [String]
    var id: String { "\(row.rawValue)|\(column)" }
}

private func columnTitle(_ column: String) -> String {
    column == TransitionMatrix.noFailures ? "No failures" : Phase(rawValue: column)?.title ?? column
}

/// The 6×7 grid: count and share in every cell, colour by share.
private struct MatrixGrid: View {
    let matrix: TransitionMatrix
    let title: String
    let normalisation: TransitionMatrixSection.Normalisation
    /// The share that gets the full colour.
    let scale: Double
    let open: (Phase, String) -> Void

    static func share(_ matrix: TransitionMatrix, _ row: Phase, _ column: String, _ normalisation: TransitionMatrixSection.Normalisation) -> Double {
        let count = matrix.count(row, column)
        let total = normalisation == .batch ? matrix.sessions : TransitionMatrixSection.columns.map { matrix.count(row, $0) }.reduce(0, +)
        return total > 0 ? Double(count) / Double(total) : 0
    }

    /// The largest share of a failure cell ("no failures" isn't a hot spot).
    static func maxShare(_ matrix: TransitionMatrix, _ normalisation: TransitionMatrixSection.Normalisation) -> Double {
        let shares = Phase.allCases.flatMap { row in Phase.allCases.map { share(matrix, row, $0.rawValue, normalisation) } }
        return max(shares.max() ?? 0, 0.01)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Grid(horizontalSpacing: 3, verticalSpacing: 3) {
                GridRow {
                    Text("before ↓ / decisive →").font(.caption2).foregroundStyle(.secondary)
                    ForEach(TransitionMatrixSection.columns, id: \.self) { column in
                        Text(columnTitle(column)).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                ForEach(Phase.allCases, id: \.self) { row in
                    GridRow {
                        Text(row.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        ForEach(TransitionMatrixSection.columns, id: \.self) { column in
                            cell(row, column)
                        }
                    }
                }
            }
        }
    }

    private func cell(_ row: Phase, _ column: String) -> some View {
        let count = matrix.count(row, column)
        let share = Self.share(matrix, row, column, normalisation)
        let clear = column == TransitionMatrix.noFailures
        let tint: Color = clear ? .green : .red
        return Button { open(row, column) } label: {
            VStack(spacing: 0) {
                Text("\(count)").font(.callout.weight(.semibold))
                Text(AnalysisText.percent(share)).font(.caption2).foregroundStyle(.secondary)
            }
            .monospacedDigit()
            .frame(width: 62, height: 40)
            .background(tint.opacity(count == 0 ? 0.03 : 0.08 + 0.55 * min(share / scale, 1)), in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(count == 0)
        .help("\(row.title) → \(columnTitle(column)): \(count) sessions")
    }
}

/// The change of every cell's share from the compared batch to this one: red worse, green
/// better, grey within noise (Fisher p ≥ 0.05), dimmed when both sides are too small.
private struct DifferenceGrid: View {
    let before: TransitionMatrix
    let after: TransitionMatrix

    var body: some View {
        let differences = TransitionMatrix.difference(before: before, after: after)
        VStack(alignment: .leading, spacing: 6) {
            Text("This batch (N \(after.sessions)) against the compared one (N \(before.sessions))").font(.headline)
            Grid(horizontalSpacing: 3, verticalSpacing: 3) {
                GridRow {
                    Text("before ↓ / decisive →").font(.caption2).foregroundStyle(.secondary)
                    ForEach(TransitionMatrixSection.columns, id: \.self) { column in
                        Text(columnTitle(column)).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                ForEach(Phase.allCases, id: \.self) { row in
                    GridRow {
                        Text(row.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        ForEach(TransitionMatrixSection.columns, id: \.self) { column in
                            cell(differences["\(row.rawValue)|\(column)"], better: column == TransitionMatrix.noFailures)
                        }
                    }
                }
            }
            HStack(spacing: 14) {
                legend(.red, "worse")
                legend(.green, "better")
                legend(.gray, "within noise")
                Text("Faint: fewer than \(TransitionMatrix.minimumCell) sessions on both sides").foregroundStyle(.secondary)
            }
            .font(.caption)
        }
    }

    /// `better`: in "no failures" a rise is good news.
    @ViewBuilder private func cell(_ difference: TransitionMatrix.Difference?, better: Bool) -> some View {
        if let difference {
            let improved = better ? difference.change > 0 : difference.change < 0
            let color: Color = difference.withinNoise ? .gray : improved ? .green : .red
            VStack(spacing: 0) {
                Text(String(format: "%+.0f%%", difference.change * 100)).font(.callout.weight(.semibold))
                Text("\(difference.before) → \(difference.after)").font(.caption2).foregroundStyle(.secondary)
            }
            .monospacedDigit()
            .frame(width: 62, height: 40)
            .background(color.opacity(difference.withinNoise ? 0.12 : 0.15 + 0.5 * min(abs(difference.change) / 0.3, 1)),
                        in: RoundedRectangle(cornerRadius: 4))
            .opacity(difference.dimmed ? 0.4 : 1)
            .help(difference.withinNoise ? "Within noise (Fisher p ≥ 0.05)" : improved ? "Better" : "Worse")
        } else {
            Text("·").foregroundStyle(.tertiary).frame(width: 62, height: 40)
        }
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color.opacity(0.4)).frame(width: 12, height: 10)
            Text(text)
        }
    }
}

/// Deviations per phase of the decisive step, as bars.
private struct FunnelView: View {
    let matrix: TransitionMatrix
    let title: String?

    var body: some View {
        let funnel = matrix.funnel
        let top = max(funnel.values.max() ?? 1, 1)
        VStack(alignment: .leading, spacing: 4) {
            Text((title.map { "\($0) · " } ?? "") + "N \(matrix.sessions)").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                ForEach(TransitionMatrixSection.columns, id: \.self) { column in
                    let count = funnel[column] ?? 0
                    GridRow {
                        Text(columnTitle(column)).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(column == TransitionMatrix.noFailures ? Color.green.opacity(0.5) : Color.red.opacity(0.5))
                            .frame(width: max(2, 220 * CGFloat(count) / CGFloat(top)), height: 14)
                        Text("\(count)").monospacedDigit()
                    }
                }
            }
            .font(.callout)
        }
    }
}

/// The sessions of one cell with their notes (step + quote), and each session's full notes.
private struct MatrixDrillSheet: View {
    @Environment(AnalysisModel.self) private var analysis
    @Environment(\.dismiss) private var dismiss
    let cell: MatrixCell
    @State private var notesFor: SessionNotesTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(cell.row.title) → \(columnTitle(cell.column))").font(.title2.bold())
            Text("\(cell.sessions.count) sessions").foregroundStyle(.secondary)
            List(cell.sessions, id: \.self) { key in
                let notes = analysis.data.notes(of: key)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(notes?.title ?? key).fontWeight(.medium).lineLimit(1)
                        if let outcome = notes?.outcome { OutcomeBadge(outcome: outcome) }
                        Spacer()
                        if notes != nil {
                            Button("Show Session Notes") { notesFor = SessionNotesTarget(sessionKey: key) }
                                .controlSize(.small)
                                .help("The session's outcome, paragraph, all notes, advice, routes and signals")
                        }
                    }
                    if let notes {
                        let decisive = notes.deviation.decisiveStep
                        ForEach(notes.accepted.sorted { ($0.step == decisive ? 0 : 1, $0.step) < ($1.step == decisive ? 0 : 1, $1.step) }) { note in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Step #\(note.step)\(note.step == decisive ? " · decisive" : "") · \(note.description)")
                                    .fixedSize(horizontal: false, vertical: true)
                                QuoteText(text: note.quote)
                            }
                        }
                        if notes.accepted.isEmpty { Text("No accepted notes: nothing went wrong.").foregroundStyle(.secondary) }
                    } else {
                        Text("Its notes are no longer in the pool.").foregroundStyle(.secondary)
                    }
                }
                .textSelection(.enabled)
                .padding(.vertical, 4)
            }
            .frame(height: 420)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640)
        .sheet(item: $notesFor) { SessionNotesSheet(sessionKey: $0.sessionKey) }
    }
}
