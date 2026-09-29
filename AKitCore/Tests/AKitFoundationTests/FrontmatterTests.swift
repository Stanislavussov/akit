import Foundation
import Testing
@testable import AKitFoundation

struct FrontmatterTests {
    @Test func simpleAndQuoted() {
        let meta = Frontmatter.parse("---\nname: tdd\ndescription: \"Test: first\"\nother: 'it''s'\n---\nbody")
        #expect(meta == ["name": "tdd", "description": "Test: first", "other": "it's"])
    }

    @Test func blockAndFoldedAndPlainContinuation() {
        let text = """
        ---
        name: x
        description: >
          one
          two
        notes: |
          line1
          line2
        long: first
          second
        tags:
          - a
        ---
        """
        let meta = Frontmatter.parse(text)
        #expect(meta["description"] == "one two")
        #expect(meta["notes"] == "line1\nline2")
        #expect(meta["long"] == "first second")
        #expect(meta["tags"] == nil)
    }

    @Test func noHeader() {
        #expect(Frontmatter.parse("# Title\nname: x").isEmpty)
        #expect(Frontmatter.parse("---\nname: x\n").isEmpty)
    }
}
