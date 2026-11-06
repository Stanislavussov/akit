import AVFoundation
import Foundation
import MeetingsCore

/// One recording (M2, M6): the microphone and the system sound, each into its own raw pieces;
/// a piece that both sources closed is mixed at once on a background queue, the rest at Stop.
public final class Recorder: @unchecked Sendable {
    public let folder: URL
    let pieceSeconds: TimeInterval
    let echoCancellation: Bool
    private let engine = AVAudioEngine()
    private let tap = SystemAudioTap()
    private var mic: PieceWriter!
    private var system: PieceWriter!
    private let mixQueue = DispatchQueue(label: "meetings.mix", qos: .utility)
    private let lock = NSLock()
    private var closedPieces: [PieceMixer.Source: Set<Int>] = [:]
    public private(set) var startedAt: Date?

    public init(folder: URL, pieceSeconds: TimeInterval = 300, echoCancellation: Bool = true) {
        self.folder = folder
        self.pieceSeconds = pieceSeconds
        self.echoCancellation = echoCancellation
    }

    /// Asks for the microphone if macOS has not asked yet. False when it is denied.
    public static func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    public func start() async throws {
        guard await Self.microphoneAllowed() else {
            throw TapError("Microphone access is off. Turn it on in System Settings → Privacy & Security → Microphone.")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let first = (PieceMixer.rawFiles(in: folder).keys.max() ?? 0) + 1
        let pieceDone: @Sendable (PieceMixer.Source, Int) -> Void = { [weak self] source, index in self?.closed(source, index) }
        mic = PieceWriter(folder: folder, source: .mic, pieceSeconds: pieceSeconds, startIndex: max(first, nextPieceIndex()), closed: pieceDone)
        system = PieceWriter(folder: folder, source: .sys, pieceSeconds: pieceSeconds, startIndex: max(first, nextPieceIndex()), closed: pieceDone)

        let input = engine.inputNode
        if echoCancellation {
            do {
                try input.setVoiceProcessingEnabled(true)
                // Do not turn the call's sound down while we record.
                input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
            } catch {
                try? input.setVoiceProcessingEnabled(false)
            }
        }
        let format = input.outputFormat(forBus: 0)
        let micWriter = mic!
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { buffer, _ in micWriter.append(buffer) }
        engine.prepare()
        try engine.start()

        let systemWriter = system!
        do {
            try tap.start { buffer in systemWriter.append(buffer) }
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            throw error
        }
        startedAt = Date()
    }

    /// Stops both sources and mixes every piece left. Returns the recorded seconds.
    public func stop() async -> TimeInterval {
        tap.stop()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        mic?.stop()
        system?.stop()
        let folder = self.folder
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            mixQueue.async {
                PieceMixer.mixPending(in: folder)
                done.resume()
            }
        }
        return Self.recordedSeconds(in: folder)
    }

    /// The pieces mixed so far plus the open ones, for the elapsed time.
    public var elapsed: TimeInterval { startedAt.map { Date().timeIntervalSince($0) } ?? 0 }

    func nextPieceIndex() -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let last = names.compactMap { name -> Int? in
            guard name.hasPrefix("piece-"), name.hasSuffix(".aac") else { return nil }
            return Int(name.dropFirst(6).dropLast(4))
        }.max() ?? 0
        return last + 1
    }

    private func closed(_ source: PieceMixer.Source, _ index: Int) {
        lock.lock()
        closedPieces[source, default: []].insert(index)
        let ready = (closedPieces[.mic] ?? []).intersection(closedPieces[.sys] ?? [])
        closedPieces[.mic]?.subtract(ready)
        closedPieces[.sys]?.subtract(ready)
        lock.unlock()
        guard !ready.isEmpty else { return }
        let folder = self.folder
        mixQueue.async { PieceMixer.mixPending(in: folder, only: ready) }
    }

    /// The sum of the mixed pieces' lengths.
    public static func recordedSeconds(in folder: URL) -> TimeInterval {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasPrefix("piece-") && $0.hasSuffix(".json") }.reduce(0) { sum, name in
            guard let data = try? Data(contentsOf: folder.appending(path: name)),
                  let info = try? JSONDecoder().decode(PieceInfo.self, from: data) else { return sum }
            return sum + info.duration
        }
    }

    /// A recording that was not stopped (AKit quit or crashed): its raw pieces are mixed now.
    public static func recover(folder: URL) -> TimeInterval {
        PieceMixer.mixPending(in: folder)
        return recordedSeconds(in: folder)
    }
}
