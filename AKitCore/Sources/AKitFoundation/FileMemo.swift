import Foundation

/// Values read from files, by file: a file whose modification date and size haven't changed is
/// not read again. For readers that go over every session file on each refresh or screen load,
/// where reading the files was most of the time. Kept in memory as long as the process runs;
/// nothing is written.
public final class FileMemo<Value: Sendable>: @unchecked Sendable {
    private struct Entry {
        let modified: Date
        let size: Int
        let value: Value
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    public init() {}

    /// The value of the file, from `read` when the file is new or changed since the last call.
    public func value(of file: URL, _ read: (URL) -> Value) -> Value {
        let info = JSONLines.fileInfo(file)
        if let hit = lock.withLock({ entries[file.path] }), hit.modified == info.modified, hit.size == info.size {
            return hit.value
        }
        let value = read(file)
        lock.withLock { entries[file.path] = Entry(modified: info.modified, size: info.size, value: value) }
        return value
    }
}
