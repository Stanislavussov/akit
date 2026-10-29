import Foundation
import Testing
import AKitFoundation
import AKitInsights
import AKitSessions
@testable import AKitErrorAnalysis

/// The user's reactions: the checkpoints a review must explain.
struct UserReactionsTests {
    func item(_ id: Int, _ kind: TranscriptItem.Kind, _ text: String, outcome: ToolResultOutcome? = nil) -> TranscriptItem {
        TranscriptItem(id: id, kind: kind, text: text, timestamp: nil, outcome: outcome)
    }

    @Test func reactionsAreFoundInOrderAndTheTaskIsNotOne() {
        let items = [
            item(0, .user, "Fix the failing test in Foo."),
            item(1, .toolCall(name: "Bash"), "swift test"),
            item(2, .user, "[Request interrupted by user]"),
            item(3, .user, "No, run only FooTests."),
            item(4, .toolCall(name: "Bash"), "rm -rf build"),
            item(5, .toolResult(name: "Bash", isError: true), "The user doesn't want to proceed with this tool use. Don't delete build."),
            item(6, .assistant, "Done."),
            item(7, .user, "Now commit it."),
        ]
        let ratings = [RunRating(rating: "bad", comment: "It deleted things.", anchor: nil, timestamp: nil, afterItem: 6),
                       RunRating(rating: "good", comment: nil, anchor: nil, timestamp: nil, afterItem: nil)]
        let reactions = UserReactions.of(items, ratings: ratings)
        #expect(reactions.map(\.kind) == [.interrupt, .pushback, .rejected, .badRating, .followUp])
        #expect(reactions.map(\.id) == ["r1", "r2", "r3", "r4", "r5"])
        #expect(reactions.map(\.step) == [2, 3, 5, 6, 7])
        #expect(reactions[3].text == "It deleted things.")
        #expect(UserReactions.text(reactions).contains(#"- r4 · #6 · bad-rating · "It deleted things.""#))
        // A rating off the active branch has no place: it's left out.
        #expect(!reactions.contains { $0.kind == .goodRating })
    }

    @Test func aSessionThatStartsWithAnInterruptStillSkipsTheTask() {
        let reactions = UserReactions.of([item(0, .user, "[Request interrupted by user]"), item(1, .user, "Do X."),
                                          item(2, .user, "Thanks.")], ratings: [])
        #expect(reactions.map(\.step) == [2])
    }

    @Test func longTextIsCut() {
        let reactions = UserReactions.of([item(0, .user, "Task"), item(1, .user, String(repeating: "a", count: 1000))], ratings: [])
        #expect(reactions[0].text.count == UserReactions.textLimit + 1)
    }

    @Test func spoolRatingsJoinTheLogsOnes() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "akit-reactions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let env = HarnessEnvironment(homeDirectory: home, variables: ["HOME": home.path], executableSearchPaths: [])
        let file = home.appending(path: "session.jsonl")
        let stdin = try JSONSerialization.data(withJSONObject: ["session_id": "s1", "transcript_path": file.path, "text": "Wrong file."])
        try RateRun.run(arguments: ["--harness", "claude", "--rating", "bad"], stdin: stdin, env: env,
                        now: Date(timeIntervalSince1970: 1_000))
        let transcript = SessionTranscript(items: [
            TranscriptItem(id: 0, kind: .user, text: "Task", timestamp: Date(timeIntervalSince1970: 900)),
            TranscriptItem(id: 1, kind: .assistant, text: "Done", timestamp: Date(timeIntervalSince1970: 950)),
            TranscriptItem(id: 2, kind: .user, text: "Next", timestamp: Date(timeIntervalSince1970: 1_100)),
        ])
        let ratings = UserReactions.ratings(of: transcript, file: file, env: env)
        #expect(ratings.map(\.afterItem) == [1])
        #expect(ratings.first?.comment == "Wrong file.")
        #expect(UserReactions.of(transcript.items, ratings: ratings).map(\.kind) == [.badRating, .followUp])
    }
}
