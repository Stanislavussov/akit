import AKitFoundation
import CoreServices
import Foundation

/// Watches `<git common dir>/worktrees` of each local-only project while the app runs
/// (layers.md, "Local-only files and git worktrees"): about a second after a worktree is added
/// or removed, `onChange` gets the project's id, so only that project's worktrees are synced.
/// Only a record coming or going counts (`worktrees` itself, its direct children, and each
/// record's `gitdir` and `locked`), not the index, HEAD and logs git writes there on every
/// command. Before a repository's first worktree there is no `worktrees` folder: its common
/// git folder is watched instead and an event counts once `worktrees` is a folder. Used on
/// the main thread only; the streams stop when the watcher goes away.
final class WorktreeWatcher: @unchecked Sendable {
    private final class Watch {
        let id: String
        let commonDir: URL
        /// `<common dir>/worktrees` with links resolved, as FSEvents names paths.
        let records: String
        /// The folder the stream watches: `records`, or the common dir while it doesn't exist.
        let root: String
        var stream: FSEventStreamRef?
        weak var owner: WorktreeWatcher?

        init(id: String, commonDir: URL, records: String, root: String) {
            self.id = id
            self.commonDir = commonDir
            self.records = records
            self.root = root
        }

        /// `worktrees` itself, a record (`worktrees/<name>`) made or removed, or its `gitdir`
        /// or `locked` (git drops the lock once the checkout is done).
        func isRecordChange(_ path: String) -> Bool {
            if path == records { return true }
            guard path.hasPrefix(records + "/") else { return false }
            let parts = path.dropFirst(records.count + 1).split(separator: "/", omittingEmptySubsequences: false)
            return parts.count == 1 || (parts.count == 2 && (parts[1] == "gitdir" || parts[1] == "locked"))
        }
    }

    private var watches: [String: Watch] = [:]
    private var pending: [String: Task<Void, Never>] = [:]
    private let onChange: @MainActor (String) -> Void

    init(onChange: @escaping @MainActor (String) -> Void) {
        self.onChange = onChange
    }

    deinit {
        for id in Array(watches.keys) { stop(id) }
    }

    /// Watches these projects (id → git common dir) and stops watching the others. A stream
    /// whose folder is unchanged keeps running.
    @MainActor
    func watch(_ projects: [String: URL]) {
        for id in Array(watches.keys) where projects[id] == nil { stop(id) }
        for (id, commonDir) in projects { arm(id, commonDir: commonDir) }
    }

    @MainActor
    private func arm(_ id: String, commonDir: URL) {
        let common = FileWalk.realPath(commonDir) ?? commonDir.standardizedFileURL.path
        let records = common + "/worktrees"
        let root = FileWalk.isDirectory(URL(filePath: records)) ? records : common
        if watches[id]?.root == root { return }
        stop(id)
        let watch = Watch(id: id, commonDir: commonDir, records: records, root: root)
        watch.owner = self
        // The stream owns its Watch: released with the stream.
        let info = Unmanaged.passRetained(watch).toOpaque()
        var context = FSEventStreamContext(version: 0, info: info, retain: nil,
                                           release: { info in if let info { Unmanaged<Watch>.fromOpaque(info).release() } },
                                           copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let watch = Unmanaged<Watch>.fromOpaque(info).takeUnretainedValue()
            if watch.root == watch.records {
                let changed = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
                guard changed.contains(where: watch.isRecordChange) else { return }
            } else {
                // The common git folder: busy with every git command, so no paths are read.
                guard FileWalk.isDirectory(URL(filePath: watch.records)) else { return }
            }
            // The stream runs on the main queue.
            MainActor.assumeIsolated { watch.owner?.changed(watch.id) }
        }
        // File events: the creation of `worktrees` itself is named, not only its parent.
        // WatchRoot: a removed `worktrees` folder is reported too.
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [root] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags) else {
            Unmanaged<Watch>.fromOpaque(info).release()
            return
        }
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        watch.stream = stream
        watches[id] = watch
    }

    /// Waits for a quiet second (git writes several files per worktree), then re-arms on the
    /// right folder and reports the change. Not done in the stream's callback: a stream isn't
    /// stopped from inside its own callback.
    @MainActor
    private func changed(_ id: String) {
        pending[id]?.cancel()
        pending[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, let watch = self.watches[id] else { return }
            self.pending[id] = nil
            self.arm(id, commonDir: watch.commonDir)
            self.onChange(id)
        }
    }

    private func stop(_ id: String) {
        pending.removeValue(forKey: id)?.cancel()
        guard let watch = watches.removeValue(forKey: id), let stream = watch.stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
