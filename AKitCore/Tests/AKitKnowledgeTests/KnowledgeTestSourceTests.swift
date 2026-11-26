import Testing
@testable import AKitKnowledge

/// A linked test in its source (K45): the call found by its title, and the steps' terms.
struct KnowledgeTestSourceTests {
    static let source = """
    describe("cancel", () => {
    \tbeforeEach(() => stub("customer.firstName"));
    \tit("refunds a paid order", async () => {
    \t\t// a comment with a ) and a "
    \t\tconst text = "a ) in a string, and 'quotes'";
    \t\texpect(await refund(`${id})`)).toBe(403);
    \t\texpect(screen.getByRole("button", { name: /Zpět na úvod/ })).toBeVisible();
    \t});
    \tit("keeps a shipped order", () => {
    \t\texpect(customer.lastName).toBe("Novák");
    \t});
    \tit.each(["a", "b"])("rejects the code %s", (code) => {});
    \ttest.each`\n\tcode\n\t${"a"}\n\t`("checks $code", () => {});
    });
    """

    @Test func theTestIsItsCallFromTitleToTheClosingParenthesis() throws {
        let test = try #require(KnowledgeTestSource.test(titled: ["cancel", "refunds a paid order"], in: Self.source))
        #expect(test.text.hasPrefix("(\"refunds a paid order\""))
        #expect(test.text.hasSuffix("toBeVisible();\n\t})"))
        #expect(test.text.contains("403") && !test.text.contains("lastName") && !test.text.contains("firstName"))
        #expect(!test.parametrized)
    }

    @Test func aTitleOutsideACallOrMissingIsNoTest() {
        #expect(KnowledgeTestSource.test(titled: ["no such test"], in: Self.source) == nil)
        #expect(KnowledgeTestSource.test(titled: ["Zpět na úvod"], in: "const name = \"Zpět na úvod\";") == nil)
        #expect(KnowledgeTestSource.test(titled: [], in: Self.source) == nil)
    }

    @Test func eachTablesAndPlaceholdersAreParametrized() throws {
        #expect(try #require(KnowledgeTestSource.test(titled: ["rejects the code %s"], in: Self.source)).parametrized)
        #expect(try #require(KnowledgeTestSource.test(titled: ["checks $code"], in: Self.source)).parametrized)
        #expect(try #require(KnowledgeTestSource.test(titled: ["keeps a shipped order"], in: Self.source)).text.contains("Novák"))
    }

    @Test func termsAreQuotedTextDottedNamesStatusesAndConstants() {
        let terms = KnowledgeTestSource.terms(in: [
            "Given the backend answers with HTTP 5xx, 403 or a network error and X-COL-SERVICE-FLAG SIMULATED",
            "Then the errors are at customer.firstName, customer.lastName, e.g. the form.",
            "And \"Zpět na úvod\" returns to „Požadavky“, `PARAM_FIELD_FE` names it, partner kind Z001",
            "And customer.firstName is still there in 14 days, on 1 January 1900",
        ])
        #expect(terms == ["403", "X-COL-SERVICE-FLAG", "customer.firstName", "customer.lastName", "Zpět na úvod", "Požadavky", "PARAM_FIELD_FE", "Z001"])
    }
}
