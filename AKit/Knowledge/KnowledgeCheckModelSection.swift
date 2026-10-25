import AKitFoundation
import AKitLab
import SwiftUI

/// Settings → Knowledge check model (K15): the harness, model and thinking `akit kb check` uses
/// to mark a proposal (duplicate, contradiction with a map arrow, broken link), kept in
/// `~/.akit/lab/settings.json` (`akit kb check-model` sets it too). Harnesses are the ones this
/// Mac has; each keeps its own model. Models come only from the harness's list; the default is
/// picked from it (Pi: the GPT-6 Luna it lists; Claude Code: haiku).
struct KnowledgeCheckModelSection: View {
    @Environment(AppModel.self) private var model
    @Binding var lab: LabSettings
    /// The chosen harness's own list (`pi --list-models`, Claude Code's aliases).
    @State private var models: [String] = []

    private var agent: LabAgent { KnowledgeCheckModel.agent(settings: lab) }
    /// The installed harnesses, and the chosen one even when it is gone.
    private var harnesses: [LabHarness] {
        let found = model.labHarnesses
        return found.contains(agent.harness) ? found : [agent.harness] + found
    }

    /// What a `--settings --tab knowledge` snapshot prints.
    static func manifest(env: HarnessEnvironment = .current) -> String {
        "knowledge check model: " + KnowledgeCheckModel.label(KnowledgeCheckModel.agent(settings: LabSettings.load(env: env)))
    }

    var body: some View {
        Section {
            Picker("Harness", selection: Binding(get: { agent.harness }, set: { harness in
                guard harness != agent.harness else { return }
                set(KnowledgeCheckModel.agent(for: harness, settings: lab))
            })) {
                ForEach(harnesses, id: \.self) { Text($0.title).tag($0) }
            }
            let fallback = KnowledgeCheckModel.defaultModel(for: agent.harness, available: models)
            PiModelPicker(selection: Binding(get: { agent.model }, set: { name in
                var changed = agent
                changed.model = name
                set(changed)
            }), models: models, empty: "Default (\(fallback ?? (models.isEmpty ? "reading the list…" : "none")))",
                           help: agent.harness == .pi ? "Models Pi has credentials for (pi --list-models)" : "Claude Code's models",
                           allowsOther: false) {
                Text("Model")
            }
            if !models.isEmpty, !agent.model.isEmpty, !models.contains(agent.model) {
                LabeledContent("\(agent.harness.title) has no \(agent.model)") {
                    Button("Use Default (\(fallback ?? "-"))") {
                        var changed = agent
                        changed.model = ""
                        set(changed)
                    }
                }
            }
            Picker(agent.harness == .pi ? "Thinking" : "Effort", selection: Binding(get: { agent.effort }, set: { effort in
                var changed = agent
                changed.effort = effort
                set(changed)
            })) {
                ForEach(agent.harness.efforts, id: \.self) { Text($0).tag($0) }
            }
            if lab.knowledgeCheckAgent != nil || !lab.knowledgeCheckModels.isEmpty {
                Button("Reset to Default") {
                    lab.knowledgeCheckAgent = nil
                    lab.knowledgeCheckModels = [:]
                }
            }
        } header: {
            Text("Knowledge check model").id("knowledge-check")
        } footer: {
            Text("akit kb check sends an agent's proposal, with the notes and map arrows it is compared with (at most about 1,500 tokens), to this model. It only marks a duplicate, a contradiction with a map arrow or a broken link; you accept or reject. Any Pi model may get it; another harness must be on the Sending policy's list. Each check is one call under the sending policy, the monthly limit and the send log (kb-check).")
                .foregroundStyle(.secondary)
        }
        .task(id: agent.harness) {
            models = []
            let harness = agent.harness
            let found = await model.labModels(for: harness)
            if agent.harness == harness { models = found }
        }
    }

    private func set(_ agent: LabAgent) {
        KnowledgeCheckModel.choose(agent, in: &lab)
    }
}
