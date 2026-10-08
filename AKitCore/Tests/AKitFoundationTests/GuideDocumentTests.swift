import Foundation
import Testing
@testable import AKitFoundation

struct GuideDocumentTests {
    @Test func sectionsSubsectionsAndIDs() {
        let document = GuideDocument.parse("""
        # Guide title

        Intro line one
        and two.

        ## Overview
        <!-- section: overview -->

        Text.

        ### Run Batch…
        <!-- section: run-batch -->

        - first
          - nested
        1. one
        2. two

        ## Second part

        > **Совет:** a tip
        > that goes on.

        ```
        akit analysis status
          indented
        ```
        """)
        #expect(document.title == "Guide title")
        #expect(document.intro == [.paragraph("Intro line one and two.")])
        #expect(document.sections.map(\.id) == ["overview", "second-part"])
        #expect(document.sections[0].blocks == [.paragraph("Text.")])
        let sub = document.sections[0].subsections[0]
        #expect(sub.id == "run-batch")
        #expect(sub.title == "Run Batch…")
        #expect(sub.blocks == [.bullet(level: 0, text: "first"), .bullet(level: 1, text: "nested"),
                               .numbered(number: 1, text: "one"), .numbered(number: 2, text: "two")])
        #expect(document.sections[1].blocks == [.callout("**Совет:** a tip that goes on."),
                                                .code("akit analysis status\n  indented")])
        #expect(document.path(to: "run-batch") == ["overview", "run-batch"])
        #expect(document.path(to: "second-part") == ["second-part"])
        #expect(document.path(to: "missing") == nil)
    }

    @Test func slugsAreUniqueAndKeepCyrillic() {
        let document = GuideDocument.parse("## Что такое режим?\n## Что такое режим?\n## 1. Шаг")
        #expect(document.sections.map(\.id) == ["что-такое-режим", "что-такое-режим-2", "1-шаг"])
    }

    @Test func numberedNeedsASpaceAfterTheDot() {
        #expect(GuideDocument.parse("## A\n0.95 is the bar").sections[0].blocks == [.paragraph("0.95 is the bar")])
    }

    @Test func searchSeesSubsectionsWithoutMarks() {
        let document = GuideDocument.parse("## A\n### B\nPress **Run Batch** now")
        #expect(document.sections[0].contains("run batch"))
        #expect(!document.sections[0].contains("absent"))
    }

    /// The app's Guide buttons open these sections of `docs/guides/error-analysis.ru.md`.
    @Test func theErrorAnalysisGuideHasTheSectionsTheButtonsOpen() throws {
        let file = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../../../docs/guides/error-analysis.ru.md").standardizedFileURL
        let document = GuideDocument.parse(try String(contentsOf: file, encoding: .utf8))
        #expect(!document.title.isEmpty)
        for id in ["overview", "modes", "review", "bootstrap", "reports", "evals", "lab", "settings"] {
            #expect(document.path(to: id) == [id], "no section \(id)")
        }
        // The Guide buttons of Brain → layer → Evals and the Evaluate… sheet.
        #expect(document.path(to: "evaluate-layer") == ["evals", "evaluate-layer"])
    }

    /// The sidebar opens `docs/guides/screens.ru.md` at its group and screen ids
    /// (`SidebarGroup`, `SidebarSection` raw values in the app).
    @Test func theScreensGuideHasASectionPerSidebarItem() throws {
        let file = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../../../docs/guides/screens.ru.md").standardizedFileURL
        let document = GuideDocument.parse(try String(contentsOf: file, encoding: .utf8))
        #expect(!document.title.isEmpty)
        let screens = ["installed": ["overview", "skills", "skillsSh", "mcp"], "setup": ["brain"],
                       "activity": ["sessions", "usage"], "improve": ["insights", "lab", "analysis"]]
        for (group, ids) in screens {
            #expect(document.path(to: group) == [group], "no section \(group)")
            for id in ids { #expect(document.path(to: id) == [group, id], "no section \(id) in \(group)") }
        }
        #expect(document.path(to: "map") == ["map"])
    }
}
