import AKitErrorAnalysis
import AKitFoundation
import AKitLab
import SwiftUI

/// `akit analysis control run`: repeats × tasks × setups queued in the Lab, interleaved, each
/// cell in an isolated clone. The baseline runs as is; the variant makes exactly one
/// difference (text appended to CLAUDE.md, AGENTS.md or a skill), typed here or taken from a
/// mode's fix draft. A brain layer as the difference (`--layer`) is a layer eval: its
/// required layers alone against them and the layer (`docs/design/layer-evals.md`). Cells
/// already done are skipped.
struct RunCellsSheet: View {
    enum PatchSource: String, CaseIterable {
        case text, fix, layer
        var title: String {
            switch self {
            case .text: "File and text"
            case .fix: "A mode's fix draft"
            case .layer: "A brain layer"
            }
        }
    }

    /// What the plan and the estimate depend on: the cells that would be queued.
    private struct EstimateKey: Hashable {
        var tasks: [ControlTask]
        var setups: [ControlSetup]
        var repeats: Int
        var sanity: ControlSetup?
        var sanityTasks: [ControlTask]
        var agent: LabAgent
    }

    /// The cells still to run (a dry run of the queue), their estimate, and how many cells the
    /// baseline alone would still run (the hint when the baseline is off).
    private struct Planned {
        var toQueue: Int
        var skipped: Int
        var estimate: CostEstimate
        var baselineLeft: Int
    }

    /// What a layer eval's preparation depends on: a change prepares it again.
    private struct LayerRequest: Hashable {
        var layer: String
        var tasks: Set<String>
        var agent: LabAgent
        var sanity: Bool
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
    @State private var layerName: String?
    /// The layer eval for the current request, or why it can't be prepared.
    @State private var prepared: (request: LayerRequest, result: Result<LayerSetups.Prepared, AnalysisFailure>)?
    @State private var readOnly = false
    @State private var harness: LabHarness = .claudeCode
    @State private var modelName = ""
    @State private var effort = "high"
    @State private var repeats = 3
    @State private var environment: LabEnvironment?
    @State private var keep = false
    /// The plan and estimate for the current cells (`ControlRuns.plan`, `ControlRuns.estimate`).
    @State private var planned: (key: EstimateKey, value: Planned)?
    @State private var error: String?
    @State private var busy = false
    /// Paid cells wait for the user to confirm the amount.
    @State private var confirming = false

    /// `fixMode`: Try on Control Tasks… of a mode page (`--fix MODE`). `layer`: Run Cells… of a
    /// layer set's page, a layer eval of that layer.
    init(tasks: Set<String>, fixMode: String?, layer layerSet: String? = nil) {
        // Snapshot hook: `--query layer` opens the sheet on a brain layer.
        let layer = fixMode == nil && (layerSet != nil || DebugSnapshot.options?.query == "layer")
        _tasks = State(initialValue: tasks)
        _variant = State(initialValue: fixMode != nil || layer)
        _patchSource = State(initialValue: fixMode != nil ? .fix : layer ? .layer : .text)
        _fixMode = State(initialValue: fixMode)
        _layerName = State(initialValue: layerSet)
    }

    private var agent: LabAgent {
        var agent = model.defaultAgent(harness)
        agent.model = modelName.trimmingCharacters(in: .whitespaces)
        agent.effort = effort
        return agent
    }

    /// A layer eval: its own two setups instead of the baseline and a patch.
    private var isLayer: Bool { variant && patchSource == .layer }

    /// Brain layers that can be evaluated: every one but core (the home folder's layer).
    private var layers: [String] { model.evaluableLayers }

    private var layerRequest: LayerRequest? {
        guard isLayer, let layerName, harness == .claudeCode, !agent.model.isEmpty, !tasks.isEmpty else { return nil }
        return LayerRequest(layer: layerName, tasks: tasks, agent: agent, sanity: readOnly)
    }

    /// The prepared layer eval when it matches the current request.
    private var layerEval: LayerSetups.Prepared? {
        guard let prepared, prepared.request == layerRequest, case .success(let eval) = prepared.result else { return nil }
        return eval
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
        case .layer:
            return .failure(AnalysisFailure("A brain layer makes its own setups."))
        }
    }

    private var setups: [ControlSetup] {
        if isLayer { return layerEval?.setups ?? [] }
        var setups: [ControlSetup] = []
        if baseline { setups.append(ControlSetup(name: "baseline", agent: agent)) }
        if variant, case .success(let patch) = patch { setups.append(ControlSetup(name: "variant", agent: agent, patch: patch)) }
        if readOnly { setups.append(ControlSetup(name: "read-only", agent: agent, readOnly: true)) }
        return setups
    }

    private var chosenTasks: [ControlTask] { analysis.data.controlTasks.filter { tasks.contains($0.id) } }
    private var cells: Int {
        guard isLayer else { return repeats * chosenTasks.count * setups.count }
        guard let layerEval else { return 0 }
        return repeats * layerEval.runnable.count * layerEval.setups.count + layerEval.sanityTasks.count
    }
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
            if variant, !isLayer, case .failure(let reason) = patch {
                Label(reason.message, systemImage: "info.circle").foregroundStyle(.orange).font(.callout)
            }
            if variant, !isLayer, !baseline {
                Label("A variant is only compared with a baseline of the same agent: turn the baseline on."
                      + (currentPlan?.baselineLeft == 0 ? " Its cells are all done or queued, so it costs nothing." : ""),
                      systemImage: "info.circle")
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isLayer, layerEval != nil, let estimate = currentPlan?.estimate, estimate.perCell == nil {
                Label("No paid layer cells without an estimate: queue 1 calibration cell in Brain → \(layerName ?? "the layer") → Evaluate… "
                      + "(the tasks must be in the layer's set); the eval reuses it.", systemImage: "info.circle")
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
                Button(currentPlan.map { $0.toQueue == 1 ? "Queue 1 Cell…" : "Queue \($0.toQueue) Cells…" } ?? "Queue Cells…") { confirming = true }
                    .keyboardShortcut(.defaultAction)
                    // Paid cells only after the plan and estimate; a layer eval's only with a recorded cost, as in Evaluate….
                    .disabled(busy || cells == 0 || !redTasks.isEmpty || currentPlan == nil || currentPlan?.toQueue == 0
                              || (isLayer && currentPlan?.estimate.perCell == nil)
                              || (variant && !isLayer && setups.allSatisfy { $0.patch == nil }) || (variant && !isLayer && !baseline)
                              || (harness == .claudeCode && modelName.trimmingCharacters(in: .whitespaces).isEmpty))
            }
        }
        .padding(20)
        .frame(width: 780)
        .confirmationDialog(confirmationTitle, isPresented: $confirming, titleVisibility: .visible) {
            Button("Queue", action: queue)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
        .task(id: estimateKey) {
            let key = estimateKey, env = analysis.env, baselineSetup = ControlSetup(name: "baseline", agent: agent)
            let value = await Task.detached {
                let sanity = key.sanity.map { ($0, key.sanityTasks, 1) }
                let counts = ControlRuns.plan(tasks: key.tasks, setups: key.setups, repeats: key.repeats, sanity: sanity, env: env)
                let estimate = ControlRuns.estimate(cells: counts.toQueue, agent: key.agent, repo: key.tasks.first?.mainFolder, env: env)
                let baselineLeft = ControlRuns.plan(tasks: key.tasks, setups: [baselineSetup], repeats: key.repeats, env: env).toQueue
                return Planned(toQueue: counts.toQueue, skipped: counts.skipped, estimate: estimate, baselineLeft: baselineLeft)
            }.value
            guard !Task.isCancelled else { return }
            planned = (key, value)
        }
        .task {
            // Snapshot hook: `--project <layer>` picks the layer.
            if layerName == nil { layerName = DebugSnapshot.options?.project.flatMap { layers.contains($0) ? $0 : nil } ?? layers.first }
        }
        .task(id: layerRequest) {
            guard let request = layerRequest, prepared?.request != request else { return }
            let chosen = chosenTasks
            do {
                let eval = try await model.prepareLayerEval(layer: request.layer, tasks: chosen, agent: request.agent, sanity: request.sanity)
                guard !Task.isCancelled else { return }
                prepared = (request, .success(eval))
            } catch {
                guard !Task.isCancelled else { return }
                prepared = (request, .failure(AnalysisFailure(error.localizedDescription)))
            }
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
                if !isLayer { Toggle("Baseline: the task as is", isOn: $baseline) }
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
                    case .layer:
                        layerFields
                    }
                }
                Toggle(isLayer ? "Read-only sanity cells on 3 tasks (must fail)" : "Read-only sanity setup (must fail)", isOn: $readOnly)
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

    /// The layer picker and what its preparation found: the two setups, blocked tasks, notes
    /// and the overlap with home skills.
    @ViewBuilder private var layerFields: some View {
        if layers.isEmpty {
            Text("The brain has no layer to evaluate (the core layer is the home folder's).").font(.caption).foregroundStyle(.secondary)
        } else {
            Picker("Layer", selection: $layerName) {
                ForEach(layers, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            Text("Baseline: the layer's required layers alone; variant: them and the layer. Rendered once from the brain's commit with the layer set's answers, then the project's saved answers and the layer's defaults; the layer's text is appended to the file Claude Code reads in the clone.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if harness != .claudeCode {
                Label("Layer evals run Claude Code only for now.", systemImage: "info.circle").foregroundStyle(.orange).font(.caption)
            } else if let prepared, prepared.request == layerRequest {
                switch prepared.result {
                case .failure(let failure):
                    Label(failure.message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                case .success(let eval):
                    layerSummary(eval)
                }
            } else if layerRequest != nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Rendering the layer…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func layerSummary(_ eval: LayerSetups.Prepared) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(eval.setups, id: \.self) { setup in
                Text("\(setup.layer?.title ?? setup.name) · overlay \(setup.layer?.overlayHash.map { String($0.prefix(8)) } ?? "none")")
                    .font(.caption.monospaced())
            }
            Text("\(eval.runnable.count) of \(chosenTasks.count) tasks can run · eval \(eval.evalID)")
                .font(.caption)
            ForEach(eval.blocked.sorted(by: { $0.key < $1.key }), id: \.key) { id, reason in
                Label("\(chosenTasks.first { $0.id == id }?.title ?? id): \(reason)", systemImage: "nosign")
                    .foregroundStyle(.orange)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Per file: tasks whose project has its own file that gets the layer's text.
            ForEach(Dictionary(grouping: eval.ownFiles, by: \.value).sorted(by: { $0.key < $1.key }), id: \.key) { file, tasks in
                Text("\(tasks.count == 1 ? "1 task" : "\(tasks.count) tasks"): the layer's text is appended to the project's own \(file); "
                     + "the project would get it only by accepting the suggestion.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(eval.overlap + eval.warnings, id: \.self) { line in
                Label(line, systemImage: "info.circle")
                    .foregroundStyle(.orange)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var estimateKey: EstimateKey {
        if isLayer, let layerEval {
            return EstimateKey(tasks: layerEval.runnable, setups: layerEval.setups, repeats: repeats, sanity: layerEval.sanitySetup,
                               sanityTasks: layerEval.sanityTasks, agent: agent)
        }
        return EstimateKey(tasks: chosenTasks, setups: setups, repeats: repeats, sanity: nil, sanityTasks: [], agent: agent)
    }

    /// The current plan and estimate, once computed for these cells.
    private var currentPlan: Planned? {
        guard let planned, planned.key == estimateKey else { return nil }
        return planned.value
    }

    /// "Queue up to N cells for about $X (range $L–$H)?", or the count alone with no recorded cost.
    private var confirmationTitle: String {
        guard let plan = currentPlan else { return "" }
        let count = plan.toQueue == 1 ? "1 cell" : "\(plan.toQueue) cells"
        guard let total = plan.estimate.total, let low = plan.estimate.low, let high = plan.estimate.high else {
            return "Queue \(count) with no estimate yet?"
        }
        return String(format: "Queue up to %@ for about $%.2f (range $%.2f–$%.2f)?", count, total, low, high)
    }

    private var confirmationMessage: String {
        let waiting = model.labRuns.filter { $0.status == .queued }.count
        let agentText = "\(agent.harness.title) account (\(agent.model.isEmpty ? "default model" : agent.model), \(agent.effort))"
        return (currentPlan?.estimate.perCell == nil ? "No control or replay cell of this model recorded a cost, so AKit can't say what they cost. " : "")
            + "They run with your \(agentText), go through the sending policy and count toward the monthly limit."
            + (currentPlan?.estimate.timeText.map { " \($0)." } ?? "")
            + (waiting == 0 ? "" : " \(waiting) other queued \(waiting == 1 ? "run" : "runs") will start too.")
    }

    /// As the CLI prints it (`ControlRuns.plan`, `ControlRuns.estimate`): the cells still to run,
    /// the recorded cost of earlier control cells (else replays) of the same harness and model,
    /// and the time in the Lab queue.
    private var costLine: String {
        guard let plan = currentPlan else { return cells == 0 ? "No cells." : "Counting the cells to run…" }
        return "\(plan.toQueue) cells to run (\(plan.skipped) already done or queued); \(plan.estimate.costText)."
            + (plan.estimate.timeText.map { " \($0)." } ?? "")
    }

    private func queue() {
        busy = true
        error = nil
        let tasks = chosenTasks, setups = setups, repeats = repeats, environment = environment, keep = keep
        guard let plan = currentPlan else { return }
        let estimate = plan.estimate.total, maxCost = plan.estimate.high, confirmed = plan.toQueue
        let env = analysis.env
        let layerEval = isLayer ? layerEval : nil
        Task {
            do {
                try await Task.detached { try SendLog.checkLimit(estimate: estimate, settings: LabSettings.loadForSending(env: env), env: env) }.value
                if let layerEval {
                    let queued = try await model.queueLayerCells(layerEval, repeats: repeats, toQueue: confirmed, maxCost: maxCost ?? 0,
                                                                 environment: environment, keep: keep)
                    let skipped = queued.skipped > 0 ? " Skipped \(queued.skipped) cells already done or queued." : ""
                    analysis.message = queued.runs.isEmpty ? "Nothing to queue.\(skipped)"
                        : "Queued \(queued.runs.count) cells of eval \(layerEval.evalID): \(repeats) × \(layerEval.runnable.count) tasks × "
                            + "without \(layerEval.layer), layer \(layerEval.layer).\(skipped)"
                } else {
                    let queued = try await model.queueControlRuns(tasks: tasks, setups: setups, repeats: repeats, toQueue: confirmed, maxCost: maxCost,
                                                                  environment: environment, keep: keep)
                    let skipped = queued.skipped > 0 ? " Skipped \(queued.skipped) cells already done or queued." : ""
                    analysis.message = queued.runs.isEmpty ? "Nothing to queue.\(skipped)"
                        : "Queued \(queued.runs.count) cells: \(repeats) × \(tasks.count) tasks × \(setups.map(\.name).joined(separator: ", ")).\(skipped)"
                }
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
