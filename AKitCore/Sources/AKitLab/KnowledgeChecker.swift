import AKitFoundation
import AKitKnowledge
import Foundation

/// One check of a knowledge base proposal by the check model (5.2, K15): the candidates
/// (`KnowledgeBase.checkCandidates`), one `ModelCall` through the sending policy (origin
/// `.knowledgeBase`, purpose `kb-check`), the parsed marks kept beside the proposal. The answer
/// only marks: the proposal and the base stay as they are. `akit kb check` and the app's Inbox
/// → Check Again both run this.
public enum KnowledgeChecker {
    public struct Outcome: Sendable {
        public let result: KnowledgeCheck.Result
        public let candidates: KnowledgeCheck.Candidates
    }

    public struct Failure: Error, LocalizedError, Sendable {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Checks `proposal` with `agent` (nil: Settings → Knowledge check model). Throws `Failure`
    /// with the reason when the settings can't be read, the gate refuses, the call fails, or the
    /// answer isn't marks; the sending policy's refusal reads as it does in the CLI ("Not sent: …").
    public static func run(_ proposal: KnowledgeProposal, in base: KnowledgeBase, agent: LabAgent? = nil,
                           env: HarnessEnvironment) async throws(Failure) -> Outcome {
        do {
            let chosen = try agent ?? KnowledgeCheckModel.agent(settings: LabSettings.loadForSending(env: env))
            let agent = try await KnowledgeCheckModel.resolved(chosen, env: env)
            let candidates = base.checkCandidates(for: proposal)
            let request = ModelCall.Request(agent: agent, purpose: KnowledgeCheckModel.purpose, system: KnowledgeCheck.system,
                                            input: KnowledgeCheck.input(proposal, candidates: candidates), schema: KnowledgeCheck.schema,
                                            origin: .knowledgeBase)
            let folder = FileManager.default.temporaryDirectory.appending(path: "akit-kb-check-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: folder) }
            let gate = try await SendGate.open(agent: agent, env: env)
            let answer = try await ModelCall.run(request, gate: gate, folder: folder, env: env)
            let marks = try KnowledgeCheck.marks(fromAnswer: answer.text)
            let result = try base.saveCheck(marks, of: proposal, model: KnowledgeCheckModel.label(agent))
            return Outcome(result: result, candidates: candidates)
        } catch let error as KnowledgeCheck.Failure {
            throw Failure(message: error.message)
        } catch let error as KnowledgeCheckModel.Failure {
            throw Failure(message: error.message)
        } catch let error as KnowledgeBase.Failure {
            throw Failure(message: error.message)
        } catch {
            throw Failure(message: error.localizedDescription)
        }
    }
}
