@testable import AKitReview
import Foundation
import Testing

/// What a review missed in the knowledge base: searches with no answer (unless another search
/// with the same words answered), gaps reported with `system: knowledge`, notes it used without
/// a description. Made-up run folder and base.
struct ReviewKnowledgeGapsTests {
    static func call(_ tool: String, _ input: String, _ answer: String, pass: String = "role-contracts", n: Int) -> String {
        let object: [String: Any] = ["pass": pass, "tool": tool, "input": input, "text": [answer], "isError": false, "server": "akit-kb"]
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    @Test func searchesReportedGapsAndNotesWithoutDescription() throws {
        let home = TempHome()
        let run = "run"
        home.write("\(run)/mcp/calls/role-contracts-1-0001.json", Self.call("akit_kb_search", #"{"query":"refund  webhook"}"#,
                                                                            #"{"results":[],"stale":false,"tokens":0}"#, n: 1))
        home.write("\(run)/mcp/calls/role-tests-2-0002.json", Self.call("akit_kb_search", #"{"query":"Refund webhook"}"#,
                                                                        #"{"results":[],"stale":false,"tokens":0}"#, pass: "role-tests", n: 2))
        home.write("\(run)/mcp/calls/role-tests-3-0003.json", Self.call("akit_kb_search", #"{"query":"order events","area":"payments"}"#,
                                                                        #"{"results":[{"note":"payments/order-events","heading":null,"score":-3,"snippet":"x","neighbors":[]}],"stale":false,"tokens":5}"#,
                                                                        pass: "role-tests", n: 3))
        home.write("\(run)/mcp/calls/role-tests-4-0004.json", Self.call("akit_kb_search", #"{"query":"ledger"}"#,
                                                                        #"{"results":[],"stale":false,"tokens":0}"#, pass: "role-tests", n: 4))
        home.write("\(run)/mcp/calls/role-tests-5-0005.json", Self.call("akit_kb_search", #"{"query":"Ledger"}"#,
                                                                        #"{"results":[{"note":"payments/billing","heading":null,"score":-2,"snippet":"y","neighbors":[]}],"stale":false,"tokens":5}"#,
                                                                        pass: "role-tests", n: 5))
        home.write("\(run)/mcp/calls/role-tests-6-0006.json", Self.call("akit_kb_show", #"{"note":"billing"}"#,
                                                                        #"{"note":"payments/billing","title":"billing","sections":[]}"#, pass: "role-tests", n: 6))
        home.write("\(run)/gaps.json", #"""
        [{"id":"g1","system":"knowledge","needed":"Who consumes order.created","why":"A field is removed","howToGet":"payments","effect":"","reportedBy":"role-contracts"},
         {"id":"g2","system":"gitlab","needed":"The pipeline","why":"x","howToGet":"","effect":"","reportedBy":"gather"},
         {"id":"g3","system":"knowledge","needed":"The card is cut","why":"budget","howToGet":"","effect":"","reportedBy":"gather"}]
        """#)
        home.write("\(run)/context/knowledge-card.md", "# Knowledge card\n\n### Systems (touched first)\n\n- payments/orders-api (orders-api), touched: src/a.ts: Takes orders.\n\n### Relations\n\n- payments/orders-api -events-> payments/billing\n")
        home.write("kb/areas/payments/orders-api.md", "---\ndescription: Takes orders.\n---\n# orders-api\n")
        home.write("kb/areas/payments/billing.md", "---\nkind: service\n---\n# billing\n\nBills orders.\n")
        home.write("kb/areas/payments/order-events.md", "# order-events\n")

        let gaps = ReviewKnowledgeGaps.read(folder: home.url.appending(path: run), base: home.url.appending(path: "kb"))
        #expect(gaps.map { "\($0.id) \($0.kind.rawValue) \($0.subject) [\($0.passes.joined(separator: ","))]" } == [
            "k1 search refund  webhook [role-contracts,role-tests]",
            "k2 reported Who consumes order.created [role-contracts]",
            "k3 no-description payments/order-events [role-tests]",
            "k4 no-description payments/billing [role-tests]",
        ], "a search another one answered (ledger) and gather's own gaps are not missing knowledge")
        #expect(gaps[1].why == "A field is removed" && gaps[1].area == "payments")
        #expect(ReviewKnowledgeGaps.proposeCommand(gaps[3], run: "r1", base: "/kb")
            == "akit kb propose --note 'payments/billing' --set 'description=<one line>' --reason 'AKit review r1 used this note; it had no description' --base '/kb'")
        #expect(ReviewKnowledgeGaps.draftBody(gaps[1]).hasPrefix("# Who consumes order.created\n\nWhy a review needed it: A field is removed"))
        #expect(ReviewKnowledgeGaps.read(folder: home.url.appending(path: run), base: nil).allSatisfy { $0.kind != .noDescription })
    }
}
