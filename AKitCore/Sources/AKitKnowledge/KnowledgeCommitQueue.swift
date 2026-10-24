import AKitFoundation
import Foundation

/// In-app edits are committed in batches (U2): a save puts the note's path in the queue, and a
/// flush (a note tab closes, 5 min without edits, the app quits, or the next launch) commits
/// every pending path in one commit. The queue lives in `<base>/.akit-pending.json`, so it
/// outlives the app and is shared with every other process (app and CLI). `enqueue` and `flush`
/// both hold the base's git lock (`.akit-queue.lock`, P8) while they read and rewrite that file,
/// so a path added during a flush is either in that flush's commit or still pending, never lost.
/// Nothing here throws: a busy lock or a git failure keeps the paths for the next trigger.
public struct KnowledgeCommitQueue: Sendable {
    public static let fileName = ".akit-pending.json"

    public enum EnqueueResult: Equatable, Sendable {
        /// The paths are pending (the ones under `inbox/` left out, see `refused`).
        case queued(refused: [String])
        /// The lock stayed held (another writer); nothing was queued, so the caller tries again later.
        case busy
        /// The queue file couldn't be read or written.
        case failed(String)
    }

    public enum FlushResult: Equatable, Sendable {
        /// Nothing was pending, or nothing pending had changed: no commit.
        case nothing
        /// One commit of these paths.
        case committed([String])
        /// The lock stayed held; the paths stay pending.
        case busy
        /// Git or the queue file failed; the paths stay pending.
        case failed(String)
    }

    private struct Pending: Codable {
        var paths: [String]
    }

    public let base: URL
    public let env: HarnessEnvironment
    /// How long `enqueue` and `flush` wait for the lock.
    public let lockTimeout: TimeInterval

    public init(base: URL, env: HarnessEnvironment, lockTimeout: TimeInterval = 2) {
        self.base = base
        self.env = env
        self.lockTimeout = lockTimeout
    }

    private var file: URL { base.appending(path: Self.fileName) }
    private var lockFile: URL { base.appending(path: KnowledgeBase.queueLockName) }

    /// Only Accept and Reject change `inbox/` in git (P3).
    public static func isInbox(_ path: String) -> Bool { path == "inbox" || path.hasPrefix("inbox/") }

    /// The pending paths, sorted (read without the lock: for display only).
    public func pending() -> [String] { (try? read()) ?? [] }

    /// Adds base-relative `paths` to the queue. Paths under `inbox/` and paths outside the base
    /// are refused.
    @discardableResult
    public func enqueue(_ paths: [String]) -> EnqueueResult {
        let refused = paths.filter { Self.isInbox($0) || !KnowledgeGit.isInside($0) }
        let wanted = paths.filter { !refused.contains($0) }
        guard !wanted.isEmpty else { return .queued(refused: refused) }
        let lock: FileLock?
        do { lock = try FileLock.acquire(lockFile, timeout: lockTimeout) } catch { return .failed(error.localizedDescription) }
        guard let lock else { return .busy }
        defer { lock.release() }
        do {
            try write(Array(Set(try read() + wanted)))
        } catch {
            return .failed(error.localizedDescription)
        }
        return .queued(refused: refused)
    }

    /// Commits every pending path in one commit and empties the queue. `message` defaults to one
    /// that names the notes.
    @discardableResult
    public func flush(message: String? = nil) async -> FlushResult {
        let lock: FileLock?
        do { lock = try FileLock.acquire(lockFile, timeout: lockTimeout) } catch { return .failed(error.localizedDescription) }
        guard let lock else { return .busy }
        defer { lock.release() }
        let paths: [String]
        do { paths = try read() } catch { return .failed(error.localizedDescription) }
        guard !paths.isEmpty else { return .nothing }
        let committed: Bool
        do {
            committed = try await KnowledgeGit(base: base, env: env).commit(paths: paths, message: message ?? Self.message(for: paths),
                                                                           alreadyLocked: lock)
        } catch {
            return .failed(error.message)
        }
        do { try write([]) } catch { return .failed(error.localizedDescription) }
        return committed ? .committed(paths) : .nothing
    }

    /// Notes only: "Edit payments/orders-api" or "Edit 3 notes: a, b, c". Maps only: "Edit maps:
    /// payments/maps/overview". Both: "Edit notes and maps: a, b".
    static func message(for paths: [String]) -> String {
        let names = paths.map { path in
            var name = path.hasPrefix("areas/") ? String(path.dropFirst("areas/".count)) : path
            for ext in [".md", ".excalidraw"] where name.hasSuffix(ext) { name.removeLast(ext.count) }
            return name
        }
        let maps = paths.filter { $0.hasSuffix(".excalidraw") }.count
        if maps == paths.count { return "Edit maps: " + names.joined(separator: ", ") }
        if maps > 0 { return "Edit notes and maps: " + names.joined(separator: ", ") }
        return names.count == 1 ? "Edit \(names[0])" : "Edit \(names.count) notes: " + names.joined(separator: ", ")
    }

    /// The queue file's paths; empty when it doesn't exist. Throws when it exists but isn't a queue,
    /// so a broken file is never overwritten with less.
    private func read() throws -> [String] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let data = try Data(contentsOf: file)
        do {
            return try JSONDecoder().decode(Pending.self, from: data).paths.sorted()
        } catch {
            throw KnowledgeGit.Failure(message: "\(file.path) is not a commit queue: \(error.localizedDescription)")
        }
    }

    private func write(_ paths: [String]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Pending(paths: paths.sorted())).write(to: file, options: .atomic)
    }
}
