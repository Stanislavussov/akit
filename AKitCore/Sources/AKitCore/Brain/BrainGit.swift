import Foundation

/// How a work Mac's git commands in the brain keep the work identity out: the brain's own
/// name and email, never the environment's, and never signed with a global key. Used by a
/// sync's rebase and by the insights commits (`WorkFilter`).
enum BrainGit {
    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Variables that would win over the brain's configured identity in a commit git makes.
    static let identityVariables = ["GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL", "EMAIL"]

    /// The environment without `identityVariables`, so commits (also a sync's rebase) carry the brain's own identity.
    static func withoutIdentity(_ environment: [String: String]) -> [String: String] {
        environment.filter { !identityVariables.contains($0.key) }
    }

    /// Keeps a global `commit.gpgsign` (maybe with a work key) from signing the brain's commits.
    static let noSigning = ["-c", "commit.gpgsign=false"]

    /// The brain's own `user.email` and `user.name` (in its `.git/config`), checked fail-closed with
    /// git: without them a commit would carry the global ones, maybe the work ones.
    static func requireOwnIdentity(brain root: URL, env: HarnessEnvironment) async throws(Failure) {
        for (key, what) in [("user.email", "email"), ("user.name", "name")] {
            let value = try await git(["config", "--local", "--get", key], in: root, env: env,
                                      failure: "The brain has no git \(what) of its own, so a commit would carry the global one (maybe the work \(what))")
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Failure(message: "The brain's git \(what) is empty. Set one: git -C \(root.path) config \(key) <personal \(what)>")
            }
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
