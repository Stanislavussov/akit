import AKitErrorAnalysis
import AKitFoundation
import SwiftUI

/// A batch's report (`akit analysis report [BATCH] [--compare BATCH]`): coverage and the
/// quality of its notes, mode frequencies from checks only, saturation, and the transition
/// matrix, optionally against a second batch.
struct ReportsTab: View {
    @Environment(AnalysisModel.self) private var analysis
    @State private var report: BatchReport?
    @State private var other: BatchReport?
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        @Bindable var analysis = analysis
        let batches = analysis.data.batches
        VStack(spacing: 0) {
            HStack {
                Picker("Batch", selection: $analysis.reportBatch) {
                    ForEach(batches, id: \.runID) { Text(title($0)).tag(String?.some($0.runID)) }
                }
                .frame(maxWidth: 380)
                Picker("Compare with", selection: $analysis.compareBatch) {
                    Text("Nothing").tag(String?.none)
                    ForEach(batches.filter { $0.runID != analysis.reportBatch }, id: \.runID) {
                        Text(title($0)).tag(String?.some($0.runID))
                    }
                }
                .frame(maxWidth: 380)
                if loading { ProgressView().controlSize(.small) }
                Spacer()
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            content
        }
        .task(id: "\(analysis.reportBatch ?? "")|\(analysis.compareBatch ?? "")|\(batches.count)|\(analysis.data.trust.count)") {
            if analysis.reportBatch == nil || !batches.contains(where: { $0.runID == analysis.reportBatch }) {
                analysis.reportBatch = batches.first?.runID
            }
            await load()
        }
    }

    @ViewBuilder private var content: some View {
        if analysis.data.batches.isEmpty {
            ContentUnavailableView("No Batches Yet", systemImage: "chart.bar.doc.horizontal",
                                   description: Text("Lab → New Run… → Error Analysis Batch samples sessions of the index and reviews them. Its report shows here."))
        } else if let error {
            ContentUnavailableView("No Report", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if let report {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        ReportHeader(report: report, batch: analysis.data.batches.first { $0.runID == report.batchID })
                        ReportFrequencies(report: report)
                        ReportSaturation(report: report)
                        TransitionMatrixSection(report: report, other: other).id("matrix")
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .task(id: report.batchID) {
                    // Snapshots: `--tab reports --add` scrolls to the matrix.
                    guard DebugSnapshot.options?.add == true else { return }
                    try? await Task.sleep(for: .milliseconds(300))
                    proxy.scrollTo("matrix", anchor: .top)
                }
            }
        } else {
            ProgressView("Building the report…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func title(_ batch: Batch) -> String {
        let coverage = batch.coverage
        let project = batch.filter.project.map { URL(filePath: $0).lastPathComponent } ?? (batch.fixed ? "bootstrap" : "all projects")
        return "\(batch.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(project) · \(coverage.done)/\(coverage.total)"
    }

    /// Builds the reports off the main thread: phases read every session's transcript.
    private func load() async {
        guard let id = analysis.reportBatch, let batch = analysis.data.batches.first(where: { $0.runID == id }) else {
            report = nil
            other = nil
            return
        }
        let compared = analysis.compareBatch.flatMap { id in analysis.data.batches.first { $0.runID == id } }
        let env = analysis.env
        loading = true
        defer { loading = false }
        do {
            let built = try await Task.detached { () -> (BatchReport, BatchReport?) in
                let first = try await Reports.build(batch, env: env)
                var second: BatchReport?
                if let compared { second = try await Reports.build(compared, env: env) }
                return (first, second)
            }.value
            error = nil
            report = built.0
            other = built.1
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Coverage, the notes version and its bootstrap recall, verifier rejection and spot-check
/// precision with their counts; route acceptance, which is over the whole pool, apart.
private struct ReportHeader: View {
    let report: BatchReport
    let batch: Batch?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Batch \(report.batchID)").font(.title2.bold()).textSelection(.enabled)
                if let batch {
                    Text("\(batch.createdAt.formatted(date: .abbreviated, time: .shortened)) · notes by \(batch.notesAgent.model)")
                        .foregroundStyle(.secondary)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 220), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                tile("Coverage", "\(report.coverage[0])/\(report.coverage[1])", counts: nil, coverage)
                tile("Notes recall", AnalysisText.percent(report.notesRecall), counts: report.notesRecallCounts,
                     report.notesVersion.map { "of your bootstrap problems, found and kept by the verifier · \($0)" } ?? "no notes version")
                tile("Verifier rejected", AnalysisText.percent(report.verifierRejection), counts: report.verifierRejectionCounts,
                     "of the model's notes in this batch")
                tile("Spot checks", AnalysisText.percent(report.spotCheckPrecision), counts: report.spotCheckCounts,
                     report.spotCheckPrecision == nil ? "no spot checks yet: answer them on the Review tab"
                                                      : "precision: notes you agreed are real problems")
                tile("Routes accepted · whole pool", report.routeAcceptance[1] == 0 ? "—" : "\(report.routeAcceptance[0])/\(report.routeAcceptance[1])",
                     counts: nil, "of the routes you reviewed in every batch, not just this one")
            }
        }
    }

    /// Done of all; the rest is still running, waiting while paused, or failed.
    private var coverage: String {
        guard let batch else { return report.coverage[0] < report.coverage[1] ? "sessions done; the rest aren't" : "sessions done" }
        let open = batch.sessions.filter { $0.status == .pending || $0.status == .running }.count
        let failed = batch.sessions.filter { $0.status == .error }.count
        var parts = ["sessions done"]
        if open > 0 { parts.append(batch.paused ? "\(open) waiting, paused" : "\(open) still running") }
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.joined(separator: " · ")
    }

    private func tile(_ title: String, _ value: String, counts: [Int]?, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value).font(.title2.weight(.semibold))
                if let counts, counts.count == 2, counts[1] > 0 {
                    Text("\(counts[0])/\(counts[1])").font(.callout).foregroundStyle(.secondary)
                }
            }
            .monospacedDigit()
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Unmatched share and new modes, overall and per project, with the rebuild suggestion.
private struct ReportSaturation: View {
    @Environment(AnalysisModel.self) private var analysis
    let report: BatchReport

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Saturation").font(.title3.bold())
            Text("\(AnalysisText.percent(report.unmatchedShare)) of the notes matched no mode · new modes: \(report.newModes.isEmpty ? "none" : report.newModes.joined(separator: ", "))")
            if !report.projects.isEmpty {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow {
                        Text("Project")
                        Text("Sessions")
                        Text("Unmatched")
                        Text("New modes")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    ForEach(report.projects.sorted { $0.key < $1.key }, id: \.key) { project, saturation in
                        GridRow {
                            Text(project)
                            Text("\(saturation.sessions)").monospacedDigit()
                            Text(AnalysisText.percent(saturation.unmatchedShare)).monospacedDigit()
                            Text("\(saturation.newModes)").monospacedDigit()
                        }
                    }
                }
                .font(.callout)
            }
            Text("Both near zero for several runs in a row: the list of modes is saturated.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let rebuild = report.rebuild {
                HStack {
                    Label(rebuild, systemImage: "arrow.triangle.2.circlepath")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Cluster All Notes Again…") { analysis.send = .rebuild(analysis.data, model: analysis) }
                        .help("Cluster every note from scratch, without the list, to compare with it; nothing is saved (a model call; the cost first)")
                }
                .padding(10)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
            if let candidates = analysis.rebuild {
                RebuildResult(candidates: candidates)
            }
        }
    }
}

/// What clustering from scratch made, next to the current list; not saved.
private struct RebuildResult: View {
    @Environment(AnalysisModel.self) private var analysis
    let candidates: [Clustering.Candidate]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Clustered from scratch: \(candidates.count) groups (not saved)").font(.headline)
                Spacer()
                Button("Dismiss") { analysis.rebuild = nil }.controlSize(.small)
            }
            ForEach(candidates, id: \.self) { candidate in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(candidate.name) · \(AnalysisText.notes(candidate.notes.count))").fontWeight(.medium)
                    Text(candidate.definition).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    let modes = Set(candidate.notes.compactMap { ref in modeOf(ref) })
                    if modes.count > 1 {
                        Text("Spans \(modes.sorted().joined(separator: ", ")): an umbrella, or modes to merge.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .textSelection(.enabled)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func modeOf(_ ref: NoteRef) -> String? {
        analysis.data.seenByMode.first { $0.value.contains(ref) }?.key
    }
}

extension AnalysisSend {
    /// `akit analysis cluster --rebuild`: every note clustered from scratch, without the list
    /// of modes, to compare with it. Shown, never saved.
    static func rebuild(_ data: AnalysisData, model: AnalysisModel) -> AnalysisSend {
        let items = Clustering.items(data.pool)
        return AnalysisSend(
            title: "Cluster All Notes Again",
            detail: "One call over all \(AnalysisText.notes(items.count)) of the pool, without the list of modes: a rebuild from scratch to compare with the list. Nothing is saved.",
            characters: items.map { $0.description.count + $0.quote.count + 60 }.reduce(0, +)
        ) { agent, gate, env in
            let store = ModeStore(env: env)
            let items = Clustering.items(NotesStore(env: env).all())
            guard !items.isEmpty else { return "No notes to cluster." }
            var leftOut: [String] = []
            let candidates = try await Clustering.cluster(items, existing: try await store.list(), rejected: try await store.rejectedNames(),
                                                          rebuild: true, agent: agent, gate: gate, runID: nil,
                                                          workFolder: AnalysisModel.workFolder(env), env: env, out: { leftOut.append($0) })
            await MainActor.run { model.rebuild = candidates }
            return withLeftOut("Clustered \(items.count) notes from scratch into \(candidates.count) groups; nothing was saved.", leftOut)
        }
    }
}
