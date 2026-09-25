import Darwin
import Foundation

/// Runs a program and collects its output (stdout and stderr combined).
///
/// The program gets its own process group, so everything it starts can be stopped
/// with it. The timeout is a hard limit: after `timeout` seconds the group gets
/// SIGTERM, then SIGKILL after a short grace period. Output is drained while the
/// program runs and reading stops soon after it exits, even if a child it left
/// behind still holds the pipe open. Leftover children are terminated.
enum ProcessRunner {
    struct Result: Sendable {
        let exitedNormally: Bool
        let status: Int32
        let timedOut: Bool
        let output: String
        var succeeded: Bool { exitedNormally && status == 0 && !timedOut }
    }

    static func run(_ executable: URL, arguments: [String], directory: URL? = nil,
                    environment: [String: String], timeout: TimeInterval,
                    killGrace: TimeInterval = 2) async -> Result? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runBlocking(executable, arguments: arguments, directory: directory,
                                                           environment: environment, timeout: timeout,
                                                           killGrace: killGrace))
            }
        }
    }

    /// Blocking run; called only on a background queue. nil = could not start.
    private static func runBlocking(_ executable: URL, arguments: [String], directory: URL?,
                                    environment: [String: String], timeout: TimeInterval,
                                    killGrace: TimeInterval) -> Result? {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return nil }
        let (readEnd, writeEnd) = (fds[0], fds[1])

        guard let pid = spawn(executable, arguments: arguments, directory: directory, environment: environment,
                              output: writeEnd) else {
            close(readEnd)
            close(writeEnd)
            return nil
        }
        close(writeEnd) // only the child holds the write end now

        let output = OutputBuffer()
        let reader = FileHandle(fileDescriptor: readEnd, closeOnDealloc: true)
        let drained = DispatchSemaphore(value: 0)
        reader.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                drained.signal()
            } else {
                output.append(data)
            }
        }

        let exited = DispatchSemaphore(value: 0)
        let status = StatusBox()
        DispatchQueue.global().async {
            var raw: Int32 = 0
            while waitpid(pid, &raw, 0) == -1 && errno == EINTR {}
            status.value = raw
            exited.signal()
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            kill(-pid, SIGTERM)
            if exited.wait(timeout: .now() + killGrace) == .timedOut {
                kill(-pid, SIGKILL)
                exited.wait()
            }
        }
        // Children the program left behind (e.g. servers started by extensions).
        kill(-pid, SIGTERM)
        if drained.wait(timeout: .now() + 1) == .timedOut {
            kill(-pid, SIGKILL)
            _ = drained.wait(timeout: .now() + 1)
        }
        reader.readabilityHandler = nil
        try? reader.close()

        let raw = status.value
        let exitedNormally = raw & 0x7f == 0 // WIFEXITED
        return Result(exitedNormally: exitedNormally, status: exitedNormally ? (raw >> 8) & 0xff : raw & 0x7f,
                      timedOut: timedOut, output: output.text)
    }

    /// posix_spawn with stdin from /dev/null, stdout+stderr into `output` and a new process group.
    private static func spawn(_ executable: URL, arguments: [String], directory: URL?,
                              environment: [String: String], output: Int32) -> pid_t? {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, output, 1)
        posix_spawn_file_actions_adddup2(&actions, output, 2)
        if let directory {
            guard posix_spawn_file_actions_addchdir_np(&actions, directory.path) == 0 else { return nil }
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // New process group (pgid = child pid); descriptors not listed above are not inherited;
        // signal mask and handlers reset (like Foundation's Process), so SIGTERM works in the child.
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

/// Output collected on the reader's queue, read once at the end.
private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }
    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}

/// Exit status written by the waiter before it signals; read after the wait.
private final class StatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var raw: Int32 = 0
    var value: Int32 {
        get { lock.withLock { raw } }
        set { lock.withLock { raw = newValue } }
    }
}
