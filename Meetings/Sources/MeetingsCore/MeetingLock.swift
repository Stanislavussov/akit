import Foundation

/// An exclusive lock on a file in a meeting's folder (`flock`): `audio/.recording.lock` while a
/// host records, `.processing.lock` while one transcribes. AKit and `Meetings.app` share the
/// folder, so a host that cannot take the lock leaves the meeting alone. The OS drops the lock
/// when its process ends, so a crashed recording can be taken over.
public final class MeetingLock: @unchecked Sendable {
    private let descriptor: Int32
    private let lock = NSLock()
    private var held = true

    private init(descriptor: Int32) { self.descriptor = descriptor }

    /// The lock, or nil when another open file holds it (another host, another window).
    public static func take(_ url: URL) -> MeetingLock? {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        return MeetingLock(descriptor: fd)
    }

    public static func recording(_ store: MeetingStore, _ id: String) -> URL { store.audioFolder(id).appending(path: ".recording.lock") }
    public static func processing(_ store: MeetingStore, _ id: String) -> URL { store.folder(id).appending(path: ".processing.lock") }

    /// True when nobody holds the lock now.
    public static func isFree(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        return take(url).map { $0.release(); return true } ?? false
    }

    public func release() {
        lock.lock()
        defer { lock.unlock() }
        guard held else { return }
        held = false
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    deinit { release() }
}
