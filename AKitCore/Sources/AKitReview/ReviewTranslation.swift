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
    /// A merge request's origin (Pi got it through its MCP servers); a local review's is the
    /// repository's code, which Pi read. Cached in the run's folder.
    public var translationSource: OutputTranslation.Source {
        var parts = [OutputTranslation.Part(TranslationKey.brief, passes?.brief ?? "")]
        parts += (plan?.requests ?? []).map { OutputTranslation.Part(TranslationKey.request($0.id), $0.text) }
        return OutputTranslation.Source(parts: parts, origins: [spec.local == nil ? .mergeRequest : .code(.pi)], cacheFolder: folder)
    }
}
