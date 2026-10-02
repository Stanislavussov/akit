import AKitErrorAnalysis
import AKitFoundation
import AKitLab
import SwiftUI

/// Controlled evals (`akit analysis control …`): fixed tasks with an oracle, cells queued in
/// the Lab per setup, and the paired comparison that says whether a fix helped.
struct EvalsTab: View {
    @Environment(AnalysisModel.self) private var analysis
    @Environment(AppModel.self) private var model
    /// Snapshots: `--select <task id>[,<task id>…]`.
    @State private var selection: Set<String> = Set(DebugSnapshot.options?.select?.split(separator: ",").map(String.init) ?? [])
    @State private var sheet: Sheet?
    @State private var remove: ControlTask?

    enum Sheet: String, Identifiable {
        case fromSession, reproduction, run
        var id: String { rawValue }
    }

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
            case .run: RunCellsSheet(tasks: selection, fixMode: nil)
            }
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
        .task {
            // Snapshots: `--tab evals --add` opens Run Cells…, `--query fromSession|reproduction` a new task sheet.
            if DebugSnapshot.options?.add == true, !selection.isEmpty { sheet = .run }
            if let query = DebugSnapshot.options?.query, let open = Sheet(rawValue: query) { sheet = open }
        }
    }

    private var tasks: [ControlTask] { analysis.data.controlTasks }
    private var selected: [ControlTask] { tasks.filter { selection.contains($0.id) } }

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
                Button("Run Cells…", systemImage: "play") { sheet = .run }
                    .disabled(selection.isEmpty)
                    .help("Queue repeats × tasks × setups in the Lab")
            }
            .controlSize(.small)
            .font(.callout)
            .padding(12)
            List(tasks, selection: $selection) { task in
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
            .overlay {
                if tasks.isEmpty, analysis.loaded {
                    ContentUnavailableView("No control tasks", systemImage: "checklist",
                                           description: Text("Make one from an exemplar session of a frequent mode, or write a minimal reproduction."))
                }
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if selected.isEmpty {
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

/// One task: prompt, repository, oracle, source, and Check Reference / Remove.
private struct ControlTaskView: View {
    @Environment(AnalysisModel.self) private var analysis
    let task: ControlTask
    let remove: () -> Void

    var body: some View {
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
                Button("Remove…", systemImage: "trash", role: .destructive, action: remove)
            }
            .controlSize(.small)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                row("Repository", "\(URL(filePath: task.repo).tildePath) at \(task.base.prefix(10))")
                row("Oracle", task.oracle.label + (task.successMode == true ? " (a success mode: passes when it shows)" : ""))
                row("Source", task.sourceTitle)
                if let mode = task.modeID { row("Mode", analysis.data.mode(mode)?.name ?? mode) }
                if let reference = task.reference {
                    row("Reference", "\(reference.prefix(10)) · " + (task.referenceGreen.map { $0 ? "tests pass there" : "tests fail there: fix the command or the reference" } ?? "not checked yet"))
                }
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
