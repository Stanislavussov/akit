import Darwin
import Foundation

/// An exclusive `flock` on a file, shared between processes. Waiting doesn't block a thread.
enum FileLock {
    static func holding<T>(_ file: URL, _ work: () async throws -> T) async throws -> T {
        let descriptor = open(file.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw LabStore.Failure(message: "Can't open \(file.path).") }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else { throw LabStore.Failure(message: "Can't lock \(file.path).") }
            try await Task.sleep(for: .milliseconds(100))
        }
        defer { flock(descriptor, LOCK_UN) }
        return try await work()
    }
}
