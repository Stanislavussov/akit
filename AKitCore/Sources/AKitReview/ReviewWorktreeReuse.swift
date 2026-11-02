import AKitFoundation
import Foundation

/// A new run of a merge request takes the worktree of its newest earlier run instead of making
/// one (R65): the files, and what setup commands installed in them, are already there. AKit
/// moves the worktree into the new run, renames its `akit-review/…` branch, then brings it to the
/// merge request's head: `git pull --ff-only` from the source branch; when the pull fails
/// (the author rewrote the branch, a conflict), `git reset --hard origin/<source branch>`; last,
/// always `git reset --hard` to the exact head GitLab named. The earlier run gets `worktree-removed.json` with `movedTo`, so
/// Ask…, Discuss in Pi… and Restore Files make it a worktree of its own again (R61).
public enum ReviewWorktreeReuse {
    /// A run that may still use its worktree: it gathers or runs passes, and its status changed
    /// within this time.
    static let busyWindow: TimeInterval = 3 * 3600

    /// The newest earlier run of the same merge request with a worktree from the same clone that
    /// nothing works in now; nil when there is none.
    static func donor(for folder: URL, spec: ReviewRunSpec, clone: URL, home: URL, now: Date = .now) -> URL? {
        guard spec.local == nil else { return nil }
        let paths = ReviewPaths(home: home)
        let wanted = clone.standardizedFileURL.resolvingSymlinksInPath().path
        for run in ReviewRuns.list(home: home) where run.id != folder.lastPathComponent {
            guard run.spec.local == nil, run.spec.mergeRequest.url == spec.mergeRequest.url,
                  let used = run.spec.repository?.clone,
                  URL(filePath: used).standardizedFileURL.resolvingSymlinksInPath().path == wanted else { continue }
            let candidate = paths.run(run.id)
            guard FileManager.default.fileExists(atPath: candidate.appending(path: "worktree/.git").path) else { continue }
            if let status = run.status, [.gathering, .estimating, .passes].contains(status.stage),
               now.timeIntervalSince(status.updated) < busyWindow { continue }
            return candidate
        }
        return nil
    }

    /// What a reuse did.
    public struct Taken: Sendable, Hashable {
        /// The earlier run.
        public var from: String
        /// How the worktree reached the head: `pull`, `reset to origin/<branch>`, `reset to <head>`.
        public var how: String
    }

    /// Moves the earlier run's worktree into `folder/worktree` and brings it to `head`. nil when
    /// there is nothing to take or the move failed: Gather then makes a new worktree. A worktree
    /// that moved but can't reach `head` is removed, so no run reads the wrong commit.
    static func take(into folder: URL, spec: ReviewRunSpec, clone: URL, branch: String?, head: String, sourceBranch: String,
                     env: HarnessEnvironment, progress: @escaping @Sendable (String) -> Void) async -> Taken? {
        guard let donor = donor(for: folder, spec: spec, clone: clone, home: env.homeDirectory),
              let git = env.findExecutable("git") else { return nil }
        let target = folder.appending(path: "worktree", directoryHint: .isDirectory)
        guard !FileManager.default.fileExists(atPath: target.path) else { return nil }
        // The same lock as the earlier run's cleanup and restore: neither runs during the move.
        let moved: Bool = await CloneLock.shared.run("run:" + donor.path) {
            let tree = donor.appending(path: "worktree", directoryHint: .isDirectory)
            guard FileManager.default.fileExists(atPath: tree.appending(path: ".git").path) else { return false }
            let bytes = ReviewCleanup.size(of: tree)
            let result = await ProcessRunner.run(git, arguments: ["-C", clone.path, "worktree", "move", tree.path, target.path],
                                                 environment: env.gitVariables, timeout: 300)
            guard result?.succeeded == true else {
                progress("AKit couldn't take the worktree of \(donor.lastPathComponent): "
                         + SecretFilter.masked(String((result?.failureText ?? "git didn't start").suffix(300))))
                return false
            }
            ReviewCleanup.recordMoved(donor, to: folder.lastPathComponent, bytes: bytes)
            return true
        }
        guard moved else { return nil }
        progress("Took the worktree of \(donor.lastPathComponent); updating it to \(head.prefix(10))…")
        // No hooks: the tree holds the merge request's code, and a hooks path in it would run it.
        @Sendable func run(_ arguments: [String], timeout: TimeInterval = 120) async -> ProcessRunner.Result? {
            await ProcessRunner.run(git, arguments: ["-C", target.path, "-c", "core.hooksPath=/dev/null"] + arguments,
                                    environment: env.gitVariables, timeout: timeout)
        }
        if let branch {
            _ = await run(["branch", "-M", branch])
        }
        // One git operation per clone at a time, as the clone's own fetch (R57).
        let how: String = await CloneLock.shared.run(clone.path) {
            var how = ""
            if ReviewGather.isBranchName(sourceBranch) {
                if await run(["pull", "--ff-only", "--no-rebase", "--no-tags", "origin", sourceBranch], timeout: 300)?.succeeded == true {
                    how = "pull"
                } else if await run(["reset", "--hard", "--quiet", "refs/remotes/origin/\(sourceBranch)"])?.succeeded == true {
                    how = "reset to origin/\(sourceBranch)"
                }
            }
            // Always the head GitLab named, and a clean tree: a pull keeps local edits of tracked
            // files (a lock file a setup command rewrote), and the branch may have moved on since.
            if await run(["cat-file", "-e", "\(head)^{commit}"])?.succeeded != true {
                _ = await run(["fetch", "--no-tags", "origin", "refs/merge-requests/\(spec.mergeRequest.iid)/head"], timeout: 300)
            }
            let before = await run(["rev-parse", "HEAD"])?.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if await run(["reset", "--hard", "--quiet", head])?.succeeded == true, before != head {
                how = how.isEmpty ? "reset to \(head.prefix(10))" : how + ", then reset to \(head.prefix(10))"
            }
            return how
        }
        guard await run(["rev-parse", "HEAD"])?.output.trimmingCharacters(in: .whitespacesAndNewlines) == head else {
            progress("The taken worktree couldn't reach \(head.prefix(10)); AKit makes a new one.")
            await ReviewRepository.removeWorktree(target, clones: [clone], env: env)
            return nil
        }
        ReviewGather.removeSecretFiles(in: target)
        progress("The worktree is at \(head.prefix(10)) (\(how.isEmpty ? "already there" : how)).")
        return Taken(from: donor.lastPathComponent, how: how.isEmpty ? "already at the head" : how)
    }
}
