import Foundation

/// One importer at a time: `flock(LOCK_EX | LOCK_NB)` on `import.lock`. Released when the
/// value goes away (or the process ends). Hooks never take it.
public final class ImportLock {
    private let descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    /// nil when another importer holds the lock.
    public static func acquire(_ url: URL) throws -> ImportLock? {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw IndexDatabase.Failure(message: "Can't open \(url.path): \(String(cString: strerror(errno)))")
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let busy = errno == EWOULDBLOCK
            let message = String(cString: strerror(errno))
            close(fd)
            if busy { return nil }
            throw IndexDatabase.Failure(message: "Can't lock \(url.path): \(message)")
        }
        return ImportLock(descriptor: fd)
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
