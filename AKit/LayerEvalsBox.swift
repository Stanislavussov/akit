import AKitErrorAnalysis
import AKitFoundation
import AKitLab
import SwiftUI

/// A layer's last eval verdict as a small badge (Brain list and layer page). Read from
/// `~/.akit/lab/evals/verdicts/<layer>.json`, never from the brain.
struct LayerVerdictBadge: View {
    let verdict: LayerVerdict

    var body: some View {
        let tint: Color = switch verdict.verdict {
        case .helped, .helpsOffline: .green
        case .notShown: .orange
        case .noConclusion: .secondary
        }
        Text(verdict.verdict.title)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .foregroundStyle(tint)
            .background(tint.opacity(0.12), in: Capsule())
            .help(LayerVerdicts.lines(verdict).joined(separator: "\n"))
    }
}

/// "Evals" on a brain layer's page (not on core): the last verdict per agent, evals still
/// running, and Evaluate… / Create Layer Set… / Show in Error Analysis.
struct LayerEvalsBox: View {
    @Environment(AppModel.self) private var model
    let layer: String
    /// The layer's stored verdicts, newest first.
    let verdicts: [LayerVerdict]
    let onEvaluate: () -> Void
    /// The layer's set (nil: none) and evals, read off the main thread.
    @State private var loaded: (set: LayerSet?, evals: [LayerEvalManifest])?
    @State private var error: String?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if verdicts.isEmpty {
                    Text("No verdict yet: Evaluate… runs the layer's set without the layer and with it.").foregroundStyle(.secondary)
                }
                ForEach(verdicts, id: \.evalID) { verdict in
                    HStack(spacing: 6) {
                        LayerVerdictBadge(verdict: verdict)
                        Text("\(verdict.model) · \(verdict.effort) · \(verdict.decidedAt.formatted(.dateTime.day().month(.abbreviated))) · @\(verdict.brainCommit.prefix(7))")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .help(LayerVerdicts.lines(verdict).joined(separator: "\n"))
                }
                ForEach(running, id: \.id) { eval in
                    Label("running: \(eval.finished) of \(eval.total) cells · eval of \(eval.created.formatted(.dateTime.day().month(.abbreviated)))",
                          systemImage: "hourglass")
                        .foregroundStyle(.secondary)
                }
                if let loaded {
                    if let set = loaded.set {
                        if set.tasks.isEmpty {
                            Text("The \(layer) set has no tasks yet: add them in Error Analysis → Evals (Add to Layer Set… on a task).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("Set: \(set.tasks.count) \(set.tasks.count == 1 ? "task" : "tasks")").font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("No layer set yet: the tasks an eval of \(layer) runs, kept on this Mac.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.caption)
                }
                HStack {
                    if let set = loaded?.set {
                        Button("Evaluate…", systemImage: "checkmark.seal", action: onEvaluate)
                            .buttonStyle(.borderedProminent)
                            .disabled(set.tasks.isEmpty)
                            .help("Plan an eval of the set, see its cost estimate, then queue it")
                        Button("Show in Error Analysis") { model.showLayerSet(layer) }
                            .help("The set's page: its tasks, answers and evals")
                    } else if loaded != nil {
                        Button("Create Layer Set…", systemImage: "plus", action: createSet)
                            .help("An empty set for \(layer), opened in Error Analysis → Evals")
                    }
                }
                .padding(.top, 2)
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Evals")
        }
        .font(.callout)
        .task(id: "\(layer) \(model.labRuns.filter { $0.spec.kind == .control }.count) \(model.lastScan?.timeIntervalSince1970 ?? 0)") {
            let layer = layer
            let read = await Task.detached { (LayerSets.load(layer, env: .current), LayerEvalStore.evals(of: layer, env: .current)) }.value
            guard !Task.isCancelled else { return }
            loaded = (read.0, read.1)
        }
    }

    /// Evals of the layer with cells still queued or running, from the Lab's runs.
    private var running: [(id: String, created: Date, finished: Int, total: Int)] {
        (loaded?.evals ?? []).compactMap { eval in
            let runs = model.labRuns.filter { $0.spec.kind == .control && $0.spec.controlSetup?.layer?.evalID == eval.id }
            guard runs.contains(where: { $0.status == .queued || $0.status == .running }) else { return nil }
            let total = eval.repeats * eval.tasks.count * eval.setups.count + (eval.sanity == nil ? 0 : eval.sanityTasks.count)
            return (eval.id, eval.createdAt, runs.filter { $0.status == .finished }.count, total)
        }
    }

    private func createSet() {
        let layer = layer
        error = nil
        Task {
            do {
                _ = try await Task.detached { try LayerSets.create(layer, env: .current) }.value
                model.showLayerSet(layer)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
