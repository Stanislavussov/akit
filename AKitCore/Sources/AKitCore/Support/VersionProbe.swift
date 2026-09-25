import Foundation

/// Gets a program's version by running `<program> --version`.
/// Output (stdout and stderr combined) is drained while the program runs;
/// otherwise a large output would block it on a full pipe.
/// If the program doesn't exit within `timeout` seconds it is terminated and nil is returned.
public enum VersionProbe {
    public static func version(of executable: URL, in env: HarnessEnvironment, timeout: TimeInterval = 5) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: run(executable, env: env, timeout: timeout))
            }
        }
    }

    /// Blocking run; called only on a background queue.
    private static func run(_ executable: URL, env: HarnessEnvironment, timeout: TimeInterval) -> String? {
        let process = ProcessBox(Process())
        process.value.executableURL = executable
        process.value.arguments = ["--version"]
        var childEnv = env.variables
        childEnv["PATH"] = env.pathForChildProcesses
        childEnv["NO_COLOR"] = "1"
        process.value.environment = childEnv
        let pipe = Pipe()
        process.value.standardOutput = pipe
        process.value.standardError = pipe
        process.value.standardInput = FileHandle.nullDevice
        do { try process.value.run() } catch { return nil }

        let killer = DispatchWorkItem { if process.value.isRunning { process.value.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

        // Read to EOF (reached when the program exits or is terminated).
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.value.waitUntilExit()
        killer.cancel()

        guard process.value.terminationReason == .exit, process.value.terminationStatus == 0 else { return nil }
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// First non-empty line containing a digit (banners without digits are skipped).
    static func parse(_ output: String) -> String? {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { line in !line.isEmpty && line.contains(where: \.isNumber) }
    }
}

/// Process isn't Sendable; it is used strictly sequentially on one background
/// queue, plus `terminate()` from the timer, which is thread-safe.
private final class ProcessBox: @unchecked Sendable {
    let value: Process
    init(_ value: Process) { self.value = value }
}
