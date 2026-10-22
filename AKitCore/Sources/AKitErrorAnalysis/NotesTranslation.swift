import AKitFoundation
import AKitLab
import Foundation

extension SessionNotes {
    /// Keys of the texts Translate covers in a review's notes.
    public enum TranslationKey {
        public static let conclusion = "conclusion"
        public static let paragraph = "paragraph"
        public static func requirement(_ index: Int) -> String { "requirement:\(index)" }
        public static func adviceTitle(_ index: Int) -> String { "advice:\(index):title" }
        public static func adviceDetail(_ index: Int) -> String { "advice:\(index):detail" }
        public static func note(_ id: String) -> String { "note:\(id)" }
        public static func verdict(_ id: String) -> String { "verdict:\(id)" }
        public static func steelman(_ id: String) -> String { "steelman:\(id)" }
    }

    /// The model-written texts of these notes, for one Translate call: the conclusion, the
    /// paragraph, requirements, improvements (title and detail) and the model's notes with the
    /// verifier's reasons. Quotes from the session and the user's own notes stay as they are.
    /// The session's origin; cached in `~/.akit/lab/analysis/translations`.
    public func translationSource(env: HarnessEnvironment) -> OutputTranslation.Source {
        typealias Key = TranslationKey
        var parts = [OutputTranslation.Part(Key.conclusion, conclusion ?? ""), OutputTranslation.Part(Key.paragraph, paragraph)]
        parts += requirements.enumerated().map { OutputTranslation.Part(Key.requirement($0.offset), $0.element) }
        for (index, advice) in advice.enumerated() {
            parts.append(OutputTranslation.Part(Key.adviceTitle(index), advice.title))
            parts.append(OutputTranslation.Part(Key.adviceDetail(index), advice.detail))
        }
        for note in notes where note.source == .model {
            parts.append(OutputTranslation.Part(Key.note(note.id), note.description))
            if let verdict = note.verdict, verdict.by == .model {
                parts.append(OutputTranslation.Part(Key.verdict(note.id), verdict.reason))
                parts.append(OutputTranslation.Part(Key.steelman(note.id), verdict.steelman ?? ""))
            }
        }
        return OutputTranslation.Source(parts: parts, origins: [origin], cacheFolder: AnalysisPaths(env: env).folder)
    }
}
