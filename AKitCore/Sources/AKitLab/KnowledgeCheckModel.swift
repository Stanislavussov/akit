import Foundation

/// The model that checks knowledge base proposals (`akit kb check`, K15): a light model run
/// through Pi, set in Settings → Knowledge check model (`akit kb check-model`). The prompt, the
/// candidates and the parser are in `AKitKnowledge.KnowledgeCheck`; the call goes through
/// `ModelCall` with the origin `.knowledgeBase` and the purpose `kb-check`.
public enum KnowledgeCheckModel {
    /// The send log's purpose.
    public static let purpose = "kb-check"
    /// The user's choice for the work Mac (K15): GPT-6 Luna through Pi's GitHub Copilot provider.
    public static let defaultAgent = LabAgent(harness: .pi, model: "opencode-go/gpt-6-luna", effort: "low", mode: .call)

    /// The model the check uses now.
    public static func agent(settings: LabSettings) -> LabAgent { settings.knowledgeCheckAgent ?? defaultAgent }

    /// "Pi · opencode-go/gpt-6-luna · low".
    public static func label(_ agent: LabAgent) -> String {
        "\(agent.harness.title) · \(agent.model.isEmpty ? "default model" : agent.model) · \(agent.effort)"
    }
}
