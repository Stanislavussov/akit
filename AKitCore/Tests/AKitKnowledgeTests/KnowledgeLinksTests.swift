import Foundation
import Testing
@testable import AKitKnowledge

/// The link table of P1 (plan "Link rules"), row by row, plus case, spaces, `.md`, NFD and from-paths.
struct KnowledgeLinksTests {
    let links = KnowledgeLinks(
        notes: ["payments/orders-api", "payments/billing", "payments/flows/order-to-billing", "logistics/warehouse",
                "logistics/orders-api", "logistics/shipping", "logistics/flows/pick-and-ship", "payments/Order Flow",
                "payments/café"],
        maps: ["payments/maps/overview", "logistics/maps/routes", "logistics/maps/overview"])

    struct Row: Sendable, CustomTestStringConvertible {
        let link: String, from: String, expected: KnowledgeLinks.Resolution
        var testDescription: String { "\(link) from \(from)" }
    }

    static let rows: [Row] = [
        // Shortest unique path.
        Row(link: "[[billing]]", from: "areas/logistics/shipping.md", expected: .note("payments/billing")),
        Row(link: "[[order-to-billing]]", from: "areas/payments/billing.md", expected: .note("payments/flows/order-to-billing")),
        // Two matches: the linking file's area, else ambiguous.
        Row(link: "[[orders-api]]", from: "areas/payments/billing.md", expected: .note("payments/orders-api")),
        Row(link: "[[orders-api]]", from: "areas/logistics/flows/pick-and-ship.md", expected: .note("logistics/orders-api")),
        Row(link: "[[orders-api]]", from: "areas/other/x.md", expected: .ambiguous(["logistics/orders-api", "payments/orders-api"])),
        // A path suffix.
        Row(link: "[[payments/orders-api]]", from: "areas/logistics/shipping.md", expected: .note("payments/orders-api")),
        Row(link: "[[flows/pick-and-ship]]", from: "areas/payments/billing.md", expected: .note("logistics/flows/pick-and-ship")),
        Row(link: "[[areas/payments/billing]]", from: "areas/logistics/shipping.md", expected: .note("payments/billing")),
        // Maps: the current area's, or another area's by path.
        Row(link: "[[maps/overview]]", from: "areas/payments/maps/overview.excalidraw", expected: .map("payments/maps/overview")),
        Row(link: "[[maps/overview]]", from: "areas/logistics/shipping.md", expected: .map("logistics/maps/overview")),
        Row(link: "[[logistics/maps/routes]]", from: "areas/payments/maps/overview.excalidraw", expected: .map("logistics/maps/routes")),
        Row(link: "[[maps/routes]]", from: "areas/payments/billing.md", expected: .map("logistics/maps/routes")),
        Row(link: "[[maps/overview]]", from: "areas/other/x.md", expected: .ambiguous(["logistics/maps/overview", "payments/maps/overview"])),
        Row(link: "[[routes.excalidraw]]", from: "areas/payments/billing.md", expected: .map("logistics/maps/routes")),
        // Heading and alias: resolved by the note part.
        Row(link: "[[billing#Invoices]]", from: "areas/payments/x.md", expected: .note("payments/billing")),
        Row(link: "[[billing|the billing]]", from: "areas/payments/x.md", expected: .note("payments/billing")),
        Row(link: #"[[billing\|the billing]]"#, from: "areas/payments/x.md", expected: .note("payments/billing")),
        Row(link: "[[billing#Invoices|see]]", from: "areas/payments/x.md", expected: .note("payments/billing")),
        // akit: links, exactly that id.
        Row(link: "akit:note/payments/orders-api", from: "areas/logistics/shipping.md", expected: .note("payments/orders-api")),
        Row(link: "akit:note/orders-api", from: "areas/payments/billing.md", expected: .missing),
        Row(link: "akit:map/logistics/maps/routes", from: "areas/payments/billing.md", expected: .map("logistics/maps/routes")),
        Row(link: "akit:note/payments/Order%20Flow", from: "areas/payments/billing.md", expected: .note("payments/Order Flow")),
        // Case, spaces, .md, a bare name without brackets.
        Row(link: "[[Billing]]", from: "areas/payments/x.md", expected: .note("payments/billing")),
        Row(link: "[[ billing ]]", from: "areas/payments/x.md", expected: .note("payments/billing")),
        Row(link: "[[Order Flow]]", from: "areas/payments/x.md", expected: .note("payments/Order Flow")),
        Row(link: "[[billing.md]]", from: "areas/payments/x.md", expected: .note("payments/billing")),
        Row(link: "billing", from: "areas/payments/x.md", expected: .note("payments/billing")),
        // NFD input finds the NFC name, and the from-path may be an id.
        Row(link: "[[cafe\u{301}]]", from: "areas/payments/x.md", expected: .note("payments/café")),
        Row(link: "[[orders-api]]", from: "payments/billing", expected: .note("payments/orders-api")),
        // Nothing there.
        Row(link: "[[nothing]]", from: "areas/payments/x.md", expected: .missing),
        Row(link: "[[]]", from: "areas/payments/x.md", expected: .missing),
        Row(link: "[[maps/nothing]]", from: "areas/payments/x.md", expected: .missing),
        Row(link: "[[api]]", from: "areas/payments/x.md", expected: .missing),
    ]

    @Test(arguments: rows) func resolves(_ row: Row) {
        #expect(links.resolve(row.link, from: row.from) == row.expected)
    }

    @Test func idsGivenInNFDAreStoredNFC() {
        let nfd = KnowledgeLinks(notes: ["payments/cafe\u{301}"], maps: [])
        #expect(nfd.notes == ["payments/café"])
        #expect(nfd.resolve("akit:note/payments/café", from: "") == .note("payments/café"))
    }

    @Test func twoCasesOfOneNameTakeTheExactOne() {
        let both = KnowledgeLinks(notes: ["a/orders-api", "a/Orders-API"], maps: [])
        #expect(both.resolve("[[Orders-API]]", from: "areas/a/x.md") == .note("a/Orders-API"))
        #expect(both.resolve("[[ORDERS-API]]", from: "areas/a/x.md") == .ambiguous(["a/Orders-API", "a/orders-api"]))
    }
}
