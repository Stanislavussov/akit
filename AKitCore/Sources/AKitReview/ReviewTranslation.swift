import AKitFoundation
import AKitLab
import Foundation

extension ReviewWorkflow.Run {
    /// Keys of the texts Translate covers in a review run.
    public enum TranslationKey {
        public static let brief = "brief"
        public static func request(_ id: String) -> String { "request:\(id)" }
    }

    /// The whole review in one Translate call: the brief and every request's text as it would
    /// go to GitLab. Translating never changes them: the drafts AKit sends stay the originals.
    /// The origin the review's passes were checked under (`.mergeRequest`, a local review's too):
    /// a translation by Pi sends the same text where the passes sent it. Cached in the run's
    /// folder. When the policy refuses
    /// the translation model, the review's own Pi model (`reviewAgent`) translates it: the
    /// passes sent this data there already.
    public var translationSource: OutputTranslation.Source {
        var parts = [OutputTranslation.Part(TranslationKey.brief, passes?.brief ?? "")]
        parts += (plan?.requests ?? []).map { OutputTranslation.Part(TranslationKey.request($0.id), $0.text) }
        return OutputTranslation.Source(parts: parts, origins: [.mergeRequest], cacheFolder: folder,
                                        ownAgent: reviewAgent, ownAgentName: "the review's model")
    }

    /// The model of the brief and role passes, as one Pi call: its model (empty = Pi's
    /// default) and its thinking level, or `low` when it has none.
    public var reviewAgent: LabAgent {
        let choice = spec.passes.value
        return LabAgent(harness: .pi, model: choice.model, effort: LabHarness.pi.efforts.contains(choice.thinking) ? choice.thinking : "low",
                        mode: .call)
    }
}
