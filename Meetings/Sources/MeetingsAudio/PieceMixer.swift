@preconcurrency import AVFoundation
import Foundation
import MeetingsCore

/// Raw pieces → one mixed piece (M6, M12). While it records, each source writes its own raw
/// files in its own format: `raw-mic-003-1.caf`, `raw-sys-003-1.caf` (a second part `-2` when a
/// source restarts, for example on a new output device). A piece is mixed when both sources
/// closed it: both are read at 16 kHz mono, the microphone's speech spans are found, the sum is
/// written as AAC in ADTS (`piece-003.aac`, joinable by bytes) with `piece-003.json`, and the raw
/// files are removed.
public enum PieceMixer {
    public static let sampleRate = 16_000.0
    static let levelWindow = 0.1

    public enum Source: String, Sendable { case mic, sys }

    public static func rawName(_ source: Source, index: Int, part: Int) -> String {
        String(format: "raw-%@-%03d-%d.caf", source.rawValue, index, part)
    }

    static func pieceName(_ index: Int) -> String { String(format: "piece-%03d.aac", index) }

    /// Raw files by piece index and source, parts in order.
    static func rawFiles(in folder: URL) -> [Int: [Source: [URL]]] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var result: [Int: [Source: [URL]]] = [:]
        for name in names.sorted() where name.hasPrefix("raw-") && name.hasSuffix(".caf") {
            let parts = name.dropLast(4).split(separator: "-")
            guard parts.count == 4, let source = Source(rawValue: String(parts[1])), let index = Int(parts[2]) else { continue }
            result[index, default: [:]][source, default: []].append(folder.appending(path: name))
        }
        for (index, sources) in result {
            for (source, urls) in sources {
                result[index]![source] = urls.sorted { partNumber($0) < partNumber($1) }
            }
        }
        return result
    }

    static func partNumber(_ url: URL) -> Int { Int(url.deletingPathExtension().lastPathComponent.split(separator: "-").last ?? "") ?? 0 }

    /// Mixes every piece that has raw files (all of them, or only `indices`). Used after a piece
    /// closes, at Stop, and for a recording that was not stopped (a crash).
    @discardableResult
    public static func mixPending(in folder: URL, only indices: Set<Int>? = nil) -> [Int] {
        var done: [Int] = []
        for (index, sources) in rawFiles(in: folder).sorted(by: { $0.key < $1.key }) where indices?.contains(index) ?? true {
            do {
                try mix(mic: sources[.mic] ?? [], system: sources[.sys] ?? [], into: folder, index: index)
                done.append(index)
            } catch {
                // An unreadable raw file (empty, cut by a crash) is left for a look; the next
                // pieces still mix.
                continue
            }
        }
        return done
    }

    /// One piece. A missing source counts as silence.
    @discardableResult
    public static func mix(mic: [URL], system: [URL], into folder: URL, index: Int) throws -> PieceInfo {
        let micSamples = try mic.flatMap { try load($0) }
        let sysSamples = try system.flatMap { try load($0) }
        let count = max(micSamples.count, sysSamples.count)
        var mixed = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let value = (i < micSamples.count ? micSamples[i] : 0) + (i < sysSamples.count ? sysSamples[i] : 0)
            mixed[i] = min(1, max(-1, value))
        }
        let info = PieceInfo(duration: Double(count) / sampleRate,
                             me: SpeechSpans.spans(levels: levels(micSamples), window: levelWindow))
        let out = folder.appending(path: pieceName(index))
        try write(mixed, to: out)
        try JSONEncoder().encode(info).write(to: out.deletingPathExtension().appendingPathExtension("json"), options: .atomic)
        for url in mic + system { try? FileManager.default.removeItem(at: url) }
        return info
    }

    /// RMS of each `levelWindow`.
    static func levels(_ samples: [Float]) -> [Float] {
        let size = Int(sampleRate * levelWindow)
        guard size > 0, !samples.isEmpty else { return [] }
        return stride(from: 0, to: samples.count, by: size).map { start in
            let end = min(start + size, samples.count)
            var sum: Float = 0
            for i in start..<end { sum += samples[i] * samples[i] }
            return (sum / Float(end - start)).squareRoot()
        }
    }

    static let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!

    /// A file at 16 kHz mono.
    public static func load(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let inFormat = file.processingFormat
        guard file.length > 0 else { return [] }
        guard let converter = AVAudioConverter(from: inFormat, to: monoFormat) else {
            throw NSError(domain: "Meetings", code: 1, userInfo: [NSLocalizedDescriptionKey: "no converter from \(inFormat)"])
        }
        converter.downmix = true
        let inCapacity: AVAudioFrameCount = 16_384
        guard let buffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: inCapacity) else { return [] }
        nonisolated(unsafe) let input = buffer
        let outCapacity = AVAudioFrameCount(Double(inCapacity) * sampleRate / inFormat.sampleRate) + 2_048
        var result: [Float] = []
        result.reserveCapacity(Int(Double(file.length) * sampleRate / inFormat.sampleRate) + 1)
        nonisolated(unsafe) var finished = false
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: outCapacity) else { break }
            var failure: NSError?
            let status = converter.convert(to: output, error: &failure) { _, outStatus in
                if finished {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                do { try file.read(into: input, frameCount: inCapacity) } catch { input.frameLength = 0 }
                if input.frameLength == 0 {
                    finished = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return input
            }
            if let failure { throw failure }
            if let data = output.floatChannelData, output.frameLength > 0 {
                result.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
            }
            if status == .endOfStream || status == .error { break }
        }
        return result
    }

    /// 16 kHz mono AAC in an ADTS file (the `.aac` extension picks ADTS).
    static func write(_ samples: [Float], to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let block = 16_000
        var start = 0
        while start < samples.count {
            let count = min(block, samples.count - start)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(count)) else { break }
            buffer.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { source in
                buffer.floatChannelData![0].update(from: source.baseAddress! + start, count: count)
            }
            try file.write(from: buffer)
            start += count
        }
        file.close()
    }
}
