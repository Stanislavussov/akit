@preconcurrency import AVFoundation
import Foundation

/// Writes one source's buffers into raw piece files in the source's own format (M6). All sources
/// count time from the recording's common start (`startHost`): a gap before the first buffer or
/// between two buffers (a device switch, a restart, buffers dropped after a write error) is
/// written as silence. Every piece is exactly `pieceSeconds` long (a buffer that crosses the end
/// is split there), so piece N of every source covers the same minutes and the mix stays in step.
/// A new format (another device) opens a new part of the same piece.
final class PieceWriter: @unchecked Sendable {
    let folder: URL
    let source: PieceMixer.Source
    let pieceSeconds: TimeInterval
    /// Called with a piece's index after it is closed.
    let closed: @Sendable (PieceMixer.Source, Int) -> Void
    /// Called with a sentence for the screen when writing fails.
    let problem: @Sendable (String) -> Void
    private var file: AVAudioFile?
    private var index = 1
    private var part = 0
    /// Seconds written into the open piece (sums of whole frames / rate).
    private var written: TimeInterval = 0
    /// The host time the next buffer should start at; a gap before it is silence. It moves only
    /// after a write, so buffers dropped while writing is blocked are filled later.
    private var nextHost: UInt64?
    private var blockedUntil: Date?
    private var stopped = false
    private let lock = NSLock()
    /// A gap longer than this is not filled (a clock jump, not a real gap).
    static let longestGap: TimeInterval = 3_600

    init(folder: URL, source: PieceMixer.Source, pieceSeconds: TimeInterval, startHost: UInt64? = nil,
         closed: @escaping @Sendable (PieceMixer.Source, Int) -> Void, problem: @escaping @Sendable (String) -> Void = { _ in }) {
        self.folder = folder
        self.source = source
        self.pieceSeconds = pieceSeconds
        nextHost = startHost
        self.closed = closed
        self.problem = problem
    }

    /// A buffer and the host time its first frame was heard (nil: right after the last one).
    func append(_ buffer: AVAudioPCMBuffer, hostTime: UInt64? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped, buffer.frameLength > 0 else { return }
        if let until = blockedUntil, until > Date() { return }
        blockedUntil = nil
        if let hostTime, let expected = nextHost {
            let gap = AVAudioTime.seconds(forHostTime: hostTime) - AVAudioTime.seconds(forHostTime: expected)
            if gap > 0.05, gap < Self.longestGap {
                guard writeSilence(gap, format: buffer.format) else { return }
            }
        }
        if nextHost == nil, let hostTime { nextHost = hostTime }
        // `write` moves `nextHost` by every slice it wrote, so after a failure the next gap counts
        // only what is missing from the file.
        guard write(buffer) else { return }
        if let hostTime {
            nextHost = hostTime + AVAudioTime.hostTime(forSeconds: Double(buffer.frameLength) / buffer.format.sampleRate)
        }
    }

    /// Frames still to write into the open piece at this rate.
    private func framesLeft(_ rate: Double) -> Int {
        Int(((pieceSeconds - written) * rate).rounded())
    }

    /// The buffer, split at piece ends. False when writing failed (then blocked for a second).
    private func write(_ buffer: AVAudioPCMBuffer) -> Bool {
        let total = Int(buffer.frameLength)
        let rate = buffer.format.sampleRate
        var offset = 0
        do {
            while offset < total {
                let left = framesLeft(rate)
                if left <= 0 {
                    rotate()
                    continue
                }
                let count = min(left, total - offset)
                let slice = offset == 0 && count == total ? buffer : try Self.slice(buffer, from: offset, count: count)
                try openFile(buffer.format)
                try file?.write(from: slice)
                written += Double(count) / rate
                if let next = nextHost { nextHost = next + AVAudioTime.hostTime(forSeconds: Double(count) / rate) }
                offset += count
                if framesLeft(rate) <= 0 { rotate() }
            }
            return true
        } catch {
            file?.close()
            file = nil
            blockedUntil = Date().addingTimeInterval(1)
            problem("Could not write the \(source == .mic ? "microphone" : "system sound") audio: \(error.localizedDescription)")
            return false
        }
    }

    /// `count` frames of `buffer` from `offset`, for any PCM layout (each AudioBuffer holds whole
    /// frames: all channels when interleaved, one channel each when not).
    static func slice(_ buffer: AVAudioPCMBuffer, from offset: Int, count: Int) throws -> AVAudioPCMBuffer {
        guard let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(count)) else {
            throw TapError("no buffer for \(count) frames")
        }
        out.frameLength = AVAudioFrameCount(count)
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let target = UnsafeMutableAudioBufferListPointer(out.mutableAudioBufferList)
        for (from, to) in zip(source, target) {
            guard let src = from.mData, let dst = to.mData, buffer.frameLength > 0 else { continue }
            let bytesPerFrame = Int(from.mDataByteSize) / Int(buffer.frameLength)
            memcpy(dst, src + offset * bytesPerFrame, count * bytesPerFrame)
        }
        return out
    }

    private func openFile(_ format: AVAudioFormat) throws {
        if let current = file, current.processingFormat != format {
            current.close()
            file = nil
        }
        guard file == nil else { return }
        part += 1
        let url = folder.appending(path: PieceMixer.rawName(source, index: index, part: part))
        file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
    }

    /// Silence of `seconds` in whole frames, in blocks of up to 10 s; split at piece ends by `write`.
    private func writeSilence(_ seconds: TimeInterval, format: AVAudioFormat) -> Bool {
        var frames = Int((seconds * format.sampleRate).rounded())
        let block = Int(10 * format.sampleRate)
        while frames > 0 {
            let count = min(frames, block)
            guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return false }
            silence.frameLength = AVAudioFrameCount(count)
            for buffer in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            guard write(silence) else { return false }
            frames -= count
        }
        return true
    }

    private func rotate() {
        file?.close()
        file = nil
        if part > 0 { closed(source, index) }
        index += 1
        part = 0
        written = 0
    }

    /// Closes the open piece; later buffers are ignored.
    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        stopped = true
        file?.close()
        file = nil
        if part > 0 { closed(source, index) }
    }
}
