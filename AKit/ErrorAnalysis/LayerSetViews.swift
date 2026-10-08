import AKitBrain
import AKitErrorAnalysis
import AKitFoundation
import AKitLab
import AppKit
import SwiftUI

/// "Add to layer set" in the new task sheets: none, or a brain layer (core excluded).
struct LayerSetPicker: View {
    @Environment(AppModel.self) private var model
    @Binding var layer: String?

    var body: some View {
        Picker("Add to layer set", selection: $layer) {
            Text("None").tag(String?.none)
            ForEach(model.evaluableLayers, id: \.self) { Text($0).tag(String?.some($0)) }
        }
        .help("The layer's set gets the task: an eval of the layer runs it (Evals → Layer Sets)")
    }

    /// Adds a saved task to the chosen set; the message says what happened.
    nonisolated static func add(_ task: ControlTask, to layer: String?, saved: String, env: HarnessEnvironment) throws -> String {
        guard let layer else { return saved }
        do {
            let set = try LayerSets.add([task], to: layer, env: env)
            return saved + " Added to the \(layer) set (\(set.tasks.count) \(set.tasks.count == 1 ? "task" : "tasks"))."
        } catch {
            throw AnalysisFailure("\(saved) It can't join the \(layer) set: \(error.localizedDescription)")
        }
    }
}

/// `akit analysis control task new --commit`: a task from a commit of a repository, judged by
/// the commit's own tests. The commit is checked first (two local builds, minutes, no
/// tokens) unless it was checked before; a commit that is a task already gives that task.
struct NewCommitTaskSheet: View {
    @Environment(AnalysisModel.self) private var analysis
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var gitRepositories: [URL] = []
    @State private var repo: URL?
    @State private var candidates: [ReplayTasks.Candidate] = []
    @State private var picked: String?
    @State private var commit = ""
    @State private var layerSet: String?
    @State private var progress: String?
    @State private var error: String?
    @State private var busy = false
    /// The running check: Cancel stops its builds and nothing is saved.
    @State private var work: Task<Void, Never>?
    @State private var scope: Cancellation.Scope?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Control Task from a Commit").font(.title2.bold())
            Text("The agent redoes the commit from its parent in an isolated clone. The commit's own tests judge each cell: the ones that failed before it must pass, the others must keep passing. Swift packages only for now. A commit is checked once first: two local builds, a few minutes, no tokens.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                HStack {
                    Picker("Repository", selection: $repo) {
                        Text("Choose…").tag(URL?.none)
                        ForEach(repositories, id: \.self) { Text($0.lastPathComponent).tag(URL?.some($0)) }
                    }
                    Button("Other…", action: chooseRepository)
                }
                TextField("Commit", text: $commit, prompt: Text("a hash, or pick a commit below"))
                    .monospaced()
                LayerSetPicker(layer: $layerSet)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: 150)
            List(candidates, selection: $picked) { candidate in
                HStack {
                    Text(candidate.commit.prefix(7)).monospaced().foregroundStyle(.secondary)
                    Text(candidate.subject).lineLimit(1)
                    Spacer()
                    if candidate.task != nil {
                        Text("checked").font(.caption).foregroundStyle(.green).help("Already checked: saving takes no build")
                    }
                }
                .tag(candidate.commit)
            }
            .frame(height: 220)
            .overlay {
                if repo != nil, candidates.isEmpty {
                    ContentUnavailableView("No recent commits that change Swift tests", systemImage: "point.3.connected.trianglepath.dotted")
                }
            }
            if let progress {
                Text(progress).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") {
                    scope?.cancel()
                    work?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Check and Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || repo == nil || commit.trimmingCharacters(in: .whitespaces).count < 4)
                    .help("Check the commit as a task (unless it was checked before), then save it")
            }
        }
        .padding(20)
        .frame(width: 640)
        .task(id: model.projects) {
            let projects = model.projects
            gitRepositories = await Task.detached {
                projects.filter { FileManager.default.fileExists(atPath: $0.appending(path: ".git").path) }
            }.value
            // Snapshot hook: `--project <name>` picks that repository.
            if repo == nil, let name = DebugSnapshot.options?.project { repo = gitRepositories.first { $0.lastPathComponent == name } }
        }
        .task(id: repo) {
            candidates = []
            picked = nil
            guard let repo else { return }
            candidates = await model.replayCandidates(in: repo)
        }
        .onChange(of: picked) { if let picked { commit = picked } }
    }

    private var repositories: [URL] {
        var list = gitRepositories
        if let repo, !list.contains(repo) { list.append(repo) }
        return list.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func chooseRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        panel.message = "The git repository of the commit (or one of its worktrees)"
        if panel.runModal() == .OK, let url = panel.url { repo = url }
    }

    private func save() {
        guard let repo else { return }
        busy = true
        error = nil
        progress = "Reading the commit…"
        let commit = commit.trimmingCharacters(in: .whitespaces), layerSet = layerSet
        let report: @MainActor (String) -> Void = { progress = $0 }
        let scope = Cancellation.Scope()
        self.scope = scope
        work = Task {
            do {
                try await analysis.run { env in
                    // The check's git and build processes belong to this scope: Cancel stops them.
                    let task = try await Cancellation.$scope.withValue(scope) {
                        try await ControlTasks.fromCommit(commit, repo: repo, env: env) { line in Task { @MainActor in report(line) } }
                    }
                    guard !scope.isCancelled else { throw CancellationError() }
                    let known = ControlTasks.load(task.id, env: env) != nil
                    if !known { try ControlTasks.save(task, env: env) }
                    let saved = known ? "The commit is already control task \(task.id)." : "Saved control task \(task.id): \(task.title)."
                    return try LayerSetPicker.add(task, to: layerSet, saved: saved, env: env)
                }
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            progress = nil
            busy = false
        }
    }
}

/// A layer set's page on the Evals tab: its tasks (missing ones marked), Remove from Set, and
/// the answers editor, the one place a set's field answers are changed.
struct LayerSetView: View {
    @Environment(AnalysisModel.self) private var analysis
    @Environment(AppModel.self) private var model
    let set: LayerSet
    let runCells: () -> Void
    let delete: () -> Void
    /// The answers as edited, saved with Save Answers.
    @State private var answers: [String: FieldValue] = [:]
    /// The layer's evals, newest first, and the one whose comparison is shown.
    @State private var evals: [LayerEvalManifest] = []
    @State private var shownEval: String?

    var body: some View {
        let tasks = Dictionary(analysis.data.controlTasks.map { ($0.id, $0) }) { first, _ in first }
        let found = set.tasks.compactMap { tasks[$0] }
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(set.layer).font(.title2.bold()).textSelection(.enabled)
                Text("Layer set").foregroundStyle(.secondary)
                Spacer()
                Button("Run Cells…", systemImage: "play", action: runCells)
                    .disabled(found.isEmpty)
                    .help("A layer eval of the set's tasks: the layer's required layers alone against them and the layer")
                Button("Delete Set…", systemImage: "trash", role: .destructive, action: delete)
            }
            .controlSize(.small)
            Text("The tasks an eval of \(set.layer) runs, and the field answers it renders the layer with. Local only: nothing of a set goes into the brain. A set takes the tasks of one repository for now"
                 + (found.first.map { " (here: \(URL(filePath: $0.repo).lastPathComponent))." } ?? "."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            GroupBox("Tasks (\(set.tasks.count))") {
                VStack(alignment: .leading, spacing: 6) {
                    if set.tasks.isEmpty {
                        Text("No tasks yet: Add to Layer Set… on a task, or pick the set when you make one.").foregroundStyle(.secondary)
                    }
                    ForEach(set.tasks, id: \.self) { id in
                        HStack(alignment: .firstTextBaseline) {
                            if let task = tasks[id] {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(task.title).lineLimit(1)
                                    Text("\(URL(filePath: task.repo).lastPathComponent)@\(task.base.prefix(7)) · \(task.oracle.label)")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            } else {
                                Label("\(id): missing (removed from the tasks; skipped)", systemImage: "questionmark.circle")
                                    .foregroundStyle(.orange)
                            }
                            Spacer()
                            Button("Remove from Set") { remove(id) }.controlSize(.small)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
            GroupBox("Answers") { answersEditor.padding(4) }
            if !evals.isEmpty { evalsBox(tasks) }
        }
        .onAppear { answers = set.answers }
        .task(id: "\(set.layer) \(model.labRuns.filter { $0.spec.kind == .control }.count)") {
            let layer = set.layer
            evals = await Task.detached { LayerEvalStore.evals(of: layer, env: .current) }.value
            if shownEval == nil || !evals.contains(where: { $0.id == shownEval }) { shownEval = evals.first?.id }
        }
        .onChange(of: set) { old, new in
            // Another set: its own answers. The same set read again (after any change on the
            // screen): only the fields whose saved answer changed; unsaved edits stay.
            guard old.layer == new.layer else {
                answers = new.answers
                return
            }
            for field in Set(old.answers.keys).union(new.answers.keys) where old.answers[field] != new.answers[field] {
                answers[field] = new.answers[field]
            }
        }
    }

    /// The layer's evals (Evaluate… in Brain, or Run Cells… here), newest first; the chosen
    /// one's comparison and verdict below.
    private func evalsBox(_ tasks: [String: ControlTask]) -> some View {
        GroupBox("Evals (\(evals.count))") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Eval", selection: $shownEval) {
                    ForEach(evals) { eval in
                        Text("\(eval.createdAt.formatted(date: .abbreviated, time: .shortened)) · "
                             + "\(eval.agent.map { "\($0.model) · \($0.effort)" } ?? "") · \(eval.tasks.count) tasks × \(eval.repeats)")
                            .tag(String?.some(eval.id))
                    }
                }
                .fixedSize()
                if let eval = evals.first(where: { $0.id == shownEval }) {
                    let denied = Set(eval.setups.flatMap { $0.denied ?? [] }).sorted()
                    Text("Eval \(eval.id) · brain \(eval.brainCommit.prefix(7))"
                         + (denied.isEmpty ? "" : " · the agent may not run: \(denied.joined(separator: ", "))"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    ControlComparisonView(tasks: eval.tasks.compactMap { tasks[$0] }, eval: eval.id)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    @ViewBuilder private var answersEditor: some View {
        let fields = model.layerFields(of: set.layer)
        VStack(alignment: .leading, spacing: 8) {
            if model.brain == nil {
                Text("No brain repo: the layer's fields come from it.").foregroundStyle(.secondary)
            } else if fields.isEmpty {
                Text("\(set.layer) and the layers it requires have no fields.").foregroundStyle(.secondary)
            } else {
                Text("An empty answer leaves the field to the project's saved answer, then the layer's default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                    ForEach(fields) { field in
                        GridRow {
                            Text((field.prompt.isEmpty ? field.id : field.prompt) + (field.required ? " *" : ""))
                                .gridColumnAlignment(.trailing)
                                .help(field.id)
                            input(field)
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("Revert") { answers = set.answers }.disabled(answers == set.answers)
                    Button("Save Answers", action: saveAnswers).disabled(answers == set.answers)
                }
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One field: empty or "Default" means no answer in the set.
    @ViewBuilder private func input(_ field: LayerField) -> some View {
        let fallback = field.defaultValue.map { "default: \($0.display)" } ?? "no default"
        switch field.kind {
        case .text:
            TextField(fallback, text: Binding(
                get: { if case .text(let text) = answers[field.id] { text } else { "" } },
                set: { answers[field.id] = $0.isEmpty ? nil : .text($0) }))
        case .bool:
            Picker("", selection: Binding<Bool?>(
                get: { if case .bool(let flag) = answers[field.id] { flag } else { nil } },
                set: { answers[field.id] = $0.map(FieldValue.bool) })) {
                Text("Default (\(field.defaultValue?.display ?? "none"))").tag(Bool?.none)
                Text("Yes").tag(Bool?.some(true))
                Text("No").tag(Bool?.some(false))
            }
            .labelsHidden()
            .fixedSize()
        case .choice:
            Picker("", selection: Binding<String?>(
                get: { if case .text(let text) = answers[field.id] { text } else { nil } },
                set: { answers[field.id] = $0.map(FieldValue.text) })) {
                Text("Default (\(field.defaultValue?.display ?? "none"))").tag(String?.none)
                ForEach(field.options, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .labelsHidden()
            .fixedSize()
        case .multi:
            TextField(fallback, text: Binding(
                get: { if case .list(let items) = answers[field.id] { items.joined(separator: ", ") } else { "" } },
                set: { text in
                    let items = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    answers[field.id] = items.isEmpty ? nil : .list(items)
                }))
                .help(field.options.isEmpty ? "Comma-separated" : "Comma-separated, from: \(field.options.joined(separator: ", "))")
        }
    }

    private func remove(_ id: String) {
        let layer = set.layer
        analysis.act { env in
            try LayerSets.remove([id], from: layer, env: env)
            return "Removed \(id) from the \(layer) set."
        }
    }

    private func saveAnswers() {
        let layer = set.layer, before = set.answers, after = answers
        analysis.act { env in
            for field in Set(before.keys).union(after.keys).sorted() where before[field] != after[field] {
                try LayerSets.setAnswer(field, after[field], in: layer, env: env)
            }
            return "Saved the answers of the \(layer) set."
        }
    }
}
