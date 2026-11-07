import AVFoundation
import Foundation
import Testing
@testable import MeetingsAudio
@testable import MeetingsCore

/// M33: a file from another app → pieces like a recording's.
struct AudioImportTests {
    /// A 5 s, 44.1 kHz stereo tone as WAV.
    static func tone(_ url: URL, seconds: Double = 5) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100,
                                                               AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16])
        let frames = AVAudioFrameCount(seconds * 44_100)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<2 {
            for i in 0..<Int(frames) { buffer.floatChannelData![channel][i] = 0.3 * sin(Float(i) * 2 * .pi * 440 / 44_100) }
        }
        try file.write(from: buffer)
    }

    @Test func wavBecomesPieces() throws {
        let root = TempRoot()
        let wav = root.url.appending(path: "call.wav")
        try Self.tone(wav)
        let folder = root.url.appending(path: "audio", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let seconds = try AudioImport.importFile(wav, into: folder, pieceSeconds: 2, ffmpeg: nil)
        #expect(abs(seconds - 5) < 0.1)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(names == ["piece-001.aac", "piece-001.json", "piece-002.aac", "piece-002.json", "piece-003.aac", "piece-003.json"])
        let info = try JSONDecoder().decode(PieceInfo.self, from: Data(contentsOf: folder.appending(path: "piece-003.json")))
        #expect(abs(info.duration - 1) < 0.1)
        #expect(info.me.isEmpty)
        #expect(!(info.others ?? []).isEmpty)
        // The piece reads back at about its length.
        #expect(abs(Double(try PieceMixer.load(folder.appending(path: "piece-001.aac")).count) / 16_000 - 2) < 0.2)
        #expect(FileManager.default.fileExists(atPath: wav.path))
    }

    @Test func m4aIsRead() throws {
        let root = TempRoot()
        let wav = root.url.appending(path: "t.wav")
        let m4a = root.url.appending(path: "t.m4a")
        try Self.tone(wav, seconds: 3)
        let run = Process()
        run.executableURL = URL(filePath: "/usr/bin/afconvert")
        run.arguments = ["-f", "m4af", "-d", "aac", wav.path, m4a.path]
        try run.run()
        run.waitUntilExit()
        let seconds = try AudioImport.importFile(m4a, into: root.url, pieceSeconds: 300, ffmpeg: nil)
        #expect(abs(seconds - 3) < 0.2)
    }

    @Test func unreadableFileNamesFFmpeg() throws {
        let root = TempRoot()
        let bad = root.url.appending(path: "x.ogg")
        try Data("not audio".utf8).write(to: bad)
        #expect(throws: AudioImport.ImportError.self) { try AudioImport.importFile(bad, into: root.url, ffmpeg: nil) }
        #expect(!FileManager.default.fileExists(atPath: root.url.appending(path: "piece-001.aac").path))
    }
}

extension AudioImportTests {
    /// Only where ffmpeg is installed: OGG/Opus is not readable by AVFoundation.
    @Test(.enabled(if: AudioImport.findFFmpeg() != nil)) func oggThroughFFmpeg() throws {
        let root = TempRoot()
        let wav = root.url.appending(path: "t.wav")
        let ogg = root.url.appending(path: "t.ogg")
        try Self.tone(wav, seconds: 3)
        let run = Process()
        run.executableURL = AudioImport.findFFmpeg()
        run.arguments = ["-nostdin", "-loglevel", "error", "-i", wav.path, "-c:a", "libopus", ogg.path]
        try run.run()
        run.waitUntilExit()
        let seconds = try AudioImport.importFile(ogg, into: root.url, pieceSeconds: 300)
        #expect(abs(seconds - 3) < 0.2)
    }
}
