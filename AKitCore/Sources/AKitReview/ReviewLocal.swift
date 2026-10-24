import AKitFoundation
import Foundation

/// A review of a local git workspace (`docs/design/review.md`, "Local review"): a worktree of
/// Orca or herdr, or any clone. No GitLab: the change is a range of commits, the uncommitted
/// changes, or both, and the findings stay in AKit.
public struct ReviewLocalTarget: Codable, Sendable, Hashable {
    public enum Mode: String, Codable, Sendable, CaseIterable, Identifiable {
        /// The commits since the base and the uncommitted changes.
        case all
        case commits
        case uncommitted

        public var id: Self { self }

        public var title: String {
            switch self {
            case .all: "Commits and uncommitted changes"
            case .commits: "Commits only"
            case .uncommitted: "Uncommitted changes only"
            }
        }
    }

    public struct Commit: Codable, Sendable, Hashable, Identifiable {
        public var sha: String
        public var subject: String
        public var author: String
        public var date: String
        public var id: String { sha }
    }

    /// The workspace's top folder.
    public var path: String
    public var repository: String
    /// `HEAD` when detached.
    public var branch: String
    /// What the commits are counted from: `origin/main`, or the ref the user gave.
    public var baseRef: String
    /// The ref the user gave as the end of the range; nil = the workspace's HEAD.
    public var headRef: String?
    public var mode: Mode
    /// The diff is `base..head`.
    public var base: String
    /// HEAD, or a snapshot commit of the uncommitted changes (made with a temporary index, so
    /// nothing of the workspace changes).
    public var head: String
    public var commits: [Commit]
    /// `git status --porcelain` lines of the uncommitted changes the review includes.
    public var uncommitted: [String]

    /// "3 commits since origin/main and 2 uncommitted files".
    public var summary: String {
        let commitText = "\(commits.count) commit\(commits.count == 1 ? "" : "s") since \(baseRef)"
        let changeText = "\(uncommitted.count) uncommitted file\(uncommitted.count == 1 ? "" : "s")"
        return switch mode {
        case .all: "\(commitText) and \(changeText)"
        case .commits: commitText
        case .uncommitted: changeText + " (the diff against HEAD)"
        }
    }
}

public enum ReviewLocal {
    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// What a workspace holds to review, before anything is made.
    public struct Inspection: Sendable, Hashable {
        public var path: String
        public var repository: String
        public var branch: String
        public var head: String
        /// The end of the range the user gave; nil = the workspace's HEAD (then the uncommitted
        /// changes count too).
        public var headRef: String?
        /// nil when no base branch was found (a repository without `main` or `master`).
        public var baseRef: String?
        public var mergeBase: String?
        public var commits: [ReviewLocalTarget.Commit]
        public var uncommitted: [String]
        /// `group/project` from the `origin` remote, when it has one.
        public var remoteProject: String?
        public var remoteHost: String?

        /// The mode that reviews everything there is; nil when there is nothing.
        public var suggestedMode: ReviewLocalTarget.Mode? {
            switch (!commits.isEmpty, !uncommitted.isEmpty) {
            case (true, true): .all
            case (true, false): .commits
            case (false, true): .uncommitted
            case (false, false): nil
            }
        }

        /// Whether `mode` has something to review here.
        public func has(_ mode: ReviewLocalTarget.Mode) -> Bool {
            switch mode {
            case .all: !commits.isEmpty || !uncommitted.isEmpty
            case .commits: !commits.isEmpty
            case .uncommitted: !uncommitted.isEmpty
            }
        }

        /// What the workspace holds, in one sentence: the range, or that only the diff is there.
        public var summary: String {
            let base = baseRef ?? "the base"
            switch (commits.count, uncommitted.count) {
            case (0, 0): return "Nothing to review: no commits since \(base) and no uncommitted changes."
            case (0, let files): return "No commits since \(base): only the uncommitted changes (\(files) file\(files == 1 ? "" : "s")) to review."
            case (let count, 0): return "\(count) commit\(count == 1 ? "" : "s") since \(base) (\(mergeBase?.prefix(10) ?? "?")..\(head.prefix(10))); no uncommitted changes."
            case (let count, let files):
                return "\(count) commit\(count == 1 ? "" : "s") since \(base) (\(mergeBase?.prefix(10) ?? "?")..\(head.prefix(10))) and \(files) uncommitted file\(files == 1 ? "" : "s")."
            }
        }
    }

    static let maxCommits = 200
    static let maxUncommitted = 500

    /// Reads the workspace: its branch, the base, the commits since it, the uncommitted files.
    /// `baseRef`: the ref to count from; nil = the repository's default branch.
    /// `headRef`: the end of the range; nil = HEAD. Another commit than HEAD has no uncommitted
    /// changes: they belong to the workspace's HEAD.
    public static func inspect(path: URL, baseRef: String? = nil, headRef: String? = nil, env: HarnessEnvironment) async throws -> Inspection {
        guard let git = env.findExecutable("git") else { throw Failure(message: "git is not installed.") }
        func raw(_ arguments: [String], in folder: URL = path) async -> String? {
            let result = await ProcessRunner.run(git, arguments: ["-C", folder.path] + arguments, environment: env.gitVariables, timeout: 60)
            return result?.succeeded == true ? result!.output : nil
        }
        func run(_ arguments: [String], in folder: URL = path) async -> String? {
            await raw(arguments, in: folder)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard FileManager.default.fileExists(atPath: path.path) else { throw Failure(message: "\(path.path) doesn't exist.") }
        guard let top = await run(["rev-parse", "--show-toplevel"]), !top.isEmpty else {
            throw Failure(message: "\(path.path) is not a git workspace.")
        }
        let root = URL(filePath: top)
        guard let workspaceHead = await run(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"], in: root), !workspaceHead.isEmpty else {
            throw Failure(message: "\(top) has no commit yet.")
        }
        var head = workspaceHead
        var branch = await run(["rev-parse", "--abbrev-ref", "HEAD"], in: root) ?? "HEAD"
        var chosenHead: String?
        if let headRef {
            guard isRefName(headRef), let sha = await run(["rev-parse", "--verify", "--quiet", "\(headRef)^{commit}"], in: root), !sha.isEmpty else {
                throw Failure(message: "\(headRef) is not a branch, tag or commit of \(top).")
            }
            // The workspace's own HEAD by another name is still the workspace, with its changes.
            if sha != workspaceHead {
                head = sha
                branch = headRef
                chosenHead = headRef
            }
        }
        var base: String?
        if let baseRef {
            guard isRefName(baseRef), await run(["rev-parse", "--verify", "--quiet", "\(baseRef)^{commit}"], in: root) != nil else {
                throw Failure(message: "\(baseRef) is not a branch, tag or commit of \(top).")
            }
            base = baseRef
        } else {
            var candidates: [String] = []
            if let remoteHead = await run(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], in: root) { candidates.append(remoteHead) }
            candidates += ["origin/main", "origin/master", "main", "master"]
            for candidate in candidates where candidate != branch {
                if await run(["rev-parse", "--verify", "--quiet", "\(candidate)^{commit}"], in: root) != nil {
                    base = candidate
                    break
                }
            }
        }
        var mergeBase: String?
        var commits: [ReviewLocalTarget.Commit] = []
        if let base, let point = await run(["merge-base", head, base], in: root), !point.isEmpty {
            mergeBase = point
            let log = await run(["log", "-n", String(maxCommits), "--date=short", "--format=%H%x1f%s%x1f%an%x1f%ad", "\(point)..\(head)"], in: root) ?? ""
            commits = log.split(separator: "\n").compactMap { line in
                let parts = line.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 4 else { return nil }
                return ReviewLocalTarget.Commit(sha: parts[0], subject: parts[1], author: parts[2], date: parts[3])
            }
        }
        // Untrimmed: a status line starts with a space when only the working tree changed.
        let status = chosenHead != nil ? "" : await raw(["status", "--porcelain=v1", "--untracked-files=all"], in: root) ?? ""
        let uncommitted = status.split(separator: "\n").map(String.init).filter { !$0.isEmpty }.prefix(maxUncommitted)
        let remote = await run(["remote", "get-url", "origin"], in: root).flatMap(remoteProject)
        return Inspection(path: top, repository: root.lastPathComponent, branch: branch, head: head, headRef: chosenHead, baseRef: base, mergeBase: mergeBase,
                          commits: commits, uncommitted: Array(uncommitted), remoteProject: remote?.project, remoteHost: remote?.host)
    }

    /// The range to review: `base..head`, with a snapshot commit of the uncommitted changes when
    /// the mode takes them. The snapshot is made with a temporary index, so the workspace's
    /// index, files and branches stay as they are.
    public static func target(_ inspection: Inspection, mode: ReviewLocalTarget.Mode, env: HarnessEnvironment) async throws -> ReviewLocalTarget {
        guard inspection.has(mode) else { throw Failure(message: "Nothing to review in this mode. " + inspection.summary) }
        // Everything there is: without a base, that is the uncommitted changes.
        let takesCommits = mode == .commits || (mode == .all && inspection.mergeBase != nil)
        let takesChanges = mode != .commits && !inspection.uncommitted.isEmpty
        if takesCommits, inspection.mergeBase == nil {
            throw Failure(message: "There is no base to count the commits from: give one with --base (a branch, tag or commit).")
        }
        let base = takesCommits ? inspection.mergeBase! : inspection.head
        let head = takesChanges ? try await snapshot(URL(filePath: inspection.path), env: env) : inspection.head
        return ReviewLocalTarget(path: inspection.path, repository: inspection.repository, branch: inspection.branch,
                                 baseRef: takesCommits ? (inspection.baseRef ?? "?") : "HEAD", headRef: inspection.headRef, mode: mode, base: base, head: head,
                                 commits: takesCommits ? inspection.commits : [], uncommitted: takesChanges ? inspection.uncommitted : [])
    }

    /// A commit of the whole working tree (untracked files too, `.gitignore` honoured) on top of
    /// HEAD. It is only an object in the repository: no branch, index or file of the workspace
    /// changes, and git drops it later.
    static func snapshot(_ root: URL, env: HarnessEnvironment) async throws -> String {
        guard let git = env.findExecutable("git") else { throw Failure(message: "git is not installed.") }
        let temp = FileManager.default.temporaryDirectory.appending(path: "akit-review-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        var variables = env.gitVariables
        variables["GIT_INDEX_FILE"] = temp.path
        for key in ["GIT_AUTHOR_NAME", "GIT_COMMITTER_NAME"] { variables[key] = "AKit review" }
        for key in ["GIT_AUTHOR_EMAIL", "GIT_COMMITTER_EMAIL"] { variables[key] = "akit-review@localhost" }
        func run(_ arguments: [String]) async throws -> String {
            let result = await ProcessRunner.run(git, arguments: ["-C", root.path] + arguments, environment: variables, timeout: 300)
            guard let result, result.succeeded else {
                throw Failure(message: "git \(arguments.first ?? "") failed while taking the uncommitted changes: "
                              + SecretFilter.masked(String((result?.output ?? "it didn't start").suffix(300))))
            }
            return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Start from the workspace's own index (fast for big repositories), then add everything.
        let indexPath = try await run(["rev-parse", "--git-path", "index"])
        let index = indexPath.hasPrefix("/") ? URL(filePath: indexPath) : root.appending(path: indexPath)
        if FileManager.default.fileExists(atPath: index.path) { try FileManager.default.copyItem(at: index, to: temp) }
        _ = try await run(["add", "-A"])
        let tree = try await run(["write-tree"])
        return try await run(["commit-tree", tree, "-p", "HEAD", "-m", "AKit review: uncommitted changes"])
    }

    /// A ref the user typed: a branch, tag, remote branch or commit id (`HEAD~2` too), never an
    /// option. Branch names can hold `#` and `+` (`feature/AB#41-total`); git refuses spaces,
    /// `:`, `?`, `*`, `[`, `\\` and `..` in a ref, and `{` would let a revision suffix in.
    static func isRefName(_ text: String) -> Bool {
        text.range(of: #"^[A-Za-z0-9_][^\s:?*\[\\{}]*$"#, options: .regularExpression) != nil && !text.contains("..")
            && !text.hasSuffix(".lock") && text.count <= 200
    }

    /// `git@host:group/project.git`, `https://host/group/project.git` → (host, `group/project`).
    static func remoteProject(_ url: String) -> (host: String, project: String)? {
        var text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix(".git") { text.removeLast(4) }
        if let parsed = URL(string: text), let host = parsed.host(), parsed.scheme != nil {
            let path = parsed.path().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return path.isEmpty ? nil : (host.lowercased(), path)
        }
        // scp style: user@host:group/project
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let host = text[..<colon].split(separator: "@").last.map(String.init) ?? ""
        let path = String(text[text.index(after: colon)...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return host.isEmpty || path.isEmpty ? nil : (host.lowercased(), path)
    }

    /// The project profile of a workspace: the one whose GitLab project is the `origin`
    /// remote, or whose checkout is this repository.
    public static func profile(for inspection: Inspection, in catalog: ReviewCatalog, env: HarnessEnvironment) -> ReviewProfile? {
        if let project = inspection.remoteProject?.lowercased(), let host = inspection.remoteHost {
            if let match = catalog.profiles.first(where: {
                $0.gitlabProjectPath.lowercased() == project && (URL(string: $0.gitlabHost)?.host()?.lowercased() == host)
            }) { return match }
        }
        let top = URL(filePath: inspection.path).resolvingSymlinksInPath().path
        return catalog.profiles.first { profile in
            guard let checkout = profile.checkout else { return false }
            return env.expand(checkout).resolvingSymlinksInPath().path == top
        }
    }
}
