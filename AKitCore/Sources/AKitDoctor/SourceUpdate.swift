import AKitFoundation
import Foundation

/// The app's Update button: has the source folder an AKit build came from moved on since the
/// build? A new version is a commit on the build's branch in that folder (a feature merged
/// there), or on its upstream branch (`origin/master`, a release pushed from another Mac): with
/// `fetch`, `git fetch` brings the upstream branch and tags first (objects, the remote-tracking
/// ref and tags; no gc). The folder's files change only when Update runs `pull` (fast-forward only).
public enum SourceUpdate {
    public enum Status: Sendable, Equatable {
        /// The branch is still at the build's commit.
        case upToDate
        case available(Available)
        /// The folder has another branch checked out: a build now would be of that branch.
        case otherBranch(String)
        /// Not a git checkout, or git failed; the text says why.
        case unknown(String)
    }

    public struct Available: Sendable, Equatable {
        /// Commits on the branch after the build's commit.
        public let commits: Int
        /// Their summary lines, newest first, at most `subjectLimit`.
        public let subjects: [String]
        /// The branch's commit now (short).
        public let head: String
        /// The latest date tag at the branch's commit and the commits after it, as BuildInfo stamps them.
        public let versionTag: String?
        public let commitsSinceTag: Int
        /// Uncommitted changes to tracked files in the folder: a build now would include them.
        public let hasUncommittedChanges: Bool
        /// The new commits are on the upstream branch only: Update pulls them first.
        public var needsPull = false
        /// The upstream branch, `origin/master`; nil when the branch has none.
        public var upstream: String? = nil
        /// Commits the upstream has that the folder lacks while the folder has its own on top:
        /// a release Update can't pull, to merge by hand.
        public var upstreamAhead = 0

        /// "2026.10.17", "2026.10.17 + 2"; the commit without a tag.
        public var version: String {
            guard let tag = versionTag else { return head }
            let number = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            return number + (commitsSinceTag > 0 ? " + \(commitsSinceTag)" : "")
        }
    }

    public static let subjectLimit = 10

    /// `commit` is the build's commit (short or full), `branch` the branch it was built from.
    public static func check(source: URL, branch: String, commit: String, env: HarnessEnvironment, fetch: Bool = false) async -> Status {
        guard GitCheckout.at(source) != nil else { return .unknown("\(source.path) is not a git checkout") }
        guard let current = await git(["rev-parse", "--abbrev-ref", "HEAD"], in: source, env: env) else {
            return .unknown("git can't read \(source.path)")
        }
        guard current == branch else { return .otherBranch(current) }
        // The upstream branch, fetched first: a release pushed from another Mac. The remote and
        // its branch come from the branch's settings (a remote may have a / in its name).
        let upstream = await git(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], in: source, env: env)
        if fetch, upstream != nil, let remote = await git(["config", "--get", "branch.\(branch).remote"], in: source, env: env), remote != ".",
           let merge = await git(["config", "--get", "branch.\(branch).merge"], in: source, env: env) {
            let ssh = await git(["config", "--get", "core.sshCommand"], in: source, env: env)
            // No auto gc or maintenance in the user's repository, no FETCH_HEAD; the tags are for the version text.
            _ = await git(["-c", "gc.auto=0", "-c", "maintenance.auto=false", "fetch", "--quiet", "--tags", "--no-write-fetch-head",
                           "--no-recurse-submodules", remote, merge], in: source, env: env, network: true, sshCommand: ssh)
        }
        // The upstream is the target when it is ahead of the folder and the folder has nothing of its own on top.
        var target = "HEAD"
        var upstreamAhead = 0
        if let upstream {
            let behind = await git(["rev-list", "--count", "HEAD..\(upstream)"], in: source, env: env).flatMap { Int($0) } ?? 0
            let ahead = await git(["rev-list", "--count", "\(upstream)..HEAD"], in: source, env: env).flatMap { Int($0) } ?? 0
            if behind > 0, ahead == 0 { target = upstream } else if behind > 0 { upstreamAhead = behind }
        }
        guard let count = await git(["rev-list", "--count", "\(commit)..\(target)"], in: source, env: env).flatMap({ Int($0) }) else {
            return .unknown("The build's commit \(commit) is not in \(source.path)")
        }
        guard count > 0 else { return .upToDate }
        let head = await git(["rev-parse", "--short", target], in: source, env: env) ?? target
        let subjects = await git(["log", "--format=%s", "-n", "\(subjectLimit)", "\(commit)..\(target)"], in: source, env: env)?
            .split(whereSeparator: \.isNewline).map(String.init) ?? []
        // The same commands as "Stamp build source" in project.yml.
        let tag = await git(["describe", "--tags", "--abbrev=0", "--match", "v[0-9]*", target], in: source, env: env)
        let sinceTag = if let tag { await git(["rev-list", "--count", "\(tag)..\(target)"], in: source, env: env).flatMap { Int($0) } ?? 0 } else { 0 }
        let changes = await git(["status", "--porcelain", "--untracked-files=no"], in: source, env: env) ?? ""
        var available = Available(commits: count, subjects: subjects, head: head, versionTag: tag,
                                  commitsSinceTag: sinceTag, hasUncommittedChanges: !changes.isEmpty)
        available.needsPull = target != "HEAD"
        available.upstream = upstream
        available.upstreamAhead = upstreamAhead
        return .available(available)
    }

    /// Update's first step when the new commits are upstream: `git pull --ff-only`. nil when it
    /// worked; else git's reason (the folder has commits of its own, or changes in the same files).
    public static func pull(source: URL, env: HarnessEnvironment) async -> String? {
        let result = await ProcessRunner.run(env.findExecutable("git") ?? URL(filePath: "/usr/bin/git"),
                                             arguments: ["-C", source.path, "pull", "--ff-only", "--quiet", "--no-recurse-submodules"],
                                             environment: networkVariables(env, sshCommand: await git(["config", "--get", "core.sshCommand"],
                                                                                                      in: source, env: env)),
                                             timeout: 120)
        guard let result else { return "git pull didn't start." }
        if result.succeeded { return nil }
        if result.timedOut { return "git pull took longer than 2 minutes." }
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return "git pull --ff-only failed in \(source.path)" + (output.isEmpty ? "." : ":\n\(output.split(whereSeparator: \.isNewline).suffix(8).joined(separator: "\n"))")
    }

    /// Git with the network: never a password prompt or an SSH question that would hang. The
    /// user's own SSH command (`GIT_SSH_COMMAND`, `core.sshCommand`) stays, with batch mode added;
    /// with `GIT_SSH` set, SSH is left as it is.
    static func networkVariables(_ env: HarnessEnvironment, sshCommand: String? = nil) -> [String: String] {
        var variables = env.gitVariables.merging(["GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0"]) { $1 }
        if let own = env.variables["GIT_SSH_COMMAND"] ?? sshCommand, !own.isEmpty {
            variables["GIT_SSH_COMMAND"] = own + " -o BatchMode=yes"
        } else if env.variables["GIT_SSH"] == nil {
            variables["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes"
        }
        return variables
    }

    private static func git(_ arguments: [String], in folder: URL, env: HarnessEnvironment, network: Bool = false,
                            sshCommand: String? = nil) async -> String? {
        guard let result = await ProcessRunner.run(env.findExecutable("git") ?? URL(filePath: "/usr/bin/git"),
                                                   arguments: ["-C", folder.path] + arguments,
                                                   // No index refresh by `git status`: its index.lock would make an
                                                   // agent's commit in the same folder fail while AKit checks.
                                                   environment: network ? networkVariables(env, sshCommand: sshCommand) : env.gitVariables.merging(["GIT_OPTIONAL_LOCKS": "0"]) { $1 },
                                                   timeout: network ? 60 : 30),
              result.succeeded else { return nil }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
