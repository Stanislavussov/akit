import Foundation

/// Runs a program and collects its output (stdout and stderr combined).
/// Output is drained while the program runs; otherwise a large output would block
/// it on a full pipe. If the program doesn't exit within `timeout` seconds it is terminated.
enum ProcessRunner {
    struct Result: Sendable {
        let exitedNormally: Bool
        let status: Int32
        let output: String
        var succeeded: Bool { exitedNormally && status == 0 }
    }

    static func run(_ executable: URL, arguments: [String], directory: URL? = nil,
                    environment: [String: String], timeout: TimeInterval) async -> Result? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runBlocking(executable, arguments: arguments, directory: directory,
                                                           environment: environment, timeout: timeout))
            }
        }
    }

    /// Blocking run; called only on a background queue. nil = could not start.
    private static func runBlocking(_ executable: URL, arguments: [String], directory: URL?,
                                    environment: [String: String], timeout: TimeInterval) -> Result? {
        let process = ProcessBox(Process())
        process.value.executableURL = executable
        process.value.arguments = arguments
        process.value.environment = environment
        if let directory { process.value.currentDirectoryURL = directory }
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

        return Result(exitedNormally: process.value.terminationReason == .exit,
                      status: process.value.terminationStatus,
                      output: String(decoding: data, as: UTF8.self))
    }
}

/// Process isn't Sendable; it is used strictly sequentially on one background
/// queue, plus `terminate()` from the timer, which is thread-safe.
private final class ProcessBox: @unchecked Sendable {
    let value: Process
    init(_ value: Process) { self.value = value }
}
