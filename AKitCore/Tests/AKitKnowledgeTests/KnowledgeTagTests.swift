import Foundation
import Testing
@testable import AKitKnowledge

/// Badges on notes: `tags:` in the frontmatter, a color from the text, suggestions of used tags.
struct KnowledgeTagTests {
    @Test func readsTagsAsListOrString() {
        #expect(KnowledgeNote(text: "---\ntags: [legacy, \"on call\", Legacy]\n---\n# A\n").tags == ["legacy", "on-call"])
        #expect(KnowledgeNote(text: "---\ntags:\n  - '#team/core'\n  - beta\n---\n").tags == ["team/core", "beta"])
        #expect(KnowledgeNote(text: "---\ntags: one, two three\n---\n").tags == ["one", "two", "three"])
        #expect(KnowledgeNote(text: "# No frontmatter\n").tags == [])
    }

    @Test func normalizes() {
        #expect(KnowledgeTag.normalize("  #needs review ") == "needs-review")
        #expect(KnowledgeTag.normalize("a,b") == "ab")
        #expect(KnowledgeTag.normalize(" # ") == nil)
    }

    @Test func colorIsStableAndIgnoresCase() {
        let index = KnowledgeTag.colorIndex("payments")
        #expect(index == KnowledgeTag.colorIndex("Payments"))
        #expect((0..<KnowledgeTag.colorCount).contains(index))
        // FNV-1a of "a" is 0xE40C292C: the slot never changes between runs or Macs.
        #expect(KnowledgeTag.colorIndex("a") == Int(UInt32(0xE40C292C) % 10))
        // Different tags spread over the colors.
        #expect(Set(["a", "b", "c", "d", "e", "f", "g", "h"].map(KnowledgeTag.colorIndex)).count > 3)
    }

    @Test func usageCountsNotesMostUsedFirst() {
        let usage = KnowledgeTag.usage(of: [["beta", "Legacy"], ["legacy"], ["legacy", "legacy"], ["alpha"]])
        #expect(usage.map(\.tag) == ["Legacy", "alpha", "beta"])
        #expect(usage.map(\.notes) == [3, 1, 1])
    }

    @Test func suggestsUsedTagsPrefixFirstWithoutTheNotesOwn() {
        let used = ["legacy", "on-call", "call-flow", "beta"]
        #expect(KnowledgeTag.suggestions(for: "cal", among: used, excluding: []) == ["call-flow", "on-call"])
        #expect(KnowledgeTag.suggestions(for: "", among: used, excluding: ["Beta"]) == ["legacy", "on-call", "call-flow"])
        #expect(KnowledgeTag.suggestions(for: "zzz", among: used, excluding: []).isEmpty)
    }

    @Test func tagsListRoundTripsThroughSetting() throws {
        let note = try KnowledgeNote(text: "---\nkind: service\n---\n# A\n")
            .setting("tags", to: .list(["on-call", "team/core", "v1.2"]))
        #expect(note.tags == ["on-call", "team/core", "v1.2"])
        #expect(note.text.hasPrefix("---\nkind: service\ntags: [on-call, team/core, v1.2]\n---\n"))
    }
}

extension KnowledgeTagTests {
    @Test func rewritesOnlyTagsItCanKeep() {
        #expect(KnowledgeNote(text: "# A\n").tagsRewriteSafely)
        #expect(KnowledgeNote(text: "---\ntags: [a, on-call]\n---\n").tagsRewriteSafely)
        #expect(KnowledgeNote(text: "---\ntags: a b\n---\n").tagsRewriteSafely)
        #expect(!KnowledgeNote(text: "---\ntags: [a, 2024]\n---\n").tagsRewriteSafely)
        #expect(!KnowledgeNote(text: "---\ntags: [a, A]\n---\n").tagsRewriteSafely)
        #expect(!KnowledgeNote(text: "---\ntags: [\"#a\"]\n---\n").tagsRewriteSafely)
        #expect(!KnowledgeNote(text: "---\ntags: 2024\n---\n").tagsRewriteSafely)
        #expect(!KnowledgeNote(text: "---\ntags: {a: 1}\n---\n").tagsRewriteSafely)
        #expect(KnowledgeNote(text: "---\ntags: [a, null, 3]\n---\n").tags == ["a"])
    }
}
