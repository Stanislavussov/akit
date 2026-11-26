import Foundation

/// A linked test in its source file (K45): the text of its call, found by the title as a string
/// literal, and the concrete terms of a scenario's steps that the call should mention. No parser
/// of the test's language: the call is read from its `(` to the matching `)`, past strings and
/// comments, which fits `it("…", () => {…})` and `test("…", async () => {…})` in TS and JS.
public enum KnowledgeTestSource {
    public struct Test: Sendable, Equatable {
        /// The call, from the `(` before the title to its `)`; the rest of the file when it doesn't close.
        public let text: String
        /// `it.each(…)("…")`, `test.each`…``: one title for many cases.
        public let parametrized: Bool
    }

    /// The test titled with the link's last name; nil when no call has it as a string literal.
    public static func test(titled names: [String], in source: String) -> Test? {
        guard let title = names.last, !title.isEmpty else { return nil }
        let bytes = Array(source.utf8)
        for quote in ["\"", "'", "`"] {
            let needle = Array((quote + title + quote).utf8)
            var from = 0
            while let at = find(needle, in: bytes, from: from) {
                from = at + 1
                var open = at - 1
                while open >= 0, bytes[open] == UInt8(ascii: " ") || bytes[open] == UInt8(ascii: "\t") || bytes[open] == UInt8(ascii: "\n") { open -= 1 }
                guard open >= 0, bytes[open] == UInt8(ascii: "(") else { continue }
                let before = open > 0 ? bytes[open - 1] : 0
                let parametrized = [UInt8(ascii: ")"), UInt8(ascii: "`"), UInt8(ascii: "]")].contains(before)
                    || title.contains("%") || title.contains(/\$[A-Za-z]/)
                let close = closing(bytes, open: open) ?? bytes.count - 1
                return Test(text: String(decoding: bytes[open...close], as: UTF8.self), parametrized: parametrized)
            }
        }
        return nil
    }

    /// The step terms worth finding in a test, each once, in order: quoted text (`"Zpět na úvod"`,
    /// `“…”`, `„…“`, `«…»`, `` `…` ``), dotted names (`customer.firstName`), HTTP statuses (`403`)
    /// and constants with a digit, `_` or `-` (`PARAM_FIELD_FE`, `Z001`). Plain words are no term:
    /// a test says them in its own words.
    public static func terms(in lines: [String]) -> [String] {
        var terms: [String] = []
        func add(_ term: Substring) {
            let term = term.trimmingCharacters(in: .whitespaces)
            if !term.isEmpty, !terms.contains(term) { terms.append(term) }
        }
        for line in lines {
            for match in line.matches(of: /"([^"]+)"|“([^”]+)”|„([^“]+)“|«([^»]+)»|`([^`]+)`/) {
                if let text = match.1 ?? match.2 ?? match.3 ?? match.4 ?? match.5 { add(text) }
            }
            let unquoted = line.replacing(/"[^"]*"|“[^”]*”|„[^“]*“|«[^»]*»|`[^`]*`/, with: " ")
            for match in unquoted.matches(of: /\b[a-z][A-Za-z0-9_]+(?:\.[A-Za-z_][A-Za-z0-9_]+)+\b/) { add(match.output) }
            for match in unquoted.matches(of: /\b[1-5][0-9]{2}\b/) { add(match.output) }
            for match in unquoted.matches(of: /\b[A-Z][A-Z0-9]*(?:[_-][A-Z0-9]+)*\b/) where match.output.count >= 3
                && match.output.contains(where: { $0.isNumber || $0 == "_" || $0 == "-" }) {
                add(match.output)
            }
        }
        return terms
    }

    static func find(_ needle: [UInt8], in bytes: [UInt8], from: Int) -> Int? {
        guard !needle.isEmpty, bytes.count >= needle.count, from <= bytes.count - needle.count else { return nil }
        for start in from...(bytes.count - needle.count) where bytes[start] == needle[0] {
            if bytes[start..<(start + needle.count)].elementsEqual(needle) { return start }
        }
        return nil
    }

    /// The `)` that closes the `(` at `open`, past strings, template literals and comments.
    static func closing(_ bytes: [UInt8], open: Int) -> Int? {
        var depth = 0
        var index = open
        while index < bytes.count {
            let byte = bytes[index]
            let next = index + 1 < bytes.count ? bytes[index + 1] : 0
            switch byte {
            case UInt8(ascii: "\""), UInt8(ascii: "'"), UInt8(ascii: "`"):
                index += 1
                while index < bytes.count, bytes[index] != byte {
                    if bytes[index] == UInt8(ascii: "\\") { index += 1 }
                    index += 1
                }
            case UInt8(ascii: "/") where next == UInt8(ascii: "/"):
                while index < bytes.count, bytes[index] != UInt8(ascii: "\n") { index += 1 }
            case UInt8(ascii: "/") where next == UInt8(ascii: "*"):
                index += 2
                while index + 1 < bytes.count, !(bytes[index] == UInt8(ascii: "*") && bytes[index + 1] == UInt8(ascii: "/")) { index += 1 }
                index += 1
            case UInt8(ascii: "("):
                depth += 1
            case UInt8(ascii: ")"):
                depth -= 1
                if depth == 0 { return index }
            default:
                break
            }
            index += 1
        }
        return nil
    }
}
