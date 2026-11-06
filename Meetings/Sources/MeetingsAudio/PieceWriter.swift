import AVFoundation
import Foundation

/// Writes one source's buffers into raw piece files in the source's own format, and starts the
/// next piece after `pieceSeconds` of its frames (M6). A new format (another output device) opens
/// a new part of the same piece. Callers write from one thread at a time per writer.
final class PieceWriter: @unchecked Sendable {
    let folder: URL
    let source: PieceMixer.Source
    let pieceSeconds: TimeInterval
    /// Called with a piece's index after it is closed.
    let closed: @Sendable (PieceMixer.Source, Int) -> Void
    private var file: AVAudioFile?
    private var index = 1
    private var part = 0
    private var frames: AVAudioFramePosition = 0
    private var stopped = false
    private let lock = NSLock()

    init(folder: URL, source: PieceMixer.Source, pieceSeconds: TimeInterval, startIndex: Int = 1, closed: @escaping @Sendable (PieceMixer.Source, Int) -> Void) {
        self.folder = folder
        self.source = source
        self.pieceSeconds = pieceSeconds
        index = startIndex
        self.closed = closed
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped, buffer.frameLength > 0 else { return }
        do {
            if let current = file, current.processingFormat != buffer.format {
                current.close()
                file = nil
            }
            if file == nil {
                part += 1
                let url = folder.appending(path: PieceMixer.rawName(source, index: index, part: part))
                file = try AVAudioFile(forWriting: url, settings: buffer.format.settings,
                                       commonFormat: buffer.format.commonFormat, interleaved: buffer.format.isInterleaved)
            }
            try file?.write(from: buffer)
            frames += AVAudioFramePosition(buffer.frameLength)
            if Double(frames) / buffer.format.sampleRate >= pieceSeconds {
                closeLocked()
                index += 1
            }
        } catch {
            // A write that fails drops this buffer; the next one opens a new part.
            file?.close()
            file = nil
        }
    }

    private func closeLocked() {
        file?.close()
        file = nil
        if part > 0 { closed(source, index) }
        part = 0
        frames = 0
    }

    /// Closes the open piece; later buffers are ignored.
    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        stopped = true
        closeLocked()
    }
}
