@preconcurrency import AVFoundation
import Foundation
import MeetingsCore
import UniformTypeIdentifiers

/// M33: an audio or video file made elsewhere (another recorder, a phone, a call app) → the same
/// 5-minute pieces a recording leaves (`piece-001.aac` + `piece-001.json`), so transcription and
/// summary run as for a recording. AVFoundation reads WAV, MP3, M4A/AAC, AIFF, CAF, FLAC, ALAC
/// and the sound of MP4/MOV/M4V; other formats (OGG, Opus, WebM, MKV, WMA, AMR …) go through
/// `ffmpeg` first when it is installed. The file is only read, never moved or changed.
public enum AudioImport {
    /// Extensions the open panel and drop accept. The list is wide on purpose: the reader decides.
    public static let extensions = ["wav", "wave", "mp3", "m4a", "m4b", "aac", "adts", "aif", "aiff", "aifc", "caf",
                                    "flac", "alac", "mp4", "mov", "m4v", "3gp", "3g2", "amr", "ogg", "oga", "opus",
                                    "webm", "mkv", "mka", "wma", "wmv", "avi", "ac3", "eac3", "mp2", "spx"]

    /// The open panel's types: audio and video, plus each extension's own type.
    public static var contentTypes: [UTType] {
        [.audio, .movie] + extensions.compactMap { UTType(filenameExtension: $0) }
    }

    public struct ImportError: LocalizedError {
        public let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    /// Writes the pieces into `folder` and returns the audio's length. `progress` gets seconds read.
    @discardableResult
    public static func importFile(_ url: URL, into folder: URL, pieceSeconds: TimeInterval = 300,
                                  ffmpeg: URL? = findFFmpeg(),
                                  progress: @Sendable (TimeInterval) -> Void = { _ in }) throws -> TimeInterval {
        do {
            return try importReadable(url, into: folder, pieceSeconds: pieceSeconds, progress: progress)
        } catch let first {
            guard let ffmpeg else {
                throw ImportError("Could not read \(url.lastPathComponent): \(first.localizedDescription). Install ffmpeg (brew install ffmpeg) to import more formats.")
            }
            let wav = FileManager.default.temporaryDirectory.appending(path: "meetings-import-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: wav) }
            try convert(url, to: wav, ffmpeg: ffmpeg)
            MeetingsLog.info(.mixer, "import: \(url.pathExtension) converted by ffmpeg")
            return try importReadable(wav, into: folder, pieceSeconds: pieceSeconds, progress: progress)
        }
    }

    /// The first audio track as 16 kHz mono, cut into pieces as it streams (a long file never sits
    /// in memory whole).
    static func importReadable(_ url: URL, into folder: URL, pieceSeconds: TimeInterval,
                               progress: @Sendable (TimeInterval) -> Void) throws -> TimeInterval {
        let asset = AVURLAsset(url: url)
        let tracks = try syncLoad { try await asset.loadTracks(withMediaType: .audio) }
        guard let track = tracks.first else { throw ImportError("no sound in the file") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: PieceMixer.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ImportError("the file cannot be read") }

        let perPiece = Int(pieceSeconds * PieceMixer.sampleRate)
        var samples: [Float] = []
        samples.reserveCapacity(perPiece)
        var index = 0
        var total = 0
        func flush() throws {
            guard !samples.isEmpty else { return }
            index += 1
            try writePiece(samples, index: index, into: folder)
            total += samples.count
            samples.removeAll(keepingCapacity: true)
            progress(Double(total) / PieceMixer.sampleRate)
        }
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            _ = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            var start = 0
            while start < chunk.count {
                let take = min(perPiece - samples.count, chunk.count - start)
                samples += chunk[start..<start + take]
                start += take
                if samples.count >= perPiece { try flush() }
            }
        }
        if reader.status == .failed { throw reader.error ?? ImportError("reading stopped") }
        try flush()
        guard total > 0 else { throw ImportError("no sound in the file") }
        return Double(total) / PieceMixer.sampleRate
    }

    /// One piece: the mix only, the speech as `others` (the speakers come from the transcript).
    static func writePiece(_ samples: [Float], index: Int, into folder: URL) throws {
        let out = folder.appending(path: PieceMixer.pieceName(index))
        try PieceMixer.write(samples, to: out)
        let info = PieceInfo(duration: Double(samples.count) / PieceMixer.sampleRate, me: [],
                             others: SpeechSpans.spans(levels: PieceMixer.levels(samples), window: PieceMixer.levelWindow))
        try JSONEncoder().encode(info).write(to: out.deletingPathExtension().appendingPathExtension("json"), options: .atomic)
    }

    /// `ffmpeg` from Homebrew or MacPorts (an app from Finder has no shell PATH).
    public static func findFFmpeg() -> URL? {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(filePath: $0) }
    }

    static func convert(_ url: URL, to wav: URL, ffmpeg: URL) throws {
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", url.path,
                             "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", wav.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ImportError("ffmpeg could not read \(url.lastPathComponent): \(text.split(separator: "\n").last.map(String.init) ?? "exit \(process.terminationStatus)")")
        }
    }

    /// Runs an async load on a background thread and waits (the import itself runs detached).
    static func syncLoad<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
        nonisolated(unsafe) var result: Result<T, Error>?
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do { result = .success(try await work()) } catch { result = .failure(error) }
            done.signal()
        }
        done.wait()
        return try result!.get()
    }
}
