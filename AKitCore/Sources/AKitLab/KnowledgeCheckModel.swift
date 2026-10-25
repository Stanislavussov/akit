import AKitFoundation
import Foundation

/// The model that checks knowledge base proposals (`akit kb check`, K15): a light model run
/// through a harness this Mac has (Pi by default, or Claude Code), set in Settings → Knowledge
/// check model (`akit kb check-model`). Models come only from the harness's own list
/// (`LabRuns.models`: `pi --list-models`, Claude Code's aliases), never typed in. The prompt,
/// the candidates and the parser are in `AKitKnowledge.KnowledgeCheck`; the call goes through
/// `ModelCall` with the origin `.knowledgeBase` and the purpose `kb-check`.
public enum KnowledgeCheckModel {
    public struct Failure: Error, LocalizedError, Sendable {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// The send log's purpose.
    public static let purpose = "kb-check"
    /// The user's choice (K15): GPT-6 Luna, under whichever provider Pi lists it (OpenCode Go at
    /// home, GitHub Copilot on the work Mac).
    public static let lunaModels = ["opencode-go/gpt-6-luna", "github-copilot/gpt-6-luna"]
    /// Pi at thinking low with no model: the model is picked from Pi's list at call time.
    public static let defaultAgent = defaultAgent(for: .pi)

    /// A harness with no model chosen: its model is picked from its list (`defaultModel`).
    public static func defaultAgent(for harness: LabHarness) -> LabAgent {
        LabAgent(harness: harness, model: "", effort: "low", mode: .call)
    }

    /// The default among the models `harness` lists: for Pi the first Luna it lists, else its
    /// first model; for Claude Code haiku, else its first. nil when it lists none.
    public static func defaultModel(for harness: LabHarness, available: [String]) -> String? {
        switch harness {
        case .pi: lunaModels.first(where: available.contains) ?? available.first
        case .claudeCode: available.contains("haiku") ? "haiku" : available.first
        }
    }

    /// The model the check uses now (model "" = the harness's default).
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

    /// `agent` with a model its harness lists: the default filled in, a model the harness
    /// doesn't list refused. `available` is the harness's list.
    public static func resolved(_ agent: LabAgent, available: [String]) throws(Failure) -> LabAgent {
        let source = agent.harness == .pi ? "pi --list-models" : "Claude Code's models"
        guard !available.isEmpty else {
            throw Failure(message: "\(agent.harness.title) lists no models (\(source)), so there is nothing to check with.")
        }
        var agent = agent
        if agent.model.isEmpty {
            agent.model = defaultModel(for: agent.harness, available: available) ?? ""
        } else if !available.contains(agent.model) {
            throw Failure(message: "\(agent.model) is not among \(agent.harness.title)'s models (\(source)). "
                + "Choose one in Settings → Knowledge check model or with akit kb check-model.")
        }
        return agent
    }

    /// `resolved` with the harness's list read now.
    public static func resolved(_ agent: LabAgent, env: HarnessEnvironment) async throws(Failure) -> LabAgent {
        try resolved(agent, available: await LabRuns.models(for: agent.harness, env: env))
    }

    /// "Pi · opencode-go/gpt-6-luna · low".
    public static func label(_ agent: LabAgent) -> String {
        "\(agent.harness.title) · \(agent.model.isEmpty ? "default model" : agent.model) · \(agent.effort)"
    }
}
