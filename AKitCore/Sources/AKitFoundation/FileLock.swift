import Foundation

/// An exclusive `flock` on a file. Released when the value goes away (or the process ends).
public final class FileLock: @unchecked Sendable {
    private let descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    /// nil when another holder has the lock. Never waits.
    public static func acquire(_ url: URL) throws -> FileLock? {
        try acquire(url, timeout: 0)
    }

    /// Polls `LOCK_NB` every 50 ms until `timeout` seconds pass; nil when the lock stays held.
    public static func acquire(_ url: URL, timeout: TimeInterval) throws -> FileLock? {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw SQLiteDatabase.Failure(message: "Can't open \(url.path): \(String(cString: strerror(errno)))")
        }
        let deadline = Date.now.addingTimeInterval(timeout)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            guard code == EWOULDBLOCK || code == EINTR else {
                close(fd)
                throw SQLiteDatabase.Failure(message: "Can't lock \(url.path): \(String(cString: strerror(code)))")
            }
            guard Date.now < deadline else {
                close(fd)
                return nil
            }
            usleep(50_000)
        }
        return FileLock(descriptor: fd)
    }

    /// Lets go of the lock now, without waiting for the value to go away.
    public func release() {
        flock(descriptor, LOCK_UN)
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
