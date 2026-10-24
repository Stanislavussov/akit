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
        let remotes = try await run(["remote"])
        if !remotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw Failure(message: "\(base.path) has a git remote (\(remotes.split(separator: "\n").joined(separator: ", "))), and a knowledge base never has one, so nothing was committed. Remove it: git -C \(base.path) remote remove <name>")
        }
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

    /// Every path is base-relative and stays inside the base.
    static func checkInside(_ paths: [String]) throws(Failure) {
        if let bad = paths.first(where: { !isInside($0) }) { throw Failure(message: "\(bad) is not a path inside the base.") }
    }

    static func isInside(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
    }

    /// The base's remote names; empty when it has none. nil when it is not a git repo.
    public func remotes() async -> [String]? {
        guard FileManager.default.fileExists(atPath: base.appending(path: ".git").path),
              let output = try? await run(["remote"]) else { return nil }
        return output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Runs git in the base; the output on success.
    @discardableResult
    func run(_ arguments: [String]) async throws(Failure) -> String {
        let git = env.findExecutable("git") ?? URL(filePath: "/usr/bin/git")
        let result = await ProcessRunner.run(git, arguments: arguments, directory: base, environment: Self.variables(env), timeout: 30)
        guard let result, result.succeeded else {
            let detail = result.map(\.failureText) ?? "couldn't start git"
            throw Failure(message: "git \(arguments.first { !$0.hasPrefix("-") && !$0.contains("=") } ?? "") failed in \(base.path): \(detail)")
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
