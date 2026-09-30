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
    static func run(_ executable: URL, arguments: [String], directory: URL, environment: [String: String],
                    timeout: TimeInterval?, onLine: @escaping @Sendable (String) -> Void) async -> Exit? {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(returning: runBlocking(executable, arguments: arguments, directory: directory,
                                                           environment: environment, timeout: timeout, onLine: onLine))
            }
        }
    }

    private static func runBlocking(_ executable: URL, arguments: [String], directory: URL, environment: [String: String],
                                    timeout: TimeInterval?, onLine: @escaping @Sendable (String) -> Void) -> Exit? {
        guard !Cancellation.isCancelled else { return Exit(status: 0, exitedNormally: false, timedOut: false, cancelled: true) }
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return nil }
        let (readEnd, writeEnd) = (fds[0], fds[1])
        guard let pid = spawn(executable, arguments: arguments, directory: directory, environment: environment, output: writeEnd) else {
            close(readEnd)
            close(writeEnd)
            return nil
        }
        close(writeEnd)
        Cancellation.track(pid)
        defer { Cancellation.untrack(pid) }

        let reader = FileHandle(fileDescriptor: readEnd, closeOnDealloc: true)
        let drained = DispatchSemaphore(value: 0)
        let lines = LineBuffer(onLine: onLine)
        reader.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
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
        if drained.wait(timeout: .now() + 2) == .timedOut {
            kill(-pid, SIGKILL)
            _ = drained.wait(timeout: .now() + 1)
        }
        reader.readabilityHandler = nil
        try? reader.close()
        let raw = box.value
        let normal = raw & 0x7f == 0
        return Exit(status: normal ? (raw >> 8) & 0xff : raw & 0x7f, exitedNormally: normal, timedOut: timedOut,
                    cancelled: Cancellation.isCancelled)
    }

    /// stdin from /dev/null, stdout+stderr into `output`, a new process group, default signals.
    private static func spawn(_ executable: URL, arguments: [String], directory: URL, environment: [String: String],
                              output: Int32) -> pid_t? {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
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
/// and no further child starts.
enum Cancellation {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cancelled = false
    nonisolated(unsafe) private static var children = Set<pid_t>()
    nonisolated(unsafe) private static var sources: [DispatchSourceSignal] = []

    static var isCancelled: Bool { lock.withLock { cancelled } }

    static func track(_ pid: pid_t) {
        let stop = lock.withLock { () -> Bool in
            children.insert(pid)
            return cancelled
        }
        if stop { kill(-pid, SIGTERM) }
    }

    static func untrack(_ pid: pid_t) { lock.withLock { _ = children.remove(pid) } }

    static func cancel() {
        let pids = lock.withLock { () -> Set<pid_t> in
            cancelled = true
            return children
        }
        for pid in pids { kill(-pid, SIGTERM) }
    }

    /// For tests.
    static func reset() { lock.withLock { cancelled = false } }

    /// Routes SIGTERM and SIGINT to `cancel()`.
    static func installSignalHandlers() {
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
            source.setEventHandler { cancel() }
            source.resume()
            lock.withLock { sources.append(source) }
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
