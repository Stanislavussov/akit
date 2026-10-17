import AKitFoundation
import Foundation

/// The app's Update button: has the source folder an AKit build came from moved on since the
/// build? Only reading git commands run (no fetch, no pull): a new version is a commit on the
/// build's branch in that folder, e.g. a feature merged into master there.
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

        /// "2026.10.17", "2026.10.17 + 2"; the commit without a tag.
        public var version: String {
            guard let tag = versionTag else { return head }
            let number = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            return number + (commitsSinceTag > 0 ? " + \(commitsSinceTag)" : "")
        }
    }

    public static let subjectLimit = 10

    /// `commit` is the build's commit (short or full), `branch` the branch it was built from.
    public static func check(source: URL, branch: String, commit: String, env: HarnessEnvironment) async -> Status {
        guard GitCheckout.at(source) != nil else { return .unknown("\(source.path) is not a git checkout") }
        guard let current = await git(["rev-parse", "--abbrev-ref", "HEAD"], in: source, env: env) else {
            return .unknown("git can't read \(source.path)")
        }
        guard current == branch else { return .otherBranch(current) }
        guard let count = await git(["rev-list", "--count", "\(commit)..HEAD"], in: source, env: env).flatMap({ Int($0) }) else {
            return .unknown("The build's commit \(commit) is not in \(source.path)")
        }
        guard count > 0 else { return .upToDate }
        let head = await git(["rev-parse", "--short", "HEAD"], in: source, env: env) ?? "HEAD"
        let subjects = await git(["log", "--format=%s", "-n", "\(subjectLimit)", "\(commit)..HEAD"], in: source, env: env)?
            .split(whereSeparator: \.isNewline).map(String.init) ?? []
        // The same commands as "Stamp build source" in project.yml.
        let tag = await git(["describe", "--tags", "--abbrev=0", "--match", "v[0-9]*", "HEAD"], in: source, env: env)
        let sinceTag = if let tag { await git(["rev-list", "--count", "\(tag)..HEAD"], in: source, env: env).flatMap { Int($0) } ?? 0 } else { 0 }
        let changes = await git(["status", "--porcelain", "--untracked-files=no"], in: source, env: env) ?? ""
        return .available(Available(commits: count, subjects: subjects, head: head, versionTag: tag,
                                    commitsSinceTag: sinceTag, hasUncommittedChanges: !changes.isEmpty))
    }

    private static func git(_ arguments: [String], in folder: URL, env: HarnessEnvironment) async -> String? {
        guard let result = await ProcessRunner.run(env.findExecutable("git") ?? URL(filePath: "/usr/bin/git"),
                                                   arguments: ["-C", folder.path] + arguments, environment: env.gitVariables,
                                                   timeout: 30),
              result.succeeded else { return nil }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
