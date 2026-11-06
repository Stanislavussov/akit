@preconcurrency import AVFoundation
import Foundation
import MeetingsCore

/// One recording (M2, M6): the microphone and the system sound, each into its own raw pieces
/// counted from one common start; a piece that both sources closed is mixed at once on a
/// background queue, the rest at Stop. While it records it holds the meeting's recording lock,
/// so the other Meetings host does not take the recording for a crashed one.
public final class Recorder: @unchecked Sendable {
    public let folder: URL
    let pieceSeconds: TimeInterval
    let echoCancellation: Bool
    /// A sentence for the screen when a source stops or a piece cannot be written or mixed.
    let problem: @Sendable (String) -> Void
    private let engine = AVAudioEngine()
    private let tap = SystemAudioTap()
    private var mic: PieceWriter?
    private var system: PieceWriter?
    private let mixQueue = DispatchQueue(label: "meetings.mix", qos: .utility)
    private let micQueue = DispatchQueue(label: "meetings.mic-restart")
    private let lock = NSLock()
    private var closedPieces: [PieceMixer.Source: Set<Int>] = [:]
    private var mixProblems: [String] = []
    private var configObserver: NSObjectProtocol?
    private var recordingLock: MeetingLock?
    private var running = false
    public private(set) var startedAt: Date?

    public init(folder: URL, pieceSeconds: TimeInterval = 300, echoCancellation: Bool = true,
                problem: @escaping @Sendable (String) -> Void = { _ in }) {
        self.folder = folder
        self.pieceSeconds = pieceSeconds
        self.echoCancellation = echoCancellation
        self.problem = problem
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
        guard let held = MeetingLock.take(folder.appending(path: ".recording.lock")) else {
            throw TapError("This meeting is recording in the other Meetings app.")
        }
        recordingLock = held
        let startHost = mach_absolute_time()
        let pieceDone: @Sendable (PieceMixer.Source, Int) -> Void = { [weak self] source, index in self?.closed(source, index) }
        let micWriter = PieceWriter(folder: folder, source: .mic, pieceSeconds: pieceSeconds, startHost: startHost, closed: pieceDone, problem: problem)
        let systemWriter = PieceWriter(folder: folder, source: .sys, pieceSeconds: pieceSeconds, startHost: startHost, closed: pieceDone, problem: problem)
        mic = micWriter
        system = systemWriter
        do {
            try startMicrophone()
            try tap.start(handler: { buffer, host in systemWriter.append(buffer, hostTime: host) }, problem: problem)
        } catch {
            stopMicrophone()
            await tap.stop()
            recordingLock?.release()
            recordingLock = nil
            throw error
        }
        // H3: AirPods, a call's Bluetooth profile, another input or a wake from sleep stop the
        // engine; it is set up again on the new device and the gap becomes silence.
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.micQueue.async { self.restartMicrophone() }
        }
        running = true
        startedAt = Date()
    }

    private func startMicrophone() throws {
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
        guard format.sampleRate > 0, format.channelCount > 0 else { throw TapError("No microphone is available.") }
        let writer = mic
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { buffer, when in
            writer?.append(buffer, hostTime: when.isHostTimeValid ? when.hostTime : nil)
        }
        engine.prepare()
        try engine.start()
    }

    private func stopMicrophone() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func restartMicrophone() {
        lock.lock()
        let isRunning = running
        lock.unlock()
        guard isRunning else { return }
        stopMicrophone()
        for delay in [0.0, 0.3, 0.7, 1.5] {
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            if (try? startMicrophone()) != nil { return }
        }
        problem("The microphone stopped after the audio device changed. Stop and Record again to record your voice.")
    }

    /// Stops both sources and mixes every piece left. Returns the recorded seconds and what could
    /// not be mixed.
    public func stop() async -> (seconds: TimeInterval, problems: [String]) {
        lock.withLock { running = false }
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        await tap.stop()
        micQueue.sync {}
        stopMicrophone()
        mic?.stop()
        system?.stop()
        let folder = self.folder
        let last: [String] = await withCheckedContinuation { done in
            mixQueue.async { done.resume(returning: PieceMixer.mixPending(in: folder).problems) }
        }
        recordingLock?.release()
        recordingLock = nil
        let problems = lock.withLock { mixProblems } + last
        return (Self.recordedSeconds(in: folder), problems)
    }

    /// H1: a recorder released while it records (its window closed) stops its devices.
    deinit {
        if running {
            if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            mic?.stop()
            system?.stop()
        }
    }

    public var elapsed: TimeInterval { startedAt.map { Date().timeIntervalSince($0) } ?? 0 }

    private func closed(_ source: PieceMixer.Source, _ index: Int) {
        lock.lock()
        closedPieces[source, default: []].insert(index)
        let ready = (closedPieces[.mic] ?? []).intersection(closedPieces[.sys] ?? [])
        closedPieces[.mic]?.subtract(ready)
        closedPieces[.sys]?.subtract(ready)
        lock.unlock()
        guard !ready.isEmpty else { return }
        let folder = self.folder
        mixQueue.async { [weak self] in
            let problems = PieceMixer.mixPending(in: folder, only: ready).problems
            guard !problems.isEmpty, let self else { return }
            self.lock.withLock { self.mixProblems += problems }
            for text in problems { self.problem(text) }
        }
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

    /// A recording that was not stopped (AKit quit or crashed): its raw pieces are mixed now. Nil
    /// when another host still records it (its lock is held).
    public static func recover(folder: URL) -> (seconds: TimeInterval, problems: [String])? {
        guard let held = MeetingLock.take(folder.appending(path: ".recording.lock")) else { return nil }
        defer { held.release() }
        let problems = PieceMixer.mixPending(in: folder).problems
        return (recordedSeconds(in: folder), problems)
    }
}
