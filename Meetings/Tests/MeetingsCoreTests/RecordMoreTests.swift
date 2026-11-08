import AVFoundation
import Foundation
import Testing
@testable import MeetingsAudio
@testable import MeetingsCore

/// M34 (Record More) and M35 (transcribe while recording).
@Suite struct RecordMoreTests {
    func addPiece(_ store: MeetingStore, _ id: String, _ index: Int, info: Bool = true) throws {
        let piece = store.audioFolder(id).appending(path: String(format: "piece-%03d.aac", index))
        try Data("piece\(index)".utf8).write(to: piece)
        if info {
            try JSONEncoder().encode(PieceInfo(duration: 300, me: [])).write(to: piece.deletingPathExtension().appendingPathExtension("json"))
        }
    }

    @Test func nextPieceAndReadyCount() throws {
        let store = TempRoot().store
        let meeting = try store.create()
        #expect(store.nextPieceNumber(meeting.id) == 1)
        #expect(store.readyPieceCount(meeting.id) == 0)
        try addPiece(store, meeting.id, 1)
        try addPiece(store, meeting.id, 2)
        try addPiece(store, meeting.id, 3, info: false) // still being written
        #expect(store.nextPieceNumber(meeting.id) == 4)
        #expect(store.readyPieceCount(meeting.id) == 2)
    }

    @Test func pieceWriterStartsAtTheGivenPiece() throws {
        let root = TempRoot()
        let closed = Closed()
        let writer = PieceWriter(folder: root.url, source: .mic, pieceSeconds: 1, firstIndex: 4) { _, index in closed.add(index) }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000)!
        buffer.frameLength = 8_000
        for _ in 0..<3 { writer.append(buffer) } // 1.5 s → piece 4 closed, 5 open
        writer.stop()
        #expect(closed.indices == [4, 5])
        #expect(Set(PieceMixer.rawFiles(in: root.url).keys) == [4, 5])
    }

    /// While it records: only whole pieces, one per call, no summary, the state stays recording.
    @Test func whileRecordingSendsWholePiecesOnly() async throws {
        let store = TempRoot().store
        var meeting = try store.create()
        meeting.duration = 0
        try store.save(meeting) // state recording
        try addPiece(store, meeting.id, 1)
        try addPiece(store, meeting.id, 2)
        try addPiece(store, meeting.id, 3, info: false)
        let server = FakeServer([
            (200, chat(#"{"segments":[{"start":"00:10","speaker":"Me","text":"a"}]}"#)),
            (200, chat(#"{"segments":[{"start":"00:20","speaker":"S1","text":"b"}]}"#)),
        ])
        let processor = MeetingProcessor(store: store, settings: MeetingsSettings(), client: server.client)
        #expect(try await processor.runWhileRecording(meeting.id) == 2)
        let saved = try #require(store.load(meeting.id))
        #expect(saved.state == .recording)
        #expect(saved.transcribedPieces == 2)
        #expect(saved.segments.map(\.start) == [10, 320])
        #expect(server.requests.count == 2)
        #expect(store.summary(meeting.id).isEmpty)
        // Nothing new: no call.
        #expect(try await processor.runWhileRecording(meeting.id) == 0)
        #expect(server.requests.count == 2)
    }

    /// A failed call while recording leaves the meeting recording; the run after Stop goes on
    /// from the next piece and writes the summary.
    @Test func failureWhileRecordingThenRunAfterStop() async throws {
        let store = TempRoot().store
        let meeting = try store.create()
        for i in 1...2 { try addPiece(store, meeting.id, i) }
        let live = FakeServer([
            (200, chat(#"{"segments":[{"start":"00:01","speaker":"Me","text":"a"}]}"#)),
            (502, #"{"error":{"message":"down"}}"#),
        ])
        await #expect(throws: MeetingsError.self) {
            try await MeetingProcessor(store: store, settings: MeetingsSettings(), client: live.client).runWhileRecording(meeting.id)
        }
        var stopped = try #require(store.load(meeting.id))
        #expect(stopped.state == .recording)
        #expect(stopped.failure == nil)
        #expect(stopped.transcribedPieces == 1)
        try addPiece(store, meeting.id, 3)
        stopped.state = .waiting
        try store.save(stopped)
        let after = FakeServer([
            (200, chat(#"{"segments":[{"start":"00:02","speaker":"S1","text":"b"}]}"#)),
            (200, chat(#"{"title":"T","summary":"S","decisions":[],"tasks":[]}"#)),
        ])
        let done = try await sixPieces(MeetingProcessor(store: store, settings: MeetingsSettings(), client: after.client)).run(meeting.id)
        #expect(done.state == .done)
        #expect(done.segments.map(\.start) == [1, 302])
        #expect(done.transcribedPieces == 3)
        #expect(after.requests.count == 2)
    }

    /// Record More on a done meeting: the next run sends only the new pieces and writes the
    /// summary again over the whole transcript.
    @Test func recordMoreGoesOnAfterTheLastPiece() async throws {
        let store = TempRoot().store
        let meeting = try store.create()
        try addPiece(store, meeting.id, 1)
        var first = try #require(store.load(meeting.id))
        first.state = .waiting
        try store.save(first)
        let one = FakeServer([
            (200, chat(#"{"segments":[{"start":"00:01","speaker":"Me","text":"a"}]}"#)),
            (200, chat(#"{"title":"T1","summary":"S1","decisions":[],"tasks":[]}"#)),
        ])
        _ = try await MeetingProcessor(store: store, settings: MeetingsSettings(), client: one.client).run(meeting.id)
        try addPiece(store, meeting.id, store.nextPieceNumber(meeting.id))
        let two = FakeServer([
            (200, chat(#"{"segments":[{"start":"00:05","speaker":"S1","text":"b"}]}"#)),
            (200, chat(#"{"title":"T2","summary":"S2","decisions":[],"tasks":[]}"#)),
        ])
        let done = try await MeetingProcessor(store: store, settings: MeetingsSettings(), client: two.client).run(meeting.id)
        let parts = (two.body(0)["messages"] as? [[String: Any]])?.last?["content"] as? [[String: Any]]
        let audio = (parts?.last?["input_audio"] as? [String: String])?["data"] ?? ""
        #expect(Data(base64Encoded: audio) == Data("piece2".utf8))
        #expect(done.segments.map(\.text) == ["a", "b"])
        #expect(done.segments.map(\.start) == [1, 305])
        #expect(store.summary(meeting.id).contains("S2"))
    }

    /// A raw or bad file of a piece that did not mix keeps its number taken.
    @Test func nextPieceSkipsUnmixedRawFiles() throws {
        let store = TempRoot().store
        let meeting = try store.create()
        try addPiece(store, meeting.id, 1)
        let audio = store.audioFolder(meeting.id)
        try Data("raw".utf8).write(to: audio.appending(path: "raw-mic-002-1.caf"))
        #expect(store.nextPieceNumber(meeting.id) == 3)
        try Data("bad".utf8).write(to: audio.appending(path: "bad-sys-004-2.caf"))
        #expect(store.nextPieceNumber(meeting.id) == 5)
        try Data("raw".utf8).write(to: audio.appending(path: "raw-sys-1000-1.caf"))
        #expect(store.nextPieceNumber(meeting.id) == 1001)
    }
}
