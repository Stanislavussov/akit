import Foundation
import Testing
import AKitSessions
@testable import AKitLab

struct ReviewDigestTests {
    func item(_ id: Int, _ kind: TranscriptItem.Kind, _ text: String) -> TranscriptItem {
        TranscriptItem(id: id, kind: kind, text: text, timestamp: nil)
    }

    @Test func shortSessionIsKeptWholeWithoutThinking() {
        let transcript = SessionTranscript(items: [
            item(0, .user, "Fix it"), item(1, .thinking, "hmm"), item(2, .toolCall(name: "Bash"), "swift test"),
            item(3, .toolResult(name: "Bash", isError: true), "boom"), item(4, .assistant, "Done"),
        ])
        #expect(ReviewDigest.text(transcript) == """
            [#0 user] Fix it
            [#2 call Bash] swift test
            [#3 error Bash] boom
            [#4 assistant] Done
            """)
    }

    @Test func toolOutputKeepsItsEnd() {
        let text = String(repeating: "a", count: 500) + "FAILED"
        let cut = ReviewDigest.cut(text, to: 100, keepEnd: true)
        #expect(cut.hasPrefix(String(repeating: "a", count: 50)) && cut.hasSuffix("FAILED") && cut.contains("[…406 chars…]"))
    }

    @Test func longSessionFitsTheBudget() {
        let items = (0..<400).map { item($0, $0 % 2 == 0 ? .user : .toolResult(name: "Read", isError: false), String(repeating: "x", count: 3000)) }
        let digest = ReviewDigest.text(SessionTranscript(items: items), budget: 50_000)
        #expect(digest.count <= 50_100)
        #expect(digest.hasPrefix("[#0 user]") && digest.contains("items in the middle left out") && digest.contains("[#398 user]"))
        #expect(!digest.contains("result Read"))
    }
}
