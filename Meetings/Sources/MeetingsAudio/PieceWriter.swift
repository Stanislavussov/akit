@preconcurrency import AVFoundation
import Foundation

/// Writes one source's buffers into raw piece files in the source's own format (M6). All sources
/// count time from the recording's common start (`startHost`): a gap before the first buffer or
/// between two buffers (a device switch, a restart, a dropped write) is written as silence, so
/// piece N of every source covers the same minutes and the mix stays in step. A piece ends after
/// `pieceSeconds`; a new format (another device) opens a new part of the same piece.
final class PieceWriter: @unchecked Sendable {
    let folder: URL
    let source: PieceMixer.Source
    let pieceSeconds: TimeInterval
    /// Called with a piece's index after it is closed.
    let closed: @Sendable (PieceMixer.Source, Int) -> Void
    /// Called once per failure kind with a sentence for the screen.
    let problem: @Sendable (String) -> Void
    private var file: AVAudioFile?
    private var index = 1
    private var part = 0
    /// Seconds written into the open piece.
    private var written: TimeInterval = 0
    /// The host time the next buffer should start at; gaps before it are silence.
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
        let length = Double(buffer.frameLength) / buffer.format.sampleRate
        if let hostTime, let expected = nextHost {
            let gap = AVAudioTime.seconds(forHostTime: hostTime) - AVAudioTime.seconds(forHostTime: expected)
            if gap > 0.05, gap < Self.longestGap { writeSilence(gap, format: buffer.format) }
        }
        if let hostTime { nextHost = hostTime + AVAudioTime.hostTime(forSeconds: length) }
        if let until = blockedUntil, until > Date() { return }
        blockedUntil = nil
        write(buffer, length: length)
    }

    private func write(_ buffer: AVAudioPCMBuffer, length: TimeInterval) {
        do {
            try openFile(buffer.format)
            try file?.write(from: buffer)
            written += length
            if written >= pieceSeconds { rotate() }
        } catch {
            // The next second of buffers is dropped (and later filled as silence), not a new
            // empty part per buffer.
            file?.close()
            file = nil
            blockedUntil = Date().addingTimeInterval(1)
            problem("Could not write the \(source == .mic ? "microphone" : "system sound") audio: \(error.localizedDescription)")
        }
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

    /// Silence of `seconds`, split at piece ends.
    private func writeSilence(_ seconds: TimeInterval, format: AVAudioFormat) {
        var left = seconds
        while left > 0.001 {
            let now = min(left, pieceSeconds - written, 10)
            let frames = AVAudioFrameCount((now * format.sampleRate).rounded())
            guard frames > 0, let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { break }
            silence.frameLength = frames
            for buffer in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            write(silence, length: Double(frames) / format.sampleRate)
            left -= now
            if blockedUntil != nil { break }
        }
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
