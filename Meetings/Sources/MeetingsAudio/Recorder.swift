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
    /// What went wrong while it recorded (a source that stopped, a write, a piece that did not
    /// mix): shown at once and kept on the meeting by `stop()`.
    private var problems: [String] = []
    private var configObserver: NSObjectProtocol?
    private var recordingLock: MeetingLock?
    private var running = false
    public private(set) var startedAt: Date?
    /// The last ~4 s of loudness per source (0…1, newest last), for the screen's live waves.
    private var micLevels: [Float] = []
    private var sysLevels: [Float] = []
    public static let levelHistory = 48

    /// `lock`: the recording lock, when the caller took it already (right after creating the
    /// meeting, so the other host never sees a free lock on a new recording).
    public init(folder: URL, pieceSeconds: TimeInterval = 300, echoCancellation: Bool = true, lock: MeetingLock? = nil,
                problem: @escaping @Sendable (String) -> Void = { _ in }) {
        recordingLock = lock
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
        MeetingsLog.info(.recorder, "microphone permission: \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) (3 = allowed)")
        guard await Self.microphoneAllowed() else {
            throw TapError("Microphone access is off. Turn it on in System Settings → Privacy & Security → Microphone.")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if recordingLock == nil {
            guard let held = MeetingLock.take(Self.lockFile(folder)) else {
                throw TapError("This meeting is recording in the other Meetings app.")
            }
            recordingLock = held
        }
        let report: @Sendable (String) -> Void = { [weak self] text in self?.report(text) }
        let level: @Sendable (PieceMixer.Source, AVAudioPCMBuffer) -> Void = { [weak self] source, buffer in self?.noteLevel(source, buffer) }
        let startHost = mach_absolute_time()
        let pieceDone: @Sendable (PieceMixer.Source, Int) -> Void = { [weak self] source, index in self?.closed(source, index) }
        let micWriter = PieceWriter(folder: folder, source: .mic, pieceSeconds: pieceSeconds, startHost: startHost, closed: pieceDone, problem: report)
        let systemWriter = PieceWriter(folder: folder, source: .sys, pieceSeconds: pieceSeconds, startHost: startHost, closed: pieceDone, problem: report)
        mic = micWriter
        system = systemWriter
        do {
            try startMicrophone()
            try tap.start(handler: { buffer, host in
                systemWriter.append(buffer, hostTime: host)
                level(.sys, buffer)
            }, problem: report)
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
        MeetingsLog.info(.recorder, "started in \(folder.deletingLastPathComponent().lastPathComponent): mic \(engine.inputNode.outputFormat(forBus: 0)), echo cancellation \(echoCancellation)")
    }

    private func startMicrophone() throws {
        let input = engine.inputNode
        // A try that failed after installTap left its tap; a second installTap would raise.
        input.removeTap(onBus: 0)
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
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { [weak self] buffer, when in
            writer?.append(buffer, hostTime: when.isHostTimeValid ? when.hostTime : nil)
            self?.noteLevel(.mic, buffer)
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
        MeetingsLog.info(.recorder, "audio configuration changed: restarting the microphone")
        for delay in [0.0, 0.3, 0.7, 1.5] {
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            if (try? startMicrophone()) != nil {
                MeetingsLog.info(.recorder, "microphone restarted: \(engine.inputNode.outputFormat(forBus: 0))")
                return
            }
        }
        report("The microphone stopped after the audio device changed. Stop and Record again to record your voice.")
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
        let problems = lock.withLock { self.problems } + last
        let seconds = Self.recordedSeconds(in: folder)
        MeetingsLog.info(.recorder, "stopped: \(Int(seconds)) s in pieces, \(problems.count) problem(s)")
        return (seconds, problems)
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
            guard let self else { return }
            for text in problems { self.report(text) }
        }
    }

    /// The loudness of one buffer: RMS of the first channel (the voice of a voice-processing
    /// mic), shaped so speech fills the wave and silence stays flat.
    static func loudness(_ buffer: AVAudioPCMBuffer) -> Float {
        guard buffer.format.commonFormat == .pcmFormatFloat32, let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let stride = buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<count { let v = data[0][i * stride]; sum += v * v }
        let rms = (sum / Float(count)).squareRoot()
        return rms < 0.002 ? 0 : min(1, rms.squareRoot() * 2.2)
    }

    private func noteLevel(_ source: PieceMixer.Source, _ buffer: AVAudioPCMBuffer) {
        let value = Self.loudness(buffer)
        lock.withLock {
            if source == .mic {
                micLevels.append(value)
                if micLevels.count > Self.levelHistory { micLevels.removeFirst(micLevels.count - Self.levelHistory) }
            } else {
                sysLevels.append(value)
                if sysLevels.count > Self.levelHistory { sysLevels.removeFirst(sysLevels.count - Self.levelHistory) }
            }
        }
    }

    /// The recent loudness of the microphone and of the system sound, newest last.
    public var levels: (mic: [Float], system: [Float]) { lock.withLock { (micLevels, sysLevels) } }

    private func report(_ text: String) {
        MeetingsLog.error(.recorder, text)
        let new = lock.withLock { () -> Bool in
            guard !problems.contains(text) else { return false }
            problems.append(text)
            return true
        }
        if new { problem(text) }
    }

    public static func lockFile(_ folder: URL) -> URL { folder.appending(path: ".recording.lock") }

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
        guard let held = MeetingLock.take(lockFile(folder)) else { return nil }
        defer { held.release() }
        let problems = PieceMixer.mixPending(in: folder).problems
        return (recordedSeconds(in: folder), problems)
    }
}
