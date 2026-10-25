import AKitFoundation
import Darwin
import Foundation

/// Git in a knowledge base (P8). `commit(paths:message:)` is the only way anything in AKit
/// commits there: it takes the base's git lock (`.akit-queue.lock`, shared with the app's commit
/// queue and every other process), stages exactly the named paths and commits exactly those
/// (`git add -- <paths>`, `git commit -- <paths>`), never whatever else is staged. A base never
/// has a remote (K11): a commit is refused while one is set.
public struct KnowledgeGit: Sendable {
    public struct Failure: Error, LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { message }
        public init(message: String) { self.message = message }
    }

    public let base: URL
    public let env: HarnessEnvironment

    public init(base: URL, env: HarnessEnvironment) {
        self.base = base
        self.env = env
    }

    /// Commits the base-relative `paths` (added, changed or deleted files) with `message`.
    /// false when none of them changed (nothing is committed). Waits up to `lockTimeout` seconds
    /// for another writer to finish.
    @discardableResult
    public func commit(paths: [String], message: String, lockTimeout: TimeInterval = 2) async throws(Failure) -> Bool {
        guard !paths.isEmpty else { return false }
        try Self.checkInside(paths)
        let lockFile = base.appending(path: KnowledgeBase.queueLockName)
        let lock: FileLock?
        do { lock = try FileLock.acquire(lockFile, timeout: lockTimeout) } catch {
            throw Failure(message: "Can't open the lock \(lockFile.path): \(error.localizedDescription)")
        }
        guard let lock else {
            throw Failure(message: "Another AKit is writing to the knowledge base (\(lockFile.lastPathComponent) is held); try again in a moment.")
        }
        defer { lock.release() }
        return try await commit(paths: paths, message: message, alreadyLocked: lock)
    }

    /// The commit itself, for a caller that holds the base's git lock already (the commit queue's
    /// flush, which must not take it a second time: a second `flock` on a new descriptor of the
    /// same file would wait for the first one, in the same process too).
    func commit(paths: [String], message: String, alreadyLocked lock: FileLock) async throws(Failure) -> Bool {
        guard !paths.isEmpty else { return false }
        try Self.checkInside(paths)
        let remotes = try await remoteNames()
        if !remotes.isEmpty {
            throw Failure(message: "\(base.path) has a git remote (\(remotes.joined(separator: ", "))), and a knowledge base never has one, so nothing was committed. Remove it: git -C \(base.path) remote remove <name>")
        }
        let aliases = caseAliases(paths)
        if !aliases.isEmpty { return try await commitCaseRename(paths: paths, aliases: aliases, message: message) }
        // A path git doesn't know and that is gone has nothing to add.
        let present = paths.filter { FileManager.default.fileExists(atPath: base.appending(path: $0).path) }
        let tracked = try await run(["ls-files", "--"] + paths).split(separator: "\n").map(String.init)
        let staged = Array(Set(present + paths.filter { path in tracked.contains { $0 == path || $0.hasPrefix(path + "/") } })).sorted()
        guard !staged.isEmpty else { return false }
        _ = try await run(["add", "--all", "--"] + staged)
        guard !(try await run(["diff", "--cached", "--name-only", "--"] + staged)).isEmpty else { return false }
        _ = try await run(["-c", "commit.gpgsign=false", "commit", "--quiet", "--no-verify", "-m", message, "--"] + staged)
        return true
    }

    /// The old names of case-only renames among `paths` on a disk that ignores case: two paths
    /// that differ only in case, both "existing", while the folder lists one of them. That one is
    /// the new name; the other is returned.
    func caseAliases(_ paths: [String]) -> Set<String> {
        var old: Set<String> = []
        for (index, path) in paths.enumerated() {
            for other in paths[(index + 1)...] where other != path && other.lowercased() == path.lowercased() {
                let folder = base.appending(path: path).deletingLastPathComponent()
                let names = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
                let first = (path as NSString).lastPathComponent, second = (other as NSString).lastPathComponent
                guard FileManager.default.fileExists(atPath: base.appending(path: path).path),
                      FileManager.default.fileExists(atPath: base.appending(path: other).path) else { continue }
                if names.contains(first), !names.contains(second) { old.insert(other) }
                if names.contains(second), !names.contains(first) { old.insert(path) }
            }
        }
        return old
    }

    /// A commit with a case-only rename on a disk that ignores case. `git commit -- paths` builds
    /// its index from HEAD, where the old name is, and refuses the new one as its alias, so the
    /// commit is built in a temporary index instead: HEAD, the old names removed, the other paths
    /// added (explicit pathspecs only), committed whole. The real index then gets the same
    /// change for these paths; whatever else is staged there stays staged and out of the commit.
    func commitCaseRename(paths: [String], aliases: Set<String>, message: String) async throws(Failure) -> Bool {
        let added = Array(Set(paths.filter { !aliases.contains($0) && FileManager.default.fileExists(atPath: base.appending(path: $0).path) }))
            .sorted()
        // The old names, and any named path that is gone (a deletion in the same commit).
        let removed = Array(aliases.union(paths.filter { !FileManager.default.fileExists(atPath: base.appending(path: $0).path) })).sorted()
        let index = base.appending(path: ".git/akit-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: index) }
        let temporary = ["GIT_INDEX_FILE": index.path]
        _ = try await run(["read-tree", "HEAD"], extra: temporary)
        _ = try await run(["rm", "-r", "--cached", "--quiet", "--ignore-unmatch", "--"] + removed, extra: temporary)
        if !added.isEmpty { _ = try await run(["add", "--all", "--"] + added, extra: temporary) }
        guard !(try await run(["diff", "--cached", "--name-only", "HEAD"], extra: temporary)).isEmpty else { return false }
        _ = try await run(["-c", "commit.gpgsign=false", "commit", "--quiet", "--no-verify", "-m", message], extra: temporary)
        _ = try await run(["rm", "-r", "--cached", "--quiet", "--ignore-unmatch", "--"] + removed)
        if !added.isEmpty { _ = try await run(["add", "--all", "--"] + added) }
        return true
    }

    /// Every path is base-relative and stays inside the base.
    static func checkInside(_ paths: [String]) throws(Failure) {
        if let bad = paths.first(where: { !isInside($0) }) { throw Failure(message: "\(bad) is not a path inside the base.") }
    }

    static func isInside(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
    }

    /// The base's remote names; empty when it has none. nil when it is not a git repo.
    public func remotes() async -> [String]? {
        guard FileManager.default.fileExists(atPath: base.appending(path: ".git").path) else { return nil }
        return try? await remoteNames()
    }

    /// The remote names, read from the repository's config file without starting git (`GitCheckout`);
    /// through `git remote` only when that file includes others or can't be read.
    func remoteNames() async throws(Failure) -> [String] {
        if let checkout = GitCheckout.at(base),
           let config = try? String(contentsOf: checkout.commonDir.appending(path: "config"), encoding: .utf8),
           let names = GitCheckout.remoteNames(inConfig: config) {
            return names
        }
        return try await run(["remote"]).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The base-relative paths under `areas/` and `kb.yaml` that differ from the last commit
    /// (changed, added, deleted, untracked; both sides of a rename), sorted. Read with
    /// `GIT_OPTIONAL_LOCKS=0`, so it never takes git's index lock from a writer.
    public func changedPaths() async throws(Failure) -> [String] {
        let output = try await run(["status", "--porcelain=v1", "-z", "--untracked-files=all", "--", "areas/", KnowledgeKinds.fileName],
                                   extra: ["GIT_OPTIONAL_LOCKS": "0"])
        var paths: Set<String> = []
        var entries = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)[...]
        while let entry = entries.popFirst() {
            guard entry.count > 3 else { continue }
            let status = entry.prefix(2)
            paths.insert(String(entry.dropFirst(3)))
            // A rename or copy names its source next, as an entry of its own.
            if status.contains("R") || status.contains("C"), let source = entries.popFirst() { paths.insert(source) }
        }
        return paths.filter { $0 == KnowledgeKinds.fileName || $0.hasPrefix("areas/") }.sorted()
    }

    /// Runs git in the base; the output on success. Only `init` runs in a folder without its own
    /// `.git`: any other command would reach a repository above the base (git looks up the folder
    /// tree), so it is refused, and `GIT_CEILING_DIRECTORIES` keeps git from looking above the base.
    @discardableResult
    func run(_ arguments: [String], extra: [String: String] = [:]) async throws(Failure) -> String {
        let command = arguments.first { !$0.hasPrefix("-") && !$0.contains("=") } ?? ""
        if command != "init", !FileManager.default.fileExists(atPath: base.appending(path: ".git").path) {
            throw Failure(message: "\(base.path) is not a git repository (no .git), so git \(command) didn't run there.")
        }
        var variables = Self.variables(env).merging(extra) { _, new in new }
        variables["GIT_CEILING_DIRECTORIES"] = FileWalk.realPath(base.deletingLastPathComponent()) ?? base.deletingLastPathComponent().path
        let git = env.findExecutable("git") ?? URL(filePath: "/usr/bin/git")
        let result = await ProcessRunner.run(git, arguments: arguments, directory: base, environment: variables, timeout: 30)
        guard let result, result.succeeded else {
            let detail = result.map(\.failureText) ?? "couldn't start git"
            throw Failure(message: "git \(command) failed in \(base.path): \(detail)")
        }
        return result.output
    }

    /// The caller's environment without the variables that would point git at another repository
    /// (set when akit runs inside a git hook).
    static func variables(_ env: HarnessEnvironment) -> [String: String] {
        let redirecting: Set = ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_COMMON_DIR", "GIT_PREFIX"]
        return env.gitVariables.filter { !redirecting.contains($0.key) }
    }
}
