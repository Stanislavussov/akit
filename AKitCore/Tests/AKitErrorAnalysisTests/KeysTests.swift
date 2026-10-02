import Foundation
import Testing
import AKitFoundation
import AKitModel
import AKitSessions
@testable import AKitErrorAnalysis

struct SessionKeyTests {
    func summary(_ harness: HarnessID, _ file: URL) -> SessionSummary {
        SessionSummary(harness: harness, file: file, title: "t", project: nil, started: nil, modified: .now, size: 0)
    }

    @Test func claudeKeyIsTheFileStem() {
        let file = URL(filePath: "/tmp/home/.claude/projects/-x/0b6c1d2e-aaaa-bbbb-cccc-1234567890ab.jsonl")
        let key = SessionKey.of(summary(.claudeCode, file))
        #expect(key?.description == "claude:0b6c1d2e-aaaa-bbbb-cccc-1234567890ab")
        let subagent = URL(filePath: "/tmp/home/.claude/projects/-x/abc/subagents/agent-1.jsonl")
        // Reviewed on its own, a subagent run keeps a key apart from its parent's.
        #expect(SessionKey.of(summary(.claudeCode, subagent))?.description == "claude:abc/agent-1")
        #expect(SessionKey.of(summary(.codex, file)) == nil)
    }

    @Test func piKeyIsTheHeaderID() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "akit-key-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "2026-10-01T10-00-00-000Z_file-uuid.jsonl")
        try Data(#"""
            {"type":"session","version":3,"id":"header-uuid","timestamp":"2026-10-01T10:00:00.000Z","cwd":"/x"}
            {"type":"message","id":"a1","message":{"role":"user","content":"hi"}}

            """#.utf8).write(to: file)
        #expect(SessionKey.of(summary(.pi, file))?.description == "pi:header-uuid")
        let headless = folder.appending(path: "old.jsonl")
        try Data("{\"type\":\"message\"}\n".utf8).write(to: headless)
        #expect(SessionKey.of(summary(.pi, headless))?.description == "pi:old")
    }

    @Test func parsingAndCoding() throws {
        let key = try #require(SessionKey(parsing: "pi:a:b"))
        #expect(key.harness == "pi" && key.nativeID == "a:b" && key.description == "pi:a:b")
        #expect(SessionKey(parsing: "nocolon") == nil && SessionKey(parsing: ":x") == nil && SessionKey(parsing: "claude:") == nil)
        let data = try JSONEncoder().encode([key])
        #expect(String(decoding: data, as: UTF8.self) == #"["pi:a:b"]"#)
        #expect(try JSONDecoder().decode([SessionKey].self, from: data) == [key])
    }
}

struct DoneKeyTests {
    let input = Data("transcript".utf8)
    let notes = StepConfig(step: "notes", harness: "claude", model: "opus", promptVersion: 1, scrubVersion: 2)
    let verifier = StepConfig(step: "verifier", harness: "claude", model: "sonnet", promptVersion: 1, scrubVersion: 2)

    @Test func sameInputAndConfigsGiveTheSameKey() {
        let key = DoneKey.make(input: input, configs: [notes, verifier])
        #expect(key == DoneKey.make(input: input, configs: [notes, verifier]))
        #expect(key.split(separator: ".").map(\.count) == [64, 64])
        #expect(key.hasPrefix(Checksum.sha256(input) + "."))
    }

    @Test func orderOfConfigsDoesNotMatter() {
        #expect(DoneKey.make(input: input, configs: [notes, verifier]) == DoneKey.make(input: input, configs: [verifier, notes]))
    }

    @Test func upstreamConfigChangesTheKey() {
        var otherNotes = notes
        otherNotes.model = "sonnet"
        #expect(DoneKey.make(input: input, configs: [notes, verifier]) != DoneKey.make(input: input, configs: [otherNotes, verifier]))
        var extra = verifier
        extra.extra = ["modes": "3"]
        #expect(DoneKey.make(input: input, configs: [notes, verifier]) != DoneKey.make(input: input, configs: [notes, extra]))
    }

    @Test func inputChangesTheKey() {
        #expect(DoneKey.make(input: input, configs: [notes]) != DoneKey.make(input: Data("other".utf8), configs: [notes]))
    }
}

struct QuoteMatcherTests {
    let transcript = """
        [#4 assistant] I’ll run the   tests now.
        The build "passed" on the
        first try, so I'm done.
        """

    @Test func matchesAfterNormalising() {
        #expect(QuoteMatcher.matches(quote: "I'll run the tests now.", in: transcript))
        #expect(QuoteMatcher.matches(quote: "“passed” on the first try", in: transcript))
        #expect(QuoteMatcher.matches(quote: "\"so I'm done\"", in: transcript))
        #expect(QuoteMatcher.matches(quote: "  The build\n\"passed\"  ", in: transcript))
    }

    @Test func isCaseSensitiveAndExact() {
        #expect(!QuoteMatcher.matches(quote: "i'll run the tests", in: transcript))
        #expect(!QuoteMatcher.matches(quote: "the tests failed", in: transcript))
    }

    @Test func elisionsMatchPartsInOrder() {
        #expect(QuoteMatcher.matches(quote: "I'll run … so I'm done", in: transcript))
        #expect(QuoteMatcher.matches(quote: "\"I'll run...first try\"", in: transcript))
        #expect(!QuoteMatcher.matches(quote: "so I'm done … I'll run", in: transcript))
    }

    @Test func emptyQuoteNeverMatches() {
        #expect(!QuoteMatcher.matches(quote: "", in: transcript))
        #expect(!QuoteMatcher.matches(quote: "  \"\" ", in: transcript))
        #expect(!QuoteMatcher.matches(quote: "…", in: transcript))
    }
}
