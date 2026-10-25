import AKitFoundation
import AKitKnowledge
import CoreServices
import Foundation

/// Watches the folder of the knowledge base on screen (3.3) while the app runs: after a quiet
/// second, `onChange` gets every base-relative path that changed since the last call, for
/// `WatchFilter` to sort out (an edit in Obsidian, a proposal in `inbox/`, AKit's own saves).
/// Used on the main thread only; the stream stops when the watcher goes away.
final class KnowledgeWatcher: @unchecked Sendable {
    let root: URL
    /// `root` with links resolved, as FSEvents names paths.
    private let resolved: String
    private var stream: FSEventStreamRef?
    private var changed: Set<String> = []
    private var pending: Task<Void, Never>?
    private let onChange: @MainActor ([String]) -> Void

    @MainActor
    init(root: URL, onChange: @escaping @MainActor ([String]) -> Void) {
        self.root = root
        resolved = FileWalk.realPath(root) ?? root.standardizedFileURL.path
        self.onChange = onChange
        start()
    }

    deinit {
        pending?.cancel()
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    @MainActor
    private func start() {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
                                           copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<KnowledgeWatcher>.fromOpaque(info).takeUnretainedValue()
            let changed = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            // The stream runs on the main queue.
            MainActor.assumeIsolated { watcher.received(changed) }
        }
        // File events: every changed file is named, not only its folder.
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [resolved] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        self.stream = stream
    }

    /// Collects the paths and waits for a quiet second (an editor writes a file in several steps,
    /// git touches many), then reports them all at once.
    @MainActor
    private func received(_ paths: [String]) {
        let relative = paths.compactMap { WatchFilter.relative($0, root: resolved) }
            .filter { WatchFilter.classify($0) != .ignore }
        guard !relative.isEmpty else { return }
        changed.formUnion(relative)
        pending?.cancel()
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            let paths = self.changed.sorted()
            self.changed = []
            self.pending = nil
            self.onChange(paths)
        }
    }
}
