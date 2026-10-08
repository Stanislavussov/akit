import Foundation
import Testing
@testable import AKitFoundation

struct JSONValueTests {
    func parse(_ text: String) throws -> JSONValue { try JSONValue.parse(Data(text.utf8)) }

    @Test func readsTypesAndPrintsLikeJSONStringify() throws {
        let tree = try parse(#"{"b": [1, 2.5, 1.0, true, null, "a\"\n/é"], "a": {}, "c": {"x": false}, "n": 12345678901234567}"#)
        #expect(tree.value(at: ["b"]) == .array([.number("1"), .number("2.5"), .number("1"), .bool(true), .null, .string("a\"\n/é")]))
        #expect(tree.value(at: ["n"]) == .number("12345678901234567"))
        #expect(tree.pretty == """
            {
              "a": {},
              "b": [
                1,
                2.5,
                1,
                true,
                null,
                "a\\"\\n/é"
              ],
              "c": {
                "x": false
              },
              "n": 12345678901234567
            }

            """)
        #expect(try parse(tree.pretty) == tree)
        #expect(tree.compact == #"{"a":{},"b":[1,2.5,1,true,null,"a\"\n/é"],"c":{"x":false},"n":12345678901234567}"#)
        #expect(throws: JSONValue.ParseError.self) { try parse("{ nope") }
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
    }
}
