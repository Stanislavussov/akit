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

    @Test func thirdLevelImagesAndPaths() {
        let document = GuideDocument.parse("""
        ## Group
        <!-- section: group -->
        ### Screen
        <!-- section: screen -->
        Intro.
        #### Step one
        <!-- section: step -->
        ![The **Add** button in the toolbar](images/add.png)
        Text after.
        #### Step two
        ### Other
        ![not an image] in a line
        """)
        let screen = document.sections[0].subsections[0]
        #expect(screen.blocks == [.paragraph("Intro.")])
        #expect(screen.subsections.map(\.id) == ["step", "step-two"])
        #expect(screen.subsections[0].blocks == [.image(path: "images/add.png", caption: "The **Add** button in the toolbar"),
                                                 .paragraph("Text after.")])
        #expect(document.sections[0].subsections.map(\.id) == ["screen", "other"])
        #expect(document.sections[0].subsections[1].blocks == [.paragraph("![not an image] in a line")])
        #expect(GuideDocument.image("![x](images/a.png) см. [y](#z)") == nil)
        #expect(document.path(to: "step") == ["group", "screen", "step"])
        #expect(document.path(to: "step-two") == ["group", "screen", "step-two"])
        #expect(document.sections[0].contains("add button"))
        // A deeper heading without a parent moves up.
        #expect(GuideDocument.parse("#### Alone\n## Next").sections.map(\.id) == ["alone", "next"])
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

    /// The Review screen's Guide button and the parts of `docs/guides/review.ru.md` (docs/design/review.md, Guide).
    @Test func theReviewGuideHasItsParts() throws {
        let file = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../../../docs/guides/review.ru.md").standardizedFileURL
        let document = GuideDocument.parse(try String(contentsOf: file, encoding: .utf8))
        #expect(!document.title.isEmpty)
        for id in ["overview", "setup", "run", "screen", "noise", "gaps", "discuss", "reruns", "config", "quality"] {
            #expect(document.path(to: id) == [id], "no section \(id)")
        }
    }

    /// The sidebar opens `docs/guides/screens.ru.md` at its group and screen ids
    /// (`SidebarGroup`, `SidebarSection` raw values in the app).
    @Test func theScreensGuideHasASectionPerSidebarItem() throws {
        let file = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../../../docs/guides/screens.ru.md").standardizedFileURL
        let document = GuideDocument.parse(try String(contentsOf: file, encoding: .utf8))
        #expect(!document.title.isEmpty)
        let screens = ["installed": ["overview", "skills", "skillsSh", "mcp"], "setup": ["brain"],
                       "activity": ["sessions", "usage"], "improve": ["insights", "lab", "analysis"], "work": ["review"]]
        for (group, ids) in screens {
            #expect(document.path(to: group) == [group], "no section \(group)")
            for id in ids { #expect(document.path(to: id) == [group, id], "no section \(id) in \(group)") }
        }
        for id in ["start", "map", "menus", "settings"] { #expect(document.path(to: id) == [id], "no section \(id)") }
    }

    /// `docs/guides/terms.ru.md`, the glossary Ask AKit reads first: a section per screen, and
    /// every `[text](guide#id)` link in it opens a section that guide has.
    @Test func theTermsGuideHasAGroupPerScreenAndItsLinksResolve() throws {
        let folder = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../docs/guides").standardizedFileURL
        var documents: [String: GuideDocument] = [:]
        for name in ["terms", "screens", "error-analysis", "review"] {
            documents[name] = GuideDocument.parse(try String(contentsOf: folder.appending(path: "\(name).ru.md"), encoding: .utf8))
        }
        let terms = try #require(documents["terms"])
        #expect(!terms.title.isEmpty)
        for id in ["terms-sidebar", "terms-overview", "terms-skills", "terms-skillsSh", "terms-mcp", "terms-instructions", "terms-settings",
                   "terms-sessions", "terms-usage", "terms-brain", "terms-insights", "terms-lab", "terms-analysis"] {
            #expect(terms.path(to: id) == [id], "no section \(id)")
        }
        #expect(terms.path(to: "terms-sidebar-ask") == ["terms-sidebar", "terms-sidebar-ask"])
        let text = try String(contentsOf: folder.appending(path: "terms.ru.md"), encoding: .utf8)
        var links = 0
        for match in text.matches(of: /\]\(([a-z-]*)#([A-Za-z0-9-]+)\)/) {
            let guide = match.output.1.isEmpty ? "terms" : String(match.output.1)
            let document = try #require(documents[guide], "no guide \(guide)")
            #expect(document.path(to: String(match.output.2)) != nil, "terms.ru.md links to \(guide)#\(match.output.2), which doesn't exist")
            links += 1
        }
        #expect(links > 100)
        // Ask AKit's sections that the glossary and the panel point to.
        for id in ["ask", "ask-panel", "ask-element", "ask-data"] { #expect(documents["screens"]?.path(to: id) != nil, "no screens#\(id)") }
    }
}
