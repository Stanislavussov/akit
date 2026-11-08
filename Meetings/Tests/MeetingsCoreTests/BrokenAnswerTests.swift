import Foundation
import Testing
@testable import MeetingsCore

/// Stability wave 3: broken transcript answers, the summary's caps and retries.
@Suite struct BrokenAnswerTests {
    /// Unbalanced braces (log of 2026-11-07): the whole segments up to the end still count.
    @Test func brokenAnswerKeepsItsWholeSegments() throws {
        let text = #"{"segments":[{"start":"00:01","speaker":"Me","text":"a {b}"},{"start":"04:30","speaker":"S1","text":"end"}"#
        let segments = try Transcriber.parseSegments(text, offset: 300, length: 300)
        #expect(segments.map(\.text) == ["a {b}", "end"])
        #expect(segments.map(\.start) == [301, 570])
    }

    /// A cut answer that stops early is still unreadable, so the piece gets another try.
    @Test func cutAnswerThatEndsEarlyFails() {
        let text = #"{"segments":[{"start":"00:01","speaker":"Me","text":"a"},{"start":"01:00","speaker":"Me","text":"b"},{"start":"01:10","spea"#
        #expect(throws: MeetingsError.self) { try Transcriber.parseSegments(text, offset: 0, length: 300, cutOff: true) }
    }

    /// A model that loops until the cap: its repeated line is kept once.
    @Test func loopAtTheCapKeepsTheLineOnce() throws {
        let line = #"{"start":"04:50","speaker":"S1","text":"we will check it tomorrow"}"#
        let text = #"{"segments":[{"start":"00:02","speaker":"Me","text":"hello"},"# + Array(repeating: line, count: 40).joined(separator: ",")
        let segments = try Transcriber.parseSegments(text, offset: 0, length: 300, cutOff: true)
        #expect(segments.map(\.text) == ["hello", "we will check it tomorrow"])
    }

    /// A broken answer the model ended itself keeps its lines, also when the audio's end is silent.
    @Test func brokenStoppedAnswerEndingEarlyKeepsItsLines() throws {
        let text = #"{"segments":[{"start":"00:01","speaker":"Me","text":"say \"hi\" \\ {x}"}"#
        let segments = try Transcriber.parseSegments(text, offset: 0, length: 300)
        #expect(segments.map(\.text) == [#"say "hi" \ {x}"#])
    }

    /// A readable answer keeps a line said twice; the repeat filter is only for broken answers.
    @Test func readableAnswerKeepsARepeatedLine() throws {
        let line = #"{"start":"00:10","speaker":"Me","text":"can you hear me now?"}"#
        let text = #"{"segments":["# + line + "," + line + "]}"
        #expect(try Transcriber.parseSegments(text, offset: 0, length: 300, cutOff: true).count == 2)
    }

    /// A timeout of a paid call is not sent again (the provider may bill it); a GET is.
    @Test func paidTimeoutIsNotRetried() {
        #expect(!OpenRouterClient.isRetryable(URLError(.timedOut), paid: true))
        #expect(!OpenRouterClient.isRetryable(URLError(.networkConnectionLost), paid: true))
        #expect(OpenRouterClient.isRetryable(URLError(.cannotConnectToHost), paid: true))
        #expect(OpenRouterClient.isRetryable(URLError(.timedOut)))
    }

    /// A summary that fails once gets one more try; the meeting ends done.
    @Test func failedSummaryIsTriedOnceMore() async throws {
        let store = TempRoot().store
        var meeting = try store.create()
        let piece = store.audioFolder(meeting.id).appending(path: "piece-001.aac")
        try Data("piece1".utf8).write(to: piece)
        try JSONEncoder().encode(PieceInfo(duration: 300, me: [])).write(to: piece.deletingPathExtension().appendingPathExtension("json"))
        meeting.state = .waiting
        try store.save(meeting)
        let server = FakeServer([
            (200, chat(#"{"segments":[{"start":"00:01","speaker":"Me","text":"a"}]}"#)),
            (200, chat("not json")),
            (200, chat(#"{"title":"T","summary":"S","decisions":[],"tasks":[]}"#)),
        ])
        let done = try await MeetingProcessor(store: store, settings: MeetingsSettings(), client: server.client).run(meeting.id)
        #expect(done.state == .done && done.title == "T")
        #expect(abs(done.costUSD - 0.03) < 0.000_1)
        #expect(server.requests.count == 3)
        #expect(server.body(2)["max_tokens"] as? Int == Transcriber.summaryBudget)
    }
}
