import AKitFoundation
import Foundation

/// Old runs give their disk space back (R61). A run nobody touched for 14 days loses its
/// worktrees (the files at the reviewed commit, with what setup commands installed in them) and
/// their `akit-review/…` branches; the run folder with its findings, requests and sessions stays.
/// `worktree-removed.json` in the run says what went. Continuing the run (the passes, Ask…,
/// Discuss in Pi…, Restore Files) makes the worktrees again at the same commits: the clone is
/// fetched, the worktree added, the setup commands run again.
public enum ReviewCleanup {
    public static let defaultDays = 14
    static let markerName = "worktree-removed.json"

    /// What a cleanup removed from a run (`worktree-removed.json`).
    public struct Removed: Codable, Sendable, Hashable {
        public var date: Date
        /// The removed worktrees, relative to the run folder: `worktree`, `linked/<key>/worktree`.
        public var worktrees: [String]
        /// Their size on disk.
        public var bytes: Int64
        /// Why the last restore failed; nil before one.
        public var problem: String?
        /// The days without use that let the cleanup take them; nil = 14.
        public var days: Int?
        /// The later run of the same merge request that took the worktree (R65); nil = a cleanup.
        public var movedTo: String?
    }

    /// A run whose worktrees a cleanup may remove.
    public struct Candidate: Codable, Sendable, Hashable {
        public var id: String
        public var folder: URL
        /// The newest change of the run's own files.
        public var lastUsed: Date
        /// Relative to the run folder.
        public var worktrees: [String]
        public var bytes: Int64
    }

    // MARK: - Which runs

    /// Runs with a worktree whose own files didn't change for `days` days, oldest first.
    /// `skip`: runs AKit works on now.
    public static func candidates(home: URL, days: Int = defaultDays, now: Date = .now, skip: Set<String> = []) -> [Candidate] {
        let limit = now.addingTimeInterval(-Double(days) * 86_400)
        return FileWalk.children(of: ReviewPaths(home: home).runs).compactMap { folder -> Candidate? in
            let id = folder.lastPathComponent
            guard !skip.contains(id), FileManager.default.fileExists(atPath: folder.appending(path: "run.json").path) else { return nil }
            let trees = worktrees(folder)
            guard !trees.isEmpty, let used = lastUsed(folder), used < limit else { return nil }
            return Candidate(id: id, folder: folder, lastUsed: used, worktrees: trees, bytes: 0)
        }.sorted { $0.lastUsed < $1.lastUsed }
    }

    /// The worktrees a run has now, relative to its folder.
    static func worktrees(_ folder: URL) -> [String] {
        var found: [String] = []
        if FileManager.default.fileExists(atPath: folder.appending(path: "worktree/.git").path) { found.append("worktree") }
        for linked in FileWalk.children(of: folder.appending(path: "linked")) where
            FileManager.default.fileExists(atPath: linked.appending(path: "worktree/.git").path) {
            found.append("linked/\(linked.lastPathComponent)/worktree")
        }
        return found
    }

    /// The newest modification of the files at the top of the run folder (run.json, status,
    /// findings, requests, the conversation, …), not of the worktrees.
    static func lastUsed(_ folder: URL) -> Date? {
        FileWalk.children(of: folder).compactMap { url -> Date? in
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true else { return nil }
            return values.contentModificationDate
        }.max()
    }

    /// The allocated size of a folder's files; symbolic links are not followed.
    public static func size(of folder: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    // MARK: - Removing

    /// Removes the worktrees of every run unused for `days` days; returns what it removed.
    public static func pruneOld(env: HarnessEnvironment, days: Int = defaultDays, now: Date = .now, skip: Set<String> = []) async -> [Candidate] {
        var pruned: [Candidate] = []
        for candidate in candidates(home: env.homeDirectory, days: days, now: now, skip: skip) {
            if let removed = await prune(candidate.folder, env: env, days: days) {
                var done = candidate
                done.bytes = removed.bytes
                pruned.append(done)
            }
        }
        return pruned
    }

    /// Removes a run's worktrees and their `akit-review/…` branches when it went `days` days
    /// without use, and records it; nil when it had none or was used since.
    @discardableResult
    public static func prune(_ folder: URL, env: HarnessEnvironment, days: Int = defaultDays) async -> Removed? {
        await CloneLock.shared.run("run:" + folder.path) { await pruneNow(folder, env: env, days: days) }
    }

    private static func pruneNow(_ folder: URL, env: HarnessEnvironment, days: Int) async -> Removed? {
        let trees = worktrees(folder)
        // Used again since it was listed (a restore marks it): it stays.
        guard !trees.isEmpty, let used = lastUsed(folder), used < Date.now.addingTimeInterval(-Double(days) * 86_400) else { return nil }
        let bytes = trees.reduce(Int64(0)) { $0 + size(of: folder.appending(path: $1)) }
        // An earlier record keeps what it named: a failed restore may have made only some trees.
        let earlier = removed(folder)?.worktrees ?? []
        await ReviewGather.removeWorktree(run: folder, env: env)
        await ReviewLinked.removeWorktrees(run: folder, env: env)
        let record = Removed(date: .now, worktrees: earlier + trees.filter { !earlier.contains($0) }, bytes: bytes, days: days)
        try? ReviewJSON.write(record, to: folder.appending(path: markerName))
        return record
    }

    /// A later run took the run's worktree (R65): restoring makes it a new one, as after a cleanup.
    static func recordMoved(_ folder: URL, to run: String, bytes: Int64) {
        let earlier = removed(folder)?.worktrees ?? []
        let record = Removed(date: .now, worktrees: earlier.contains("worktree") ? earlier : earlier + ["worktree"], bytes: bytes, movedTo: run)
        try? ReviewJSON.write(record, to: folder.appending(path: markerName))
    }

    /// What a cleanup removed from the run; nil when its worktrees are there (or it never had one).
    public static func removed(_ folder: URL) -> Removed? {
        ReviewJSON.read(Removed.self, from: folder.appending(path: markerName))
    }

    // MARK: - Restoring

    /// Makes the removed worktrees again at the run's commits and runs the setup commands in the
    /// main one. nil when every worktree is back; else what failed (the record stays).
    /// One restore or prune of a run at a time in this process; a restore marks the run used
    /// first, so a cleanup elsewhere (the app, `akit review prune`) doesn't take it meanwhile.
    public static func restore(_ folder: URL, env: HarnessEnvironment, progress: @escaping @Sendable (String) -> Void = { _ in }) async -> String? {
        await CloneLock.shared.run("run:" + folder.path) { await restoreNow(folder, env: env, progress: progress) }
    }

    private static func restoreNow(_ folder: URL, env: HarnessEnvironment, progress: @escaping @Sendable (String) -> Void) async -> String? {
        guard var record = removed(folder) else { return nil }
        markUsed(folder)
        guard let spec = ReviewJSON.read(ReviewRunSpec.self, from: folder.appending(path: "run.json")), let head = spec.headSHA else {
            return "\(folder.lastPathComponent) has no gathered run.json."
        }
        let profiles = ReviewCatalog.load(home: env.homeDirectory, brain: nil).profiles
        func profile(_ slug: String?) -> ReviewProfile? { slug.flatMap { slug in profiles.first { $0.slug == slug } } }
        var problems: [String] = []
        // Entries made again (with their setup) leave the record: a later call doesn't redo them.
        var done: Set<String> = []

        if record.worktrees.contains("worktree") {
            let tree = folder.appending(path: "worktree", directoryHint: .isDirectory)
            var checkout: URL?
            var branch: String?
            if let local = spec.local {
                checkout = URL(filePath: local.path, directoryHint: .isDirectory)
            } else {
                let got = await ReviewRepository.source(for: spec.mergeRequest, profile: profile(spec.project), env: env, progress: progress)
                if let source = got.source {
                    checkout = source.checkout
                    branch = source.owned ? spec.repository?.branch : nil
                } else {
                    problems.append((got.problem ?? "There is no clone of \(spec.mergeRequest.projectPath).") + (got.how.isEmpty ? "" : " " + got.how))
                }
            }
            if let checkout {
                progress("Restoring the worktree at \(head.prefix(10))…")
                if let problem = await ReviewGather.makeWorktree(checkout: checkout, at: tree, head: head, iid: spec.mergeRequest.iid,
                                                                 branch: branch, env: env) {
                    problems.append(problem)
                } else if let setup = spec.setup, !setup.isEmpty,
                          let failed = await ReviewGather.runSetup(setup, in: tree, folder: folder, env: env, progress: progress).failed {
                    problems.append("The setup command `\(failed.run)` failed; its log is setup/\(failed.name).log in the run folder.")
                } else {
                    done.insert("worktree")
                }
            }
        }
        for change in spec.linked ?? [] {
            let relative = "linked/\(change.key)/worktree"
            guard record.worktrees.contains(relative), let linkedHead = change.headSHA else { continue }
            let got = await ReviewRepository.source(for: change.mergeRequest, profile: profile(change.project), env: env, progress: progress)
            guard let source = got.source else {
                problems.append("\(change.mergeRequest.label): " + (got.problem ?? "there is no clone."))
                continue
            }
            progress("Restoring the worktree of \(change.mergeRequest.label) at \(linkedHead.prefix(10))…")
            let branch = source.owned ? ReviewRepository.branch(for: "\(spec.id)-\(change.key)") : nil
            if let problem = await ReviewGather.makeWorktree(checkout: source.checkout, at: ReviewLinked.worktree(folder, key: change.key),
                                                             head: linkedHead, iid: change.mergeRequest.iid, branch: branch, env: env) {
                problems.append("\(change.mergeRequest.label): \(problem)")
            } else {
                done.insert(relative)
            }
        }
        // A tree removed meanwhile (another AKit's cleanup) is not back.
        for relative in done where !FileManager.default.fileExists(atPath: folder.appending(path: relative + "/.git").path) {
            done.remove(relative)
            problems.append("\(relative) was removed again while AKit restored it.")
        }

        let marker = folder.appending(path: markerName)
        if problems.isEmpty {
            try? FileManager.default.removeItem(at: marker)
            markUsed(folder)
            progress("The worktrees are back.")
            return nil
        }
        let problem = problems.joined(separator: " ")
        record.problem = problem
        record.worktrees.removeAll { done.contains($0) }
        try? ReviewJSON.write(record, to: marker)
        return problem
    }

    /// Restored counts as used: the next cleanup doesn't take it during or right after.
    static func markUsed(_ folder: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: folder.appending(path: "run.json").path)
    }

    /// Before the run is continued: restores what a cleanup removed. A failure is a progress
    /// line, not an error: the run goes on with the diff alone, as without a clone.
    public static func restoreIfRemoved(_ folder: URL, env: HarnessEnvironment, progress: @escaping @Sendable (String) -> Void) async {
        guard let record = removed(folder) else { return }
        progress(record.movedTo.map { "The newer review \($0) took this run's worktree; making a new one…" }
                 ?? "AKit removed this run's worktree to save disk space; making it again…")
        if let problem = await restore(folder, env: env, progress: progress) {
            progress("The worktree couldn't be restored: \(problem)")
        }
    }
}

