import Foundation
import Testing
@testable import AKitFoundation

struct JSONValueTests {
    func parse(_ text: String) throws -> JSONValue { try JSONValue.parse(Data(text.utf8)) }

    @Test func readsTypesAndPrintsLikeJSONStringify() throws {
        let tree = try parse(#"{"b": [1, 2.5, 1.0, true, null, "a\"\n/é\u00e9\ud83d\ude00\/"], "a": {}, "c": {"x": false}, "n": 18446744073709551616, "f": -3.14159265358979323846e-2}"#)
        #expect(tree.value(at: ["b"]) == .array([.number("1"), .number("2.5"), .number("1.0"), .bool(true), .null, .string("a\"\n/éé😀/")]))
        // Numbers keep their text: a rewrite never rounds the project's values.
        #expect(tree.value(at: ["n"]) == .number("18446744073709551616"))
        #expect(tree.value(at: ["f"]) == .number("-3.14159265358979323846e-2"))
        #expect(tree.pretty == """
            {
              "a": {},
              "b": [
                1,
                2.5,
                1.0,
                true,
                null,
                "a\\"\\n/éé😀/"
              ],
              "c": {
                "x": false
              },
              "f": -3.14159265358979323846e-2,
              "n": 18446744073709551616
            }

            """)
        #expect(try parse(tree.pretty) == tree)
        #expect(tree.compact == #"{"a":{},"b":[1,2.5,1.0,true,null,"a\"\n/éé😀/"],"c":{"x":false},"f":-3.14159265358979323846e-2,"n":18446744073709551616}"#)
        #expect(try parse("\u{FEFF} [\"x\"] ") == .array([.string("x")]))
        let bad = ["{ nope", #"{"a": 1,}"#, "[01]", #"{"a": 1} x"#, #""\ud800""#, #"{"dup": 1, "dup": 2}"#, "// c\n{}",
                   String(repeating: "[", count: 150)]
        for text in bad {
            #expect(throws: JSONValue.ParseError.self, "\(text.prefix(20))") { try parse(text) }
        }
    }

    @Test func keyPathsSetRemoveAndPointers() throws {
        var tree = try parse(#"{"a": {"b": {"c": 1}, "d": 2}, "e": {}}"#)
        #expect(tree.leaves.map(\.path) == [["a", "b", "c"], ["a", "d"]])
        tree.remove(at: ["a", "b", "c"])
        #expect(tree == .object(["a": .object(["d": .number("2")]), "e": .object([:])]))
        tree.remove(at: ["a", "d"])
        #expect(tree == .object(["e": .object([:])]))
        tree.set(.string("x"), at: ["e", "f", "g"])
        #expect(tree.value(at: ["e", "f", "g"]) == .string("x"))
        #expect(tree.value(at: ["e", "f", "g", "h"]) == nil)

        let path = ["mcpServers", "a/b", "c~d"]
        #expect(JSONValue.pointer(path) == "/mcpServers/a~1b/c~0d")
        #expect(JSONValue.path(pointer: JSONValue.pointer(path)) == path)
    }

    @Test func secretsUnderEnvAndHeaders() throws {
        #expect(JSONValue.isVariableReference("${GITHUB_TOKEN}"))
        #expect(!JSONValue.isVariableReference("Bearer ${TOKEN}"))
        #expect(!JSONValue.isVariableReference("${}"))
        #expect(!JSONValue.isVariableReference("${TOKEN:-default}"))
        let tree = try parse(#"{"s": {"env": {"A": "${A}", "B": "secret", "C": 3}, "headers": {"H": "x"}, "args": ["secret"]}, "env": []}"#)
        #expect(tree.secretLeaves == [["s", "env", "B"], ["s", "env", "C"], ["s", "headers", "H"]])
        let masked = tree.masked
        #expect(masked.value(at: ["s", "env", "A"]) == .string("${A}"))
        #expect(masked.value(at: ["s", "env", "B"]) == .string("••••"))
        #expect(masked.value(at: ["s", "env", "C"]) == .string("••••"))
        #expect(masked.value(at: ["s", "args"]) == .array([.string("secret")]))
        // Inside a list of objects too.
        let listed = try parse(#"{"servers": [{"env": {"T": "tok"}, "headers": {"R": "${R}"}, "name": "a"}]}"#).masked
        #expect(listed.value(at: ["servers"]) == .array([.object([
            "env": .object(["T": .string("••••")]), "headers": .object(["R": .string("${R}")]), "name": .string("a")])]))
    }
}
