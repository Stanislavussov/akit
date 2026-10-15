import Foundation
import Testing
@testable import AKitFoundation

struct GuideSearchTests {
    private static let search: GuideSearch = {
        let screens = GuideDocument.parse("""
        # Guide
        Вступление про скиллы.
        ## On This Mac
        <!-- section: installed -->
        ### Skills
        <!-- section: skills -->
        Экран показывает скиллы.
        #### Убрать скилл в Корзину
        <!-- section: skills-trash -->
        1. Нажмите **Move to Trash…** в карточке скилла.
        ![Карточка скилла tdd: кнопки Edit in Brain и корзина справа вверху](images/skill-card.png)
        - **Remove Everywhere…** убирает скилл отовсюду, а **Move to Project…** переносит.
        """)
        let other = GuideDocument.parse("# Other\n## Режимы\n<!-- section: modes -->\nСтраница режима и её кнопки.")
        return GuideSearch(guides: [("screens", "AKit Screens", screens), ("error-analysis", "Error Analysis", other)],
                           features: [.init(id: "skills", title: "Skills", summary: "Every skill the agents see now",
                                            guide: "screens", section: "skills")])
    }()

    @Test func findsScreensTitlesButtonsScreenshotsAndText() {
        let hits = Self.search.hits(for: "skills")
        #expect(hits.map(\.kind).prefix(2) == [.feature, .heading])
        #expect(hits[0].feature == "skills")
        #expect(hits[0].snippet == "Every skill the agents see now")
        #expect(hits[1].breadcrumb == ["AKit Screens", "On This Mac"])

        let button = Self.search.hits(for: "move trash")
        #expect(button.first?.kind == .button)
        #expect(button.first?.title == "Move to Trash…")
        #expect(button.first?.section == "skills-trash")
        #expect(button.first?.breadcrumb == ["AKit Screens", "On This Mac", "Skills", "Убрать скилл в Корзину"])

        let shot = Self.search.hits(for: "карточка edit in brain")
        #expect(shot.map(\.kind) == [.screenshot])
        #expect(shot.first?.image == "images/skill-card.png")

        // Two guides, one search.
        #expect(Self.search.hits(for: "режима").map(\.guide) == ["error-analysis", "error-analysis"])
        #expect(Self.search.hits(for: "нет такого").isEmpty)
        #expect(Self.search.hits(for: "  ").isEmpty)
    }

    @Test func endingsCaseAndWordOrderDoNotMatter() {
        // «скиллы», «скилла», «скилл» are one word; «корзину» finds «Корзину».
        for query in ["скиллов корзина", "КОРЗИНУ скилл", "корзине скиллы"] {
            #expect(Self.search.hits(for: query).contains { $0.section == "skills-trash" && $0.kind == .heading }, "\(query)")
        }
        // A word of the titles above completes a match, but doesn't make one.
        #expect(Self.search.hits(for: "skills everywhere").first?.title == "Remove Everywhere…")
        #expect(!Self.search.hits(for: "installed").contains { $0.kind == .text })
        let linked = GuideSearch(guides: [("g", "G", GuideDocument.parse("## A\nСмотрите [экран Skills](#skills) и **Apply**."))])
        #expect(linked.hits(for: "смотрите").first?.snippet == "Смотрите экран Skills и Apply.")
        #expect(linked.hits(for: "apply").first?.kind == .button)
        // A button needs every found word in one bold name; code is literal.
        #expect(Self.search.hits(for: "remove project").first?.kind == .text)
        let code = GuideSearch(guides: [("g", "G", GuideDocument.parse("## A\n```\nls **/*.swift **/*.md\n```\nСлово apply, потом **Apply**."))])
        #expect(code.hits(for: "swift").map(\.kind) == [.text])
        #expect(code.hits(for: "apply").first?.kind == .button)
        #expect(Self.search.hits(for: "скилл", limit: 3).count == 3)
        #expect(GuideSearch.terms("ёлка Ёлки") == ["елка", "елки"])
        // A bold Russian lead-in is text, not a button.
        let lead = GuideSearch(guides: [("g", "G", GuideDocument.parse("## A\n**Что это:** экран.\n**Apply** пишет."))])
        #expect(lead.hits(for: "что это").map(\.kind) == [.text])
        #expect(lead.hits(for: "apply").map(\.kind) == [.button])
        #expect(GuideSearch.terms("Скиллы, скиллов и серверы servers") == ["скилл", "и", "сервер", "server"])
    }

    @Test func snippetsAndHighlights() {
        let text = String(repeating: "слово ", count: 60) + "нужная кнопка здесь " + String(repeating: "хвост ", count: 60)
        let range = text.range(of: "кнопка")!
        let snippet = GuideSearch.snippet(text, around: range)
        #expect(snippet.count < 230)
        #expect(snippet.hasPrefix("…") && snippet.hasSuffix("…") && snippet.contains("нужная кнопка здесь"))
        #expect(GuideSearch.snippet("short", around: "short".startIndex..<"short".endIndex) == "short")
        let found = GuideSearch.matches(of: "кнопки", in: "Две кнопки и кнопка.")
        #expect(found.map { String("Две кнопки и кнопка."[$0]) } == ["кнопки", "кнопка"])
    }

    /// Every screenshot a guide names is in `docs/guides`, and has a caption to search by.
    @Test func theGuidesNameOnlyScreenshotsThatExist() throws {
        let folder = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../docs/guides").standardizedFileURL
        for name in ["screens.ru.md", "error-analysis.ru.md", "terms.ru.md", "review.ru.md"] {
            let document = GuideDocument.parse(try String(contentsOf: folder.appending(path: name), encoding: .utf8))
            func check(_ blocks: [GuideDocument.Block]) {
                for case .image(let path, let caption) in blocks {
                    #expect(FileManager.default.fileExists(atPath: folder.appending(path: path).path), "\(name): no \(path)")
                    #expect(caption.count > 20, "\(name): \(path) needs a caption that says what it shows")
                }
            }
            func walk(_ section: GuideDocument.Section) {
                check(section.blocks)
                section.subsections.forEach(walk)
            }
            check(document.intro)
            document.sections.forEach(walk)
        }
    }
}
