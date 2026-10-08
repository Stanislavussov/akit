import AKitErrorAnalysis
import AKitFoundation
import AKitLab
import Foundation

/// `akit analysis control compare --eval ID`: one layer eval's comparison and its verdict
/// (`docs/design/layer-evals.md`, "Verdict").
extension AKitCLI {
    struct LayerEvalReport: Encodable {
        let eval: String
        let layer: String
        /// Cells of the eval still queued or running; the verdict waits for them.
        let open: Int
        let comparison: ControlComparison
        let verdict: LayerVerdict?
        /// Whether the verdict was stored as the layer's last one for its agent.
        let saved: Bool
    }

    static func compareLayerEval(_ id: String, _ args: inout Arguments, json: Bool, env: HarnessEnvironment,
                                 out: (String) -> Void) throws -> Int32 {
        guard args.positional() == nil else { throw Failure(message: "--eval ID compares that eval's own tasks; leave out the task list.") }
        try args.finish()
        guard let manifest = LayerEvalStore.manifest(id, env: env) else {
            throw Failure(message: LayerEvalStore.problem(id, env: env) ?? "No eval \(id).")
        }
        let runs = LabStore.list(env: env).filter { $0.spec.kind == .control && $0.spec.controlSetup?.layer?.evalID == manifest.id }
        let open = runs.filter { $0.status == .queued || $0.status == .running }.count
        let comparison = ControlComparison.compare(ControlComparison.Cell.of(runs))
        let verdict = LayerVerdicts.verdict(of: manifest, runs: runs, costs: SendLog.runCosts(SendLog.records(env: env)))
        var saved = false
        if let verdict {
            do {
                saved = try LayerVerdicts.save(verdict, env: env)
            } catch {
                throw Failure(message: error.localizedDescription)
            }
        }
        if json {
            out(try labJSON(LayerEvalReport(eval: manifest.id, layer: manifest.layer, open: open, comparison: comparison,
                                            verdict: verdict, saved: saved)))
            return 0
        }
        out(comparisonText(comparison, tasks: manifest.tasks.compactMap { ControlTasks.load($0, env: env) }, open: open))
        out("")
        guard let verdict else {
            out(runs.isEmpty ? "No cells of the eval \(manifest.id) yet." : "The verdict waits for \(open) cells still queued or running.")
            return 0
        }
        LayerVerdicts.lines(verdict).forEach(out)
        let file = EvalPaths(env: env).verdict(manifest.layer).path.replacingOccurrences(of: env.homeDirectory.path, with: "~")
        out(saved ? "Saved as the last verdict of \(manifest.layer) for \(verdict.agent.harness.title) · \(verdict.model) · \(verdict.effort) (\(file))."
            : "The stored verdict for this agent is already this one or comes from a newer eval (\(file)).")
        return 0
    }
}
