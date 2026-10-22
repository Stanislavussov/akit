import Foundation
import Testing
import AKitFoundation
import AKitLab
@testable import AKitErrorAnalysis

/// What Translate takes from a review's notes: the model's texts, never the session's quotes
/// or the user's own notes.
struct NotesTranslationTests {
    @Test func theSourceHoldsTheModelsTextsOnly() {
        let home = FileManager.default.temporaryDirectory.appending(path: "akit-notes-translate-\(UUID().uuidString)")
        let env = HarnessEnvironment(homeDirectory: home, variables: ["HOME": home.path], executableSearchPaths: [])
        let notes = SessionNotes(
            sessionKey: "claude-code:s1", transcript: "/t/s1.jsonl", title: "Fix the build", project: nil,
            requirements: ["Build passes"], outcome: .partly,
            notes: [
                Note(id: "n1", source: .model, description: "The agent skipped the tests", step: 3, quote: "QUOTE-n1",
                     verdict: Verdict(accepted: true, reason: "Seen at step 3", by: .model, steelman: "Tests were optional")),
                Note(id: "n2", source: .model, description: "Wrong file", step: 4, quote: "QUOTE-n2",
                     verdict: Verdict(accepted: false, reason: "Not at that step", by: .code)),
                Note(id: "h1", source: .human, description: "My own note", step: 5, quote: "QUOTE-h1"),
            ],
            deviation: Deviation(), paragraph: "It went partly well.",
            advice: [Advice(title: "Run tests", evidence: "EVIDENCE", detail: "Add a rule", noteIDs: ["n1"])],
            notesConfig: StepConfig(step: "notes"), verifierConfig: nil, doneKeys: [:], runID: nil)
        let source = notes.translationSource(env: env)
        typealias Key = SessionNotes.TranslationKey
        #expect(source.parts.map(\.key) == [Key.paragraph, Key.requirement(0), Key.adviceTitle(0), Key.adviceDetail(0),
                                            Key.note("n1"), Key.verdict("n1"), Key.steelman("n1"), Key.note("n2")])
        let texts = source.parts.map(\.text).joined(separator: "\n")
        #expect(!texts.contains("QUOTE") && !texts.contains("EVIDENCE") && !texts.contains("My own note"))
        #expect(source.origins == [.claudeSession])
        #expect(source.cacheFolder == AnalysisPaths(env: env).folder)
    }
}
