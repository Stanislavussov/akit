import Foundation

/// What a changed file in a base means for AKit's watcher (3.3): the app watches the base folder
/// (FSEvents, 1 s debounce) and hands every changed path here.
/// - `areas/…` (notes, maps, `area.yaml`): the index is refreshed, and an outside change goes to
///   the commit queue (U2).
/// - `kb.yaml`: the kinds are read again; queued like an area file.
/// - `inbox/…` (a proposal, or its hidden `.<id>.check.json` marks): only the Inbox count and list
///   are refreshed. Never queued: only Accept and Reject
///   change `inbox/` in git (P3).
/// - git's, Obsidian's and AKit's own working files (`.git/`, `.obsidian/`, the index, the locks,
///   the queue, the miss log) and any other hidden file (`.DS_Store`, an editor's swap file):
///   ignored. Queuing one would commit litter, or fail on a path the base's `.gitignore` names.
/// - Anything else, like the sample base's `.akit-seed.json` (committed by `kb seed` itself) or a
///   file at the base's top: `other`, nothing to do.
public enum WatchFilter {
    public enum Change: Equatable, Sendable {
        case ignore
        case area(String)
        case inbox(String)
        case baseConfig(String)
        case other(String)
    }

    /// AKit's, git's and Obsidian's working files at the base's top.
    static let ignoredTop: Set<String> = [
        ".git", ".obsidian", KnowledgeIndex.lockName, KnowledgeBase.queueLockName,
        KnowledgeCommitQueue.fileName, KnowledgeIndex.missesName,
    ]

    /// The meaning of a base-relative path.
    public static func classify(_ path: String) -> Change {
        let path = KnowledgeBase.nfc(path)
        let parts = path.split(separator: "/").map(String.init)
        guard let top = parts.first else { return .ignore }
        if ignoredTop.contains(top) || top.hasPrefix(KnowledgeIndex.fileName) { return .ignore }
        if path == KnowledgeSeed.markerName { return .other(path) }
        // The check model's hidden marks of a proposal (5.2) refresh the Inbox like the proposal.
        if top == "inbox", parts.count == 2, parts[1].hasPrefix("."), parts[1].hasSuffix(".check.json") { return .inbox(path) }
        if parts.contains(where: { $0.hasPrefix(".") }) { return .ignore }
        switch top {
        case "areas" where parts.count > 1: return .area(path)
        case "inbox" where parts.count > 1: return .inbox(path)
        case KnowledgeKinds.fileName where parts.count == 1: return .baseConfig(path)
        default: return .other(path)
        }
    }

    /// `absolute` relative to the base folder `root`; nil when it is the folder itself or outside it.
    /// FSEvents names paths with links resolved, so give `root` resolved too.
    public static func relative(_ absolute: String, root: String) -> String? {
        let root = root.hasSuffix("/") ? String(root.dropLast()) : root
        guard absolute.hasPrefix(root + "/") else { return nil }
        let rest = String(absolute.dropFirst(root.count + 1))
        return rest.isEmpty ? nil : rest
    }

    /// What one quiet batch of changes asks for.
    public struct Batch: Equatable, Sendable {
        /// An area file or `kb.yaml` changed: refresh the index. Own writes too (the rule below).
        public var reindex = false
        /// `kb.yaml` changed: read the kinds again.
        public var reloadKinds = false
        /// Something under `inbox/` changed: count it again.
        public var inbox = false
        /// Outside changes to queue for the batch commit; never a path under `inbox/`.
        public var enqueue: [String] = []
        /// Changed paths whose bytes are not AKit's last write: an open note or map among them
        /// asks Reload / Keep Mine ("Changed on disk").
        public var outside: [String] = []

        public init() {}
    }

    /// The own-write rule: `own` maps a base-relative path to the hash of the bytes AKit last read
    /// or wrote there. A change whose disk hash (`diskHash`, nil for a removed file) equals it is
    /// AKit's own write: it is neither queued again (the save queued it) nor "Changed on disk" —
    /// but it is still reindexed. Every other area or `kb.yaml` change is an outside one.
    public static func batch(_ paths: [String], own: [String: String], diskHash: (String) -> String?) -> Batch {
        var batch = Batch()
        for path in Set(paths).sorted() {
            switch classify(path) {
            case .ignore, .other:
                continue
            case .inbox:
                batch.inbox = true
            case .area(let path), .baseConfig(let path):
                batch.reindex = true
                if path == KnowledgeKinds.fileName { batch.reloadKinds = true }
                if let mine = own[path], mine == diskHash(path) { continue }
                batch.enqueue.append(path)
                batch.outside.append(path)
            }
        }
        return batch
    }

    /// The files under `inbox/` (hidden ones left out, and a map proposal's draft, which goes with
    /// its proposal): the Inbox badge.
    public static func inboxCount(_ root: URL) -> Int {
        let inbox = root.appending(path: "inbox", directoryHint: .isDirectory)
        guard let walker = FileManager.default.enumerator(at: inbox, includingPropertiesForKeys: [.isRegularFileKey],
                                                          options: [.skipsHiddenFiles]) else { return 0 }
        var count = 0
        for case let url as URL in walker where url.pathExtension != "excalidraw"
            && (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            count += 1
        }
        return count
    }
}
