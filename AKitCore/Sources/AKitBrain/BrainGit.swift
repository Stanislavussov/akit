import AKitFoundation
import Foundation

/// How a work Mac's git commands in the brain keep the work identity out: the brain's own
/// name and email, never the environment's, and never signed with a global key. Used by a
/// sync's rebase and by the insights commits (`WorkFilter`).
public enum BrainGit {
    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Variables that would win over the brain's configured identity in a commit git makes.
    static let identityVariables = ["GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL", "EMAIL"]

    /// The environment without `identityVariables`, so commits (also a sync's rebase) carry the brain's own identity.
    public static func withoutIdentity(_ environment: [String: String]) -> [String: String] {
        environment.filter { !identityVariables.contains($0.key) }
    }

    /// Keeps a global `commit.gpgsign` (maybe with a work key) from signing the brain's commits.
    public static let noSigning = ["-c", "commit.gpgsign=false"]

    /// The brain's own `user.email` and `user.name` (in its `.git/config`), checked fail-closed with
    /// git: without them a commit would carry the global ones, maybe the work ones.
    public static func requireOwnIdentity(brain root: URL, env: HarnessEnvironment) async throws(Failure) {
        for (key, what) in [("user.email", "email"), ("user.name", "name")] {
            let value = try await git(["config", "--local", "--get", key], in: root, env: env,
                                      failure: "The brain has no git \(what) of its own, so a commit would carry the global one (maybe the work \(what))")
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Failure(message: "The brain's git \(what) is empty. Set one: git -C \(root.path) config \(key) <personal \(what)>")
            }
        }
    }

    /// How a skill, layer or library commit runs in the brain. A personal Mac: as it always did. A
    /// work Mac (or one whose machine.json can't be read): like the work Mac's other brain commits:
    /// the brain's own identity (checked first; the environment's dropped), no hooks, never signed.
    public struct CommitStyle: Sendable {
        /// Before the git command (`-c` options).
        public let options: [String]
        /// After `commit`.
        public let commitFlags: [String]
        public let environment: [String: String]
    }

    public static func commitStyle(brain root: URL, env: HarnessEnvironment) async throws(Failure) -> CommitStyle {
        let environment = env.variables.merging(["PATH": env.pathForChildProcesses]) { $1 }
        guard MachineProfile.load(home: env.homeDirectory).isWork else {
            return CommitStyle(options: [], commitFlags: [], environment: environment)
        }
        try await requireOwnIdentity(brain: root, env: env)
        return CommitStyle(options: ["-c", "core.hooksPath=/dev/null"] + noSigning, commitFlags: ["--no-verify"],
                           environment: withoutIdentity(environment))
    }

    /// Before a skill, layer or library edit writes anything: on a work Mac the brain must have its own
    /// identity, or the commit after the edit would be refused and leave the edit uncommitted.
    /// Returns the problem, nil when the commit can go ahead (or the brain is not a git repo).
    public static func commitProblem(brain root: URL, env: HarnessEnvironment) async -> String? {
        guard FileManager.default.fileExists(atPath: root.appending(path: ".git").path),
              MachineProfile.load(home: env.homeDirectory).isWork else { return nil }
        do {
            try await requireOwnIdentity(brain: root, env: env)
            return nil
        } catch {
            return error.message + " Nothing was changed."
        }
    }

    /// Runs git in the brain. Output is stdout and stderr combined.
    private static func git(_ arguments: [String], in root: URL, env: HarnessEnvironment, failure: String) async throws(Failure) -> String {
        guard let git = env.findExecutable("git") else { throw Failure(message: "git was not found, so nothing was committed.") }
        let result = await ProcessRunner.run(git, arguments: ["-C", root.path] + arguments, directory: root,
                                             environment: env.gitVariables, timeout: 30)
        guard let result, result.succeeded else {
            let output = result.map(\.failureText) ?? "couldn't start git"
            throw Failure(message: "\(failure) (\(output)). Nothing was committed.")
        }
        return result.output
    }
}
