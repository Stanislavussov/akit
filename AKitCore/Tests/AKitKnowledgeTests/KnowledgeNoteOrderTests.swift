import Foundation
import Testing
@testable import AKitKnowledge

/// The note list's order (K42): numbered titles first by number, the rest by title.
struct KnowledgeNoteOrderTests {
    private func note(_ file: String, _ title: String) -> KnowledgeBase.NoteEntry {
        KnowledgeBase.NoteEntry(id: "spikes/form/" + file, area: "spikes", path: "areas/spikes/form/\(file).md",
                                kind: nil, title: title)
    }

    @Test func readsTheLeadingNumber() {
        #expect(note("a", "(1) COL-321305 Entry").number == 1)
        #expect(note("a", "12. Release").number == 12)
        #expect(note("a", "3) Submit").number == 3)
        #expect(note("a", "[4] Captcha").number == 4)
        #expect(note("a", "(5)").number == 5)
        #expect(note("a", "2026-11-18 Kick-off").number == nil)
        #expect(note("a", "1.5 release notes").number == nil)
        #expect(note("a", "API endpoints").number == nil)
    }

    @Test func numberedFirstByNumberThenByTitle() {
        // File names (task ids) are in another order than the numbers in the titles.
        let notes = [
            note("summary", "Summary of tasks"),
            note("321325", "(5) COL-321325 Submit"),
            note("321305", "(1) COL-321305 Entry"),
            note("api", "API endpoints"),
            note("321399", "(10) COL-321399 Mobile"),
            note("321316", "(2) COL-321316 Products"),
            note("2026-11-18", "2026-11-18 Kick-off"),
        ]
        #expect(KnowledgeBase.NoteEntry.inListOrder(notes).map(\.title) == [
            "(1) COL-321305 Entry", "(2) COL-321316 Products", "(5) COL-321325 Submit", "(10) COL-321399 Mobile",
            "2026-11-18 Kick-off", "API endpoints", "Summary of tasks",
        ])
    }

    @Test func sameNumberOrSameTitleKeepsAStableOrder() {
        let notes = [note("b", "(1) Same"), note("a", "(1) Same"), note("c", "(1) Other")]
        #expect(KnowledgeBase.NoteEntry.inListOrder(notes).map(\.id) == ["spikes/form/c", "spikes/form/a", "spikes/form/b"])
    }
}
