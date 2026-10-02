import AKitErrorAnalysis
import AKitLab
import SwiftUI

/// Harness, model and effort of a review agent, with the models the harness offers. Fields
/// of a grouped `Form`; picks the harness's defaults when it appears and on every switch.
struct ReviewAgentFields: View {
    @Environment(AppModel.self) private var model
    @Binding var harness: LabHarness
    @Binding var modelName: String
    @Binding var effort: String
    /// Models to offer for the harness (Pi: the ones it has credentials for).
    @State private var models: [String] = []

    var body: some View {
        Picker("Harness", selection: $harness) {
            ForEach(model.labHarnesses, id: \.self) { Text($0.title).tag($0) }
        }
        .task {
            if !model.labHarnesses.contains(harness), let first = model.labHarnesses.first { harness = first }
            await load(harness)
        }
        .onChange(of: harness) { _, chosen in Task { await load(chosen) } }
        HStack {
            TextField("Model", text: $modelName, prompt: Text(harness == .pi ? "Pi's default" : "opus"))
            Menu("Models") {
                ForEach(models, id: \.self) { name in Button(name) { modelName = name } }
            }
            .fixedSize()
            .disabled(models.isEmpty)
            .help(harness == .pi ? "Models Pi has credentials for (pi --list-models)" : "Claude Code model aliases")
        }
        Picker(harness == .pi ? "Thinking" : "Effort", selection: $effort) {
            ForEach(harness.efforts, id: \.self) { Text($0).tag($0) }
        }
    }

    /// The chosen harness's defaults and models. `ProcessRunner` doesn't stop on cancel, so a
    /// slow `pi --list-models` that ends after a switch back to Claude Code is dropped.
    private func load(_ chosen: LabHarness) async {
        let defaults = model.defaultAgent(chosen)
        modelName = defaults.model
        effort = chosen.efforts.contains(defaults.effort) ? defaults.effort : chosen.efforts[0]
        models = []
        let found = await model.labModels(for: chosen)
        if harness == chosen { models = found }
    }
}

/// Reviews the same session again with another model, as one model call: for hard sessions
/// where a second opinion helps. The new notes replace this review's.
struct RecheckSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let run: LabRun
    let onQueued: (LabRun) -> Void
    @State private var harness: LabHarness = .claudeCode
    @State private var modelName = ""
    @State private var effort = "high"
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Re-check with Another Model").font(.title2.bold())
            Text("A new review of the same session: notes and the verifier, as one model call each. Its notes replace this review's; this run keeps its paragraph and improvements.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let agent = run.spec.agent {
                Text("This review: \(agent.label)").font(.callout)
            }
            Form {
                ReviewAgentFields(harness: $harness, modelName: $modelName, effort: $effort)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .scrollContentBackground(.hidden)
            .frame(height: 150)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Queue and Start", action: queue)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || (harness == .claudeCode && modelName.trimmingCharacters(in: .whitespaces).isEmpty))
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func queue() {
        guard let transcript = run.spec.reviewedTranscript else { return }
        busy = true
        error = nil
        let agent = LabAgent(harness: harness, model: modelName.trimmingCharacters(in: .whitespaces), effort: effort, mode: .call)
        Task {
            do {
                let file = URL(filePath: transcript)
                let session = model.sessions.first { $0.file.path == transcript }
                    ?? NotesPipeline.Target(harness: run.spec.reviewedHarness, file: file, title: run.spec.reviewedTitle).summary
                onQueued(try await model.queueReview(of: session, agent: agent, environment: nil))
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
