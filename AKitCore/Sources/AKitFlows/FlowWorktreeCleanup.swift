import AKitFoundation
import Foundation

/// Old run worktrees give their disk space back (flows.md step 2c/5, as Review's R61): a run's
/// worktree `~/.akit/local/flows/runs/<run>/worktree` that nobody touched for 14 days is removed
/// with `git worktree remove` only when its run's lock is dead and it has no uncommitted change.
/// A dirty one is kept and flagged on the Runs screen. The run branch `akit-flow/<run>` and the
/// run record stay: the commits are the run's history.
public enum FlowWorktreeCleanup {
    public static let defaultDays = 14

    public struct Worktree: Equatable, Sendable {
        public var run: String
        public var folder: URL
        /// The project's main checkout, from the worktree's `.git` file.
        public var project: URL?
        public var lastUsed: Date
        public var dirty: Bool
        public var locked: Bool
    }

    public static func root(env: HarnessEnvironment) -> URL {
        env.homeDirectory.appending(path: ".akit/local/flows/runs")
    }

    /// Every run worktree on this Mac older than `days` days, with its state.
    public static func old(env: HarnessEnvironment, days: Int = defaultDays, now: Date = .now) -> [Worktree] {
        let limit = now.addingTimeInterval(-Double(days) * 86_400)
        return FileWalk.children(of: root(env: env)).compactMap { run -> Worktree? in
            let tree = run.appending(path: "worktree")
            guard FileManager.default.fileExists(atPath: tree.appending(path: ".git").path) else { return nil }
            let project = mainCheckout(of: tree)
            let record = project?.appending(path: ".pi/akit-flow/runs/\(run.lastPathComponent)")
            let gitDir = GitCheckout.at(tree)?.gitDir
            let used = [record.flatMap { modified($0.appending(path: "events.jsonl")) }, modified(tree),
                        gitDir.flatMap { modified($0.appending(path: "HEAD")) }, gitDir.flatMap { modified($0.appending(path: "index")) }]
                .compactMap { $0 }.max() ?? .distantPast
            guard used < limit else { return nil }
            return Worktree(run: run.lastPathComponent, folder: tree, project: project, lastUsed: used,
                            dirty: isDirty(tree, env: env), locked: record.map(FlowRunSummary.lockAlive) ?? false)
        }
    }

    /// Removes the clean, unlocked old worktrees; returns those removed. Dirty or locked ones stay.
    @discardableResult
    public static func prune(env: HarnessEnvironment, days: Int = defaultDays, now: Date = .now) -> [Worktree] {
        old(env: env, days: days, now: now).filter { tree in
            guard !tree.dirty, !tree.locked, let project = tree.project else { return false }
            let result = git(["worktree", "remove", tree.folder.path], in: project, env: env)
            return result?.succeeded == true
        }
    }

    /// The project's main checkout, read from the worktree's `.git` file (absolute or relative `gitdir:`).
    static func mainCheckout(of tree: URL) -> URL? {
        GitCheckout.at(tree)?.mainFolder
    }

    /// Changed or untracked files; an unreadable worktree counts as dirty, so it is kept.
    static func isDirty(_ tree: URL, env: HarnessEnvironment) -> Bool {
        guard let result = git(["status", "--porcelain"], in: tree, env: env), result.succeeded else { return true }
        return !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    static func git(_ arguments: [String], in folder: URL, env: HarnessEnvironment) -> ProcessRunner.Result? {
        ProcessRunner.runAndWait(URL(filePath: "/usr/bin/git"), arguments: ["-C", folder.path] + arguments,
                                 environment: env.variables.merging(["HOME": env.homeDirectory.path]) { $1 }, timeout: 30)
    }
}
