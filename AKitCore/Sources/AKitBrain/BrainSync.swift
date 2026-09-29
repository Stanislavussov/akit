import AKitFoundation
import Foundation

/// Keeps the brain in step with its git remote (GitHub) so every Mac sees the same skills
/// and layers. Sync = fetch, bring in the other Macs' commits (fast-forward, or a rebase of
/// the local commits when both sides changed), then push. Nothing is ever forced: a conflict
/// is undone and reported, uncommitted edits are never committed or thrown away.
public enum BrainSync {
    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    public struct Status: Sendable, Equatable {
        /// The current branch has an upstream (e.g. origin/main).
        public var hasRemote: Bool
        /// Local commits not on the remote yet, and remote commits not here yet
        /// (as of the last fetch).
        public var ahead: Int
        public var behind: Int
        /// Uncommitted paths (hand edits); sync leaves them alone.
        public var changed: [String]
        /// Why sync can't run now, or the last fetch failed (e.g. no network).
        public var problem: String?

        public var isInSync: Bool { hasRemote && ahead == 0 && behind == 0 }
    }

    public struct Outcome: Sendable, Equatable {
        public var pulled: Int
        public var pushed: Int
        /// Brain paths the pulled commits changed.
        public var pulledPaths: [String]

        /// The pull changed the core layer or a skill it lists: the home folder needs
        /// `akit apply --home`.
        public func changesCore(in brain: Brain?) -> Bool {
            let coreSkills = Set(brain?.layers.first { $0.name == "core" }?.skills.map(\.name) ?? [])
            return pulledPaths.contains { path in
                path.hasPrefix("layers/core/")
                    || (path.hasPrefix("skills/") && coreSkills.contains(String(path.dropFirst(7).prefix { $0 != "/" })))
            }
        }
    }

    /// The brain's sync state. `fetch` asks the remote first (network); without it the
    /// counts are as of the last fetch. nil when the brain isn't a git repo or git is missing.
    public static func status(of root: URL, env: HarnessEnvironment, fetch: Bool) async -> Status? {
        guard FileManager.default.fileExists(atPath: root.appending(path: ".git").path),
              let changed = try? await uncommitted(in: root, env: env) else { return nil }
        var status = Status(hasRemote: false, ahead: 0, behind: 0, changed: changed)
        if let problem = await blocker(in: root, env: env) {
            status.problem = problem
            return status
        }
        guard let upstream = await upstream(in: root, env: env) else { return status }
        status.hasRemote = true
        if fetch {
            do {
                try await git(["fetch", "--quiet", upstream.remote], in: root, env: env, timeout: 60,
                              extra: await sshVariables(in: root, env: env), failure: "Couldn't reach the remote")
            } catch {
                status.problem = error.message
            }
        }
        if let (ahead, behind) = try? await counts(in: root, env: env) {
            (status.ahead, status.behind) = (ahead, behind)
        }
        return status
    }

    /// Fetches, brings in remote commits, pushes local ones. On a work Mac (or with a broken
    /// `machine.json`) the commits a rebase makes carry the brain's own git identity, never the
    /// environment's or a global signing key, and it refuses to rebase without that identity.
    @discardableResult
    public static func sync(_ root: URL, env: HarnessEnvironment) async throws(Failure) -> Outcome {
        guard FileManager.default.fileExists(atPath: root.appending(path: ".git").path) else {
            throw Failure(message: "\(root.path) is not a git repo.")
        }
        let work = MachineProfile.load(home: env.homeDirectory).isWork
        if let problem = await blocker(in: root, env: env) { throw Failure(message: problem) }
        guard let upstream = await upstream(in: root, env: env) else {
            throw Failure(message: "The brain has no remote to sync with. Add one: git -C \(root.path) remote add origin <url> && git -C \(root.path) push -u origin HEAD")
        }
        let ssh = await sshVariables(in: root, env: env)
        try await git(["fetch", "--quiet", upstream.remote], in: root, env: env, timeout: 60, extra: ssh, failure: "Couldn't reach the remote")
        guard (try? await git(["rev-parse", "--verify", "--quiet", "@{upstream}"], in: root, env: env)) != nil else {
            throw Failure(message: "The remote has no branch \(upstream.branch) yet. Push it once: git -C \(root.path) push -u \(upstream.remote) HEAD")
        }
        var (ahead, behind) = try await counts(in: root, env: env)

        var pulledPaths: [String] = []
        if behind > 0 {
            let before = lastLine(try await git(["rev-parse", "HEAD"], in: root, env: env))
            if ahead == 0 {
                // Uncommitted edits stay; git refuses only when the pull would touch them.
                try await git(["merge", "--ff-only", "--quiet", "@{upstream}"], in: root, env: env, timeout: 120, work: work,
                              failure: "Couldn't bring in the remote changes (commit or undo your edits to those files first)")
            } else {
                // Both Macs committed: put the local commits on top of the remote ones.
                let dirty = try await git(["status", "--porcelain", "--untracked-files=no"], in: root, env: env)
                guard withoutWarnings(dirty).isEmpty else {
                    throw Failure(message: "Both this Mac and the remote have new commits, and the brain has uncommitted edits. Commit or undo them, then sync again.")
                }
                let merges = try await git(["rev-list", "--merges", "@{upstream}..HEAD"], in: root, env: env)
                guard withoutWarnings(merges).isEmpty else {
                    throw Failure(message: "This Mac has merge commits the remote doesn't have. Merge by hand in \(root.path), then sync again.")
                }
                if work {
                    do {
                        try await BrainGit.requireOwnIdentity(brain: root, env: env)
                    } catch {
                        throw Failure(message: "Both this Mac and the remote have new commits; putting this Mac's on top would re-stamp them. \(error.message). Nothing was changed.")
                    }
                }
                do {
                    try await git(["rebase", "--quiet", "@{upstream}"], in: root, env: env, timeout: 120, work: work)
                } catch {
                    try await undoRebase(in: root, env: env, work: work, after: error)
                }
            }
            let diff = try await git(["-c", "core.quotePath=false", "diff", "--name-only", "--no-renames", "-z", before, "HEAD"], in: root, env: env)
            pulledPaths = records(diff)
            (ahead, _) = try await counts(in: root, env: env)
        }
        if ahead > 0 {
            try await git(["push", "--quiet", upstream.remote, "HEAD:\(upstream.merge)"], in: root, env: env, timeout: 60,
                          extra: ssh, work: work, failure: "Couldn't push")
        }
        return Outcome(pulled: behind, pushed: ahead, pulledPaths: pulledPaths)
    }

    /// A failed rebase: abort it and say why, or say plainly that it is still half done.
    private static func undoRebase(in root: URL, env: HarnessEnvironment, work: Bool, after error: Failure) async throws(Failure) -> Never {
        let conflicts = records((try? await git(["-c", "core.quotePath=false", "diff", "--name-only", "--diff-filter=U", "-z"], in: root, env: env)) ?? "")
        let aborted = (try? await git(["rebase", "--abort"], in: root, env: env, timeout: 60, work: work)) != nil
        let fm = FileManager.default
        guard aborted, !fm.fileExists(atPath: root.appending(path: ".git/rebase-merge").path),
              !fm.fileExists(atPath: root.appending(path: ".git/rebase-apply").path) else {
            throw Failure(message: "The brain is stuck halfway through a rebase. Run: git -C \(root.path) rebase --abort (\(error.message))")
        }
        guard !conflicts.isEmpty else {
            throw Failure(message: "Couldn't put this Mac's commits on top of the remote ones; nothing was changed. \(error.message)")
        }
        throw Failure(message: "This Mac and the remote changed the same lines in \(conflicts.joined(separator: ", ")). Nothing was changed; merge them by hand in \(root.path).")
    }

    /// A half-done git operation or a detached HEAD: sync would do the wrong thing.
    private static func blocker(in root: URL, env: HarnessEnvironment) async -> String? {
        let git = root.appending(path: ".git")
        let fm = FileManager.default
        if fm.fileExists(atPath: git.appending(path: "rebase-merge").path) || fm.fileExists(atPath: git.appending(path: "rebase-apply").path) {
            return "A rebase is in progress in \(root.path). Finish it or run git rebase --abort, then sync."
        }
        if fm.fileExists(atPath: git.appending(path: "MERGE_HEAD").path) || fm.fileExists(atPath: git.appending(path: "CHERRY_PICK_HEAD").path) {
            return "A merge is in progress in \(root.path). Finish it or abort it, then sync."
        }
        if (try? await self.git(["symbolic-ref", "--quiet", "HEAD"], in: root, env: env)) == nil {
            return "The brain is not on a branch (detached HEAD). Check out its branch in \(root.path), then sync."
        }
        return nil
    }

    private struct Upstream {
        let remote: String
        /// `refs/heads/main` on the remote.
        let merge: String
        var branch: String { merge.hasPrefix("refs/heads/") ? String(merge.dropFirst(11)) : merge }
    }

    /// The current branch's configured upstream, or nil.
    private static func upstream(in root: URL, env: HarnessEnvironment) async -> Upstream? {
        guard let branch = try? lastLine(await git(["symbolic-ref", "--quiet", "--short", "HEAD"], in: root, env: env)),
              let remote = try? lastLine(await git(["config", "--get", "branch.\(branch).remote"], in: root, env: env)),
              let merge = try? lastLine(await git(["config", "--get", "branch.\(branch).merge"], in: root, env: env)),
              !remote.isEmpty, remote != ".", !merge.isEmpty else { return nil }
        return Upstream(remote: remote, merge: merge)
    }

    /// Uncommitted paths, without taking git's index lock (the app may be syncing).
    private static func uncommitted(in root: URL, env: HarnessEnvironment) async throws(Failure) -> [String] {
        let output = try await git(["--no-optional-locks", "-c", "core.quotePath=false", "status", "--porcelain", "-z"], in: root, env: env)
        var paths: [String] = []
        var entries = records(output).makeIterator()
        while let entry = entries.next() {
            paths.append(String(entry.dropFirst(3)))
            if entry.first == "R" || entry.first == "C" { _ = entries.next() }  // the old path
        }
        return paths
    }

    /// Commits ahead of and behind the upstream.
    private static func counts(in root: URL, env: HarnessEnvironment) async throws(Failure) -> (Int, Int) {
        let output = lastLine(try await git(["rev-list", "--left-right", "--count", "HEAD...@{upstream}"], in: root, env: env))
        let numbers = output.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        guard numbers.count == 2 else { throw Failure(message: "git rev-list said: \(output)") }
        return (numbers[0], numbers[1])
    }

    /// Keeps ssh from asking for a passphrase, unless the user configured ssh for git
    /// themselves (another key or account): then that is used as is.
    private static func sshVariables(in root: URL, env: HarnessEnvironment) async -> [String: String] {
        if env.variables["GIT_SSH_COMMAND"] != nil || env.variables["GIT_SSH"] != nil { return [:] }
        if let configured = try? await git(["config", "--get", "core.sshCommand"], in: root, env: env), !lastLine(configured).isEmpty { return [:] }
        return ["GIT_SSH_COMMAND": "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new"]
    }

    // git's stderr is mixed into the output: drop its warnings before parsing.
    private static func withoutWarnings(_ output: String) -> String {
        output.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("warning: ") && !$0.hasPrefix("hint: ") }
            .joined(separator: "\n")
    }

    private static func lastLine(_ output: String) -> String {
        withoutWarnings(output).split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    /// NUL-separated records (`-z` output).
    private static func records(_ output: String) -> [String] {
        withoutWarnings(output).split(separator: "\0").map(String.init).filter { !$0.trimmingCharacters(in: .newlines).isEmpty }
    }

    /// Runs git in the brain; never waits for a password prompt. `work`: as `WorkFilter` commits,
    /// without the identity variables and unsigned, so a work Mac's rebase carries the brain's identity.
    @discardableResult
    private static func git(_ arguments: [String], in root: URL, env: HarnessEnvironment, timeout: TimeInterval = 30,
                            extra: [String: String] = [:], work: Bool = false, failure: String? = nil) async throws(Failure) -> String {
        guard let git = env.findExecutable("git") else { throw Failure(message: "git was not found.") }
        var environment = env.gitVariables
            .merging(extra) { $1 }
        if work { environment = BrainGit.withoutIdentity(environment) }
        let result = await ProcessRunner.run(git, arguments: (work ? BrainGit.noSigning : []) + arguments, directory: root,
                                             environment: environment, timeout: timeout)
        guard let result, result.succeeded else {
            let output = result.map(\.failureText) ?? "couldn't start git"
            throw Failure(message: "\(failure ?? "git \(arguments.first { !$0.hasPrefix("-") } ?? "") failed"): \(output)")
        }
        return result.output
    }
}
