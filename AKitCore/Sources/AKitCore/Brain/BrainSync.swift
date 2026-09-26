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
              let porcelain = try? await git(["status", "--porcelain"], in: root, env: env) else { return nil }
        let changed = porcelain.split(separator: "\n").map { String($0.dropFirst(3)) }
        guard (try? await git(["rev-parse", "--abbrev-ref", "@{upstream}"], in: root, env: env)) != nil else {
            return Status(hasRemote: false, ahead: 0, behind: 0, changed: changed)
        }
        if fetch { _ = try? await git(["fetch", "--quiet"], in: root, env: env, timeout: 60) }
        let (ahead, behind) = (try? await counts(in: root, env: env)) ?? (0, 0)
        return Status(hasRemote: true, ahead: ahead, behind: behind, changed: changed)
    }

    /// Fetches, brings in remote commits, pushes local ones.
    @discardableResult
    public static func sync(_ root: URL, env: HarnessEnvironment) async throws(Failure) -> Outcome {
        guard FileManager.default.fileExists(atPath: root.appending(path: ".git").path) else {
            throw Failure(message: "\(root.path) is not a git repo.")
        }
        guard (try? await git(["rev-parse", "--abbrev-ref", "@{upstream}"], in: root, env: env)) != nil else {
            throw Failure(message: "The brain has no remote to sync with. Add one: git -C \(root.path) remote add origin <url> && git -C \(root.path) push -u origin HEAD")
        }
        try await git(["fetch", "--quiet"], in: root, env: env, timeout: 60, failure: "Couldn't reach the remote")
        var (ahead, behind) = try await counts(in: root, env: env)

        var pulledPaths: [String] = []
        if behind > 0 {
            let before = try await git(["rev-parse", "HEAD"], in: root, env: env).trimmingCharacters(in: .whitespacesAndNewlines)
            if ahead == 0 {
                // Uncommitted edits stay; git refuses only when the pull would touch them.
                try await git(["merge", "--ff-only", "--quiet", "@{upstream}"], in: root, env: env,
                              failure: "Couldn't bring in the remote changes (commit or undo your edits to those files first)")
            } else {
                // Both Macs committed: put the local commits on top of the remote ones.
                let dirty = try await git(["status", "--porcelain", "--untracked-files=no"], in: root, env: env)
                guard dirty.isEmpty else {
                    throw Failure(message: "Both this Mac and the remote have new commits, and the brain has uncommitted edits. Commit or undo them, then sync again.")
                }
                do {
                    try await git(["rebase", "--quiet", "@{upstream}"], in: root, env: env)
                } catch {
                    let conflicts = (try? await git(["diff", "--name-only", "--diff-filter=U"], in: root, env: env)) ?? ""
                    _ = try? await git(["rebase", "--abort"], in: root, env: env)
                    let files = conflicts.split(separator: "\n").joined(separator: ", ")
                    guard !files.isEmpty else {
                        throw Failure(message: "Couldn't put this Mac's commits on top of the remote ones; nothing was changed. \(error.message)")
                    }
                    throw Failure(message: "This Mac and the remote changed the same lines in \(files). Nothing was changed; merge them by hand in \(root.path).")
                }
            }
            pulledPaths = try await git(["diff", "--name-only", before, "HEAD"], in: root, env: env)
                .split(separator: "\n").map(String.init)
            (ahead, _) = try await counts(in: root, env: env)
        }
        if ahead > 0 {
            try await git(["push", "--quiet"], in: root, env: env, timeout: 60, failure: "Couldn't push")
        }
        return Outcome(pulled: behind, pushed: ahead, pulledPaths: pulledPaths)
    }

    /// Commits ahead of and behind the upstream.
    private static func counts(in root: URL, env: HarnessEnvironment) async throws(Failure) -> (Int, Int) {
        let output = try await git(["rev-list", "--left-right", "--count", "HEAD...@{upstream}"], in: root, env: env)
        let numbers = output.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        guard numbers.count == 2 else { throw Failure(message: "git rev-list said: \(output)") }
        return (numbers[0], numbers[1])
    }

    /// Runs git in the brain; never waits for a password or passphrase prompt.
    @discardableResult
    private static func git(_ arguments: [String], in root: URL, env: HarnessEnvironment, timeout: TimeInterval = 30,
                            failure: String? = nil) async throws(Failure) -> String {
        guard let git = env.findExecutable("git") else { throw Failure(message: "git was not found.") }
        var environment = env.variables.merging(["PATH": env.pathForChildProcesses, "GIT_TERMINAL_PROMPT": "0"]) { $1 }
        if environment["GIT_SSH_COMMAND"] == nil { environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes" }
        let result = await ProcessRunner.run(git, arguments: arguments, directory: root, environment: environment, timeout: timeout)
        guard let result, result.succeeded else {
            let output = result.map { $0.timedOut ? "timed out" : $0.output.trimmingCharacters(in: .whitespacesAndNewlines) } ?? "couldn't start git"
            throw Failure(message: "\(failure ?? "git \(arguments[0]) failed"): \(output)")
        }
        return result.output
    }
}
