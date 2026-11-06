import Foundation

/// M23: what the screen controls while a local run works: Pause, Resume, Stop, and whether a
/// recording runs (a call needs the Mac). One per run; the screen and the run share it.
public final class LocalControl: @unchecked Sendable {
    /// Why a run waits.
    public enum Pause: String, Sendable, Equatable {
        /// The user clicked Pause.
        case user
        /// A new recording runs.
        case recording
        /// The Mac is hot (thermal state serious).
        case hot
    }

    private let lock = NSLock()
    private var userPausedValue = false
    private var recordingValue = false
    private var stoppedValue = false

    public init(recording: Bool = false) { recordingValue = recording }

    public var userPaused: Bool {
        get { lock.withLock { userPausedValue } }
        set { lock.withLock { userPausedValue = newValue } }
    }

    public var recording: Bool {
        get { lock.withLock { recordingValue } }
        set { lock.withLock { recordingValue = newValue } }
    }

    /// Stop: the running process is killed and the run ends.
    public var stopped: Bool {
        get { lock.withLock { stoppedValue } }
        set { lock.withLock { stoppedValue = newValue } }
    }

    /// Why a run must wait now, nil when it may work. Heat goes first: it is the reason the user
    /// cannot fix by a click.
    public func pause(_ thermal: ProcessInfo.ThermalState) -> Pause? {
        if thermal == .serious || thermal == .critical { return .hot }
        if recording { return .recording }
        if userPaused { return .user }
        return nil
    }
}

/// What a local run reports to the screen.
public struct LocalStatus: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// Waiting until another meeting's local run ends (one at a time).
        case queued
        /// Working on a piece (`piece` of `pieces`).
        case transcribing
        /// A short rest between pieces, so the Mac is never busy for long.
        case resting
        /// Pi writes the summary.
        case summarizing
        case paused(LocalControl.Pause)
    }

    public var phase: Phase
    /// The piece in work (1-based) and how many there are.
    public var piece: Int
    public var pieces: Int

    public init(phase: Phase, piece: Int = 0, pieces: Int = 0) {
        self.phase = phase
        self.piece = piece
        self.pieces = pieces
    }
}

/// The parts a local run needs from outside: the control, the Mac's heat (a closure, so tests
/// can make it hot) and where to report.
public struct LocalEnvironment: Sendable {
    public var control: LocalControl
    public var thermal: @Sendable () -> ProcessInfo.ThermalState
    public var status: @Sendable (LocalStatus) -> Void
    /// How often a run checks the control and the heat.
    public var tick: Duration

    public init(control: LocalControl = LocalControl(),
                thermal: @escaping @Sendable () -> ProcessInfo.ThermalState = { ProcessInfo.processInfo.thermalState },
                status: @escaping @Sendable (LocalStatus) -> Void = { _ in }, tick: Duration = .milliseconds(500)) {
        self.control = control
        self.thermal = thermal
        self.status = status
        self.tick = tick
    }

    /// Throws when the user stopped the run or the Mac is critically hot.
    func check() throws {
        if control.stopped { throw MeetingsError.stopped }
        if thermal() == .critical { throw MeetingsError.tooHot }
    }

    /// Waits while the run must pause; `phase` is reported again when it may go on.
    func waitWhilePaused(resume phase: LocalStatus, cancelled: @Sendable () -> Bool = { Task.isCancelled }) async throws {
        var reported: LocalControl.Pause?
        while true {
            try check()
            if cancelled() { throw CancellationError() }
            guard let reason = control.pause(thermal()) else { break }
            if reason != reported {
                status(LocalStatus(phase: .paused(reason), piece: phase.piece, pieces: phase.pieces))
                MeetingsLog.info(.local, "paused: \(reason.rawValue)")
                reported = reason
            }
            try await Task.sleep(for: tick)
        }
        if reported != nil {
            MeetingsLog.info(.local, "resumed")
            status(phase)
        }
    }

    /// Rests for `seconds` between pieces, still stopping and pausing on time.
    func rest(_ seconds: TimeInterval, status phase: LocalStatus) async throws {
        status(phase)
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            try await waitWhilePaused(resume: phase)
            try await Task.sleep(for: tick)
        }
    }
}

/// One child process of a local run (`afconvert`, `whisper-cli`, `pi`), started at background
/// priority by `taskpolicy -b` (efficiency cores, low I/O and GPU priority). While it runs, a
/// pause stops it with SIGSTOP and a resume goes on with SIGCONT; Stop, critical heat or a time
/// limit kill it.
public enum ChildRun {
    public struct Result: Sendable {
        public var status: Int32
        public var output: Data
        public var errors: Data
    }

    static let taskpolicy = URL(filePath: "/usr/sbin/taskpolicy")

    /// Collects a pipe's bytes from its reader thread.
    final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func add(_ more: Data) { lock.withLock { data.append(more) } }
        var value: Data { lock.withLock { data } }
    }

    /// Runs `program` with `arguments`. `background`: through `taskpolicy -b`. `pausable`: a
    /// pause stops the process (a network call like Pi's is better left running).
    public static func run(_ program: URL, _ arguments: [String], environment: [String: String]? = nil, directory: URL? = nil,
                           background: Bool = true, pausable: Bool = true, timeout: TimeInterval = 3600,
                           local: LocalEnvironment, resume phase: LocalStatus) async throws -> Result {
        try local.check()
        let process = Process()
        if background && FileManager.default.isExecutableFile(atPath: taskpolicy.path) {
            process.executableURL = taskpolicy
            process.arguments = ["-b", program.path] + arguments
        } else {
            process.executableURL = program
            process.arguments = arguments
        }
        if let environment { process.environment = environment }
        if let directory { process.currentDirectoryURL = directory }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        let output = Sink(), errors = Sink()
        out.fileHandleForReading.readabilityHandler = { handle in output.add(handle.availableData) }
        err.fileHandleForReading.readabilityHandler = { handle in errors.add(handle.availableData) }
        try process.run()
        let pid = process.processIdentifier
        let started = Date()
        var paused: LocalControl.Pause?
        do {
            while process.isRunning {
                if local.control.stopped { throw MeetingsError.stopped }
                if local.thermal() == .critical { throw MeetingsError.tooHot }
                if Task.isCancelled { throw CancellationError() }
                if Date().timeIntervalSince(started) > timeout { throw MeetingsError.local("\(program.lastPathComponent) took longer than \(Int(timeout / 60)) min") }
                if pausable {
                    let reason = local.control.pause(local.thermal())
                    if reason != paused {
                        if let reason {
                            kill(pid, SIGSTOP)
                            local.status(LocalStatus(phase: .paused(reason), piece: phase.piece, pieces: phase.pieces))
                            MeetingsLog.info(.local, "\(program.lastPathComponent) paused: \(reason.rawValue)")
                        } else {
                            kill(pid, SIGCONT)
                            local.status(phase)
                            MeetingsLog.info(.local, "\(program.lastPathComponent) resumed")
                        }
                        paused = reason
                    }
                }
                try await Task.sleep(for: local.tick)
            }
        } catch {
            end(process)
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            MeetingsLog.info(.local, "\(program.lastPathComponent) killed: \(error)")
            throw error
        }
        process.waitUntilExit()
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        output.add(out.fileHandleForReading.readDataToEndOfFile())
        errors.add(err.fileHandleForReading.readDataToEndOfFile())
        return Result(status: process.terminationStatus, output: output.value, errors: errors.value)
    }

    /// SIGTERM (after SIGCONT, so a stopped process can take it), then SIGKILL after 2 s.
    static func end(_ process: Process) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        kill(pid, SIGCONT)
        kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < deadline { usleep(50_000) }
        if process.isRunning { kill(pid, SIGKILL) }
        process.waitUntilExit()
    }
}
