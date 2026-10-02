import AKitErrorAnalysis
import AKitFoundation
import AKitLab
import SwiftUI

/// `akit analysis control run`: repeats × tasks × setups queued in the Lab, interleaved, each
/// cell in an isolated clone. The baseline runs as is; the variant makes exactly one
/// difference (text appended to CLAUDE.md, AGENTS.md or a skill), typed here or taken from a
/// mode's fix draft. Cells already done are skipped.
struct RunCellsSheet: View {
    enum PatchSource: String, CaseIterable {
        case text, fix
        var title: String { self == .text ? "File and text" : "A mode's fix draft" }
    }

    @Environment(AnalysisModel.self) private var analysis
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var tasks: Set<String>
    @State private var baseline = true
    @State private var variant: Bool
    @State private var patchSource: PatchSource
    @State private var patchFile = "CLAUDE.md"
    @State private var patchText = ""
    @State private var fixMode: String?
    @State private var readOnly = false
    @State private var harness: LabHarness = .claudeCode
    @State private var modelName = ""
    @State private var effort = "high"
    @State private var repeats = 3
    @State private var environment: LabEnvironment?
    @State private var keep = false
    @State private var records: [SendRecord] = []
    @State private var error: String?
    @State private var busy = false

    /// `fixMode`: Try on Control Tasks… of a mode page (`--fix MODE`).
    init(tasks: Set<String>, fixMode: String?) {
        _tasks = State(initialValue: tasks)
        _variant = State(initialValue: fixMode != nil)
        _patchSource = State(initialValue: fixMode != nil ? .fix : .text)
        _fixMode = State(initialValue: fixMode)
    }

    private var agent: LabAgent {
        var agent = model.defaultAgent(harness)
        agent.model = modelName.trimmingCharacters(in: .whitespaces)
        agent.effort = effort
        return agent
    }

    /// The variant's one difference, or why there is none.
    private var patch: Result<ControlPatch, AnalysisFailure> {
        switch patchSource {
        case .text:
            let file = patchFile.trimmingCharacters(in: .whitespaces)
            guard !file.isEmpty, !patchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure(AnalysisFailure("Give the file and the text: the variant's one difference from the baseline."))
            }
            return .success(ControlPatch(file: file, text: patchText))
        case .fix:
            guard let fixMode, let draft = analysis.data.fixes[fixMode] else { return .failure(AnalysisFailure("Pick a mode with a fix draft.")) }
            guard let patch = draft.patch else {
                return .failure(AnalysisFailure("This draft's layer (\(draft.layer.title)) isn't a file in the repository, so it can't be tried here."))
            }
            return .success(patch)
        }
    }

    private var setups: [ControlSetup] {
        var setups: [ControlSetup] = []
        if baseline { setups.append(ControlSetup(name: "baseline", agent: agent)) }
        if variant, case .success(let patch) = patch { setups.append(ControlSetup(name: "variant", agent: agent, patch: patch)) }
        if readOnly { setups.append(ControlSetup(name: "read-only", agent: agent, readOnly: true)) }
        return setups
    }

    private var chosenTasks: [ControlTask] { analysis.data.controlTasks.filter { tasks.contains($0.id) } }
    private var cells: Int { repeats * chosenTasks.count * setups.count }
    /// Test oracles that fail on their reference commit can't tell a fix from noise.
    private var redTasks: [ControlTask] { chosenTasks.filter { $0.referenceGreen == false } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Run Cells").font(.title2.bold())
            Text("Each cell is a Lab run: the agent gets the task's prompt in a fresh clone of its base commit. Repeats are interleaved, so a half-done comparison stays fair. Repository code goes to the agent under the sending policy.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 16) {
                taskList.frame(width: 230)
                form
            }
            Text(costLine)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if let red = redTasks.first {
                Label("The tests of \(red.title) fail on its reference commit: fix the test command or the reference, then Check Reference on the Evals tab.",
                      systemImage: "xmark.seal")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if variant, case .failure(let reason) = patch {
                Label(reason.message, systemImage: "info.circle").foregroundStyle(.orange).font(.callout)
            }
            if variant, !baseline {
                Label("A variant is only compared with a baseline of the same agent: turn the baseline on. Cells already done are skipped, so it costs nothing where they ran before.",
                      systemImage: "info.circle")
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(cells == 1 ? "Queue 1 Cell" : "Queue \(cells) Cells", action: queue)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || cells == 0 || !redTasks.isEmpty || (variant && setups.allSatisfy { $0.patch == nil }) || (variant && !baseline)
                              || (harness == .claudeCode && modelName.trimmingCharacters(in: .whitespaces).isEmpty))
            }
        }
        .padding(20)
        .frame(width: 780)
        .task {
            let env = analysis.env
            records = await Task.detached { SendLog.records(env: env).filter { $0.purpose == "control" } }.value
        }
    }

    private var taskList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tasks").font(.headline)
            List(analysis.data.controlTasks) { task in
                Toggle(isOn: Binding(get: { tasks.contains(task.id) }, set: { on in
                    if on { tasks.insert(task.id) } else { tasks.remove(task.id) }
                })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(task.title).lineLimit(1)
                        Text(task.oracle.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .frame(height: 440)
        }
    }

    private var form: some View {
        Form {
            Section("Setups") {
                Toggle("Baseline: the task as is", isOn: $baseline)
                Toggle("Variant: one difference from the baseline", isOn: $variant)
                if variant {
                    Picker("Difference", selection: $patchSource) {
                        ForEach(PatchSource.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    switch patchSource {
                    case .text:
                        TextField("File", text: $patchFile, prompt: Text("CLAUDE.md, AGENTS.md or .claude/skills/NAME/SKILL.md"))
                        TextEditor(text: $patchText)
                            .font(.callout)
                            .frame(height: 60)
                            .scrollContentBackground(.hidden)
                            .background(.background, in: RoundedRectangle(cornerRadius: 4))
                    case .fix:
                        Picker("Mode", selection: $fixMode) {
                            Text("Choose…").tag(String?.none)
                            ForEach(analysis.data.modes.filter { analysis.data.fixes[$0.id] != nil }, id: \.id) { mode in
                                Text(mode.name).tag(String?.some(mode.id))
                            }
                        }
                        if case .success(let patch) = patch {
                            Text("Appends the draft to \(patch.file) in the clone.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Toggle("Read-only sanity setup (must fail)", isOn: $readOnly)
                    .help("An agent that can only read can't do the task: its cells failing shows the oracle works")
            }
            Section("Agent") {
                ReviewAgentFields(harness: $harness, modelName: $modelName, effort: $effort)
                Stepper("Repeats: \(repeats) per task and setup", value: $repeats, in: 1...10)
                Picker("Open in", selection: $environment) {
                    Text("Automatic").tag(LabEnvironment?.none)
                    ForEach(model.labEnvironments, id: \.self) { Text($0.title).tag(LabEnvironment?.some($0)) }
                }
                Toggle("Keep the clones", isOn: $keep)
            }
        }
        .formStyle(.grouped)
        .frame(height: 470)
    }

    /// As the CLI prints it: an estimate from the recorded cost of earlier control cells of
    /// the same harness and model.
    private var costLine: String {
        let costs = records.filter { $0.harness == agent.harness && $0.model == agent.model }.compactMap(\.usage.cost)
        guard !costs.isEmpty else {
            return "Up to \(cells) cells; no estimate yet (no recorded cost of control cells with \(agent.harness.title) · \(agent.model.isEmpty ? "default model" : agent.model))."
        }
        let estimate = costs.reduce(0, +) / Double(costs.count) * Double(cells)
        return String(format: "Up to %d cells, ≈ $%.2f at the recorded cost of %d earlier cells.", cells, estimate, costs.count)
    }

    private func queue() {
        busy = true
        error = nil
        let tasks = chosenTasks, setups = setups, repeats = repeats, environment = environment, keep = keep
        let costs = records.filter { $0.harness == agent.harness && $0.model == agent.model }.compactMap(\.usage.cost)
        let estimate = costs.isEmpty ? nil : costs.reduce(0, +) / Double(costs.count) * Double(cells)
        let env = analysis.env
        Task {
            do {
                try await Task.detached { try SendLog.checkLimit(estimate: estimate, settings: LabSettings.loadForSending(env: env), env: env) }.value
                let queued = try await model.queueControlRuns(tasks: tasks, setups: setups, repeats: repeats, environment: environment, keep: keep)
                let skipped = queued.skipped > 0 ? " Skipped \(queued.skipped) cells already done or queued." : ""
                analysis.message = queued.runs.isEmpty ? "Nothing to queue.\(skipped)"
                    : "Queued \(queued.runs.count) cells: \(repeats) × \(tasks.count) tasks × \(setups.map(\.name).joined(separator: ", ")).\(skipped)"
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
