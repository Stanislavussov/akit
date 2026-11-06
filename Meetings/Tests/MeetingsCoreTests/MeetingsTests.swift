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

    init(_ answers: [(Int, String)]) { self.answers = answers }

    var client: OpenRouterClient {
        OpenRouterClient(key: "test-key", base: URL(string: "https://fake.invalid/api/v1/")!) { [self] request in
            let (code, body) = lock.withLock { () -> (Int, String) in
                requests.append(request)
                return answers.isEmpty ? (500, #"{"error":{"message":"no more answers"}}"#) : answers.removeFirst()
            }
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
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
        #expect(store.trashExpiredAudio() == 1)
        #expect(store.load(done.id)?.audioTrashed == true)
        #expect(!FileManager.default.fileExists(atPath: store.audioFolder(done.id).path))
        #expect(FileManager.default.fileExists(atPath: store.audioFolder(waiting.id).path))
        #expect(store.trashExpiredAudio() == 0)
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
        // The piece reads back as about 3 s of audio.
        let samples = try PieceMixer.load(piece)
        #expect(abs(Double(samples.count) / PieceMixer.sampleRate - 3) < 0.2)
        #expect(abs(Recorder.recordedSeconds(in: folder) - 3) < 0.05)
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
