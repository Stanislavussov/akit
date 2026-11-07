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
    /// The first piece's number: 1 for a new meeting, after the last piece for Record More.
    let firstPiece: Int
    /// Called on a background queue after pieces are mixed while it records (they can be
    /// transcribed before Stop).
    let piecesMixed: @Sendable () -> Void
    /// Replaced by a new one when the microphone sends nothing (`MicWatch`); changed only on
    /// `micQueue` while it records.
    private var engine = AVAudioEngine()
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
    /// M32: how many buffers the microphone sent, and the check that it still sends.
    private var micBuffers = 0
    private var micWatch = MicWatch()
    private var micTimer: DispatchSourceTimer?
    private var sysLevels: [Float] = []
    public static let levelHistory = 48

    /// `lock`: the recording lock, when the caller took it already (right after creating the
    /// meeting, so the other host never sees a free lock on a new recording).
    public init(folder: URL, pieceSeconds: TimeInterval = 300, echoCancellation: Bool = true, lock: MeetingLock? = nil,
                firstPiece: Int = 1, piecesMixed: @escaping @Sendable () -> Void = {},
                problem: @escaping @Sendable (String) -> Void = { _ in }) {
        recordingLock = lock
        self.firstPiece = firstPiece
        self.piecesMixed = piecesMixed
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
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        MeetingsLog.info(.recorder, "microphone permission: \(status.rawValue) (3 = allowed)")
        guard await Self.microphoneAllowed() else {
            throw TapError("Microphone access is off. Turn it on in System Settings → Privacy & Security → Microphone.")
        }
        // M32: an engine made before the access was given can stay silent (2026-11-07: 17 min
        // with no microphone buffer after the first question), so a new one is made.
        if status == .notDetermined { engine = AVAudioEngine() }
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
        let micWriter = PieceWriter(folder: folder, source: .mic, pieceSeconds: pieceSeconds, startHost: startHost, firstIndex: firstPiece, closed: pieceDone, problem: report)
        let systemWriter = PieceWriter(folder: folder, source: .sys, pieceSeconds: pieceSeconds, startHost: startHost, firstIndex: firstPiece, closed: pieceDone, problem: report)
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
        observeConfiguration()
        lock.withLock { running = true }
        startedAt = Date()
        MeetingsLog.info(.recorder, "started in \(folder.deletingLastPathComponent().lastPathComponent): mic \(engine.inputNode.outputFormat(forBus: 0)), echo cancellation \(echoCancellation)")
        startMicWatch()
    }

    private func observeConfiguration() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.micQueue.async { self.restartMicrophone(reason: "audio configuration changed") }
        }
    }

    /// M32: every few seconds, checks that the microphone still sends buffers. A voice-processing
    /// tap sends buffers in silence too, so no buffer means the engine stopped, not a quiet room.
    private func startMicWatch() {
        let timer = DispatchSource.makeTimerSource(queue: micQueue)
        timer.schedule(deadline: .now() + MicWatch.interval, repeating: MicWatch.interval)
        timer.setEventHandler { [weak self] in self?.checkMicrophone() }
        micTimer = timer
        timer.resume()
    }

    private func checkMicrophone() {
        let (isRunning, buffers) = lock.withLock { (running, micBuffers) }
        guard isRunning else { return }
        switch micWatch.check(buffers: buffers) {
        case .none: break
        case .restart: restartMicrophone(reason: "no microphone sound for \(Int(MicWatch.interval)) s (\(buffers) buffer(s) in all)", fresh: true)
        case .report:
            report("The microphone sends no sound, so your voice is not recorded. Stop, check the input in System Settings → Sound, and Record again.")
        }
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

    /// On `micQueue`. `fresh`: a new engine, for one that stays silent.
    private func restartMicrophone(reason: String, fresh: Bool = false) {
        guard lock.withLock({ running }) else { return }
        stopMicrophone()
        MeetingsLog.info(.recorder, "\(reason): restarting the microphone\(fresh ? " on a new engine" : "")")
        if fresh {
            engine = AVAudioEngine()
            observeConfiguration()
        }
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
        micQueue.sync {
            micTimer?.cancel()
            micTimer = nil
            if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
            configObserver = nil
        }
        await tap.stop()
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
            micTimer?.cancel()
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
            let result = PieceMixer.mixPending(in: folder, only: ready)
            guard let self else { return }
            for text in result.problems { self.report(text) }
            if !result.done.isEmpty, self.lock.withLock({ self.running }) { self.piecesMixed() }
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
                micBuffers += 1
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

/// M32: whether the microphone still sends buffers, checked every `interval`. No new buffer
/// since the last check → restart (at most `restarts` times in a row); then one problem for the
/// screen. A buffer again starts over.
struct MicWatch: Equatable {
    static let interval: TimeInterval = 3
    static let restarts = 3
    private var last = 0
    private var tries = 0
    private var reported = false

    enum Action: Equatable { case none, restart, report }

    mutating func check(buffers: Int) -> Action {
        defer { last = buffers }
        if buffers != last {
            tries = 0
            reported = false
            return .none
        }
        if tries < Self.restarts {
            tries += 1
            return .restart
        }
        if reported { return .none }
        reported = true
        return .report
    }
}
