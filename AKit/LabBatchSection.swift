import AKitErrorAnalysis
import AKitFoundation
import AKitLab
import SwiftUI

/// An error analysis run in the Lab: progress per step read from its batch file, every
/// session with its status, and Pause / Resume / Retry Errors / Open Report.
struct LabBatchSection: View {
    @Environment(AppModel.self) private var model
    let run: LabRun
    /// Selects the run a resume queued.
    let select: (LabRun) -> Void
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        if let id = run.spec.batch {
            if let batch = model.labBatches[id] {
                content(batch)
            } else {
                Text("The batch file \(id) is missing from ~/.akit/lab/analysis/batches.").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func content(_ batch: Batch) -> some View {
        let total = batch.sessions.count
        let failed = batch.sessions.filter { $0.status == .error }.count
        VStack(alignment: .leading, spacing: 10) {
            Text("Batch").font(.title3.bold())
            Text(summary(batch))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                step("Notes", batch.progress(of: "notes"), total)
                step("Verifier", batch.progress(of: "verifier"), total)
                step("Matching", batch.progress(of: "matching"), total)
                if batch.sessions.contains(where: { $0.steps.contains("checks") }) {
                    step("Judges", batch.progress(of: "checks"), total)
                }
                GridRow {
                    Text("Clustering").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Text(batch.clustered ? "done" : "not yet").foregroundStyle(batch.clustered ? .green : .secondary)
                    Text(batch.clustered ? "\(batch.candidates.count) candidates" : "")
                        .foregroundStyle(.secondary)
                }
            }
            .monospacedDigit()
            if batch.paused {
                Label("Paused: the worker stops after its current calls. Resume continues from the same place.", systemImage: "pause.circle")
                    .foregroundStyle(.orange)
            }
            actions(batch, failed: failed)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        sessions(batch)
    }

    private func summary(_ batch: Batch) -> String {
        let coverage = batch.coverage
        let failed = batch.sessions.filter { $0.status == .error }.count
        var parts = [batch.fixed ? "Fixed sessions (the labeled bootstrap ones)" : "A sample of \(batch.sessions.count) (asked \(batch.size), seed \(batch.seed))"]
        parts.append(batch.filter.project.map { "project \(URL(filePath: $0).lastPathComponent)" } ?? "all projects")
        if let from = batch.filter.from { parts.append("from \(from.formatted(date: .abbreviated, time: .omitted))") }
        if let to = batch.filter.to { parts.append("to \(to.formatted(date: .abbreviated, time: .omitted))") }
        parts.append("notes by \(batch.notesAgent.label)")
        if batch.matchingAgent != batch.notesAgent { parts.append("matching by \(batch.matchingAgent.model)") }
        parts.append("\(coverage.done) of \(coverage.total) done" + (failed > 0 ? ", \(failed) failed" : ""))
        return parts.joined(separator: " · ")
    }

    private func step(_ name: String, _ done: Int, _ total: Int) -> some View {
        GridRow {
            Text(name).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            ProgressView(value: Double(done), total: Double(max(total, 1)))
                .frame(width: 180)
            Text("\(done)/\(total)")
        }
    }

    private func actions(_ batch: Batch, failed: Int) -> some View {
        let active = model.labRuns.contains { $0.spec.batch == batch.runID && ($0.status == .queued || $0.status == .running) }
        let unfinished = batch.sessions.contains { $0.status != .done } || !batch.clustered
        return HStack {
            if active, !batch.paused {
                Button("Pause", systemImage: "pause.circle") { act { try await model.pauseBatch(batch.runID) } }
                    .help("Stop after the current calls; Resume continues from the same place")
            }
            if !active, unfinished {
                Button("Resume", systemImage: "play.circle") { resume(batch, retryErrors: false) }
                    .help("Continue the batch as a new run, from where it stopped")
            }
            if !active, failed > 0 {
                Button("Retry Errors", systemImage: "arrow.clockwise") { resume(batch, retryErrors: true) }
                    .help("Run only the \(failed) failed sessions again; their old results stay until a retry succeeds")
            }
            if batch.coverage.done > 0 {
                Button("Open Report", systemImage: "chart.bar.doc.horizontal") {
                    model.revealBatch = batch.runID
                    model.section = .analysis
                }
                .help("Error Analysis → Reports with this batch")
            }
            if busy { ProgressView().controlSize(.small) }
        }
        .controlSize(.small)
        .disabled(busy)
    }

    private func sessions(_ batch: Batch) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sessions").font(.title3.bold())
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("Status")
                    Text("Session")
                    Text("π").help("Inclusion probability: how likely this sampling design was to pick the session")
                    Text("Sampled")
                    Text("Last step")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                Divider()
                ForEach(batch.sessions, id: \.pick.sessionKey) { session in
                    GridRow {
                        BatchStatusBadge(status: session.status)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title(session)).lineLimit(1)
                            if let message = session.message {
                                Text(message)
                                    .font(.caption)
                                    .foregroundStyle(session.status == .error ? .red : .secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                        }
                        Text(String(format: "%.2f", session.pick.inclusion)).monospacedDigit()
                        Text(session.pick.sampling == "random" ? "random" : session.pick.sampling.replacingOccurrences(of: "stratum:", with: ""))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(session.pick.stratum)
                        Text(session.steps.last ?? "—").foregroundStyle(.secondary).lineLimit(1)
                            .help(session.steps.joined(separator: " → "))
                    }
                }
            }
            .font(.callout)
        }
    }

    private func title(_ session: Batch.Session) -> String {
        model.sessions.first { $0.file.path == session.pick.file }?.title ?? session.pick.sessionKey
    }

    private func resume(_ batch: Batch, retryErrors: Bool) {
        act {
            let queued = try await model.resumeBatch(batch.runID, retryErrors: retryErrors)
            select(queued)
        }
    }

    private func act(_ work: @escaping () async throws -> Void) {
        error = nil
        busy = true
        Task {
            do { try await work() } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

/// pending / running / done / error as a small capsule.
struct BatchStatusBadge: View {
    let status: Batch.Status

    var body: some View {
        Text(status.rawValue)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch status {
        case .pending: .secondary
        case .running: .blue
        case .done: .green
        case .error: .red
        }
    }
}
