@testable import AKitFoundation
import Testing

struct MarkdownBlocksTests {
    @Test func reviewCommentBecomesBlocks() {
        let comment = """
        🤖 · `security` · **vysoká** · jistota 0,88

        **Hlavička se zapisuje do logu**

        Log jde do sdíleného úložiště.
        Kdo ho čte, získá token.

        ```suggestion
        logger.LogDebug("present");
        ```
        <!-- akit-review:v1 {"id":"f1"} -->
        """
        #expect(MarkdownBlock.parse(comment) == [
            .paragraph("🤖 · `security` · **vysoká** · jistota 0,88"),
            .paragraph("**Hlavička se zapisuje do logu**"),
            .paragraph("Log jde do sdíleného úložiště.\nKdo ho čte, získá token."),
            .code(language: "suggestion", text: "logger.LogDebug(\"present\");"),
        ])
    }

    @Test func summaryWithHeadingsListsTableAndSub() {
        let summary = """
        ### Otázky pro autora

        - `A.cs:4`: Má /health zůstat otevřený?
          - podbod
        1. první
        2) druhý

        | Kritérium | Stav |
        |---|:---:|
        | Žádný token v logu | kód: A.cs:8 \\| f1 |

        > **Tip:** pozor
        > na to

        ---
        <sub>Zkontrolovaný commit 4f2c9e1b7a.</sub>
        """
        #expect(MarkdownBlock.parse(summary) == [
            .heading(level: 3, text: "Otázky pro autora"),
            .bullet(level: 0, text: "`A.cs:4`: Má /health zůstat otevřený?"),
            .bullet(level: 1, text: "podbod"),
            .numbered(number: "1.", level: 0, text: "první"),
            .numbered(number: "2.", level: 0, text: "druhý"),
            .table(header: ["Kritérium", "Stav"], rows: [["Žádný token v logu", "kód: A.cs:8 | f1"]]),
            .quote("**Tip:** pozor\nna to"),
            .rule,
            .small("Zkontrolovaný commit 4f2c9e1b7a."),
        ])
    }

    @Test func notMarkdownStaysText() {
        #expect(MarkdownBlock.parse("#hashtag and 2026 was fine") == [.paragraph("#hashtag and 2026 was fine")])
        #expect(MarkdownBlock.parse("- [x] done\n- [ ] open") == [.bullet(level: 0, text: "☑ done"), .bullet(level: 0, text: "☐ open")])
        #expect(MarkdownBlock.parse("```\nunclosed") == [.code(language: "", text: "unclosed")])
        #expect(MarkdownBlock.parse("") == [])
    }
}
