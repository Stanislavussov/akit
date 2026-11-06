import AVFoundation
import Foundation
import Testing
@testable import MeetingsAudio
@testable import MeetingsCore

/// A temporary meetings root; deleting goes to a list instead of the Trash.
final class TempRoot: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var _trashed: [URL] = []
    var trashed: [URL] { lock.withLock { _trashed } }

    init() {
        url = FileManager.default.temporaryDirectory.appending(path: "meetings-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    var store: MeetingStore {
        MeetingStore(root: url) { [self] item in
            lock.withLock { _trashed.append(item) }
            try FileManager.default.removeItem(at: item)
        }
    }
}

/// A fake OpenRouter: answers each request with the next canned body and keeps the requests.
final class FakeServer: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [(Int, String)]
    private(set) var requests: [URLRequest] = []

    /// Retries of the client: none by default, so a 500 fails at once; retry tests pass zero waits.
    let retries: [Duration]
    let headers: [String: String]

    init(_ answers: [(Int, String)], retries: [Duration] = [], headers: [String: String] = [:]) {
        self.answers = answers
        self.retries = retries
        self.headers = headers
    }

    var client: OpenRouterClient {
        OpenRouterClient(key: "test-key", base: URL(string: "https://fake.invalid/api/v1/")!, retryDelays: retries) { [self] request in
            let (code, body) = lock.withLock { () -> (Int, String) in
                requests.append(request)
                return answers.isEmpty ? (500, #"{"error":{"message":"no more answers"}}"#) : answers.removeFirst()
            }
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: headers)!)
        }
    }

    func body(_ i: Int) -> [String: Any] {
        lock.withLock { (try? JSONSerialization.jsonObject(with: requests[i].httpBody ?? Data())) as? [String: Any] ?? [:] }
    }
}

func chat(_ content: String, cost: Double = 0.01) -> String {
    let object: [String: Any] = ["choices": [["message": ["role": "assistant", "content": content]]],
                                 "usage": ["prompt_tokens": 1000, "completion_tokens": 100, "cost": cost]]
    return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

@Suite struct StoreTests {
    @Test func createListAndSave() throws {
        let root = TempRoot()
        let store = root.store
        let start = Date(timeIntervalSince1970: 1_793_000_000)
        var a = try store.create(started: start)
        let b = try store.create(started: start)
        #expect(a.id != b.id)
        #expect(b.id.hasSuffix("-2"))
        a.segments = [Segment(start: 5, speaker: "Me", text: "Ahoj"), Segment(start: 65, speaker: "S1", text: "Dobrý den")]
        a.title = "Sync"
        try store.save(a)
        let listed = store.list()
        #expect(listed.count == 2)
        #expect(store.load(a.id) == a)
        let page = try String(contentsOf: store.folder(a.id).appending(path: "transcript.md"), encoding: .utf8)
        #expect(page.contains("[00:05] **Me**: Ahoj"))
        #expect(page.contains("[01:05] **Speaker 1**: Dobrý den"))
    }

    /// A rename in the model's own summary is still the model's: a new run keeps no Notes copy.
    @Test func renameKeepsSummaryHash() throws {
        let store = TempRoot().store
        var meeting = try store.create()
        meeting.segments = [Segment(start: 0, speaker: "S1", text: "Hi")]
        let text = "- [ ] Speaker 1: plan"
        try store.writeSummary(meeting.id, text)
        meeting.summaryHash = MeetingProcessor.hash(text)
        try store.save(meeting)
        try store.renameSpeaker(&meeting, key: "S1", to: "Jana")
        #expect(store.load(meeting.id)?.summaryHash == MeetingProcessor.hash(store.summary(meeting.id)))
    }

    @Test func renameSpeakerRewritesTranscriptAndSummary() throws {
        let root = TempRoot()
        let store = root.store
        var meeting = try store.create()
        meeting.segments = [Segment(start: 0, speaker: "S1", text: "Hi")]
        try store.save(meeting)
        try store.writeSummary(meeting.id, "- [ ] Speaker 1: send the plan")
        try store.renameSpeaker(&meeting, key: "S1", to: "Jana")
        #expect(store.load(meeting.id)?.speakerName("S1") == "Jana")
        #expect(store.summary(meeting.id).contains("Jana: send the plan"))
        let page = try String(contentsOf: store.folder(meeting.id).appending(path: "transcript.md"), encoding: .utf8)
        #expect(page.contains("**Jana**: Hi"))
    }

    @Test func ownTabs() throws {
        let root = TempRoot()
        let store = root.store
        var meeting = try store.create()
        try store.addTab(&meeting, name: "Links")
        try store.writeTab(meeting.id, "Links", "- https://example.com")
        #expect(throws: MeetingsError.self) { try store.addTab(&meeting, name: "links") }
        #expect(throws: MeetingsError.self) { try store.addTab(&meeting, name: "a/b") }
        #expect(throws: MeetingsError.self) { try store.addTab(&meeting, name: "Summary") }
        try store.renameTab(&meeting, from: "Links", to: "Notes")
        #expect(meeting.tabs == ["Notes"])
        #expect(store.tab(meeting.id, "Notes") == "- https://example.com")
        try store.removeTab(&meeting, name: "Notes")
        #expect(meeting.tabs.isEmpty)
        #expect(root.trashed.count == 1)
        #expect(store.load(meeting.id)?.tabs == [])
    }

    @Test func expiredAudioGoesToTrashOnlyWhenDone() throws {
        let root = TempRoot()
        let store = root.store
        let old = Date().addingTimeInterval(-20 * 86_400)
        var done = try store.create(started: old)
        done.state = .done
        try store.save(done)
        var waiting = try store.create(started: old.addingTimeInterval(120))
        waiting.state = .waiting
        try store.save(waiting)
        _ = try store.create() // recent
        // M26: a failed meeting and a done one with a piece not transcribed keep their audio.
        var failed = try store.create(started: old.addingTimeInterval(240))
        failed.state = .failed
        try store.save(failed)
        var partial = try store.create(started: old.addingTimeInterval(360))
        for name in ["piece-001.aac", "piece-002.aac"] { try Data("x".utf8).write(to: store.audioFolder(partial.id).appending(path: name)) }
        partial.state = .done
        partial.transcribedPieces = 1
        try store.save(partial)
        #expect(store.trashExpiredAudio() == 1)
        #expect(store.load(done.id)?.audioTrashed == true)
        #expect(!FileManager.default.fileExists(atPath: store.audioFolder(done.id).path))
        for kept in [waiting, failed, partial] {
            #expect(FileManager.default.fileExists(atPath: store.audioFolder(kept.id).path))
            #expect(store.load(kept.id)?.audioTrashed == false)
        }
        #expect(store.trashExpiredAudio() == 0)
        // Once the last piece is in the transcript, the audio goes too.
        partial.transcribedPieces = 2
        try store.save(partial)
        #expect(store.trashExpiredAudio() == 1)
    }

    @Test func monthCost() throws {
        let store = TempRoot().store
        var a = try store.create()
        a.costUSD = 0.5
        try store.save(a)
        var b = try store.create(started: Date().addingTimeInterval(-70 * 86_400))
        b.costUSD = 3
        try store.save(b)
        #expect(abs(store.monthCost() - 0.5) < 1e-9)
    }

    @Test func settingsKeepDefaultsForMissingKeys() throws {
        let root = TempRoot()
        let file = root.url.appending(path: "settings.json")
        try Data(#"{"language":"Russian"}"#.utf8).write(to: file)
        let settings = MeetingsSettings.load(from: file)
        #expect(settings.language == "Russian")
        #expect(settings.model == MeetingsSettings.defaultModel)
        #expect(settings.echoCancellation)
    }
}

@Suite struct CostReportTests {
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Prague")!
        c.firstWeekday = 2
        return c
    }

    func meeting(_ day: Int, hour: Int = 10, cost: Double, minutes: Double = 30, model: String = "m/a") -> Meeting {
        let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
        var m = Meeting(id: "\(day)/\(hour)", started: date)
        m.costUSD = cost
        m.duration = minutes * 60
        m.model = model
        return m
    }

    @Test func daysIncludeEmptyOnesAndSum() {
        let meetings = [meeting(2, cost: 0.1), meeting(2, hour: 14, cost: 0.2), meeting(4, cost: 0.05, model: "m/b"), meeting(20, cost: 9)]
        let from = calendar.date(from: DateComponents(year: 2026, month: 11, day: 2))!
        let to = calendar.date(from: DateComponents(year: 2026, month: 11, day: 5))!
        let rows = CostReport.rows(meetings, grouping: .day, from: from, to: to, calendar: calendar)
        #expect(rows.count == 4)
        #expect(rows.map(\.meetings) == [2, 0, 1, 0])
        #expect(abs(rows[0].cost - 0.3) < 1e-9)
        #expect(abs((rows[0].costPerHour ?? 0) - 0.3) < 1e-9)
        let totals = CostReport.totals(meetings, from: from, to: to, calendar: calendar)
        #expect(totals.meetings == 3 && totals.days == 4)
        #expect(abs(totals.costPerDay - 0.35 / 4) < 1e-9)
        let onlyB = CostReport.totals(meetings, from: from, to: to, model: "m/b", calendar: calendar)
        #expect(onlyB.meetings == 1)
        #expect(CostReport.models(meetings) == ["m/a", "m/b"])
    }

    @Test func weeksStartOnMondayAndCSV() {
        // 2026-11-01 is a Sunday: it belongs to the week of 26. 10.
        let meetings = [meeting(1, cost: 1), meeting(2, cost: 2), meeting(8, cost: 4)]
        let from = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        let to = calendar.date(from: DateComponents(year: 2026, month: 11, day: 9))!
        let rows = CostReport.rows(meetings, grouping: .week, from: from, to: to, calendar: calendar)
        #expect(rows.map(\.cost) == [1, 6, 0])
        let csv = CostReport.csv(rows, calendar: calendar)
        #expect(csv.hasPrefix("period,meetings,hours,usd,usd_per_hour,questions\n2026-10-26,1,0.50,1.0000,2.0000,0\n"))
    }
}

@Suite struct CatalogTests {
    let models = [
        OpenRouterModel(id: "google/gemini-2.5-flash", input: ["text", "audio"], prompt: "0.0000003", completion: "0.0000025", audio: "0.000001"),
        OpenRouterModel(id: "google/gemini-2.5-flash-lite", input: ["text", "audio"], prompt: "0.0000001", completion: "0.0000004", audio: "0.0000003"),
        OpenRouterModel(id: "openrouter/auto", input: ["text", "audio"], prompt: "-1", completion: "-1"),
        OpenRouterModel(id: "some/text-only", input: ["text"], prompt: "0.0000001", completion: "0.0000001"),
        OpenRouterModel(id: "google/gemini-3.5-flash-lite:batch", input: ["audio"], prompt: "0.00000015", completion: "0.00000125", audio: "0.00000015"),
    ]

    @Test func audioRowsSortedByHourWithRecommended() {
        let rows = ModelCatalog.audioRows(models)
        // The batch variant is cheaper here but not recommended (slower).
        #expect(rows.map(\.id) == ["google/gemini-3.5-flash-lite:batch", "google/gemini-2.5-flash-lite", "google/gemini-2.5-flash"])
        #expect(!rows[0].recommended)
        #expect(rows[1].recommended)
        // 115,200 × 0.3 µ$ + 12,000 × 0.4 µ$ ≈ $0.039
        #expect(abs((rows[1].hourCost ?? 0) - 0.03936) < 1e-6)
        #expect(ModelCatalog.priceText(rows[1].hourCost) == "$0.039/h")
    }

    @Test func textRowsLeaveOutAudioOnly() {
        let ids = ModelCatalog.textRows(models).map(\.id)
        #expect(ids.contains("some/text-only"))
        #expect(!ids.contains("google/gemini-3.5-flash-lite:batch"))
        #expect(!ids.contains("openrouter/auto"))
    }
}

@Suite struct TranscriberTests {
    @Test func parsesSegmentsInFenceAndMovesTimes() throws {
        let answer = """
        Here it is:
        ```json
        {"segments": [{"start": "00:03", "speaker": "Me", "text": "Dobrý den"}, {"start": "1:02", "speaker": "Speaker 2", "text": "Ahoj"}, {"start": "1:05", "speaker": "s1", "text": "  "}]}
        ```
        """
        let segments = try Transcriber.parseSegments(answer, offset: 1_800, length: 1_800)
        #expect(segments == [Segment(start: 1_803, speaker: "Me", text: "Dobrý den"), Segment(start: 1_862, speaker: "S2", text: "Ahoj")])
    }

    @Test func badAnswerThrows() {
        #expect(throws: MeetingsError.self) { try Transcriber.parseSegments("sorry, no", offset: 0, length: 10) }
    }

    @Test func promptHasMeSpansAndPrevious() {
        let prompt = Transcriber.transcriptPrompt(spokenHint: "Czech", length: 600, me: [TimeSpan(start: 3, end: 9.5)],
                                                  previous: [Segment(start: 0, speaker: "S1", text: "earlier line")])
        #expect(prompt.contains("00:03–00:09"))
        #expect(prompt.contains("S1: earlier line"))
        #expect(prompt.contains("most likely Czech"))
    }

    @Test func summaryMarkdown() throws {
        let summary = try Transcriber.parseSummary(#"{"title":"Plán","summary":"Krátce.","decisions":["Ano"],"tasks":[{"owner":"Me","text":"Poslat"}]}"#)
        #expect(summary.title == "Plán")
        #expect(summary.markdown.contains("- [ ] Me: Poslat"))
        #expect(summary.markdown.contains("## Decisions\n\n- Ano"))
    }
}

@Suite struct ProcessorTests {
    /// A meeting with `count` fake pieces (bytes, not audio: the fake server does not listen).
    func meetingWithPieces(_ store: MeetingStore, count: Int, length: TimeInterval = 300) throws -> Meeting {
        var meeting = try store.create()
        for i in 1...count {
            let piece = store.audioFolder(meeting.id).appending(path: String(format: "piece-%03d.aac", i))
            try Data("piece\(i)".utf8).write(to: piece)
            let info = PieceInfo(duration: length, me: [TimeSpan(start: 1, end: 2)])
            try JSONEncoder().encode(info).write(to: piece.deletingPathExtension().appendingPathExtension("json"))
        }
        meeting.state = .waiting
        try store.save(meeting)
        return meeting
    }

    @Test func chunksTranscriptAndSummary() async throws {
        let store = TempRoot().store
        let meeting = try meetingWithPieces(store, count: 7)
        let server = FakeServer([
            (200, chat(#"{"segments":[{"start":"00:10","speaker":"Me","text":"první"}]}"#)),
            (200, chat(#"{"segments":[{"start":"00:20","speaker":"S1","text":"druhý"}]}"#)),
            (200, chat(#"{"title":"Porada","summary":"Shrnutí.","decisions":[],"tasks":[]}"#, cost: 0.002)),
        ])
        var settings = MeetingsSettings()
        settings.monthlyLimitUSD = 5
        let result = try await MeetingProcessor(store: store, settings: settings, client: server.client).run(meeting.id)
        #expect(result.state == .done)
        #expect(result.title == "Porada")
        #expect(result.segments.map(\.start) == [10.0, 1_820.0])
        #expect(result.duration == 2_100)
        #expect(abs(result.costUSD - 0.022) < 1e-9)
        #expect(store.summary(meeting.id).contains("Shrnutí."))
        // The first chunk carried 6 pieces joined by bytes, the second 1; audio parts are aac.
        let parts = (server.body(0)["messages"] as? [[String: Any]])?.last?["content"] as? [[String: Any]]
        let audio = parts?.last?["input_audio"] as? [String: String]
        #expect(audio?["format"] == "aac")
        #expect(Data(base64Encoded: audio?["data"] ?? "") == Data("piece1piece2piece3piece4piece5piece6".utf8))
        #expect(server.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        // The Me span of piece 2 sits 300 s into the first chunk.
        let text = parts?.first?["text"] as? String ?? ""
        #expect(text.contains("05:01–05:02"))
    }

    @Test func failureKeepsDoneChunksAndRetryGoesOn() async throws {
        let store = TempRoot().store
        let meeting = try meetingWithPieces(store, count: 7)
        let first = FakeServer([
            (200, chat(#"{"segments":[{"start":"00:10","speaker":"Me","text":"první"}]}"#)),
            (502, #"{"error":{"message":"provider down"}}"#),
        ])
        await #expect(throws: MeetingsError.self) {
            try await MeetingProcessor(store: store, settings: MeetingsSettings(), client: first.client).run(meeting.id)
        }
        let failed = try #require(store.load(meeting.id))
        #expect(failed.state == .failed)
        #expect(failed.transcribedChunks == 1)
        #expect(failed.failure?.contains("provider down") == true)
        let second = FakeServer([
            (200, chat(#"{"segments":[{"start":"00:01","speaker":"S1","text":"druhý"}]}"#)),
            (200, chat(#"{"title":"T","summary":"S","decisions":[],"tasks":[]}"#)),
        ])
        let done = try await MeetingProcessor(store: store, settings: MeetingsSettings(), client: second.client).run(meeting.id)
        #expect(done.state == .done)
        #expect(done.segments.map(\.text) == ["první", "druhý"])
        #expect(second.requests.count == 2)
    }

    @Test func monthlyLimitStopsCalls() async throws {
        let store = TempRoot().store
        var spent = try store.create()
        spent.costUSD = 10
        spent.state = .done
        try store.save(spent)
        let meeting = try meetingWithPieces(store, count: 1)
        let server = FakeServer([])
        await #expect(throws: MeetingsError.monthlyLimit(10)) {
            try await MeetingProcessor(store: store, settings: MeetingsSettings(), client: server.client).run(meeting.id)
        }
        #expect(server.requests.isEmpty)
    }

    /// M2: pieces added after a partial run are all sent; none is skipped.
    @Test func resumeSendsEveryPieceNotYetDone() async throws {
        let store = TempRoot().store
        let meeting = try meetingWithPieces(store, count: 3)
        let first = FakeServer([
            (200, chat(#"{"segments":[{"start":"00:01","speaker":"Me","text":"a"}]}"#)),
            (500, #"{"error":{"message":"down"}}"#),
        ])
        await #expect(throws: MeetingsError.self) {
            try await MeetingProcessor(store: store, settings: MeetingsSettings(), client: first.client).run(meeting.id)
        }
        #expect(store.load(meeting.id)?.transcribedPieces == 3)
        for i in 4...8 {
            let piece = store.audioFolder(meeting.id).appending(path: String(format: "piece-%03d.aac", i))
            try Data("piece\(i)".utf8).write(to: piece)
            try JSONEncoder().encode(PieceInfo(duration: 300, me: [])).write(to: piece.deletingPathExtension().appendingPathExtension("json"))
        }
        let second = FakeServer([
            (200, chat(#"{"segments":[{"start":"00:01","speaker":"S1","text":"b"}]}"#)),
            (200, chat(#"{"title":"T","summary":"S","decisions":[],"tasks":[]}"#)),
        ])
        let done = try await MeetingProcessor(store: store, settings: MeetingsSettings(), client: second.client).run(meeting.id)
        let parts = (second.body(0)["messages"] as? [[String: Any]])?.last?["content"] as? [[String: Any]]
        let audio = (parts?.last?["input_audio"] as? [String: String])?["data"] ?? ""
        #expect(Data(base64Encoded: audio) == Data("piece4piece5piece6piece7piece8".utf8))
        #expect(done.segments.map(\.start) == [1, 901])
        #expect(done.transcribedPieces == 8)
    }

    /// H2: a second run while one holds the lock leaves the meeting alone.
    @Test func secondRunIsBusy() async throws {
        let store = TempRoot().store
        let meeting = try meetingWithPieces(store, count: 1)
        let held = try #require(MeetingLock.take(MeetingLock.processing(store, meeting.id)))
        let server = FakeServer([])
        await #expect(throws: MeetingsError.busy) {
            try await MeetingProcessor(store: store, settings: MeetingsSettings(), client: server.client).run(meeting.id)
        }
        #expect(server.requests.isEmpty)
        #expect(store.load(meeting.id)?.state == .waiting)
        held.release()
        #expect(MeetingLock.isFree(MeetingLock.processing(store, meeting.id)))
    }

    /// M3 and H5: a tab added while it transcribes stays; the user's own summary text moves to
    /// an own tab instead of being replaced.
    @Test func userChangesSurviveTheRun() async throws {
        let root = TempRoot()
        let store = root.store
        let meeting = try meetingWithPieces(store, count: 1)
        try store.writeSummary(meeting.id, "my notes during the call")
        let added = AddTabOnFirstRequest(store: store, id: meeting.id)
        let server = FakeServer([
            (200, chat(#"{"segments":[{"start":"00:01","speaker":"Me","text":"a"}]}"#)),
            (200, chat(#"{"title":"T","summary":"S","decisions":[],"tasks":[]}"#)),
        ])
        let client = OpenRouterClient(key: "k", base: URL(string: "https://fake.invalid/")!) { request in
            added.run()
            return try await server.client.transport(request)
        }
        let done = try await MeetingProcessor(store: store, settings: MeetingsSettings(), client: client).run(meeting.id)
        #expect(done.tabs == ["Links", "Notes"])
        #expect(store.tab(meeting.id, "Notes") == "my notes during the call")
        #expect(store.summary(meeting.id).contains("S"))
        // A second run over the model's own summary keeps no copy.
        let again = FakeServer([
            (200, chat(#"{"segments":[]}"#)),
        ])
        _ = try await MeetingProcessor(store: store, settings: MeetingsSettings(), client: again.client).run(meeting.id, restart: true)
        #expect(store.load(meeting.id)?.tabs == ["Links", "Notes"])
    }

    /// L1: Transcribe Again without audio keeps the transcript.
    @Test func restartWithoutAudioKeepsTranscript() async throws {
        let store = TempRoot().store
        var meeting = try store.create()
        meeting.segments = [Segment(start: 0, speaker: "Me", text: "keep")]
        meeting.state = .done
        try store.save(meeting)
        await #expect(throws: MeetingsError.noAudio) {
            try await MeetingProcessor(store: store, settings: MeetingsSettings(), client: FakeServer([]).client).run(meeting.id, restart: true)
        }
        #expect(store.load(meeting.id)?.segments.map(\.text) == ["keep"])
    }

    @Test func pastedKeyIsCleaned() {
        #expect(KeyStore.clean("  \"Bearer sk-or-v1-abc\"\n") == "sk-or-v1-abc")
        #expect(KeyStore.clean("sk-or-v1-a b") == "sk-or-v1-ab")
    }

    @Test func keyShapeNeverShowsTheKey() {
        let good = "sk-or-v1-" + String(repeating: "a1", count: 32)
        #expect(KeyStore.shape(good).contains("has the form"))
        #expect(KeyStore.shape("sk-or-v1-abc…xyz").contains("not 73"))
        #expect(KeyStore.shape("sk-proj-123").contains("not sk-or-v1-"))
        for text in [KeyStore.shape(good), KeyStore.shape("sk-or-v1-abc…xyz")] { #expect(!text.contains("a1a1") && !text.contains("abc")) }
    }

    /// A piece with its own mic and sys tracks and the given speech spans.
    func meetingWithTracks(_ store: MeetingStore, me: [TimeSpan], others: [TimeSpan]) throws -> Meeting {
        var meeting = try store.create()
        let folder = store.audioFolder(meeting.id)
        try Data("mix".utf8).write(to: folder.appending(path: "piece-001.aac"))
        try Data("mic".utf8).write(to: folder.appending(path: "mic-001.aac"))
        try Data("sys".utf8).write(to: folder.appending(path: "sys-001.aac"))
        try JSONEncoder().encode(PieceInfo(duration: 60, me: me, others: others)).write(to: folder.appending(path: "piece-001.json"))
        meeting.state = .waiting
        try store.save(meeting)
        return meeting
    }

    func sentAudio(_ server: FakeServer, _ i: Int) -> String {
        let parts = (server.body(i)["messages"] as? [[String: Any]])?.last?["content"] as? [[String: Any]]
        let data = (parts?.last?["input_audio"] as? [String: String])?["data"] ?? ""
        return String(decoding: Data(base64Encoded: data) ?? Data(), as: UTF8.self)
    }

    /// M20 Auto: room and call at once for longer than the threshold → two tracks, lines merged by time.
    @Test func overlapSendsTwoTracks() async throws {
        let store = TempRoot().store
        let meeting = try meetingWithTracks(store, me: [TimeSpan(start: 0, end: 10)], others: [TimeSpan(start: 5, end: 20)])
        let server = FakeServer([
            (200, chat(#"{"segments":[{"start":"00:01","speaker":"Me","text":"já"},{"start":"00:07","speaker":"R1","text":"kolega"}]}"#)),
            (200, chat(#"{"segments":[{"start":"00:06","speaker":"S1","text":"z hovoru"}]}"#)),
            (200, chat(#"{"title":"T","summary":"S","decisions":[],"tasks":[]}"#)),
        ])
        let done = try await MeetingProcessor(store: store, settings: MeetingsSettings(), client: server.client).run(meeting.id)
        #expect(sentAudio(server, 0) == "mic" && sentAudio(server, 1) == "sys")
        #expect(done.segments.map(\.speaker) == ["Me", "S1", "R1"])
        #expect(done.speakerName("R1") == "Room 1")
        let systemPrompt = ((server.body(1)["messages"] as? [[String: Any]])?.last?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        #expect(systemPrompt.contains("never use \"Me\""))
    }

    /// M20 Auto without overlap, and Mixed with it: one mixed call.
    @Test func noOverlapOrMixedSendsTheMix() async throws {
        for (overlap, mode) in [(false, MeetingsSettings.TrackMode.auto), (true, .mixed)] {
            let store = TempRoot().store
            let meeting = try meetingWithTracks(store, me: [TimeSpan(start: 0, end: 10)],
                                                others: [TimeSpan(start: overlap ? 5 : 12, end: 20)])
            let server = FakeServer([
                (200, chat(#"{"segments":[{"start":"00:01","speaker":"Me","text":"a"}]}"#)),
                (200, chat(#"{"title":"T","summary":"S","decisions":[],"tasks":[]}"#)),
            ])
            var settings = MeetingsSettings()
            settings.tracks = mode
            _ = try await MeetingProcessor(store: store, settings: settings, client: server.client).run(meeting.id)
            #expect(sentAudio(server, 0) == "mix")
            #expect(server.requests.count == 2)
        }
    }

    @Test func errorAnswerWith200IsAnError() {
        #expect(throws: MeetingsError.self) { try Completion.parse(Data(#"{"error":{"code":429,"message":"rate"}}"#.utf8)) }
    }
}

@Suite struct AudioTests {
    @Test func speechSpansBridgeAndDrop() {
        let levels: [Float] = [0, 0.1, 0.1, 0, 0, 0.1, 0, 0, 0, 0, 0, 0, 0, 0, 0.1]
        let spans = SpeechSpans.spans(levels: levels, window: 0.1, gate: 0.05, bridge: 0.3, shortest: 0.15)
        #expect(spans.count == 1)
        #expect(abs((spans.first?.start ?? 0) - 0.1) < 1e-9 && abs((spans.first?.end ?? 0) - 0.6) < 1e-9)
    }

    /// A sine of `seconds` at `rate`, `channels` wide, into a raw CAF piece.
    func writeTone(_ url: URL, seconds: Double, rate: Double, channels: AVAudioChannelCount, amplitude: Float) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for c in 0..<Int(channels) {
            for i in 0..<Int(frames) { buffer.floatChannelData![c][i] = amplitude * sin(Float(i) * 2 * .pi * 440 / Float(rate)) }
        }
        try file.write(from: buffer)
        file.close()
    }

    @Test func mixesTwoSourcesIntoADTSPiece() throws {
        let root = TempRoot()
        let folder = root.url
        // Mic: 2 s of tone then nothing; system: 3 s stereo at 48 kHz, quiet.
        try writeTone(folder.appending(path: PieceMixer.rawName(.mic, index: 1, part: 1)), seconds: 2, rate: 44_100, channels: 1, amplitude: 0.3)
        try writeTone(folder.appending(path: PieceMixer.rawName(.sys, index: 1, part: 1)), seconds: 3, rate: 48_000, channels: 2, amplitude: 0.1)
        #expect(PieceMixer.mixPending(in: folder).done == [1])
        let piece = folder.appending(path: "piece-001.aac")
        let data = try Data(contentsOf: piece)
        // ADTS frames start with the sync word 0xFFF.
        #expect(data.count > 100 && data[0] == 0xFF && data[1] & 0xF0 == 0xF0)
        let info = try JSONDecoder().decode(PieceInfo.self, from: Data(contentsOf: folder.appending(path: "piece-001.json")))
        #expect(abs(info.duration - 3) < 0.05)
        #expect(info.me.count == 1)
        #expect(abs((info.me.first?.end ?? 0) - 2) < 0.15)
        #expect(PieceMixer.rawFiles(in: folder).isEmpty)
        // M20: each source's own track, and when the system sound carried speech.
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "mic-001.aac").path))
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "sys-001.aac").path))
        #expect(info.others?.isEmpty == false)
        // The piece reads back as about 3 s of audio.
        let samples = try PieceMixer.load(piece)
        #expect(abs(Double(samples.count) / PieceMixer.sampleRate - 3) < 0.2)
        #expect(abs(Recorder.recordedSeconds(in: folder) - 3) < 0.05)
    }

    /// A voice-processing mic (9 channels, voice in the first) keeps its level.
    @Test func manyChannelMicTakesTheFirst() throws {
        let root = TempRoot()
        let url = root.url.appending(path: "nine.caf")
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 9)!
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, interleaved: false, channelLayout: layout)
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        buffer.frameLength = 48_000
        for c in 0..<9 { for i in 0..<48_000 { buffer.floatChannelData![c][i] = c == 0 ? 0.5 * sin(Float(i) * 2 * .pi * 440 / 48_000) : 0 } }
        try file.write(from: buffer)
        file.close()
        let peak = try PieceMixer.load(url).reduce(0) { max($0, abs($1)) }
        #expect(peak > 0.4)
    }

    /// The aggregate's input is [the output device's mic, the tap]: the tap's buffer is the last one.
    @Test func tapBufferIsTheLastMatchingStream() throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)!
        let frames = 4
        var mic = [Float](repeating: 0.9, count: frames * 6)
        var tap: [Float] = (0..<(frames * 2)).map { Float($0) / 10 }
        let expected = tap[3]
        let list = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(list.unsafeMutablePointer) }
        mic.withUnsafeMutableBytes { m in
            tap.withUnsafeMutableBytes { t in
                list[0] = AudioBuffer(mNumberChannels: 6, mDataByteSize: UInt32(m.count), mData: m.baseAddress)
                list[1] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(t.count), mData: t.baseAddress)
                let buffer = SystemAudioTap.tapBuffer(list.unsafePointer, format: format)
                #expect(buffer?.frameLength == AVAudioFrameCount(frames))
                #expect(buffer?.floatChannelData?[0][3] == expected)
            }
        }
    }

    /// The live wave: silence is 0 (a flat line), speech-level sound fills it.
    @Test func loudnessFlatInSilence() {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
        buffer.frameLength = 480
        for i in 0..<960 { buffer.floatChannelData![0][i] = 0 }
        #expect(Recorder.loudness(buffer) == 0)
        for i in 0..<960 { buffer.floatChannelData![0][i] = 0.1 * sin(Float(i / 2) * 0.3) }
        #expect(Recorder.loudness(buffer) > 0.3)
    }

    @Test func pieceWriterRotatesAndParts() throws {
        let root = TempRoot()
        let closed = Closed()
        let writer = PieceWriter(folder: root.url, source: .mic, pieceSeconds: 1) { source, index in closed.add(index) }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000)!
        buffer.frameLength = 8_000
        for _ in 0..<5 { writer.append(buffer) } // 2.5 s → pieces 1, 2 closed, 3 open
        let other = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        let wide = AVAudioPCMBuffer(pcmFormat: other, frameCapacity: 4_800)!
        wide.frameLength = 4_800
        writer.append(wide) // a new format: piece 3, part 2
        writer.stop()
        #expect(closed.indices == [1, 2, 3])
        let files = PieceMixer.rawFiles(in: root.url)
        #expect(files[3]?[.mic]?.count == 2)
        #expect(files[1]?[.mic]?.count == 1)
    }

    /// Every piece is exactly as long as asked: a buffer that crosses the end is split there.
    @Test func piecesAreExactAndGapsAcrossEndsAreWhole() throws {
        let root = TempRoot()
        let start = mach_absolute_time()
        let writer = PieceWriter(folder: root.url, source: .mic, pieceSeconds: 1, startHost: start) { _, _ in }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096)!
        buffer.frameLength = 4_096 // 0.256 s, does not divide 1 s
        var host = start
        for _ in 0..<5 { // 1.28 s
            writer.append(buffer, hostTime: host)
            host += AVAudioTime.hostTime(forSeconds: 0.256)
        }
        // A 1.5 s gap that crosses the end of piece 2, then one more buffer: 3.036 s in all.
        writer.append(buffer, hostTime: host + AVAudioTime.hostTime(forSeconds: 1.5))
        writer.stop()
        let files = PieceMixer.rawFiles(in: root.url)
        let lengths = try (1...4).map { i in try files[i]?[.mic]?.reduce(0) { $0 + (try AVAudioFile(forReading: $1).length) } ?? 0 }
        #expect(lengths[0] == 16_000 && lengths[1] == 16_000 && lengths[2] == 16_000)
        #expect(abs(Int(lengths[3]) - Int(0.036 * 16_000)) <= 2)
    }

    /// An unreadable part is kept as `bad-…`; a later mix keeps the piece.
    @Test func badPartDoesNotEmptyThePieceLater() throws {
        let root = TempRoot()
        let folder = root.url
        try writeTone(folder.appending(path: PieceMixer.rawName(.mic, index: 1, part: 1)), seconds: 1, rate: 16_000, channels: 1, amplitude: 0.3)
        try Data("not audio".utf8).write(to: folder.appending(path: PieceMixer.rawName(.mic, index: 1, part: 2)))
        let first = PieceMixer.mixPending(in: folder)
        #expect(first.done == [1] && first.problems.count == 1)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "bad-mic-001-2.caf").path))
        let second = PieceMixer.mixPending(in: folder)
        #expect(second.done.isEmpty)
        let info = try JSONDecoder().decode(PieceInfo.self, from: Data(contentsOf: folder.appending(path: "piece-001.json")))
        #expect(abs(info.duration - 1) < 0.01)
    }

    /// M1: time before the first buffer and a gap between buffers become silence, so the source
    /// stays on the recording's clock.
    @Test func gapsBecomeSilence() throws {
        let root = TempRoot()
        let start = mach_absolute_time()
        let writer = PieceWriter(folder: root.url, source: .sys, pieceSeconds: 60, startHost: start) { _, _ in }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
        buffer.frameLength = 16_000 // 1 s
        writer.append(buffer, hostTime: start + AVAudioTime.hostTime(forSeconds: 0.5))  // 0.5 s late
        writer.append(buffer, hostTime: start + AVAudioTime.hostTime(forSeconds: 3.5))  // 2 s gap
        writer.stop()
        let file = try #require(PieceMixer.rawFiles(in: root.url)[1]?[.sys]?.first)
        let samples = try PieceMixer.load(file)
        #expect(abs(Double(samples.count) / 16_000 - 4.5) < 0.02)
    }
}

/// Adds a tab to the meeting the first time a request goes out (the user acting mid-run).
final class AddTabOnFirstRequest: @unchecked Sendable {
    let store: MeetingStore
    let id: String
    private let lock = NSLock()
    private var done = false

    init(store: MeetingStore, id: String) {
        self.store = store
        self.id = id
    }

    func run() {
        let first = lock.withLock { () -> Bool in
            defer { done = true }
            return !done
        }
        guard first, var meeting = store.load(id) else { return }
        try? store.addTab(&meeting, name: "Links")
    }
}

final class Closed: @unchecked Sendable {
    private let lock = NSLock()
    private var _indices: [Int] = []
    var indices: [Int] { lock.withLock { _indices } }
    func add(_ i: Int) { lock.withLock { _indices.append(i) } }
}

@Suite struct TemplateTests {
    @Test func templateSectionsGoInPromptAndMarkdown() throws {
        let standup = MeetingTemplate.builtIn.first { $0.id == "standup" }!
        let prompt = Transcriber.summaryPrompt(language: "Czech", transcript: "[00:01] Me: ahoj", template: standup)
        #expect(prompt.contains("\"Standup\""))
        #expect(prompt.contains("    - Blockers: who is blocked by what"))
        #expect(prompt.contains(#""sections": [{"heading""#))
        #expect(!Transcriber.summaryPrompt(language: "Czech", transcript: "", template: MeetingTemplate.builtIn[0]).contains("sections"))
        let summary = try Transcriber.parseSummary(#"""
        {"title":"Standup","summary":"Krátce.","sections":[{"heading":"## Blokery:","items":["Jana čeká na API",""]},{"heading":"","items":["x"]}],
         "decisions":[],"tasks":[{"owner":"Me","text":"napsat Janě"}],"tags":["#Release Plán","api","x","navíc"]}
        """#)
        #expect(summary.sections.map(\.heading) == ["Blokery"])
        #expect(summary.sections.first?.items == ["Jana čeká na API"])
        #expect(summary.tags == ["release plán", "api", "x"])
        #expect(summary.markdown.contains("## Summary\n\nKrátce.\n\n## Blokery\n\n- Jana čeká na API\n\n## Decisions\n\n—\n\n## Tasks\n\n- [ ] Me: napsat Janě\n"))
    }

    @Test func unknownTemplateFallsBackAndOldSettingsLoad() throws {
        var settings = MeetingsSettings()
        #expect(settings.template("gone").id == MeetingTemplate.generalID)
        let id = MeetingTemplate.newID()
        settings.customTemplates = [MeetingTemplate(id: id, name: "Sales", sections: "Deal")]
        settings.defaultTemplate = id
        #expect(settings.template(nil).name == "Sales")
        #expect(MeetingTemplate.newID() != id && id.hasPrefix("own-"))
        let old = try JSONDecoder().decode(MeetingsSettings.self, from: Data(#"{"model":"m"}"#.utf8))
        #expect(old.cleanTranscript && old.defaultTemplate == MeetingTemplate.generalID && old.customTemplates.isEmpty)
    }

    @Test func cleanOrWordForWordSystemPrompt() async throws {
        let store = TempRoot().store
        let meeting = try ProcessorTests().meetingWithPieces(store, count: 1)
        for clean in [true, false] {
            let server = FakeServer([(200, chat(#"{"segments":[]}"#))])
            var settings = MeetingsSettings()
            settings.cleanTranscript = clean
            _ = try await MeetingProcessor(store: store, settings: settings, client: server.client).run(meeting.id, restart: true)
            let system = (server.body(0)["messages"] as? [[String: Any]])?.first?["content"] as? String ?? ""
            #expect(system.contains("filler") == clean)
            #expect(system.contains("word for word") == !clean)
        }
    }

    @Test func summarizeAgainSendsOnlyTextAndKeepsUserTags() async throws {
        let store = TempRoot().store
        var meeting = try ProcessorTests().meetingWithPieces(store, count: 1)
        let first = FakeServer([
            (200, chat(#"{"segments":[{"start":"00:01","speaker":"Me","text":"ahoj"}]}"#)),
            (200, chat(#"{"title":"Porada","summary":"A.","decisions":[],"tasks":[],"tags":["api"]}"#)),
        ])
        meeting = try await MeetingProcessor(store: store, settings: MeetingsSettings(), client: first.client).run(meeting.id)
        #expect(meeting.tags == ["api"])
        // The user changes the tags and the template; the summary is written again.
        try store.setTags(&meeting, ["Release", "release", " "])
        #expect(meeting.tags == ["release"])
        try store.setTemplate(&meeting, "retro")
        let again = FakeServer([(200, chat(#"{"title":"Retro","summary":"B.","sections":[{"heading":"Dobře","items":["vše"]}],"decisions":[],"tasks":[],"tags":["jiné"]}"#, cost: 0.001))])
        let result = try await MeetingProcessor(store: store, settings: MeetingsSettings(), client: again.client).summarizeAgain(meeting.id)
        #expect(again.requests.count == 1)
        let parts = (again.body(0)["messages"] as? [[String: Any]])?.last?["content"] as? [[String: Any]] ?? []
        #expect(parts.count == 1 && (parts.first?["text"] as? String ?? "").contains("\"Retro\""))
        #expect(result.state == .done && result.segments.count == 1 && result.tags == ["release"] && result.title == "Retro")
        #expect(store.summary(meeting.id).contains("## Dobře"))
        #expect(abs(result.costUSD - 0.021) < 1e-9)
        // A failed summary leaves the meeting done, with its transcript.
        let broken = FakeServer([(500, #"{"error":{"message":"down"}}"#)])
        await #expect(throws: MeetingsError.self) { try await MeetingProcessor(store: store, settings: MeetingsSettings(), client: broken.client).summarizeAgain(meeting.id) }
        #expect(store.load(meeting.id)?.state == .done)
    }
}

@Suite struct SearchTests {
    func meeting(_ store: MeetingStore, title: String, tags: [String]?, summary: String, said: [String], tab: (String, String)? = nil) throws -> Meeting {
        var meeting = try store.create(started: Date(timeIntervalSince1970: 1_800_000_000 + Double(Int.random(in: 0...100_000))))
        meeting.title = title
        meeting.tags = tags
        meeting.state = .done
        meeting.segments = said.enumerated().map { Segment(start: Double($0.offset * 10), speaker: $0.offset == 0 ? "Me" : "S1", text: $0.element) }
        try store.save(meeting)
        try store.writeSummary(meeting.id, summary)
        if let tab { try store.addTab(&meeting, name: tab.0); try store.writeTab(meeting.id, tab.0, tab.1) }
        return meeting
    }

    @Test func wordsAnywhereAccentsAndTags() throws {
        let store = TempRoot().store
        let a = try meeting(store, title: "Plán vydání", tags: ["release plán", "api"], summary: "## Summary\n\nVydání až po opravě.\n\n## Tasks\n\n- [ ] Me: přidat kontrolu idempotence\n",
                            said: ["Dobré ráno", "Událost order-created přijde dvakrát"], tab: ("Odkazy", "- [MR](https://example.com/42)"))
        let doc = MeetingSearch.document(a, store: store)
        // Words on different lines, case and accents ignored.
        #expect(MeetingSearch.match(doc, .init("PLAN dvakrat")) != nil)
        #expect(MeetingSearch.match(doc, .init("idempotence"))?.place == "Summary")
        #expect(MeetingSearch.match(doc, .init("idempotence"))?.snippet == "Me: přidat kontrolu idempotence")
        #expect(MeetingSearch.match(doc, .init("order-created"))?.place == "Transcript")
        #expect(MeetingSearch.match(doc, .init("example.com"))?.place == "Odkazy")
        #expect(MeetingSearch.match(doc, .init("platby")) == nil)
        // #tag from its start, spaces and accents left out; a tag-only search has no snippet.
        #expect(MeetingSearch.match(doc, .init("#releaseplan")) != nil)
        #expect(MeetingSearch.match(doc, .init("#rel")) != nil)
        #expect(MeetingSearch.match(doc, .init("#pay")) == nil)
        #expect(MeetingSearch.match(doc, .init("#api"))?.snippet == nil)
        #expect(MeetingSearch.match(doc, .init("#api dvakrát")) != nil)
        // A plain word may also be a tag.
        #expect(MeetingSearch.match(doc, .init("api"))?.place == "Tags")
    }

    @Test func snippetCutsAroundTheWord() {
        let text = String(repeating: "slovo ", count: 40) + "idempotence" + String(repeating: " další", count: 40)
        let snippet = MeetingSearch.snippet(text, around: "idempotence")
        #expect(snippet.hasPrefix("…") && snippet.hasSuffix("…") && snippet.contains("idempotence"))
        #expect(snippet.count <= 113)
    }

    @Test func tagsAreCleanedAndProposedOnlyOnce() throws {
        let store = TempRoot().store
        var m = try meeting(store, title: "A", tags: nil, summary: "", said: ["x"])
        try store.setTags(&m, [" #Release ", "release", "", "Platby  karty"])
        #expect(store.load(m.id)?.tags == ["release", "platby karty"])
        try store.setTags(&m, [])
        #expect(store.load(m.id)?.tags == [])
    }

    @Test func similarByTitleTagsAndSummary() throws {
        let store = TempRoot().store
        let a = try meeting(store, title: "Platby kartou selhaly", tags: ["platby"], summary: "Selhalo dvanáct plateb kartou u banky.", said: ["x"])
        let b = try meeting(store, title: "Platby: oprava", tags: ["platby"], summary: "Oprava plateb kartou u banky je hotová.", said: ["x"])
        let c = try meeting(store, title: "Plán vydání", tags: ["release"], summary: "Vydání objednávek příští týden.", said: ["x"])
        let docs = [a, b, c].map { MeetingSearch.document($0, store: store) }
        let similar = MeetingSearch.similar(to: a.id, in: docs)
        #expect(similar.map(\.id) == [b.id])
        #expect(MeetingSearch.similar(to: "missing", in: docs).isEmpty)
    }
}

@Suite struct AskTests {
    func meetings(_ store: MeetingStore) throws -> [Meeting] {
        let now = Date()
        let s = SearchTests()
        var a = try s.meeting(store, title: "Platby", tags: ["platby"], summary: "## Summary\n\nSelhaly platby kartou.\n", said: ["Banka vrací chybu 51", "Pošlu ID transakcí"])
        var b = try s.meeting(store, title: "Vydání", tags: ["release"], summary: "## Summary\n\nVydání v pátek.\n", said: ["Vydáme v pátek", "Testy jsou hotové"])
        var old = try s.meeting(store, title: "Starý plán", tags: ["release"], summary: "## Summary\n\nDávno.\n", said: ["Kdysi"])
        a.started = now.addingTimeInterval(-3_600)
        b.started = now.addingTimeInterval(-86_400)
        old.started = now.addingTimeInterval(-40 * 86_400)
        for m in [a, b, old] { try store.save(m) }
        return [a, b, old]
    }

    @Test func scopeTagAndContext() throws {
        let store = TempRoot().store
        let all = try meetings(store)
        #expect(MeetingAsk.meetings(all, scope: .days(7), tag: nil).map(\.title) == ["Platby", "Vydání"])
        #expect(MeetingAsk.meetings(all, scope: .all, tag: "release").map(\.title) == ["Vydání", "Starý plán"])
        #expect(MeetingAsk.meetings(all, scope: .meeting(all[2].id), tag: nil).map(\.title) == ["Starý plán"])
        let docs = Dictionary(uniqueKeysWithValues: all.map { ($0.id, MeetingSearch.document($0, store: store)) })
        let chosen = MeetingAsk.meetings(all, scope: .days(7), tag: nil)
        // Summaries of all; transcripts best match first, those without a match after them.
        let context = MeetingAsk.context(chosen, documents: docs, question: "Jakou chybu vrací banka?")
        #expect(context.ids == [all[0].id, all[1].id])
        #expect(context.text.contains("[1] ") && context.text.contains("Selhaly platby kartou.") && context.text.contains("Vydání v pátek."))
        #expect(context.text.contains("Transcript of [1]:") && context.text.contains("chybu 51"))
        #expect(context.text.contains("Transcript of [2]:"))
        // The date is the local day.
        #expect(context.text.contains("[1] " + MeetingAsk.day(all[0].started)))
        #expect(MeetingAsk.prompt(question: "q", context: "", history: [], today: all[0].started).hasPrefix("Today is " + MeetingAsk.day(all[0].started)))
        // One meeting always carries its transcript; a small budget cuts the list.
        #expect(MeetingAsk.context([all[2]], documents: docs, question: "nic").text.contains("Transcript of [1]:"))
        #expect(MeetingAsk.context(chosen, documents: docs, question: "x", budget: 120).ids.count == 1)
    }

    @Test func askSendsContextAndHistoryAndReadsSources() async throws {
        let store = TempRoot().store
        let all = try meetings(store)
        let docs = Dictionary(uniqueKeysWithValues: all.map { ($0.id, MeetingSearch.document($0, store: store)) })
        let context = MeetingAsk.context(Array(all.prefix(2)), documents: docs, question: "banka")
        let server = FakeServer([(200, chat(#"{"answer":"Banka vrací chybu 51 [1]; vydání je v pátek [2, 9]."}"#, cost: 0.003))])
        var settings = MeetingsSettings()
        settings.summaryModel = "text/model"
        let answer = try await MeetingAsk(client: server.client, settings: settings)
            .ask("Co banka?", context: context, history: [.init(question: "Kdy vydání?", answer: "V pátek [2].")])
        #expect(answer.sources.map(\.number) == [1, 2])
        #expect(answer.sources.map(\.id) == [all[0].id, all[1].id])
        #expect(server.body(0)["model"] as? String == "text/model")
        let prompt = ((server.body(0)["messages"] as? [[String: Any]])?.last?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        #expect(prompt.contains("Q: Kdy vydání?") && prompt.contains("Question: Co banka?") && prompt.contains("Selhaly platby"))
        await #expect(throws: PaidFailure.self) {
            try await MeetingAsk(client: FakeServer([(200, chat(#"{"text":"x"}"#))]).client, settings: settings).ask("?", context: context)
        }
    }

    @Test func askCostsCountInMonthAndReport() throws {
        let root = TempRoot()
        let store = root.store
        let log = AskLog(root: root.url)
        #expect(log.entries().isEmpty)
        try log.append(.init(date: Date(), model: "m", promptTokens: 10, completionTokens: 2, costUSD: 0.5))
        try log.append(.init(date: Date(), model: "m", promptTokens: 10, completionTokens: 2, costUSD: 0.25))
        try Data("not json\n".utf8).write(to: root.url.appending(path: "other.txt"))
        #expect(log.entries().count == 2)
        #expect(abs(store.monthCost() - 0.75) < 1e-9)
        // The limit stops transcription when questions used it up.
        let rows = CostReport.rows([], asks: log.entries(), grouping: .day, from: Date(), to: Date())
        #expect(rows.count == 1 && rows[0].questions == 2 && abs(rows[0].cost - 0.75) < 1e-9 && rows[0].meetings == 0)
        let totals = CostReport.totals([], asks: log.entries(), from: Date(), to: Date(), model: "other")
        #expect(totals.questions == 0 && totals.cost == 0)
        #expect(CostReport.models([], asks: log.entries()) == ["m"])
        #expect(store.list().isEmpty)
    }
}

@Suite struct LinkTests {
    @Test func openTasksOfASummary() {
        let summary = "## Tasks\n\n- [ ] Me: přidat kontrolu\n- [x] Jana: hotovo\n  - [ ] Jana: dopsat testy\n- [ ] bez vlastníka\n- [ ] Dlouhá věta s dvojtečkou daleko za začátkem, tedy ne vlastník: text\n- [ ] \n"
        let tasks = SummaryTask.open(in: summary)
        #expect(tasks.map(\.owner) == ["Me", "Jana", "", ""])
        #expect(tasks.map(\.text) == ["přidat kontrolu", "dopsat testy", "bez vlastníka", "Dlouhá věta s dvojtečkou daleko za začátkem, tedy ne vlastník: text"])
    }

    @Test func summaryParagraphTakesTwoSentences() {
        let summary = "## Summary\n\nPrvní věta. Druhá věta!\nTřetí věta.\n\n## Decisions\n\n- x\n"
        #expect(summaryParagraph(summary) == "První věta. Druhá věta!")
        #expect(summaryParagraph("## Summary\n\nBez tečky\n") == "Bez tečky")
        #expect(summaryParagraph("## Summary\n\n—\n") == nil)
        #expect(summaryParagraph("## Tasks\n\n- [ ] x\n") == nil)
    }

    @Test func factsParseAndPromptHasNotes() async throws {
        let facts = try FactFinder.parse(#"""
        {"facts":[{"note":"/Payments/Billing ","heading":"## Retries:","text":"Three tries.","reason":"Jana said so"},
                  {"note":"payments/billing","heading":"Retries","text":"again"},
                  {"note":"../etc","heading":"x","text":"y"},
                  {"note":"payments/new thing","heading":"x","text":"y"},
                  {"note":"payments/orders-api","heading":"Owner","text":""}]}
        """#)
        #expect(facts == [MeetingFact(note: "payments/billing", heading: "Retries", text: "Three tries.", reason: "Jana said so")])
        #expect(facts[0].body == "## Retries\n\nThree tries.\n")
        #expect(throws: MeetingsError.self) { try FactFinder.parse("{}") }
        let prompt = FactFinder.prompt(summary: "S", transcript: "T", notes: [.init(id: "payments/billing", title: "Billing")])
        #expect(prompt.contains("- payments/billing: Billing") && prompt.contains("Meeting summary:\nS"))
        #expect(FactFinder.prompt(summary: "", transcript: "", notes: []).contains("(none yet)"))
        // The call goes to the summary model with the meeting's transcript.
        let store = TempRoot().store
        let meeting = try SearchTests().meeting(store, title: "A", tags: nil, summary: "", said: ["Billing retries three times"])
        let server = FakeServer([(200, chat(#"{"facts":[]}"#, cost: 0.002))])
        let answer = try await FactFinder(client: server.client, settings: MeetingsSettings()).find(meeting, summary: "", notes: [])
        #expect(answer.facts.isEmpty && answer.completion.cost == 0.002)
        let text = ((server.body(0)["messages"] as? [[String: Any]])?.last?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        #expect(text.contains("Billing retries three times"))
    }

    @Test func exportMarksAndCostStay() throws {
        let store = TempRoot().store
        var meeting = try store.create()
        try store.markExport(&meeting, "worklog", at: Date(timeIntervalSince1970: 0))
        try store.addCost(&meeting, 0.25)
        let back = store.load(meeting.id)
        #expect(back?.exports?["worklog"] == Date(timeIntervalSince1970: 0))
        #expect(back?.costUSD == 0.25)
    }
}


@Suite struct ReviewFixTests {
    @Test func summarizeAgainRefusesAPartTranscribedMeeting() async throws {
        let store = TempRoot().store
        var meeting = try ProcessorTests().meetingWithPieces(store, count: 7)
        meeting.segments = [Segment(start: 1, speaker: "Me", text: "ahoj")]
        meeting.transcribedPieces = 6
        meeting.state = .failed
        meeting.failure = "limit"
        try store.save(meeting)
        let server = FakeServer([])
        await #expect(throws: MeetingsError.notTranscribed) {
            try await MeetingProcessor(store: store, settings: MeetingsSettings(), client: server.client).summarizeAgain(meeting.id)
        }
        #expect(server.requests.isEmpty)
        #expect(store.load(meeting.id)?.state == .failed && store.load(meeting.id)?.failure == "limit")
    }

    @Test func unreadablePaidAnswerStillCosts() async throws {
        let store = TempRoot().store
        let meeting = try ProcessorTests().meetingWithPieces(store, count: 1)
        let server = FakeServer([(200, chat("not json at all", cost: 0.04))])
        await #expect(throws: PaidFailure.self) {
            try await MeetingProcessor(store: store, settings: MeetingsSettings(), client: server.client).run(meeting.id)
        }
        let back = store.load(meeting.id)
        #expect(back?.state == .failed && abs((back?.costUSD ?? 0) - 0.04) < 1e-9)
        #expect(back?.failure?.contains("JSON") == true)
        let asked = FakeServer([(200, chat(#"{"x":1}"#, cost: 0.01))])
        do {
            _ = try await MeetingAsk(client: asked.client, settings: MeetingsSettings()).ask("?", context: ("", []))
            Issue.record("no error")
        } catch {
            #expect(PaidFailure.cost(of: error) == 0.01)
        }
    }
}


@Suite struct RetryTests {
    let ok = chat(#"{"segments":[]}"#)

    @Test func busyAndDownAreRetriedThreeTimes() async throws {
        let server = FakeServer([(429, #"{"error":{"message":"rate"}}"#), (503, "down"), (502, "bad gateway"), (200, ok)], retries: [.zero, .zero, .zero])
        let answer = try await server.client.complete(model: "m", system: "s", text: "t")
        #expect(answer.text.contains("segments"))
        #expect(server.requests.count == 4)
    }

    @Test func givesUpAfterThreeRetriesWithTheCode() async throws {
        let server = FakeServer(Array(repeating: (429, #"{"error":{"message":"rate"}}"#), count: 5), retries: [.zero, .zero, .zero],
                                headers: ["Retry-After": "0"])
        await #expect(throws: MeetingsError.http(429, "rate")) { try await server.client.complete(model: "m", system: "s", text: "t") }
        #expect(server.requests.count == 4)
    }

    @Test func otherErrorsAreNotRetried() async throws {
        for code in [400, 401, 402, 404] {
            let server = FakeServer([(code, #"{"error":{"message":"no"}}"#), (200, ok)], retries: [.zero, .zero, .zero])
            await #expect(throws: MeetingsError.self) { try await server.client.complete(model: "m", system: "s", text: "t") }
            #expect(server.requests.count == 1)
        }
    }

    @Test func anErrorInsideA200IsRetriedByItsCode() async throws {
        let server = FakeServer([(200, #"{"error":{"code":429,"message":"provider busy"}}"#), (200, ok)], retries: [.zero])
        _ = try await server.client.complete(model: "m", system: "s", text: "t")
        #expect(server.requests.count == 2)
    }

    @Test func aChunkSurvives429AndTheAudioStays() async throws {
        let store = TempRoot().store
        let meeting = try ProcessorTests().meetingWithPieces(store, count: 1)
        let server = FakeServer([(429, "rate"), (200, chat(#"{"segments":[{"start":"00:01","speaker":"Me","text":"ahoj"}]}"#)),
                                 (429, "rate"), (200, chat(#"{"title":"T","summary":"S.","decisions":[],"tasks":[]}"#))], retries: [.zero, .zero, .zero])
        let result = try await MeetingProcessor(store: store, settings: MeetingsSettings(), client: server.client).run(meeting.id)
        #expect(result.state == .done && result.segments.count == 1)
        #expect(store.pieces(meeting.id).count == 1)
        // All retries used up: failed, audio kept for Try Again.
        let again = try ProcessorTests().meetingWithPieces(store, count: 1)
        let down = FakeServer(Array(repeating: (503, "down"), count: 4), retries: [.zero, .zero, .zero])
        await #expect(throws: MeetingsError.self) { try await MeetingProcessor(store: store, settings: MeetingsSettings(), client: down.client).run(again.id) }
        #expect(store.load(again.id)?.state == .failed && store.pieces(again.id).count == 1)
        #expect(store.trashExpiredAudio(now: Date().addingTimeInterval(30 * 86_400)) == 1) // only the done one
        #expect(store.pieces(again.id).count == 1)
    }
}

@Suite struct VocabularyTests {
    @Test func parsesLinesCommasHintsAndRepeats() {
        let text = """
        # services
        orders-api, Billing; kafka
        - Kafka
        Rohlik — the client
        idempotence: making a call twice safe

        "Jana Nováková"
        """
        #expect(MeetingsSettings.vocabulary(from: text) == ["orders-api", "Billing", "kafka", "Rohlik — the client", "idempotence: making a call twice safe", "Jana Nováková"])
        #expect(MeetingsSettings.vocabulary(from: "").isEmpty)
    }

    @Test func termsGoIntoTranscriptAndSummaryPrompts() async throws {
        let store = TempRoot().store
        let meeting = try ProcessorTests().meetingWithPieces(store, count: 1)
        var settings = MeetingsSettings()
        settings.vocabulary = ["orders-api", "Rohlík"]
        let server = FakeServer([
            (200, chat(#"{"segments":[{"start":"00:01","speaker":"Me","text":"orders-api"}]}"#)),
            (200, chat(#"{"title":"T","summary":"S.","decisions":[],"tasks":[]}"#)),
        ])
        _ = try await MeetingProcessor(store: store, settings: settings, client: server.client).run(meeting.id)
        for i in 0..<2 {
            let text = ((server.body(i)["messages"] as? [[String: Any]])?.last?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
            #expect(text.contains("Words of the user's project") && text.contains("- orders-api\n- Rohlík"))
        }
        #expect(!Transcriber.transcriptPrompt(spokenHint: "Czech", length: 10, me: [], previous: []).contains("Words of the user's project"))
        let many = (1...2_000).map { "term\($0)" }
        #expect(Transcriber.vocabularyLine(many, for: "")?.contains("term1500\n") == false)
        #expect(Transcriber.vocabularyLine(many, for: "")?.hasSuffix("- term1500") == true)
        let old = try JSONDecoder().decode(MeetingsSettings.self, from: Data(#"{"model":"m"}"#.utf8))
        #expect(old.vocabulary.isEmpty && old.backgroundSounds)
    }
}
