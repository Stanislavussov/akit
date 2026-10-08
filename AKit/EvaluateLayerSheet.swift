import AKitErrorAnalysis
import AKitFoundation
import AKitLab
import SwiftUI

/// Brain → layer → Evaluate… (`akit analysis control evaluate`): the layer's set as one layer
/// eval (`docs/design/layer-evals.md`, "UI"). The plan and its estimate come first; cells are
/// queued only after a confirmation that names the amount. With no recorded cost the only paid
/// step is one calibration cell, which the eval reuses.
struct EvaluateLayerSheet: View {
    /// What a plan depends on: a change plans again.
    private struct Request: Hashable {
        var agent: LabAgent
        var repeats: Int
        var sanity: Bool
        /// nil: the plan decides (continues an eval that only has its calibration cell so far).
        var continuing: Bool?
        /// nil: the default for the set's repository.
        var denied: [String]?
    }

    private enum Confirmation: Identifiable {
        case queue, calibrate
        var id: Self { self }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let layer: String
    /// Called with what was queued, after the sheet closes.
    let onQueued: (String) -> Void
    @State private var modelName = ""
    @State private var effort = "high"
    @State private var repeats = 3
    @State private var sanity = true
    @State private var continuing: Bool?
    @State private var deniedText = ""
    /// The user changed the denied commands; until then the repository's default applies.
    @State private var deniedEdited = false
    @State private var environment: LabEnvironment?
    @State private var keep = false
    @State private var planned: (request: Request, result: Result<LayerEvals.EvalPlan, AnalysisFailure>)?
    @State private var confirmation: Confirmation?
    @State private var error: String?
    @State private var busy = false

    private var agent: LabAgent {
        LabAgent(harness: .claudeCode, model: modelName.trimmingCharacters(in: .whitespaces), effort: effort)
    }

    private var request: Request {
        Request(agent: agent, repeats: repeats, sanity: sanity, continuing: continuing,
                denied: deniedEdited ? deniedText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } : nil)
    }

    /// The plan for the current request.
    private var plan: LayerEvals.EvalPlan? {
        guard let planned, planned.request == request, case .success(let plan) = planned.result else { return nil }
        return plan
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Evaluate \(layer)").font(.title2.bold())
            Text("Runs the layer's set as one eval in the Lab: each task without \(layer) (its required layers alone) and with it, in isolated clones, with Claude Code. The tasks' oracles decide; the verdict shows on the layer. Cells are paid runs of your Claude Code account under the sending policy.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                Section("Eval") { evalFields }
                Section("Agent") {
                    Text("Claude Code").foregroundStyle(.secondary)
                    TextField("Model", text: $modelName, prompt: Text("opus"))
                    Picker("Effort", selection: $effort) {
                        ForEach(LabHarness.claudeCode.efforts, id: \.self) { Text($0).tag($0) }
                    }
                    Stepper("Repeats: \(plan?.repeats ?? repeats) per task and setup", value: $repeats, in: 1...10)
                        .disabled(plan?.prepared.continuing == true)
                    Toggle("Read-only sanity cells on 3 tasks (must fail)", isOn: $sanity)
                        .disabled(plan?.prepared.continuing == true)
                        .help("An agent that can only read can't do the task: its cells failing shows the oracle works")
                    TextField("The agent may not run", text: Binding(get: { deniedText }, set: { deniedText = $0; deniedEdited = true }),
                              prompt: Text("no extra commands"))
                        .disabled(plan?.prepared.continuing == true)
                        .help("Shell commands, comma-separated, denied in every cell of both setups (Claude Code's --disallowedTools \"Bash(command:*)\"). In AKit's own repository: the make targets that build, install or start AKit, and open, which would run a development AKit against your real ~/.akit")
                    Picker("Open in", selection: $environment) {
                        Text("Automatic").tag(LabEnvironment?.none)
                        ForEach(model.labEnvironments, id: \.self) { Text($0.title).tag(LabEnvironment?.some($0)) }
                    }
                    Toggle("Keep the clones", isOn: $keep)
                }
            }
            .formStyle(.grouped)
            .frame(height: 430)
            if let plan { estimateLines(plan) }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if busy || (planned?.request != request) { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if let plan, plan.estimate.perCell == nil {
                    Button("Queue 1 Calibration Cell…") { confirmation = .calibrate }
                        .disabled(busy || plan.prepared.runnable.isEmpty || (plan.resumable?.open ?? 0) > 0)
                        .help("One paid cell measures the cost of a cell with this model; the eval reuses it")
                }
                Button(plan.map { $0.toQueue == 1 ? "Queue 1 Cell…" : "Queue \($0.toQueue) Cells…" } ?? "Queue Cells…") { confirmation = .queue }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || plan == nil || plan?.toQueue == 0 || plan?.estimate.perCell == nil || plan?.prepared.runnable.isEmpty == true)
            }
        }
        .padding(20)
        .frame(width: 640)
        .confirmationDialog(confirmationTitle, isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }),
                            titleVisibility: .visible, presenting: confirmation) { kind in
            Button("Queue") { queue(calibrateOnly: kind == .calibrate) }
            Button("Cancel", role: .cancel) {}
        } message: { kind in
            Text(confirmationMessage(kind))
        }
        .task {
            let agent = model.defaultAgent(.claudeCode)
            if modelName.isEmpty { modelName = agent.model }
            effort = agent.effort
        }
        .task(id: request) {
            let request = request
            guard !request.agent.model.isEmpty, planned?.request != request else { return }
            do {
                var plan = try await model.planLayerEval(layer: layer, agent: request.agent, repeats: request.repeats, sanity: request.sanity,
                                                         continuing: nil, denied: request.denied)
                // An eval that only has its calibration cell so far is continued by default.
                if let resumable = plan.resumable, request.continuing ?? resumable.calibrating {
                    plan = try await model.planLayerEval(layer: layer, agent: request.agent, repeats: request.repeats, sanity: request.sanity,
                                                         continuing: resumable.evalID, denied: request.denied)
                    plan.resumable = resumable
                }
                guard !Task.isCancelled else { return }
                planned = (request, .success(plan))
                if !deniedEdited { deniedText = plan.prepared.denied.joined(separator: ", ") }
            } catch {
                guard !Task.isCancelled else { return }
                planned = (request, .failure(AnalysisFailure(error.localizedDescription)))
            }
        }
    }

    @ViewBuilder private var evalFields: some View {
        if modelName.trimmingCharacters(in: .whitespaces).isEmpty {
            Text("Which model? Type its name above.").foregroundStyle(.secondary)
        } else if let planned, planned.request == request {
            switch planned.result {
            case .failure(let failure):
                Label(failure.message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            case .success(let plan):
                planFields(plan)
            }
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Rendering the layer and counting the cells…").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func planFields(_ plan: LayerEvals.EvalPlan) -> some View {
        let prepared = plan.prepared
        if let resumable = plan.resumable {
            Toggle("Continue the eval of \(resumable.createdAt.formatted(date: .abbreviated, time: .omitted)): \(resumable.finished) of \(resumable.total) cells done"
                   + (resumable.open > 0 ? ", \(resumable.open) queued or running" : ""),
                   isOn: Binding(get: { prepared.continuing }, set: { continuing = $0 }))
                .help("Its finished cells are reused; a new eval runs every cell again")
        }
        LabeledContent("Set") {
            Text("\(plan.set.tasks.count) tasks (\(plan.missing.count) missing, \(prepared.blocked.count) blocked)"
                 + (prepared.runnable.first.map { " · repository \($0.mainFolder.lastPathComponent)" } ?? ""))
        }
        ForEach(prepared.blocked.sorted(by: { $0.key < $1.key }), id: \.key) { id, reason in
            Label("\(id): \(reason)", systemImage: "nosign")
                .foregroundStyle(.orange)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        HStack(alignment: .firstTextBaseline) {
            Text("Answers")
            Spacer()
            Text(plan.set.answers.isEmpty ? "none in the set: the project's or the defaults"
                 : plan.set.answers.sorted(by: { $0.key < $1.key }).map { "\($0.key): \($0.value.display)" }.joined(separator: " · "))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
            Button("Edit in Set…") {
                dismiss()
                model.showLayerSet(layer)
            }
            .controlSize(.small)
            .help("The set's page in Error Analysis → Evals is where its answers are changed")
        }
        LabeledContent("Setups") {
            Text((prepared.setups.map { $0.layer?.title ?? $0.name } + (prepared.sanitySetup == nil ? [] : ["read-only sanity (\(prepared.sanityTasks.count) cells)"]))
                .joined(separator: " · "))
                .multilineTextAlignment(.trailing)
        }
        LabeledContent("Eval") {
            Text("\(plan.evalID)\(prepared.continuing ? " (continued)" : " (new)")").font(.callout.monospaced()).textSelection(.enabled)
        }
        if prepared.continuing, !prepared.denied.isEmpty {
            Text("A continued eval keeps its own denied commands: \(prepared.denied.joined(separator: ", ")).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Text("Home overlap: " + (prepared.overlap.isEmpty ? "none" : prepared.overlap.joined(separator: " ")))
            .font(.caption)
            .foregroundStyle(prepared.overlap.isEmpty ? Color.secondary : Color.orange)
            .fixedSize(horizontal: false, vertical: true)
        ForEach(prepared.warnings, id: \.self) { line in
            Label(line, systemImage: "info.circle")
                .foregroundStyle(.orange)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The cells to run, the cost and the time: always in view above the buttons.
    private func estimateLines(_ plan: LayerEvals.EvalPlan) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(plan.toQueue) cells to run (\(plan.skipped) already done or queued)").fontWeight(.medium)
            Text(plan.estimate.line)
            if let time = plan.estimate.timeText { Text(time) }
            if plan.estimate.perCell == nil {
                Text((plan.resumable?.open ?? 0) > 0 && plan.prepared.continuing
                     ? "The calibration cell is queued or running: when it finishes, its cost gives the estimate."
                     : "Queue 1 Calibration Cell… runs one paid cell to measure the cost; the eval reuses it, and the estimate appears when it finishes.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var confirmationTitle: String {
        guard let plan else { return "" }
        switch confirmation {
        case .calibrate: return "Queue 1 calibration cell?"
        case .queue:
            guard let total = plan.estimate.total, let low = plan.estimate.low, let high = plan.estimate.high else { return "" }
            return String(format: "Queue %d cells for about $%.2f (range $%.2f–$%.2f)?", plan.toQueue, total, low, high)
        case nil: return ""
        }
    }

    private func confirmationMessage(_ kind: Confirmation) -> String {
        let agent = plan?.agent ?? agent
        let account = "with your Claude Code account (\(agent.model), \(agent.effort)), go through the sending policy and count toward the monthly limit."
        // The Lab queue starts after queueing: runs waiting in it start too.
        let waiting = model.labRuns.filter { $0.status == .queued }.count
        let others = waiting == 0 ? "" : " \(waiting) other queued \(waiting == 1 ? "run" : "runs") will start too."
        switch kind {
        case .calibrate:
            // Known only when a replay or another model's cell gave a range.
            let range = plan.flatMap { plan -> String? in
                guard let low = plan.estimate.low, let high = plan.estimate.high, plan.estimate.cells > 0 else { return nil }
                return String(format: " Expected: $%.2f–$%.2f.", low / Double(plan.estimate.cells), high / Double(plan.estimate.cells))
            } ?? ""
            return "1 paid cell to measure the cost; the eval reuses it." + range + " It runs " + account + others
        case .queue:
            return "They run " + account + (plan?.estimate.timeText.map { " \($0)." } ?? "") + others
        }
    }

    private func queue(calibrateOnly: Bool) {
        guard let plan else { return }
        busy = true
        error = nil
        let environment = environment, keep = keep
        Task {
            defer { busy = false }
            do {
                let queued = try await model.queueLayerEval(plan, calibrateOnly: calibrateOnly, maxCost: calibrateOnly ? nil : plan.estimate.high,
                                                            environment: environment, keep: keep)
                let skipped = queued.skipped > 0 ? " Skipped \(queued.skipped) cells already done or queued." : ""
                let text = queued.runs.isEmpty ? "Nothing to queue.\(skipped)"
                    : calibrateOnly ? "Queued 1 calibration cell of eval \(plan.evalID). When it finishes, Evaluate… shows the estimate and continues this eval."
                    : "Queued \(queued.runs.count) cells of eval \(plan.evalID).\(skipped)"
                dismiss()
                onQueued(text)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
