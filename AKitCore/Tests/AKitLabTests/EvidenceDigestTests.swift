import Foundation
import Testing
import AKitSessions
@testable import AKitLab

struct EvidenceDigestTests {
    func item(_ id: Int, _ kind: TranscriptItem.Kind, _ text: String) -> TranscriptItem {
        TranscriptItem(id: id, kind: kind, text: text, timestamp: nil)
    }

    func filler(_ count: Int, _ letter: Character = "x") -> String { String(repeating: letter, count: count) }

    /// A failing `swift test` run: exit code first, errors and the summary in the middle.
    var failingTestOutput: String {
        "Exit code 1\n" + filler(40_000, "a") + "\n"
            + "Sources/Foo.swift:12:5: error: cannot find 'bar' in scope\n"
            + "Sources/Foo.swift:12:5: error: cannot find 'bar' in scope\n" // printed twice, kept once
            + "✘ Test parsesHeader() failed after 0.002 seconds with 1 issue.\n"
            + "✘ Test readsBody() failed after 0.001 seconds with 2 issues.\n"
            + "warning: unused variable 'x'\n"
            + filler(60_000, "b")
    }

    @Test func sessionThatFitsIsUnchangedExceptThinking() {
        let transcript = SessionTranscript(items: [
            item(0, .user, "Fix it"), item(1, .thinking, "hmm"), item(2, .toolCall(name: "Bash"), "swift test"),
            item(3, .toolResult(name: "Bash", isError: true), "boom"), item(4, .assistant, "Done"),
        ])
        let digest = EvidenceDigest.text(transcript)
        #expect(digest.text == """
            [#0 user] Fix it
            [#2 call Bash] swift test
            [#3 error Bash] boom
            [#4 assistant] Done
            """)
        #expect(!digest.overBudget)
    }

    @Test func longUserTurnIsKeptVerbatim() {
        let prompt = (0..<1000).map { "Requirement \($0): keep this exact wording." }.joined(separator: "\n")
        #expect(prompt.count > 40_000)
        var items = [item(0, .user, prompt)]
        items += (1...60).map { item($0, .toolResult(name: "Read", isError: false), filler(5000)) }
        let digest = EvidenceDigest.text(SessionTranscript(items: items), budget: 80_000)
        #expect(digest.text.contains("[#0 user] " + prompt + "\n"))
        #expect(digest.text.count <= 80_000 && !digest.overBudget)
    }

    @Test func failingToolOutputKeepsExitCodeErrorsAndFailedTests() {
        let output = failingTestOutput
        #expect(output.count > 100_000)
        let items = [item(0, .user, "Run the tests"), item(1, .toolCall(name: "Bash"), #"{"command": "swift test"}"#),
                     item(2, .toolResult(name: "Bash", isError: true), output)]
        let digest = EvidenceDigest.text(SessionTranscript(items: items), budget: 4000)
        // The last item; tool output spans several lines.
        let line = digest.text.range(of: "[#2 error Bash]").map { String(digest.text[$0.lowerBound...]) } ?? ""
        #expect(line.hasPrefix("[#2 error Bash] Exit code 1"))
        #expect(line.contains("exit 1; 2 failed tests; errors: \"Sources/Foo.swift:12:5: error: cannot find 'bar' in scope\""))
        #expect(line.contains("\"warning: unused variable 'x'\""))
        #expect(line.components(separatedBy: "cannot find 'bar'").count == 2)
        #expect(line.hasSuffix("bbbb"))
        #expect(digest.text.count <= 4000)
    }

    @Test func stubReadsCommonRunners() {
        typealias Stub = EvidenceDigest.Stub
        #expect(Stub("Executed 12 tests, with 1 failure\nExecuted 40 tests, with 3 failures (0 unexpected)").failedTests == "3 failed tests")
        #expect(Stub("===== 2 failed, 10 passed in 0.5s =====").failedTests == "2 failed tests")
        #expect(Stub("Tests:       4 failed, 9 passed, 13 total").failedTests == "4 failed tests")
        #expect(Stub("test result: FAILED. 3 passed; 1 failed;\ntest result: FAILED. 0 passed; 2 failed;").failedTests == "3 failed tests")
        #expect(Stub("--- FAIL: TestA (0.00s)\n    --- FAIL: TestA/sub (0.00s)\nFAIL").failedTests == "2 failed tests")
        #expect(Stub("✘ Test run with 5 tests in 2 suites failed after 0.1 seconds with 1 issue.").failedTests == "1 test issue")
        #expect(Stub("✔ Test run with 5 tests passed after 0.1 seconds.").failedTests == nil)
        #expect(Stub("exit code: 2").exitCode == 2)
        #expect(Stub("Process exited with code 127").exitCode == 127)
        #expect(Stub("Command failed with exit code 1").exitCode == 1)
        #expect(Stub("exit status 1").exitCode == 1)
        #expect(Stub("all good").text.isEmpty)
        let noisy = Stub((0..<50).map { "error \($0): " + filler(300) }.joined(separator: "\n"))
        #expect(noisy.errors.count == 20 && noisy.errors.allSatisfy { $0.count <= 201 })
    }

    @Test func capScalesWithTheSession() {
        let items = (0..<200).map { item($0, $0 % 4 == 0 ? .user : .toolResult(name: "Read", isError: false), filler(4000)) }
        let transcript = SessionTranscript(items: items)
        let small = EvidenceDigest.text(transcript, budget: 300_000)
        let large = EvidenceDigest.text(transcript, budget: 600_000)
        #expect(small.cap > EvidenceDigest.floorCap && small.cap < large.cap)
        #expect(small.text.count <= 300_000 && large.text.count <= 600_000)
        #expect(!small.text.contains("items left out"))
        // The cap is the largest that fits: one character more would not.
        let more = EvidenceDigest.text(transcript, budget: small.text.count + 1)
        #expect(more.cap == small.cap)
    }

    @Test func belowTheFloorTheMiddleGoesButUserTurnsAndFailedStubsStay() {
        var items: [TranscriptItem] = []
        for id in 0..<600 {
            let kind: TranscriptItem.Kind = switch id % 6 {
            case 0: .user
            case 3: .toolResult(name: "Bash", isError: true)
            default: .toolResult(name: "Read", isError: false)
            }
            let text = id % 6 == 3 ? "Exit code \(id)\nerror: broke at \(id)\n" + filler(3000) : filler(3000)
            items.append(item(id, kind, text))
        }
        // 100 user turns take ~301K; the other 500 items at the floor need ~65K more.
        let digest = EvidenceDigest.text(SessionTranscript(items: items), budget: 340_000)
        #expect(digest.cap == EvidenceDigest.floorCap)
        #expect(digest.text.contains("items left out"))
        for id in stride(from: 0, to: 600, by: 6) {
            #expect(digest.text.contains("[#\(id) user] " + filler(3000)))
            #expect(digest.text.contains("{exit \(id + 3); errors: \"error: broke at \(id + 3)\"}"))
        }
        #expect(digest.text.hasPrefix("[#0 user]"))
        #expect(digest.text.hasSuffix(String(filler(40))) && digest.text.contains("[#599 result Read]"))
        #expect(!digest.text.contains("[#301 result Read]"))
        #expect(digest.text.count <= 340_000 && !digest.overBudget)
    }

    @Test func userTurnsOverTheBudgetAreStillKept() {
        let items = (0..<40).map { item($0, $0 % 2 == 0 ? .user : .toolResult(name: "Read", isError: false), filler(3000)) }
        let digest = EvidenceDigest.text(SessionTranscript(items: items), budget: 30_000)
        #expect(digest.overBudget)
        #expect(digest.text.components(separatedBy: " user] " + filler(3000)).count == 21)
        #expect(!digest.text.contains("result Read"))
    }

    @Test func middleDropStaysInBudgetWhenTheKeptPartsFit() {
        let items = (0..<1000).map { item($0, $0 == 0 ? .user : .toolResult(name: "Read", isError: false), filler(2000)) }
        let digest = EvidenceDigest.text(SessionTranscript(items: items), budget: 50_000)
        #expect(digest.text.hasPrefix("[#0 user]") && digest.text.contains("items left out") && digest.text.contains("[#999 result Read]"))
        #expect(digest.text.count <= 50_000 && !digest.overBudget)
    }

    @Test func budgetDependsOnTheModel() {
        #expect(EvidenceDigest.budget(model: nil) == 360_000)
        #expect(EvidenceDigest.budget(model: "") == 360_000)
        #expect(EvidenceDigest.budget(model: "opus") == 360_000)
        #expect(EvidenceDigest.budget(model: "claude-sonnet-4-6") == 360_000)
        #expect(EvidenceDigest.budget(model: "opus[1m]") == 1_000_000)
        #expect(EvidenceDigest.budget(model: "gpt-5.5") == 1_000_000)
        #expect(EvidenceDigest.budget(model: "openai/gpt-5") == 1_000_000)
        #expect(EvidenceDigest.budget(model: "google/gemini-3-pro") == 1_000_000)
        #expect(EvidenceDigest.budget(model: "opencode-go/kimi-k3") == 360_000)
    }
}
