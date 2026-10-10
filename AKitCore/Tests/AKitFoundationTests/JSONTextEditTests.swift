import Foundation
import Testing
@testable import AKitFoundation

/// One member changes; every other byte of the file stays.
struct JSONTextEditTests {
    let settings = """
        {
            "model": "opus",
            "env": {"TOKEN": "secret"},
            "skillOverrides": {
                "tdd": "off",
                "review": "name-only"
            },
            "z": [1, 2]
        }

        """

    @Test func replacesAValueInPlace() throws {
        let edited = try JSONTextEdit.setting(.string("on"), at: ["skillOverrides", "tdd"], in: settings)
        #expect(edited == settings.replacingOccurrences(of: #""tdd": "off""#, with: #""tdd": "on""#))
    }

    @Test func addsAMemberWithTheSiblingsIndentation() throws {
        let edited = try JSONTextEdit.setting(.string("off"), at: ["skillOverrides", "deploy"], in: settings)
        #expect(edited == settings.replacingOccurrences(of: #""review": "name-only""#,
                                                        with: "\"review\": \"name-only\",\n        \"deploy\": \"off\""))
    }

    @Test func makesMissingObjectsAtTheEnd() throws {
        let text = "{\n  \"model\": \"opus\"\n}\n"
        let edited = try JSONTextEdit.setting(.string("off"), at: ["skillOverrides", "tdd"], in: text)
        #expect(edited == "{\n  \"model\": \"opus\",\n  \"skillOverrides\": {\n    \"tdd\": \"off\"\n  }\n}\n")
        #expect(try JSONValue.parse(Data(edited.utf8)).value(at: ["skillOverrides", "tdd"]) == .string("off"))
    }

    @Test func fillsAnEmptyObject() throws {
        #expect(try JSONTextEdit.setting(.string("off"), at: ["a"], in: "{}") == "{\n  \"a\": \"off\"\n}")
        let nested = "{\n  \"skillOverrides\": {}\n}\n"
        #expect(try JSONTextEdit.setting(.string("off"), at: ["skillOverrides", "x"], in: nested)
                == "{\n  \"skillOverrides\": {\n    \"x\": \"off\"\n  }\n}\n")
    }

    @Test func keepsOneLineObjectsOnOneLine() throws {
        let edited = try JSONTextEdit.setting(.string("off"), at: ["b"], in: #"{"a": 1}"#)
        #expect(edited == #"{"a": 1, "b": "off"}"#)
    }

    @Test func replacesAOneLineListOnOneLine() throws {
        let text = "{\n  \"skills\": [\"!old\"],\n  \"x\": 1\n}\n"
        let edited = try JSONTextEdit.setting(.array([.string("!old"), .string("-skills/a/SKILL.md")]), at: ["skills"], in: text)
        #expect(edited == "{\n  \"skills\": [\"!old\", \"-skills/a/SKILL.md\"],\n  \"x\": 1\n}\n")
    }

    @Test func removesFirstMiddleAndLastMembers() throws {
        let three = "{\n  \"a\": 1,\n  \"b\": 2,\n  \"c\": 3\n}\n"
        #expect(try JSONTextEdit.removing(at: ["a"], in: three) == "{\n  \"b\": 2,\n  \"c\": 3\n}\n")
        #expect(try JSONTextEdit.removing(at: ["b"], in: three) == "{\n  \"a\": 1,\n  \"c\": 3\n}\n")
        #expect(try JSONTextEdit.removing(at: ["c"], in: three) == "{\n  \"a\": 1,\n  \"b\": 2\n}\n")
        #expect(try JSONTextEdit.removing(at: ["a"], in: "{\n  \"a\": 1\n}\n") == "{}\n")
        #expect(try JSONTextEdit.removing(at: ["missing"], in: three) == three)
        #expect(try JSONTextEdit.removing(at: ["skillOverrides", "review"], in: settings)
                == settings.replacingOccurrences(of: "\"tdd\": \"off\",\n        \"review\": \"name-only\"", with: "\"tdd\": \"off\""))
    }

    @Test func stringsWithBracesAndEscapesDontConfuseTheScanner() throws {
        let text = #"{"a": "}{\"[", "b": {"c": "]"}, "d": 1}"#
        let edited = try JSONTextEdit.setting(.number("2"), at: ["d"], in: text)
        #expect(edited == #"{"a": "}{\"[", "b": {"c": "]"}, "d": 2}"#)
        #expect(try JSONTextEdit.setting(.string("x"), at: ["b", "e"], in: text) == #"{"a": "}{\"[", "b": {"c": "]", "e": "x"}, "d": 1}"#)
    }

    @Test func keysAreComparedByUnicodeScalars() throws {
        let decomposed = "{\"cafe\u{301}\": 1}"
        // The precomposed key is a different key to a harness: nothing to remove.
        #expect(try JSONTextEdit.removing(at: ["caf\u{e9}"], in: decomposed) == decomposed)
        #expect(try JSONTextEdit.removing(at: ["cafe\u{301}"], in: decomposed) == "{}")
    }

    @Test func crlfFilesKeepCrlf() throws {
        let text = "{\r\n  \"a\": 1\r\n}\r\n"
        #expect(try JSONTextEdit.setting(.array([.string("x")]), at: ["b"], in: text)
                == "{\r\n  \"a\": 1,\r\n  \"b\": [\r\n    \"x\"\r\n  ]\r\n}\r\n")
        #expect(try JSONTextEdit.setting(.string("x"), at: ["o", "k"], in: "{\r\n  \"o\": {}\r\n}")
                == "{\r\n  \"o\": {\r\n    \"k\": \"x\"\r\n  }\r\n}")
    }

    @Test func refusesBadFilesAndNonObjectsOnThePath() {
        #expect(throws: JSONTextEdit.Failure.self) { try JSONTextEdit.setting(.null, at: ["a"], in: "{\"a\": 1,}") }
        #expect(throws: JSONTextEdit.Failure.self) { try JSONTextEdit.setting(.null, at: ["a"], in: "[1]") }
        #expect(throws: JSONTextEdit.Failure.self) { try JSONTextEdit.setting(.null, at: ["z", "x"], in: settings) }
    }
}
