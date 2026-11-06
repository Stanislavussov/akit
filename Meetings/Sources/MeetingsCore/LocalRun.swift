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
    private var quittingValue = false

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

    /// Quit: like Stop, but the meeting waits for the next start instead of failing.
    public var quitting: Bool {
        get { lock.withLock { quittingValue } }
        set { lock.withLock { quittingValue = newValue } }
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
    /// Whether a recording runs in another app (the other Meetings host).
    public var recordingElsewhere: @Sendable () -> Bool

    public init(control: LocalControl = LocalControl(),
                thermal: @escaping @Sendable () -> ProcessInfo.ThermalState = { ProcessInfo.processInfo.thermalState },
                status: @escaping @Sendable (LocalStatus) -> Void = { _ in }, tick: Duration = .milliseconds(500),
                recordingElsewhere: @escaping @Sendable () -> Bool = { false }) {
        self.control = control
        self.recordingElsewhere = recordingElsewhere
        self.thermal = thermal
        self.status = status
        self.tick = tick
    }

    /// Why the run must wait now (M23).
    func pause() -> LocalControl.Pause? {
        if let reason = control.pause(thermal()) { return reason }
        return recordingElsewhere() ? .recording : nil
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
            guard let reason = pause() else { break }
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
/// priority by `taskpolicy -b` (efficiency cores, low I/O and GPU priority) in its own process
/// group. While it runs, a pause stops the group with SIGSTOP and a resume goes on with SIGCONT;
/// Stop, critical heat or the time limit (counted while it works, not while it is paused) kill
/// the whole group. Live groups are listed in memory (Quit ends them) and in a file (the next
/// launch ends what a crash left).
public enum ChildRun {
    public struct Result: Sendable {
        public var status: Int32
        public var output: Data
        public var errors: Data
    }

    static let taskpolicy = URL(filePath: "/usr/sbin/taskpolicy")

    /// Reads one pipe until EOF on its own thread; `finish` gives up on a pipe a grandchild still
    /// holds open.
    final class Reader: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var ended = false
        private var stop = false
        let done = DispatchSemaphore(value: 0)

        init(_ fd: Int32) {
            Thread.detachNewThread { [self] in
                var buffer = [UInt8](repeating: 0, count: 65_536)
                var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                while !lock.withLock({ stop }) {
                    guard poll(&poller, 1, 100) > 0 else { continue }
                    let count = read(fd, &buffer, buffer.count)
                    if count < 0 && errno == EINTR { continue }
                    if count <= 0 { break }
                    lock.withLock { data.append(buffer, count: count) }
                }
                close(fd)
                lock.withLock { ended = true }
                done.signal()
            }
        }

        /// Waits up to `seconds` for EOF, then stops reading; the bytes so far.
        func finish(within seconds: TimeInterval) -> Data {
            if done.wait(timeout: .now() + seconds) == .timedOut {
                lock.withLock { stop = true }
                done.wait()
            }
            return lock.withLock { data }
        }
    }

    // MARK: Live groups

    private static let liveLock = NSLock()
    nonisolated(unsafe) private static var live: [pid_t: String] = [:]

    /// The folder of the live-group files: one per app process, `children-<pid>.txt`
    /// (`pid<TAB>program` lines), so AKit and `Meetings.app` never touch each other's. Tests
    /// point it at a temporary folder.
    nonisolated(unsafe) public static var liveFolder = MeetingsSettings.defaultFile.deletingLastPathComponent().appending(path: "children", directoryHint: .isDirectory)

    static var liveFile: URL { liveFolder.appending(path: "children-\(getpid()).txt") }

    static func remember(_ pid: pid_t, _ program: URL) {
        liveLock.withLock {
            live[pid] = program.path
            writeLive()
        }
    }

    static func forget(_ pid: pid_t) {
        liveLock.withLock {
            live[pid] = nil
            writeLive()
        }
    }

    private static func writeLive() {
        if live.isEmpty {
            try? FileManager.default.removeItem(at: liveFile)
            return
        }
        let text = live.map { "\($0.key)\t\($0.value)" }.joined(separator: "\n")
        try? FileManager.default.createDirectory(at: liveFolder, withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: liveFile, options: .atomic)
    }

    /// Quit: every live group gets SIGCONT and SIGTERM, then SIGKILL after up to 2 s.
    public static func endAll() {
        let pids = liveLock.withLock { Array(live.keys) }
        for pid in pids { signalGroup(pid, SIGCONT); signalGroup(pid, SIGTERM) }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, pids.contains(where: { kill(-$0, 0) == 0 }) { usleep(50_000) }
        for pid in pids where kill(-pid, 0) == 0 { signalGroup(pid, SIGKILL) }
        if !pids.isEmpty { MeetingsLog.info(.local, "quit: ended \(pids.count) child process(es)") }
    }

    /// Launch: the files of app processes that are gone (a crash or a force quit) name groups
    /// that may still run; each is ended when its leader still runs the same program, then the
    /// file goes. A living app's file is left alone. Returns how many groups were ended.
    @discardableResult
    public static func endLeftovers() -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: liveFolder, includingPropertiesForKeys: nil)) ?? []
        var ended = 0
        for file in files {
            let name = file.deletingPathExtension().lastPathComponent
            guard name.hasPrefix("children-"), let owner = pid_t(name.dropFirst("children-".count)) else { continue }
            if owner == getpid() || kill(owner, 0) == 0 || errno == EPERM { continue }
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: "\t", maxSplits: 1)
                guard parts.count == 2, let pid = pid_t(parts[0]), pid > 1, path(of: pid) == String(parts[1]) else { continue }
                signalGroup(pid, SIGCONT)
                signalGroup(pid, SIGKILL)
                ended += 1
            }
            try? FileManager.default.removeItem(at: file)
        }
        if ended > 0 { MeetingsLog.info(.local, "launch: ended \(ended) child process(es) left by an earlier run") }
        return ended
    }

    static func path(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Every child is its group's leader, so its pid is the group's id. Only the group gets the
    /// signal: after the leader is reaped, its pid may belong to another process.
    @discardableResult
    static func signalGroup(_ pid: pid_t, _ signal: Int32) -> Bool {
        kill(-pid, signal) == 0
    }

    // MARK: Running

    /// Runs `program` with `arguments`. `background`: through `taskpolicy -b`. `pausable`: a
    /// pause stops the process (a network call like Pi's is better left running). `onStart`
    /// gets the group's pid (tests).
    public static func run(_ program: URL, _ arguments: [String], environment: [String: String]? = nil, directory: URL? = nil,
                           background: Bool = true, pausable: Bool = true, timeout: TimeInterval = 3600,
                           local: LocalEnvironment, resume phase: LocalStatus, onStart: (pid_t) -> Void = { _ in }) async throws -> Result {
        try local.check()
        let viaPolicy = background && FileManager.default.isExecutableFile(atPath: taskpolicy.path)
        let executable = viaPolicy ? taskpolicy : program
        let argv = [executable.path] + (viaPolicy ? ["-b", program.path] : []) + arguments
        let pid = try spawn(executable, argv, environment: environment, directory: directory)
        // taskpolicy replaces itself with the program, so the leader's path is the program's.
        remember(pid.pid, program)
        onStart(pid.pid)
        let output = Reader(pid.out), errors = Reader(pid.err)
        var status: Int32 = 0
        var worked: TimeInterval = 0
        var last = Date()
        var paused: LocalControl.Pause?
        defer { forget(pid.pid) }
        do {
            while true {
                var raw: Int32 = 0
                let waited = waitpid(pid.pid, &raw, WNOHANG)
                if waited == pid.pid {
                    status = (raw & 0x7f) == 0 ? (raw >> 8) & 0xff : 128 + (raw & 0x7f)
                    // Ended by Stop or Quit (endAll) rather than on its own: say so.
                    if local.control.stopped { throw MeetingsError.stopped }
                    break
                }
                if waited < 0 && errno != EINTR { status = -1; break }
                let now = Date()
                if paused == nil { worked += now.timeIntervalSince(last) }
                last = now
                if local.control.stopped { throw MeetingsError.stopped }
                if local.thermal() == .critical { throw MeetingsError.tooHot }
                if Task.isCancelled { throw CancellationError() }
                if worked > timeout { throw MeetingsError.local("\(program.lastPathComponent) took longer than \(Int(timeout / 60)) min") }
                if pausable {
                    let reason = local.pause()
                    // A signal right after the start can miss a group that is not set up yet:
                    // the state changes only when the signal arrived, else the next tick tries again.
                    if reason != paused, signalGroup(pid.pid, reason == nil ? SIGCONT : SIGSTOP) {
                        if let reason {
                            local.status(LocalStatus(phase: .paused(reason), piece: phase.piece, pieces: phase.pieces))
                            MeetingsLog.info(.local, "\(program.lastPathComponent) paused: \(reason.rawValue)")
                        } else {
                            local.status(phase)
                            MeetingsLog.info(.local, "\(program.lastPathComponent) resumed")
                        }
                        paused = reason
                    }
                }
                try await Task.sleep(for: local.tick)
            }
        } catch {
            end(pid.pid, reaped: (try? waitpidDone(pid.pid)) ?? true)
            _ = output.finish(within: 0.5)
            _ = errors.finish(within: 0.5)
            MeetingsLog.info(.local, "\(program.lastPathComponent) killed: \(error)")
            throw error
        }
        if paused != nil { local.status(phase) }
        return Result(status: status, output: output.finish(within: 2), errors: errors.finish(within: 2))
    }

    /// posix_spawn in a new process group, stdin from /dev/null, stdout and stderr into pipes,
    /// and no other descriptor of the app.
    static func spawn(_ executable: URL, _ argv: [String], environment: [String: String]?, directory: URL?) throws -> (pid: pid_t, out: Int32, err: Int32) {
        var outPipe: [Int32] = [0, 0], errPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0 else { throw MeetingsError.local("no pipe") }
        guard pipe(&errPipe) == 0 else {
            close(outPipe[0]); close(outPipe[1])
            throw MeetingsError.local("no pipe")
        }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        // Default actions for every signal and an empty mask, as Foundation's Process does.
        var all = sigset_t(), none = sigset_t()
        sigfillset(&all)
        sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attributes, &all)
        posix_spawnattr_setsigmask(&attributes, &none)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        if let directory { posix_spawn_file_actions_addchdir_np(&actions, directory.path) }
        let env = (environment ?? ProcessInfo.processInfo.environment).map { "\($0.key)=\($0.value)" }
        var cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        var cEnv: [UnsafeMutablePointer<CChar>?] = env.map { strdup($0) } + [nil]
        defer {
            cArgs.forEach { free($0) }
            cEnv.forEach { free($0) }
        }
        var pid: pid_t = 0
        let code = posix_spawn(&pid, executable.path, &actions, &attributes, &cArgs, &cEnv)
        close(outPipe[1]); close(errPipe[1])
        guard code == 0 else {
            close(outPipe[0]); close(errPipe[0])
            throw MeetingsError.local("could not start \(executable.lastPathComponent): \(String(cString: strerror(code)))")
        }
        return (pid, outPipe[0], errPipe[0])
    }

    /// Whether the leader is already reaped (then only its group may still need the signal).
    static func waitpidDone(_ pid: pid_t) throws -> Bool {
        var raw: Int32 = 0
        return waitpid(pid, &raw, WNOHANG) != 0
    }

    /// SIGTERM to the group (after SIGCONT, so a stopped one can take it), then SIGKILL after 2 s.
    static func end(_ pid: pid_t, reaped: Bool = false) {
        if reaped {
            signalGroup(pid, SIGKILL)
            return
        }
        signalGroup(pid, SIGCONT)
        signalGroup(pid, SIGTERM)
        var raw: Int32 = 0
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if waitpid(pid, &raw, WNOHANG) != 0 {
                signalGroup(pid, SIGKILL)  // the leader is gone; its group may not be
                return
            }
            usleep(50_000)
        }
        signalGroup(pid, SIGKILL)
        waitpid(pid, &raw, 0)
    }
}

/// M23: "this app records now", seen by the other app's local runs. A POSIX record lock
/// (`fcntl`), not `flock`: the other app tests it with F_GETLK without taking it, so a check
/// never makes a starting recording miss its lock. One descriptor per file for the app's life,
/// never closed (closing any descriptor of the file would drop the process's record locks).
public final class RecordingSignal: @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var descriptors: [String: Int32] = [:]

    static func descriptor(_ url: URL) -> Int32? {
        lock.withLock {
            if let fd = descriptors[url.path] { return fd }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
            guard fd >= 0 else { return nil }
            descriptors[url.path] = fd
            return fd
        }
    }

    static func lockRecord(_ fd: Int32, _ type: Int32, command: Int32) -> flock {
        var record = flock()
        record.l_type = Int16(type)
        record.l_whence = Int16(SEEK_SET)
        record.l_start = 0
        record.l_len = 0
        _ = fcntl(fd, command, &record)
        return record
    }

    /// Recording starts (true) or ends (false) in this app.
    public static func set(_ url: URL, recording: Bool) {
        guard let fd = descriptor(url) else { return }
        _ = lockRecord(fd, recording ? F_WRLCK : F_UNLCK, command: F_SETLK)
    }

    /// Whether another process holds the signal now.
    public static func elsewhere(_ url: URL) -> Bool {
        guard let fd = descriptor(url) else { return false }
        return lockRecord(fd, F_WRLCK, command: F_GETLK).l_type != Int16(F_UNLCK)
    }
}
