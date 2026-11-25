import Foundation
import Testing
@testable import AKitKnowledge

/// Requirement notes (K43): the items of gherkin blocks, their test links and the IDs a text cites.
struct KnowledgeScenariosTests {
    static let note = """
    # Scenarios — orders

    ## R-ORD-01 Cancel until shipped

    # R-ORD-99 · status: agreed
    (a heading outside a gherkin block is no item)

    ```gherkin
    # R-ORD-01 · ADO 123456, 123457 · status: agreed
    Rule: An order can be cancelled until it is shipped

      # SC-ORD-001 · ADO 123456 rev. 3, ADO 123457 · Figma 3357:7208 · level: e2e · journey · status: agreed
      # test: shop-e2e · tests/orders/cancel.spec.ts · cancel › refunds a paid order (${DATA} data)
      # test: shop-web · src/orders/cancel.test.ts · shows the refund
      @smoke
      Scenario: The customer cancels a paid order before shipping
        Given an order that is paid and not shipped

      # SC-ORD-002 · ADO 123457 · level: unit · status: draft
      Scenario Outline: A shipped order cannot be cancelled
    ```

    ## Open questions

    ```gherkin
    # OPEN-ORD-001 · ADO 123457 rev. 3 · status: open
    Question: Is a partly shipped order shipped?
    ```
    """

    @Test func itemsAreReadFromGherkinBlocksOnly() throws {
        let parsed = KnowledgeScenarios.parse(Self.note, note: "shop/scenarios")
        #expect(parsed.problems.isEmpty)
        #expect(parsed.items.map(\.id) == ["R-ORD-01", "SC-ORD-001", "SC-ORD-002", "OPEN-ORD-001"])
        let rule = parsed.items[0]
        #expect(rule.kind == .rule && rule.status == "agreed" && rule.workItems == ["123456", "123457"] && rule.line == 9)
        #expect(rule.title == "An order can be cancelled until it is shipped")
        let journey = parsed.items[1]
        #expect(journey.kind == .scenario && journey.level == "e2e" && journey.journey && journey.rule == "R-ORD-01")
        #expect(journey.workItems == ["123456", "123457"], "rev. 3 and the Figma node are no work items")
        let figma = KnowledgeScenarios.parse("```gherkin\n# OPEN-ORD-002 · ADO 321323 rev. 1, ADO 321325 rev. 3, Figma 3085:9434 and 3101:11449 · status: open\nQuestion: q\n```", note: "n")
        #expect(figma.items.first?.workItems == ["321323", "321325"])
        #expect(journey.sources == "ADO 123456 rev. 3, ADO 123457 · Figma 3357:7208")
        #expect(journey.title == "The customer cancels a paid order before shipping", "test links and tags sit between header and title")
        #expect(journey.tests == [
            .init(repo: "shop-e2e", path: "tests/orders/cancel.spec.ts", names: ["cancel", "refunds a paid order (${DATA} data)"], line: 13),
            .init(repo: "shop-web", path: "src/orders/cancel.test.ts", names: ["shows the refund"], line: 14),
        ])
        #expect(parsed.items[2].title == "A shipped order cannot be cancelled" && parsed.items[2].status == "draft" && !parsed.items[2].journey)
        let question = parsed.items[3]
        #expect(question.kind == .question && question.status == "open" && question.rule == nil && question.level == nil)
    }

    @Test(arguments: [
        ("# SC-ORD-001 · ADO 1 · status: agreed\nScenario: x", "SC-ORD-001 has no level."),
        ("# SC-ORD-001 · level: unit\nScenario: x", "SC-ORD-001 has no status."),
        ("# SC-ORD-001 · level: ui · status: agreed\nScenario: x", "SC-ORD-001 has the level “ui”; a scenario is e2e or unit."),
        ("# SC-ORD-001 · level: unit · status: done\nScenario: x", "SC-ORD-001 has the status “done”; a scenario is draft, agreed, dropped."),
        ("# OPEN-ORD-001 · status: agreed\nQuestion: x", "OPEN-ORD-001 has the status “agreed”; a question is open, answered."),
        ("# R-ORD-01 · status: draft\nScenario: x", "R-ORD-01 is not followed by a “Rule:” line."),
        ("# R-ORD-01 · level: unit · status: draft\nRule: x", "R-ORD-01 is a rule: level and journey are for scenarios."),
        ("# R-ORD-01 · status: draft\n# test: shop · a.test.ts\nRule: x", "The test link of R-ORD-01 on line 3 is not “# test: repository · file · test name”."),
        ("# R-ORD-01 · status: draft\n# test: shop · a.test.ts · works\nRule: x", "R-ORD-01 is a rule: tests are linked to scenarios."),
    ])
    func aMalformedHeaderIsAProblem(_ block: String, _ message: String) {
        let rule = block.hasPrefix("# SC") ? "# R-ORD-01 · status: draft\nRule: r\n" : ""
        let parsed = KnowledgeScenarios.parse("```gherkin\n\(rule)\(block)\n```\n", note: "n")
        #expect(parsed.problems.map(\.message) == [message])
    }

    @Test func aScenarioBeforeAnyRuleIsAProblem() {
        let parsed = KnowledgeScenarios.parse("```gherkin\n# SC-ORD-001 · level: unit · status: draft\nScenario: x\n```", note: "n")
        #expect(parsed.problems.map(\.message) == ["SC-ORD-001 comes before any rule of the note."])
    }

    @Test func citedIDsAreFoundOnceEachAndNotInsideOtherWords() {
        let text = "Covers SC-ORD-001 and SC-ORD-001, R-ORD-01; OPEN-ORD-002. Not XSC-ORD-003, SC-ORD-new-1 or SC-ORD-004a."
        #expect(KnowledgeScenarios.references(in: text) == ["SC-ORD-001", "R-ORD-01", "OPEN-ORD-002"])
    }

    @Test func itemsAreFilteredByWorkItemAndStatus() {
        let items = KnowledgeScenarios.parse(Self.note, note: "n").items
        #expect(KnowledgeScenarios.filter(items, workItem: "123457").map(\.id) == ["R-ORD-01", "SC-ORD-001", "SC-ORD-002", "OPEN-ORD-001"])
        #expect(KnowledgeScenarios.filter(items, workItem: "123456", status: "agreed").map(\.id) == ["R-ORD-01", "SC-ORD-001"])
        #expect(KnowledgeScenarios.filter(items, status: "draft").map(\.id) == ["SC-ORD-002"])
    }
}
