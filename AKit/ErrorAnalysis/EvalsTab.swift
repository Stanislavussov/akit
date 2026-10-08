import AKitErrorAnalysis
import AKitFoundation
import AKitLab
import SwiftUI

/// Controlled evals (`akit analysis control …`): fixed tasks with an oracle, cells queued in
/// the Lab per setup, and the paired comparison that says whether a fix helped. Layer sets
/// (`docs/design/layer-evals.md`) list above the tasks.
struct EvalsTab: View {
    @Environment(AnalysisModel.self) private var analysis
    @Environment(AppModel.self) private var model
    /// Snapshots: `--select <task id>[,<task id>…]`, or `set:<layer>` for a layer set.
    @State private var selection: Set<String> = Set(DebugSnapshot.options?.select?.split(separator: ",").map(String.init) ?? [])
    @State private var sheet: Sheet?
    @State private var remove: ControlTask?
    @State private var deleteSet: String?

    enum Sheet: String, Identifiable {
        case fromSession, reproduction, fromCommit, run, runSet
        var id: String { rawValue }
    }

    /// A layer set's tag in the sidebar list; task ids never start with it.
    private static let setTag = "set:"

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 260, idealWidth: 320, maxWidth: 420)
            detail
                .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .fromSession: NewControlTaskSheet(fromSession: true)
            case .reproduction: NewControlTaskSheet(fromSession: false)
            case .fromCommit: NewCommitTaskSheet()
            case .run: RunCellsSheet(tasks: selection.filter { !$0.hasPrefix(Self.setTag) }, fixMode: nil)
            case .runSet: RunCellsSheet(tasks: Set(selectedSet?.tasks ?? []), fixMode: nil, layer: selectedSet?.layer)
            }
        }
        .confirmationDialog("Move the \(deleteSet ?? "") set to the Trash?", isPresented: Binding(get: { deleteSet != nil }, set: { if !$0 { deleteSet = nil } }),
                            presenting: deleteSet) { layer in
            Button("Move to Trash", role: .destructive) {
                selection.remove(Self.setTag + layer)
                analysis.act { env in
                    try LayerSets.delete(layer, env: env)
                    return "Moved the \(layer) set to the Trash. Its tasks stay."
                }
            }
        } message: { _ in
            Text("Only the set's file goes: its tasks and cells stay.")
        }
        .confirmationDialog("Move this control task to the Trash?", isPresented: Binding(get: { remove != nil }, set: { if !$0 { remove = nil } }),
                            presenting: remove) { task in
            Button("Move to Trash", role: .destructive) {
                let id = task.id
                selection.remove(id)
                analysis.act { env in
                    try ControlTasks.remove(id, env: env)
                    return "Moved control task \(id) to the Trash."
                }
            }
        } message: { _ in
            Text("Only the task's file goes; its cells stay Lab runs.")
        }
        .task(id: analysis.evalsFocus) {
            // Brain → Show in Error Analysis: the layer's set, read again (it may be new).
            guard let layer = analysis.evalsFocus else { return }
            selection = [Self.setTag + layer]
            analysis.evalsFocus = nil
            await analysis.reload()
        }
        .task {
            // Snapshots: `--tab evals --add` opens Run Cells…, `--query fromSession|reproduction|fromCommit` a new task sheet.
            guard DebugSnapshot.options != nil else { return }
            // A set's tasks are known once the data is read (at most 5 s).
            for _ in 0..<50 where !analysis.loaded { try? await Task.sleep(for: .milliseconds(100)) }
            if DebugSnapshot.options?.add == true, !selection.isEmpty { sheet = selectedSet == nil ? .run : .runSet }
            if let query = DebugSnapshot.options?.query, let open = Sheet(rawValue: query) { sheet = open }
        }
    }

    private var tasks: [ControlTask] { analysis.data.controlTasks }
    private var sets: [LayerSet] { analysis.data.layerSets }
    private var selected: [ControlTask] { tasks.filter { selection.contains($0.id) } }
    /// A selected set shows its page, whatever tasks are selected with it.
    private var selectedSet: LayerSet? { sets.first { selection.contains(Self.setTag + $0.layer) } }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(tasks.count) control tasks").font(.headline)
                Text("A prompt at a commit and an oracle. Cells run in isolated clones; select tasks to compare their setups.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("From Session…", systemImage: "plus") { sheet = .fromSession }
                        .help("A task from a reviewed session or an exemplar: its first user turn at HEAD of its start")
                    Button("Reproduction…") { sheet = .reproduction }
                        .help("A minimal reproduction you write: repository, base commit, prompt and oracle")
                }
                HStack {
                    Button("From Commit…") { sheet = .fromCommit }
                        .help("A task from a commit: redo it from its parent; the commit's own tests judge it (Swift packages)")
                    Button("Run Cells…", systemImage: "play") { sheet = .run }
                        .disabled(selected.isEmpty)
                        .help("Queue repeats × tasks × setups in the Lab")
                }
            }
            .controlSize(.small)
            .font(.callout)
            .padding(12)
            List(selection: $selection) {
                if !sets.isEmpty {
                    Section("Layer Sets") {
                        ForEach(sets) { set in
                            HStack {
                                Label(set.layer, systemImage: "square.3.layers.3d")
                                Spacer()
                                Text("\(set.tasks.count) \(set.tasks.count == 1 ? "task" : "tasks")").font(.caption).foregroundStyle(.secondary)
                            }
                            .tag(Self.setTag + set.layer)
                        }
                    }
                }
                Section(sets.isEmpty ? "" : "Tasks") {
                    ForEach(tasks) { task in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(task.title).lineLimit(1)
                                Spacer()
                                ReferenceBadge(task: task)
                            }
                            Text("\(URL(filePath: task.repo).lastPathComponent)@\(task.base.prefix(7)) · \(task.oracle.label)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 2)
                        .tag(task.id)
                    }
                }
            }
            .overlay {
                if tasks.isEmpty, analysis.loaded {
                    ContentUnavailableView("No control tasks", systemImage: "checklist",
                                           description: Text("Make one from an exemplar session of a frequent mode or from a commit, or write a minimal reproduction."))
                }
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let set = selectedSet {
            ScrollView {
                LayerSetView(set: set, runCells: { sheet = .runSet }, delete: { deleteSet = set.layer })
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if selected.isEmpty {
            ContentUnavailableView("Select Tasks", systemImage: "checklist",
                                   description: Text("Select one task to see it, several to compare setups across them. Did the fix help? The unit is a task's pass rate over its repeats, compared by task."))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(selected) { task in
                        ControlTaskView(task: task) { remove = task }
                    }
                    ControlComparisonView(tasks: selected)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Whether the test command passed on the reference commit.
private struct ReferenceBadge: View {
    let task: ControlTask

    var body: some View {
        if case .tests = task.oracle {
            let (text, color): (String, Color) = switch task.referenceGreen {
            case true?: ("green", .green)
            case false?: ("red", .red)
            case nil: (task.reference == nil ? "no reference" : "not checked", .secondary)
            }
            Text(text)
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(color.opacity(0.18), in: Capsule())
                .foregroundStyle(color)
                .help("The test command on the reference commit")
        }
    }
}

/// One task: prompt, repository, oracle, source, its layer sets, and Check Reference /
/// Add to Layer Set… / Remove.
private struct ControlTaskView: View {
    @Environment(AnalysisModel.self) private var analysis
    @Environment(AppModel.self) private var model
    let task: ControlTask
    let remove: () -> Void

    var body: some View {
        let inSets = LayerSets.layers(holding: task.id, in: analysis.data.layerSets)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(task.title).font(.title3.bold()).textSelection(.enabled)
                ReferenceBadge(task: task)
                Spacer()
                if case .tests = task.oracle, task.reference != nil {
                    Button("Check Reference", systemImage: "checkmark.seal") { check() }
                        .disabled(analysis.progress != nil)
                        .help("Run the test command on the reference commit in an isolated clone: it must pass, or the oracle can't tell a fix")
                }
                Menu("Add to Layer Set…", systemImage: "square.3.layers.3d") {
                    ForEach(model.evaluableLayers, id: \.self) { layer in
                        Button(layer) { add(to: layer) }.disabled(inSets.contains(layer))
                    }
                }
                .fixedSize()
                .disabled(model.evaluableLayers.isEmpty)
                .help("The layer's set gets this task: an eval of the layer runs it")
                Button("Remove…", systemImage: "trash", role: .destructive, action: remove)
            }
            .controlSize(.small)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                row("Repository", "\(URL(filePath: task.repo).tildePath) at \(task.base.prefix(10))")
                row("Oracle", task.oracle.label + (task.successMode == true ? " (a success mode: passes when it shows)" : ""))
                row("Source", task.sourceTitle)
                if let mode = task.modeID { row("Mode", analysis.data.mode(mode)?.name ?? mode) }
                if let reference = task.reference {
                    if case .hiddenTests = task.oracle {
                        row("Reference", "\(reference.prefix(10)) · the commit itself: its tests pass there (checked when the task was made)")
                    } else {
                        row("Reference", "\(reference.prefix(10)) · " + (task.referenceGreen.map { $0 ? "tests pass there" : "tests fail there: fix the command or the reference" } ?? "not checked yet"))
                    }
                }
                if !inSets.isEmpty { row("In sets", inSets.joined(separator: ", ")) }
                row("Id", task.id)
            }
            .font(.callout)
            .textSelection(.enabled)
            Text(task.prompt)
                .font(.callout)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                .textSelection(.enabled)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func add(to layer: String) {
        let task = task
        analysis.act { env in
            let set = try LayerSets.add([task], to: layer, env: env)
            return "Added \(task.title) to the \(layer) set (\(set.tasks.count) \(set.tasks.count == 1 ? "task" : "tasks"))."
        }
    }

    private func check() {
        let task = task
        let analysis = analysis
        analysis.error = nil
        analysis.progress = "Checking the reference of \(task.title)…"
        Task {
            defer { analysis.progress = nil }
            do {
                try await analysis.run { env in
                    let checked = try await ControlTasks.checkReference(task, env: env, out: { line in
                        Task { @MainActor in analysis.progress = "Reference: \(line)" }
                    })
                    return checked.referenceGreen == true ? "The tests pass on the reference commit: the oracle can tell a fix."
                        : "The tests fail on the reference commit: fix the test command or the reference before running cells."
                }
            } catch {
                analysis.error = error.localizedDescription
            }
        }
    }
}
