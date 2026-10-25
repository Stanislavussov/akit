import Foundation

/// The model that checks knowledge base proposals (`akit kb check`, K15): a light model run
/// through a harness this Mac has (Pi by default, or Claude Code), set in Settings → Knowledge
/// check model (`akit kb check-model`). The prompt, the candidates and the parser are in
/// `AKitKnowledge.KnowledgeCheck`; the call goes through `ModelCall` with the origin
/// `.knowledgeBase` and the purpose `kb-check`.
public enum KnowledgeCheckModel {
    /// The send log's purpose.
    public static let purpose = "kb-check"
    /// GPT-6 Luna under the Pi providers the user has (K15): OpenCode Go on the home Mac, GitHub
    /// Copilot on the work Mac. The first one is the default.
    public static let lunaModels = ["opencode-go/gpt-6-luna", "github-copilot/gpt-6-luna"]
    /// The user's choice (K15): GPT-6 Luna through Pi's OpenCode Go provider, at thinking low.
    public static let defaultAgent = LabAgent(harness: .pi, model: lunaModels[0], effort: "low", mode: .call)

    /// A harness's model when none was chosen for it: Luna for Pi, haiku for Claude Code.
    public static func defaultAgent(for harness: LabHarness) -> LabAgent {
        switch harness {
        case .pi: defaultAgent
        case .claudeCode: LabAgent(harness: .claudeCode, model: "haiku", effort: "low", mode: .call)
        }
    }

    /// The model the check uses now.
    public static func agent(settings: LabSettings) -> LabAgent { settings.knowledgeCheckAgent ?? defaultAgent }

    /// The model `harness` would use: the current one when it is that harness, else the last
    /// one chosen for it, else its default.
    public static func agent(for harness: LabHarness, settings: LabSettings) -> LabAgent {
        let current = agent(settings: settings)
        if current.harness == harness { return current }
        return settings.knowledgeCheckModels[harness.rawValue] ?? defaultAgent(for: harness)
    }

    /// Makes `agent` the check model and remembers it for its harness. The default is stored as
    /// nil, a harness's default as no entry.
    public static func choose(_ agent: LabAgent, in settings: inout LabSettings) {
        settings.knowledgeCheckAgent = agent == defaultAgent ? nil : agent
        settings.knowledgeCheckModels[agent.harness.rawValue] = agent == defaultAgent(for: agent.harness) ? nil : agent
    }

    /// Whether `model` names a model of `harness`: Pi takes `provider/model`, Claude Code an
    /// alias or a full name.
    public static func isValid(_ model: String, for harness: LabHarness) -> Bool {
        switch harness {
        case .pi: model.contains("/")
        case .claudeCode: !model.isEmpty && !model.contains(" ")
        }
    }

    /// The harness's models to choose from; for Pi both Lunas first, so either one is a click
    /// away even when Pi does not list it.
    public static func choices(_ models: [String], harness: LabHarness = .pi) -> [String] {
        guard harness == .pi else { return models }
        return lunaModels + models.filter { !lunaModels.contains($0) }
    }

    /// The other Luna when Pi lists it but not `model`: on the work Mac the default
    /// `opencode-go/gpt-6-luna` is missing and `github-copilot/gpt-6-luna` is there.
    public static func lunaSwitch(from model: String, piModels: [String]) -> String? {
        guard !piModels.isEmpty, !piModels.contains(model) else { return nil }
        return lunaModels.first { $0 != model && piModels.contains($0) }
    }

    /// "Pi · opencode-go/gpt-6-luna · low".
    public static func label(_ agent: LabAgent) -> String {
        "\(agent.harness.title) · \(agent.model.isEmpty ? "default model" : agent.model) · \(agent.effort)"
    }
}
