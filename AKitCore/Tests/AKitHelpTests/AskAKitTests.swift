import AKitFoundation
import Foundation
import Testing
@testable import AKitHelp

struct AskAKitTests {
    private static let screens = GuideDocument.parse("""
    # AKit Screens
    ## On This Mac
    <!-- section: installed -->
    Группа экранов.
    ### Skills
    <!-- section: skills -->
    Экран показывает скиллы. Подробно: [MCP](#mcp).
    #### Что на экране
    <!-- section: skills-screen -->
    - **Listing budget** — сколько места занимает список скиллов.
    #### Убрать скилл в Корзину
    <!-- section: skills-trash -->
    1. Нажмите **Move to Trash…**.
    ### MCP Servers
    <!-- section: mcp -->
    Серверы MCP по агентам.
    #### Выключить сервер
    <!-- section: mcp-switches -->
    Кнопка **Off in Project…** выключает сервер в проекте.
    """)
    private static let analysis = GuideDocument.parse("""
    # Error Analysis
    ## Режимы
    <!-- section: modes -->
    Режим ошибки и его частота.
    """)
    private static let terms = GuideDocument.parse("""
    # Термины
    ## Скилл
    <!-- section: skill -->
    Скилл — папка с инструкцией для агента.
    ## Сервер MCP
    <!-- section: mcp-server -->
    Программа, которая даёт агенту инструменты.
    """)
    private static let guides: [AskAKit.Guide] = [("screens", "AKit Screens", screens), ("error-analysis", "Error Analysis", analysis)]

    @Test func contextText() {
        let bare = AskContext(screen: "skills", screenTitle: "Skills", summary: " ")
        #expect(bare.text == "Screen: Skills")
        let full = AskContext(screen: "skills", screenTitle: "Skills", summary: "12 skills",
                              element: .init(title: "tdd", facts: "Scope: global\nHarnesses: Claude Code\n"))
        #expect(full.text == "Screen: Skills\nWhat the screen shows now:\n12 skills\nThe question is about: tdd\nScope: global\nHarnesses: Claude Code")
    }

    @Test func alwaysSendsTheScreensOwnSections() {
        let context = AskContext(screen: "skills", screenTitle: "Skills", summary: "")
        let prepared = AskAKit.prepare(question: "привет", context: context, history: [], guides: Self.guides)
        #expect(prepared.sources.map(\.section) == ["skills", "skills-screen", "skills-trash"])
        // This guide's links name the guide, so the model can cite them.
        #expect(prepared.system.contains("Подробно: [MCP](screens#mcp)."))
        #expect(prepared.system.contains("(link: screens#skills-trash)"))
        #expect(prepared.input.hasSuffix("Question: привет"))
        #expect(prepared.system.contains("Answer in the language of the question."))
        let russian = AskAKit.prepare(question: "What is this?", context: context, history: [], guides: Self.guides, language: "Russian")
        #expect(russian.system.contains("- Answer in Russian."))
    }

    @Test func picksSectionsTheQuestionAndElementName() {
        let context = AskContext(screen: "skills", screenTitle: "Skills", summary: "",
                                 element: .init(title: "Off in Project…", facts: ""))
        let prepared = AskAKit.prepare(question: "Что значит режим?", context: context, history: [], guides: Self.guides)
        let ids = prepared.sources.map(\.id)
        #expect(ids.contains("screens#mcp-switches"))
        #expect(ids.contains("error-analysis#modes"))
        // Reading order: screens before error analysis.
        #expect(ids.firstIndex(of: "screens#skills")! < ids.firstIndex(of: "error-analysis#modes")!)
    }

    @Test func staysWithinTheBudgetWithWholeSections() {
        var text = "# Big\n## Screen\n<!-- section: big -->\nНачало.\n"
        for index in 0..<50 {
            text += "### Часть \(index)\n<!-- section: part-\(index) -->\n" + String(repeating: "Слово про бюджет. ", count: 60) + "\n"
        }
        let guides: [AskAKit.Guide] = [("screens", "Big", GuideDocument.parse(text))]
        let context = AskContext(screen: "big", screenTitle: "Big", summary: "")
        let pieces = AskAKit.select(question: "бюджет", context: context, guides: guides, search: GuideSearch(guides: guides), budget: 5_000)
        #expect(pieces.reduce(0) { $0 + $1.text.count } <= 5_000)
        #expect(pieces.first?.id == "big")
        #expect(pieces.count > 2 && pieces.count < 51)
        // Whole sections: every piece is one section's full text.
        let all = AskAKit.pieces(guides)
        #expect(pieces.allSatisfy { all.contains($0) })
    }

    @Test func glossaryEntriesGoFirst() {
        let guides = Self.guides + [("terms", "Термины", Self.terms)]
        let context = AskContext(screen: "mcp", screenTitle: "MCP Servers", summary: "")
        let pieces = AskAKit.select(question: "что такое скилл", context: context, guides: guides,
                                    search: GuideSearch(guides: guides), budget: 40_000)
        #expect(pieces.contains { $0.guide == "terms" && $0.id == "skill" })
        // Within a tight budget the glossary entry still beats a ranked screen section.
        let ownSize = AskAKit.pieces(guides).filter { $0.id == "mcp" || $0.id == "mcp-switches" }.reduce(0) { $0 + $1.text.count }
        let entry = AskAKit.pieces(guides).first { $0.guide == "terms" && $0.id == "skill" }!
        let tight = AskAKit.select(question: "что такое скилл", context: context, guides: guides,
                                   search: GuideSearch(guides: guides), budget: ownSize + entry.text.count)
        #expect(tight.map(\.id).contains("skill"))
    }

    @Test func historyKeepsTheNewestTurnsWithinBounds() {
        let turns = (0..<20).map { AskTurn(role: $0.isMultiple(of: 2) ? .user : .assistant, text: "turn \($0)") }
        let kept = AskAKit.recent(turns)
        #expect(kept.count == AskAKit.historyTurns)
        #expect(kept.first?.text == "turn 12")
        #expect(kept.last?.text == "turn 19")

        let long = [AskTurn(role: .user, text: String(repeating: "a", count: 10_000)),
                    AskTurn(role: .assistant, text: String(repeating: "b", count: 5_000)),
                    AskTurn(role: .user, text: "short")]
        let cut = AskAKit.recent(long)
        // Each turn is cut at the limit; the oldest that no longer fits is dropped.
        #expect(cut.map(\.text.count) == [AskAKit.turnLimit + 1, AskAKit.turnLimit + 1, 5])
        #expect(cut.reduce(0) { $0 + $1.text.count } <= AskAKit.historyBudget)

        let prepared = AskAKit.prepare(question: "и дальше?", context: AskContext(screen: "x", screenTitle: "X", summary: ""),
                                       history: [AskTurn(role: .user, text: "что это"), AskTurn(role: .assistant, text: "Это экран.")],
                                       guides: Self.guides)
        #expect(prepared.input.contains("Earlier in this chat:\nUser: что это\n\nAsk AKit: Это экран."))
    }

    @Test func readsTheAnswer() {
        #expect(AskAKit.answer(from: #"{"answer": "**Listing budget** — это место."}"#) == "**Listing budget** — это место.")
        #expect(AskAKit.answer(from: "Here:\n```json\n{\"answer\": \"Да {скобки}\"}\n```") == "Да {скобки}")
        #expect(AskAKit.answer(from: "  Plain answer.\n") == "Plain answer.")
        #expect(AskAKit.answer(from: "} broken {") == "} broken {")
    }

    @Test func findsTheSectionsAnAnswerCites() {
        let answer = """
        См. [Skills](screens#skills), [корзина](#skills-trash), [режимы](error-analysis#modes),
        снова [Skills](screens#skills), [выдумка](screens#nope), [сайт](https://example.com#x).
        """
        let sources = AskAKit.sources(in: answer, guides: Self.guides)
        #expect(sources.map(\.id) == ["screens#skills", "screens#skills-trash", "error-analysis#modes"])
        #expect(sources.map(\.title) == ["Skills", "Убрать скилл в Корзину", "Режимы"])
    }

    /// The bundled guides: a real question stays within the budget and finds its screen.
    @Test func realGuides() throws {
        let folder = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../docs/guides").standardized
        let guides: [AskAKit.Guide] = try ["screens", "error-analysis"].map { id in
            (id, id, GuideDocument.parse(try String(contentsOf: folder.appending(path: "\(id).ru.md"), encoding: .utf8)))
        }
        let search = GuideSearch(guides: guides)
        let context = AskContext(screen: "insights", screenTitle: "Insights", summary: "",
                                 element: .init(title: "Listing budget", facts: "Used: 4,100 of 8,000 characters"))
        let prepared = AskAKit.prepare(question: "Что значит этот бюджет и что делать?", context: context, history: [], guides: guides, search: search)
        let sent = AskAKit.select(question: "Что значит этот бюджет и что делать?", context: context, guides: guides, search: search,
                                  budget: AskAKit.guideBudget)
        #expect(sent.reduce(0) { $0 + $1.text.count } <= AskAKit.guideBudget)
        #expect(prepared.sources.contains { $0.id == "screens#insights" })
        #expect(prepared.sources.count > 3)
    }
}
