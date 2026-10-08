import AKitBrain
import AKitErrorAnalysis
import AKitFoundation
import Foundation

/// `akit analysis control layer-set …` and tasks from commits: the tasks a layer eval runs and
/// the field answers it renders the layer with (docs/design/layer-evals.md, "Tasks and layer sets").
extension AKitCLI {
    static let analysisLayerSetUsage = """
          akit analysis control layer-sets [--json]
                                          Layer sets: each brain layer's tasks for layer evals and its
                                          field answers (~/.akit/lab/evals/sets; local only)
          akit analysis control layer-set LAYER [--json]
                                          One set: its tasks (missing ones marked) and answers
          akit analysis control layer-set LAYER add TASK[,TASK…]
          akit analysis control layer-set LAYER remove TASK[,TASK…]
                                          Add tasks to the set (made when the layer has none) or take
                                          them out. A set takes the tasks of one repository for now
          akit analysis control layer-set LAYER answer FIELD=VALUE… [--brain DIR]
                                          Field answers the layer's evals render with, over the
                                          project's saved answers and the layer's defaults (bool
                                          true|false, a list a,b). FIELD= removes the answer
          akit analysis control layer-set LAYER delete
                                          Move the set's file to the Trash (its tasks stay)
        """

    static func layerSets(_ command: String, _ args: inout Arguments, json: Bool, env: HarnessEnvironment, cwd: URL,
                          out: (String) -> Void, trash: (URL) throws -> URL?) throws -> Int32 {
        if command == "layer-sets" {
            try args.finish()
            let sets = LayerSets.list(env: env)
            if json { out(try labJSON(sets)); return 0 }
            out(sets.isEmpty ? "No layer sets. Add tasks with akit analysis control layer-set LAYER add TASK." : sets.map { set in
                let missing = LayerSets.tasks(of: set, env: env).missing.count
                return "\(set.layer)  \(set.tasks.count) \(set.tasks.count == 1 ? "task" : "tasks")" + (missing > 0 ? " (\(missing) missing)" : "")
                    + (set.answers.isEmpty ? "" : "  \(set.answers.count) \(set.answers.count == 1 ? "answer" : "answers")")
            }.joined(separator: "\n"))
            return 0
        }
        guard let layer = args.positional() else { throw Failure(message: "Which layer? akit analysis control layer-set LAYER ….") }
        if let problem = LayerSets.problem(layer, env: env) { throw Failure(message: problem) }
        let action = args.positional()
        do {
            switch action {
            case nil:
                try args.finish()
                guard let set = LayerSets.load(layer, env: env) else {
                    throw Failure(message: "The layer \(layer) has no set. Add tasks with akit analysis control layer-set \(layer) add TASK.")
                }
                if json { out(try labJSON(set)); return 0 }
                out(layerSetText(set, env: env))
            case "add", "remove":
                guard let list = args.positional() else { throw Failure(message: "Which tasks? akit analysis control layer-set \(layer) \(action ?? "") TASK[,TASK…].") }
                try args.finish()
                if action == "add" {
                    let set = try LayerSets.add(try controlTasks(list, env: env), to: layer, env: env)
                    out("The \(layer) set has \(set.tasks.count) \(set.tasks.count == 1 ? "task" : "tasks").")
                } else {
                    // Ids of the set (also of tasks that are gone), or a unique prefix of one.
                    let held = LayerSets.load(layer, env: env)?.tasks ?? []
                    let ids = list.split(separator: ",").map(String.init).map { part in
                        let matches = held.filter { $0.hasPrefix(part) }
                        return held.contains(part) || matches.count != 1 ? part : matches[0]
                    }
                    let set = try LayerSets.remove(ids, from: layer, env: env)
                    out("The \(layer) set has \(set.tasks.count) \(set.tasks.count == 1 ? "task" : "tasks").")
                }
            case "answer":
                let brainText = args.value("--brain")
                var texts: [String] = []
                while let text = args.positional() { texts.append(text) }
                try args.finish()
                guard !texts.isEmpty else { throw Failure(message: "Which answer? akit analysis control layer-set \(layer) answer FIELD=VALUE.") }
                let brainRoot = brainText.map { resolve($0, cwd: cwd, env: env) } ?? Brain.defaultRoot(home: env.homeDirectory)
                guard let brain = Brain.load(from: brainRoot) else {
                    throw Failure(message: "No brain repo at \(brainRoot.path); the layer's fields come from it. Pass --brain.")
                }
                // Typed by the field's kind; an empty value removes the answer.
                let typed = try layerAnswers(texts, layer: layer, brain: brain)
                for text in texts {
                    let field = String(text.prefix { $0 != "=" }).trimmingCharacters(in: .whitespaces)
                    try LayerSets.setAnswer(field, typed[field], in: layer, env: env)
                    out(typed[field].map { "\(field) = \($0.display)" } ?? "\(field): no answer in the set (the project's or the default applies).")
                }
            case "delete":
                try args.finish()
                try LayerSets.delete(layer, env: env, trash: trash)
                out("Moved the \(layer) set to the Trash. Its tasks stay.")
            case let other:
                throw Failure(message: "Unknown “akit analysis control layer-set \(layer) \(other ?? "")”: add, remove, answer or delete.")
            }
        } catch let failure as LayerSets.Failure {
            throw Failure(message: failure.message)
        }
        return 0
    }

    /// The set's tasks (missing ones marked) and answers.
    static func layerSetText(_ set: LayerSet, env: HarnessEnvironment) -> String {
        let found = Dictionary(LayerSets.tasks(of: set, env: env).found.map { ($0.id, $0) }) { first, _ in first }
        let repo = found.values.first.map { URL(filePath: $0.repo).lastPathComponent }
        var lines = ["\(set.layer): \(set.tasks.count) \(set.tasks.count == 1 ? "task" : "tasks")" + (repo.map { " · repository \($0)" } ?? "")]
        for id in set.tasks {
            if let task = found[id] {
                lines.append("  \(id)  \(String(task.base.prefix(7)))  \(task.oracle.label)  \(task.title)")
            } else {
                lines.append("  \(id)  missing (removed from ~/.akit/lab/evals/tasks; skipped)")
            }
        }
        lines.append(set.answers.isEmpty ? "No answers: the project's saved answers, then the layer's defaults." : "Answers:")
        for (field, value) in set.answers.sorted(by: { $0.key < $1.key }) { lines.append("  \(field) = \(value.display)") }
        return lines.joined(separator: "\n")
    }

    /// `task new --commit`: checks the commit as a replay task (local builds, minutes) unless
    /// it is cached, then saves the control task.
    static func newCommitTask(_ commit: String, repo: URL, layerSet: String?, env: HarnessEnvironment, out: (String) -> Void) async throws -> Int32 {
        let task: ControlTask
        do {
            task = try await ControlTasks.fromCommit(commit, repo: repo, env: env, out: { LinePrinter.shared.print($0) })
        } catch {
            throw Failure(message: error.localizedDescription)
        }
        let known = ControlTasks.load(task.id, env: env) != nil
        if !known { try ControlTasks.save(task, env: env) }
        out(known ? "The commit is already control task \(task.id): \(task.title)" : "Saved control task \(task.id): \(task.title)")
        out("  \(task.repo) at \(String(task.base.prefix(7))) · \(task.oracle.label)")
        if let layerSet { try addToLayerSet(task, layerSet, env: env, out: out) }
        return 0
    }

    /// `--layer-set` of `task new`: the task is saved first, so a refusal leaves it in place.
    static func addToLayerSet(_ task: ControlTask, _ layer: String, env: HarnessEnvironment, out: (String) -> Void) throws {
        do {
            let set = try LayerSets.add([task], to: layer, env: env)
            out("Added to the \(layer) set (\(set.tasks.count) \(set.tasks.count == 1 ? "task" : "tasks")).")
        } catch {
            throw Failure(message: "The task is saved, but it can't join the \(layer) set: \(error.localizedDescription)")
        }
    }
}
