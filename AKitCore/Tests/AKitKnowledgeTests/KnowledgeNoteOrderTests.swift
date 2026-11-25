import Foundation
import Testing
@testable import AKitKnowledge

/// The note list's order (K42): numbered titles first by number, the rest by title.
struct KnowledgeNoteOrderTests {
    private func note(_ file: String, _ title: String) -> KnowledgeBase.NoteEntry {
        KnowledgeBase.NoteEntry(id: "shop/form/" + file, area: "shop", path: "areas/shop/form/\(file).md",
                                kind: nil, title: title)
    }

    @Test func readsTheLeadingNumber() {
        #expect(note("a", "(1) SHOP-100105 Entry").number == 1)
        #expect(note("a", "12. Release").number == 12)
        #expect(note("a", "3) Submit").number == 3)
        #expect(note("a", "[4] Captcha").number == 4)
        #expect(note("a", "(5)").number == 5)
        #expect(note("a", "2026-01-15 Kick-off").number == nil)
        #expect(note("a", "1.5 release notes").number == nil)
        #expect(note("a", "API endpoints").number == nil)
    }

    @Test func numberedFirstByNumberThenByTitle() {
        // File names (task ids) are in another order than the numbers in the titles.
        let notes = [
            note("summary", "Summary of tasks"),
            note("100125", "(5) SHOP-100125 Submit"),
            note("100105", "(1) SHOP-100105 Entry"),
            note("api", "API endpoints"),
            note("100199", "(10) SHOP-100199 Mobile"),
            note("100116", "(2) SHOP-100116 Products"),
            note("2026-01-15", "2026-01-15 Kick-off"),
        ]
        #expect(KnowledgeBase.NoteEntry.inListOrder(notes).map(\.title) == [
            "(1) SHOP-100105 Entry", "(2) SHOP-100116 Products", "(5) SHOP-100125 Submit", "(10) SHOP-100199 Mobile",
            "2026-01-15 Kick-off", "API endpoints", "Summary of tasks",
        ])
    }

    @Test func sameNumberOrSameTitleKeepsAStableOrder() {
        let notes = [note("b", "(1) Same"), note("a", "(1) Same"), note("c", "(1) Other")]
        #expect(KnowledgeBase.NoteEntry.inListOrder(notes).map(\.id) == ["shop/form/c", "shop/form/a", "shop/form/b"])
    }
}
