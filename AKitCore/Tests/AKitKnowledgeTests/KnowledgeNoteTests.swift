import Foundation
import Testing
@testable import AKitKnowledge

/// Notes: frontmatter through Yams, `##` sections, and edits that keep every other byte (P4).
struct KnowledgeNoteTests {
    let note = KnowledgeNote(text: """
        ---
        kind: service
        repo: git@example.com:shop/orders-api.git
        files: [src/events/order-created.ts, src/a.ts]
        # a comment the frontmatter keeps
        ---
        # Orders API
        Takes orders.

        ## Events
        Sends "order created"; on failure a retry.

        ```
        ## not a section (code)
        ```

        ## Owners
        Team A.
        """)

    @Test func readsTheFrontmatterAndTitle() {
        #expect(note.kind == "service")
        #expect(note.repo == "git@example.com:shop/orders-api.git")
        #expect(note.files == ["src/events/order-created.ts", "src/a.ts"])
        #expect(note.title == "Orders API")
        #expect(KnowledgeNote(text: "no header\n# T\n").kind == nil)
        #expect(KnowledgeNote(text: "---\nfiles: one.ts\n---\n").files == ["one.ts"])
        #expect(KnowledgeNote(text: "---\n: [broken\n---\n# T\n").frontmatter.isEmpty)
    }

    @Test func findsSectionsOutsideCode() throws {
        #expect(note.sections.map(\.heading) == ["Events", "Owners"])
        let events = try #require(note.section("Events"))
        #expect(String(note.text[events.bodyRange]).hasPrefix("Sends \"order created\""))
        #expect(String(note.text[events.bodyRange]).hasSuffix("```\n\n"))
    }

    @Test func aSectionEditChangesOnlyThatSection() throws {
        let edited = try note.replacingSection("Owners", with: "Team B.")
        #expect(edited.text == note.text.replacingOccurrences(of: "Team A.", with: "Team B.\n"))
        let first = try note.replacingSection("Events", with: "Nothing.")
        let events = note.section("Events")!
        #expect(first.text.hasPrefix(note.text[..<events.bodyRange.lowerBound]))
        #expect(first.text.hasSuffix("Nothing.\n\n## Owners\nTeam A."))
        #expect(throws: KnowledgeNote.Failure.self) { try note.replacingSection("Nope", with: "") }
    }

    @Test func editsKeepCRLFAndABOMByteForByte() throws {
        let text = "\u{FEFF}---\r\nkind: flow\r\n---\r\n# T\r\n\r\n## A\r\nold\r\n\r\n## B\r\nkeep\r\n"
        let crlf = KnowledgeNote(text: text)
        #expect(crlf.kind == "flow")
        #expect(crlf.sections.map(\.heading) == ["A", "B"])
        let edited = try crlf.replacingSection("A", with: "new")
        #expect(Array(edited.text.utf8) == Array("\u{FEFF}---\r\nkind: flow\r\n---\r\n# T\r\n\r\n## A\r\nnew\r\n\r\n## B\r\nkeep\r\n".utf8))
        let added = crlf.appendingSection("C", body: "more")
        #expect(added.text == text + "\r\n## C\r\nmore\r\n")
    }

    @Test func appendingKeepsTheTextBefore() {
        let added = note.appendingSection("Retry", body: "backoff")
        #expect(added.text == note.text + "\n\n## Retry\nbackoff\n")
        #expect(KnowledgeNote(text: "").appendingSection("A", body: "x\n").text == "## A\nx\n")
    }

    @Test func writeAndLoadAreByteIdentical() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "akit-kb-note-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        let bytes = Data("\u{FEFF}---\r\nkind: x\r\n---\r\ntext without end".utf8)
        try bytes.write(to: url)
        let loaded = try #require(KnowledgeNote.load(url))
        try loaded.write(to: url)
        #expect(try Data(contentsOf: url) == bytes)
        try Data([0xFF, 0xFE, 0x00]).write(to: url)
        #expect(KnowledgeNote.load(url) == nil)
    }

    @Test func obsidianURLEncodesThePath() {
        let url = Obsidian.openURL(note: URL(filePath: "/Users/me/.akit/local/knowledge/work/areas/pay & co/Café #1.md"))
        #expect(url?.absoluteString == "obsidian://open?path=%2FUsers%2Fme%2F.akit%2Flocal%2Fknowledge%2Fwork%2Fareas%2Fpay%20%26%20co%2FCaf%C3%A9%20%231.md")
    }
}
