import AKitFoundation
import AKitLab
import SwiftUI

/// Settings → Knowledge check model (K15): the Pi model and thinking `akit kb check` uses to
/// mark a proposal (duplicate, contradiction with a map arrow, broken link), kept in
/// `~/.akit/lab/settings.json` (`akit kb check-model` sets it too). Unset: GPT-6 Luna through
/// Pi's GitHub Copilot provider.
struct KnowledgeCheckModelSection: View {
    @Environment(AppModel.self) private var model
    @Binding var lab: LabSettings
    @State private var models: [String] = []

    private var agent: LabAgent { KnowledgeCheckModel.agent(settings: lab) }

    /// What a `--settings --tab knowledge` snapshot prints.
    static func manifest(env: HarnessEnvironment = .current) -> String {
        "knowledge check model: " + KnowledgeCheckModel.label(KnowledgeCheckModel.agent(settings: LabSettings.load(env: env)))
    }

    var body: some View {
        Section {
            PiModelPicker(selection: Binding(get: { lab.knowledgeCheckAgent?.model ?? "" }, set: { name in
                let name = name.trimmingCharacters(in: .whitespaces)
                set(LabAgent(harness: .pi, model: name.isEmpty ? KnowledgeCheckModel.defaultAgent.model : name, effort: agent.effort, mode: .call))
            }), models: models, empty: "Default (\(KnowledgeCheckModel.defaultAgent.model))") {
                Text("Model")
            }
            Picker("Thinking", selection: Binding(get: { agent.effort }, set: { effort in
                var changed = agent
                changed.effort = effort
                set(changed)
            })) {
                ForEach(LabHarness.pi.efforts, id: \.self) { Text($0).tag($0) }
            }
            if lab.knowledgeCheckAgent != nil {
                Button("Reset to Default") { lab.knowledgeCheckAgent = nil }
            }
        } header: {
            Text("Knowledge check model").id("knowledge-check")
        } footer: {
            Text("akit kb check sends an agent's proposal, with the notes and map arrows it is compared with (at most about 1,500 tokens), to this Pi model. It only marks a duplicate, a contradiction with a map arrow or a broken link; you accept or reject. Each check is one call under the sending policy, the monthly limit and the send log (kb-check).")
                .foregroundStyle(.secondary)
        }
        .task {
            models = await model.labModels(for: .pi)
        }
    }

    /// The default is stored as nil.
    private func set(_ agent: LabAgent) {
        lab.knowledgeCheckAgent = agent == KnowledgeCheckModel.defaultAgent ? nil : agent
    }
}
