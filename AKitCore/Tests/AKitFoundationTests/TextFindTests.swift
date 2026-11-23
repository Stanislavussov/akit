import Foundation
@testable import AKitFoundation
import Testing

struct TextFindTests {
    func found(_ query: String, _ text: String) -> [String] {
        TextFind.ranges(of: query, in: text).map { String(text[$0]) }
    }

    @Test func findsEveryPlaceIgnoringCaseAndAccents() {
        #expect(found("order", "Orders: an ORDER, re-ordered.") == ["Order", "ORDER", "order"])
        #expect(found("ёлка", "Елка и ёлка") == ["Елка", "ёлка"])
        #expect(found("café", "Cafe, CAFÉ") == ["Cafe", "CAFÉ"])
        #expect(found("aa", "aaaa") == ["aa", "aa"])
        #expect(found("two words", "two words, two  words") == ["two words"])
    }

    @Test func emptyOrBlankFindsNothing() {
        #expect(found("", "text").isEmpty)
        #expect(found("  ", "a  b").isEmpty)
        #expect(found("x", "").isEmpty)
    }

    @Test func anAttributedTextGivesTheSamePlaces() {
        var text = AttributedString("Retry the ")
        text.append(AttributedString("RETRY"))
        text.append(AttributedString(" queue: retry."))
        let ranges = TextFind.ranges(of: "retry", in: text)
        #expect(ranges.map { String(text[$0].characters) } == ["Retry", "RETRY", "retry"])
        #expect(TextFind.ranges(of: " ", in: text).isEmpty)
    }
}
