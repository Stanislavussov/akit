import Darwin
import Foundation

/// A long child of `akit lab run` (the agent, a build, one test) in its own process group,
/// its output handed over line by line. Cancelling the run stops the current child's
/// whole group, so nothing it started keeps running.
enum ChildProcess {
    struct Exit: Sendable {
        let status: Int32
        let exitedNormally: Bool
        let timedOut: Bool
        let cancelled: Bool
        var succeeded: Bool { exitedNormally && status == 0 && !timedOut && !cancelled }
    }

    /// nil = couldn't start. `onLine` gets stdout and stderr lines (without the newline).
    /// `input`: a file for stdin (else /dev/null).
    static func run(_ executable: URL, arguments: [String], directory: URL, environment: [String: String], input: URL? = nil,
                    timeout: TimeInterval?, onLine: @escaping @Sendable (String) -> Void) async -> Exit? {
        // The thread carries the caller's cancellation scope.
        let scope = Cancellation.scope
        return await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(returning: Cancellation.$scope.withValue(scope) {
                    runBlocking(executable, arguments: arguments, directory: directory, environment: environment, input: input,
                                timeout: timeout, onLine: onLine)
                })
            }
        }
    }

    private static func runBlocking(_ executable: URL, arguments: [String], directory: URL, environment: [String: String],
                                    input: URL?, timeout: TimeInterval?, onLine: @escaping @Sendable (String) -> Void) -> Exit? {
        guard !Cancellation.isCancelled else { return Exit(status: 0, exitedNormally: false, timedOut: false, cancelled: true) }
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return nil }
        let (readEnd, writeEnd) = (fds[0], fds[1])
        guard let pid = spawn(executable, arguments: arguments, directory: directory, environment: environment, input: input,
                              output: writeEnd) else {
            close(readEnd)
            close(writeEnd)
            return nil
        }
        close(writeEnd)
        Cancellation.track(pid)

        let reader = FileHandle(fileDescriptor: readEnd, closeOnDealloc: false)
        let drained = DispatchSemaphore(value: 0)
        let lines = LineBuffer(onLine: onLine)
        reader.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                try? handle.close()
                lines.finish()
                drained.signal()
            } else {
                lines.append(data)
            }
        }

        let exited = DispatchSemaphore(value: 0)
        let box = Box()
        Thread.detachNewThread {
            var raw: Int32 = 0
            while waitpid(pid, &raw, 0) == -1 && errno == EINTR {}
            box.value = raw
            exited.signal()
        }
        var timedOut = false
        if let timeout, exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            kill(-pid, SIGTERM)
            if exited.wait(timeout: .now() + 5) == .timedOut {
                kill(-pid, SIGKILL)
                exited.wait()
            }
        } else if timeout == nil {
            exited.wait()
        }
        // Whatever the child left behind in its group (test helpers, servers).
        kill(-pid, SIGTERM)
        var closed = drained.wait(timeout: .now() + 2) == .success
        if !closed {
            kill(-pid, SIGKILL)
            closed = drained.wait(timeout: .now() + 1) == .success
        }
        // The group is gone (or killed); its id may be reused from now on.
        Cancellation.untrack(pid)
        if !closed {
            // A process outside the group still holds the pipe. Stop reading, but leave the
            // descriptor open: closing it while a read is running would crash.
            reader.readabilityHandler = nil
        }
        let raw = box.value
        let normal = raw & 0x7f == 0
        return Exit(status: normal ? (raw >> 8) & 0xff : raw & 0x7f, exitedNormally: normal, timedOut: timedOut,
                    cancelled: Cancellation.isCancelled)
    }

    /// stdin from `input` or /dev/null, stdout+stderr into `output`, a new process group, default signals.
    private static func spawn(_ executable: URL, arguments: [String], directory: URL, environment: [String: String],
                              input: URL?, output: Int32) -> pid_t? {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, input?.path ?? "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, output, 1)
        posix_spawn_file_actions_adddup2(&actions, output, 2)
        guard posix_spawn_file_actions_addchdir_np(&actions, directory.path) == 0 else { return nil }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
                                                    | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        posix_spawnattr_setpgroup(&attributes, 0)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        guard posix_spawn(&pid, executable.path, &actions, &attributes, argv, envp) == 0 else { return nil }
        return pid
    }
}

/// Cancelling a run: SIGTERM or SIGINT to `akit lab run` stops the current child's group,
/// and no further child starts. The state lives in a scope: the whole process by default
/// (`akit lab run` does one run), a scope of its own where several runs share a process
/// (tests run in parallel and one cancelling must not stop the others).
public enum Cancellation {
    public final class Scope: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var children = Set<pid_t>()

        public init() {}

        public var isCancelled: Bool { lock.withLock { cancelled } }

        var groups: Set<pid_t> { lock.withLock { children } }

        func track(_ pid: pid_t) {
            let stop = lock.withLock { () -> Bool in
                children.insert(pid)
                return cancelled
            }
            if stop { kill(-pid, SIGTERM) }
        }

        func untrack(_ pid: pid_t) { lock.withLock { _ = children.remove(pid) } }

        public func cancel() {
            let pids = lock.withLock { () -> Set<pid_t> in
                cancelled = true
                return children
            }
            for pid in pids { kill(-pid, SIGTERM) }
        }

        public func reset() { lock.withLock { cancelled = false } }
    }

    /// The process's own scope: what the signal handlers cancel.
    static let process = Scope()
    @TaskLocal public static var scope = process

    nonisolated(unsafe) private static var sources: [DispatchSourceSignal] = []
    private static let sourcesLock = NSLock()

    public static var isCancelled: Bool { scope.isCancelled }

    /// Process groups of the running children (each child leads its own group).
    static var trackedGroups: Set<pid_t> { scope.groups }

    static func track(_ pid: pid_t) { scope.track(pid) }

    static func untrack(_ pid: pid_t) { scope.untrack(pid) }

    static func cancel() { scope.cancel() }

    /// For tests.
    public static func reset() { scope.reset() }

    /// Routes SIGTERM, SIGINT, SIGQUIT and SIGHUP (the tab was closed) to `cancel()`. The
    /// children are in their own process groups and never see these signals themselves.
    static func installSignalHandlers() {
        for signalNumber in [SIGTERM, SIGINT, SIGQUIT, SIGHUP] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
            source.setEventHandler { process.cancel() }
            source.resume()
            sourcesLock.withLock { sources.append(source) }
        }
    }

}

/// Splits output into lines.
private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private let onLine: @Sendable (String) -> Void

    init(onLine: @escaping @Sendable (String) -> Void) { self.onLine = onLine }

    func append(_ data: Data) {
        let lines = lock.withLock { () -> [String] in
            pending.append(data)
            var result: [String] = []
            while let newline = pending.firstIndex(of: 0x0A) {
                result.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
                pending.removeSubrange(pending.startIndex...newline)
            }
            return result
        }
        lines.forEach(onLine)
    }

    func finish() {
        let rest = lock.withLock { () -> String? in
            defer { pending = Data() }
            return pending.isEmpty ? nil : String(decoding: pending, as: UTF8.self)
        }
        if let rest { onLine(rest) }
    }
}

private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var raw: Int32 = 0
    var value: Int32 {
        get { lock.withLock { raw } }
        set { lock.withLock { raw = newValue } }
    }
}
