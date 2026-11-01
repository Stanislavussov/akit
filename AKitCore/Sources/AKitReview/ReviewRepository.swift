import AKitFoundation
import Foundation

/// Where a run's worktree comes from: the profile's `checkout:` (the user's own clone), else
/// AKit's own clone of the project in `~/.akit/local/review/repos/<host>/<path>`, made on the
/// first run and fetched before each one. In its own clone AKit puts each run's worktree on a
/// branch `akit-review/<run>`; deleting the run removes the worktree and the branch.
public enum ReviewRepository {
    public static let branchPrefix = "akit-review/"

    /// The clone a run uses.
    public struct Source: Sendable, Hashable {
        public var checkout: URL
        /// AKit's own clone: AKit fetches into its refs and makes branches in it.
        public var owned: Bool
    }

    /// What git tells about the merge request before the fetch pass, so the pass reads less
    /// through GitLab's MCP server (`run.json` `repository`).
    public struct Plan: Codable, Sendable, Hashable {
        /// The merge request's head (`refs/merge-requests/<iid>/head`).
        public var head: String
        /// The merge base with the default branch, when git knows it.
        public var base: String?
        /// Files changed between `base` and `head`.
        public var files: [String]
        /// Merge requests merged before that changed these files, from git's commit messages
        /// (`See merge request group/project!123`): file → numbers, newest first.
        public var earlier: [String: [Int]]

        public var earlierNumbers: [Int] {
            var all: [Int] = []
            for file in files { for number in earlier[file] ?? [] where !all.contains(number) { all.append(number) } }
            return all
        }
    }

    /// The run's repository, as Gather used it (`run.json` `repository`).
    public struct Use: Codable, Sendable, Hashable {
        public var clone: String
        public var owned: Bool
        /// The worktree's branch in AKit's clone; nil in the user's checkout (a detached worktree).
        public var branch: String?
        public var plan: Plan?
    }

    // MARK: - Where

    public static func folder(home: URL, host: String, projectPath: String) -> URL? {
        let name = hostName(host)
        guard !name.isEmpty, name.range(of: "^[A-Za-z0-9.-]+(:[0-9]+)?$", options: .regularExpression) != nil,
              isProjectPath(projectPath) else { return nil }
        return ReviewPaths(home: home).repos.appending(path: name.replacingOccurrences(of: ":", with: "_"), directoryHint: .isDirectory)
            .appending(path: projectPath, directoryHint: .isDirectory)
    }

    /// `https://gitlab.example.com:8443/` → `gitlab.example.com:8443`.
    static func hostName(_ host: String) -> String {
        var text = host.trimmingCharacters(in: .whitespaces)
        if let range = text.range(of: "://") { text = String(text[range.upperBound...]) }
        if let slash = text.firstIndex(of: "/") { text = String(text[..<slash]) }
        if let at = text.lastIndex(of: "@") { text = String(text[text.index(after: at)...]) }
        return text.lowercased()
    }

    static func isProjectPath(_ path: String) -> Bool {
        path.range(of: "^[A-Za-z0-9_.][A-Za-z0-9_./-]*$", options: .regularExpression) != nil && !path.contains("..")
            && !path.contains("//") && !path.hasSuffix("/") && path.count <= 300
    }

    /// A git URL AKit hands to `git clone`: never an option, never a local path or `ext::`.
    public static func isCloneURL(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, !value.hasPrefix("-"), !value.contains(" "), !value.contains("\n") else { return false }
        if value.hasPrefix("https://") || value.hasPrefix("ssh://") { return true }
        return value.range(of: "^[A-Za-z0-9._-]+@[A-Za-z0-9.-]+:[A-Za-z0-9_./-]+$", options: .regularExpression) != nil
    }

    /// The URLs AKit tries, in order: the profile's `clone_url:`, else SSH, then HTTPS.
    static func cloneURLs(host: String, projectPath: String, profile: ReviewProfile?) -> [String] {
        if let url = profile?.cloneURL { return [url] }
        let name = hostName(host)
        let bare = name.split(separator: ":").first.map(String.init) ?? name
        let scheme = host.lowercased().hasPrefix("http://") ? "http" : "https"
        return ["git@\(bare):\(projectPath).git", "\(scheme)://\(name)/\(projectPath).git"]
    }

    /// The run's clone: the profile's checkout, else AKit's own (cloned or fetched now). nil and
    /// why not, with what to do about it.
    public static func source(for ref: MergeRequestRef, profile: ReviewProfile?, env: HarnessEnvironment,
                              progress: @escaping @Sendable (String) -> Void = { _ in }) async -> (source: Source?, problem: String?, how: String) {
        if let checkout = profile?.checkout {
            return (Source(checkout: env.expand(checkout), owned: false), nil, "")
        }
        guard profile?.clone != false else {
            return (nil, "The project profile turns AKit's clone off (clone: false) and names no checkout.",
                    "Set checkout: <path of your clone>, or remove clone: false.")
        }
        guard let folder = folder(home: env.homeDirectory, host: ref.host, projectPath: ref.projectPath) else {
            return (nil, "AKit can't make a clone folder for \(ref.host)/\(ref.projectPath).", "Add checkout: <path of your clone> to the profile.")
        }
        let urls = cloneURLs(host: ref.host, projectPath: ref.projectPath, profile: profile)
        let problem = await CloneLock.shared.run(folder.path) {
            await ensureClone(at: folder, urls: urls, iid: ref.iid, env: env, progress: progress)
        }
        if let problem {
            return (nil, problem, profile?.cloneURL == nil
                    ? "Check that git can clone \(urls.joined(separator: " or ")) on this Mac (an SSH key or a git credential helper), or set clone_url: or checkout: in the profile."
                    : "Check that git can clone \(urls[0]) on this Mac, or set checkout: in the profile.")
        }
        return (Source(checkout: folder, owned: true), nil, "")
    }

    /// Clones when the folder has no clone yet, else fetches every branch; then the merge
    /// request's head into `refs/akit/mr/<iid>`. nil when the clone is ready.
    static func ensureClone(at folder: URL, urls: [String], iid: Int, env: HarnessEnvironment, progress: (String) -> Void) async -> String? {
        guard let git = env.findExecutable("git") else { return "git is not installed." }
        var variables = env.gitVariables
        // No password or host key prompt: a clone that would ask fails and the next URL is tried.
        if variables["GIT_SSH_COMMAND"] == nil { variables["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes" }
        func run(_ arguments: [String], timeout: TimeInterval) async -> ProcessRunner.Result? {
            await ProcessRunner.run(git, arguments: ["-C", folder.path] + arguments, environment: variables, timeout: timeout)
        }
        let fm = FileManager.default
        if !fm.fileExists(atPath: folder.appending(path: ".git").path) {
            try? fm.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
            let partial = folder.deletingLastPathComponent().appending(path: folder.lastPathComponent + ".partial")
            var failures: [String] = []
            for url in urls {
                try? fm.removeItem(at: partial)
                progress("Cloning \(url) for AKit's own worktrees (only the first time)…")
                let result = await ProcessRunner.run(git, arguments: ["clone", "--no-checkout", "--", url, partial.path],
                                                     environment: variables, timeout: 3600)
                if result?.succeeded == true {
                    try? fm.removeItem(at: folder)
                    do { try fm.moveItem(at: partial, to: folder) } catch { return "AKit couldn't move its clone into \(folder.path)." }
                    break
                }
                failures.append("\(url): " + SecretFilter.masked(String((result?.failureText ?? "it didn't start").suffix(200))))
            }
            try? fm.removeItem(at: partial)
            guard fm.fileExists(atPath: folder.appending(path: ".git").path) else {
                return "git couldn't clone the project: " + failures.joined(separator: "; ")
            }
        } else {
            progress("Fetching the project into AKit's clone…")
            let fetched = await run(["fetch", "--no-tags", "--prune", "origin"], timeout: 1200)
            if fetched?.succeeded != true {
                return "git fetch failed in \(folder.path): " + SecretFilter.masked(String((fetched?.failureText ?? "it didn't start").suffix(300)))
            }
        }
        if iid > 0 {
            // GitLab keeps every merge request's head under refs/merge-requests/<iid>/head. An old
            // copy goes first, so a failed fetch leaves none rather than an earlier head.
            _ = await run(["update-ref", "-d", "refs/akit/mr/\(iid)"], timeout: 30)
            _ = await run(["fetch", "--no-tags", "origin", "+refs/merge-requests/\(iid)/head:refs/akit/mr/\(iid)"], timeout: 600)
        }
        return nil
    }

    // MARK: - Before the fetch pass

    /// The merge request's head, base and changed files from git, with the merge requests merged
    /// before that changed them; nil when git doesn't know the head.
    public static func plan(_ source: Source, ref: MergeRequestRef, env: HarnessEnvironment) async -> Plan? {
        guard let git = env.findExecutable("git") else { return nil }
        func run(_ arguments: [String], timeout: TimeInterval = 60) async -> String? {
            let result = await ProcessRunner.run(git, arguments: ["-C", source.checkout.path] + arguments, environment: env.gitVariables, timeout: timeout)
            return result?.succeeded == true ? result!.output.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        }
        let head: String
        if source.owned {
            guard let found = await run(["rev-parse", "--verify", "--quiet", "refs/akit/mr/\(ref.iid)^{commit}"]), ReviewGather.isCommitID(found)
            else { return nil }
            head = found
        } else {
            // The user's clone: the head's id from GitLab, then fetched without a destination, so
            // none of its branches moves and another fetch's FETCH_HEAD can't mix in.
            guard let listed = await run(["ls-remote", "origin", "refs/merge-requests/\(ref.iid)/head"], timeout: 120),
                  let id = listed.split(whereSeparator: \.isWhitespace).first.map(String.init), ReviewGather.isCommitID(id) else { return nil }
            if await run(["cat-file", "-e", "\(id)^{commit}"]) == nil {
                _ = await run(["fetch", "--no-tags", "origin", "refs/merge-requests/\(ref.iid)/head"], timeout: 300)
            }
            guard await run(["cat-file", "-e", "\(id)^{commit}"]) != nil else { return nil }
            head = id
        }
        let base = await mergeBase(source, head: head, target: nil, env: env)
        var plan = Plan(head: head, base: base, files: [], earlier: [:])
        guard let base, let names = await run(["diff", "--name-only", "--no-renames", base, head]) else { return plan }
        plan.files = names.split(separator: "\n").map(String.init)
        plan.earlier = await earlierMergeRequests(source.checkout, files: plan.files, base: base, ref: ref, env: env)
        return plan
    }

    /// Whether the clone has the commit.
    public static func knows(_ commit: String, in checkout: URL, env: HarnessEnvironment) async -> Bool {
        guard ReviewGather.isCommitID(commit), let git = env.findExecutable("git") else { return false }
        return await ProcessRunner.run(git, arguments: ["-C", checkout.path, "cat-file", "-e", "\(commit)^{commit}"],
                                       environment: env.gitVariables, timeout: 30)?.succeeded == true
    }

    /// The merge base of `head` and the target branch (the default branch when nil or unknown).
    public static func mergeBase(_ source: Source, head: String, target: String?, env: HarnessEnvironment) async -> String? {
        guard let git = env.findExecutable("git") else { return nil }
        var candidates: [String] = []
        if let target, ReviewGather.isBranchName(target) { candidates.append("refs/remotes/origin/\(target)") }
        candidates.append("refs/remotes/origin/HEAD")
        for candidate in candidates {
            let result = await ProcessRunner.run(git, arguments: ["-C", source.checkout.path, "merge-base", candidate, head],
                                                 environment: env.gitVariables, timeout: 60)
            if result?.succeeded == true, let text = result?.output.trimmingCharacters(in: .whitespacesAndNewlines), ReviewGather.isCommitID(text) {
                return text
            }
        }
        return nil
    }

    /// For up to 10 files, the merge requests of the project whose merge or squash commit on the
    /// target branch changed them (GitLab writes `See merge request group/project!123`); at most
    /// 3 per file and 10 in all.
    public static func earlierMergeRequests(_ checkout: URL, files: [String], base: String, ref: MergeRequestRef,
                                     env: HarnessEnvironment) async -> [String: [Int]] {
        guard let git = env.findExecutable("git") else { return [:] }
        var result: [String: [Int]] = [:]
        var all: Set<Int> = []
        for file in files.prefix(10) {
            guard all.count < 10 else { break }
            let log = await ProcessRunner.run(git, arguments: ["-C", checkout.path, "log", "--first-parent", "-n", "40", "--format=%B%x1e", base, "--", file],
                                              environment: env.gitVariables, timeout: 30)
            guard log?.succeeded == true, let text = log?.output else { continue }
            let numbers = mergeRequestNumbers(in: text, projectPath: ref.projectPath).filter { $0 != ref.iid }
            let kept = Array(numbers.prefix(3)).filter { all.contains($0) || all.count < 10 }
            guard !kept.isEmpty else { continue }
            result[file] = kept
            all.formUnion(kept)
        }
        return result
    }

    /// `See merge request group/project!123` lines of this project, in order, each number once.
    static func mergeRequestNumbers(in log: String, projectPath: String) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: "See merge request ([A-Za-z0-9_./-]*)!([0-9]+)") else { return [] }
        var numbers: [Int] = []
        let range = NSRange(log.startIndex..., in: log)
        for match in regex.matches(in: log, range: range) {
            guard let pathRange = Range(match.range(at: 1), in: log), let numberRange = Range(match.range(at: 2), in: log),
                  let number = Int(log[numberRange]) else { continue }
            let path = String(log[pathRange])
            guard path.isEmpty || path.lowercased() == projectPath.lowercased() else { continue }
            if !numbers.contains(number) { numbers.append(number) }
        }
        return numbers
    }

    // MARK: - The run's branch and its removal

    /// `akit-review/<run id>`; nil when the id isn't a branch name.
    public static func branch(for runID: String) -> String? {
        let name = branchPrefix + runID
        return ReviewGather.isBranchName(name) ? name : nil
    }

    /// Removes a worktree from the clone it was added to (its `.git` file names the clone), deletes
    /// its `akit-review/…` branch, prunes the clone's worktree list, then removes the folder.
    /// `clones`: the clones AKit may run git in. The worktree's `.git` file is the merge request's
    /// to change (setup commands run its code), so a clone it names elsewhere is not touched.
    public static func removeWorktree(_ tree: URL, clones: [URL], env: HarnessEnvironment) async {
        let fm = FileManager.default
        guard fm.fileExists(atPath: tree.path) else { return }
        let link = (try? String(contentsOf: tree.appending(path: ".git"), encoding: .utf8)) ?? ""
        let known = clones.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        let repos = ReviewPaths(home: env.homeDirectory).repos.standardizedFileURL.resolvingSymlinksInPath().path
        if let line = link.split(separator: "\n").first, line.hasPrefix("gitdir: "),
           let range = line.range(of: "/.git/worktrees/"), let git = env.findExecutable("git") {
            let gitdir = String(line.dropFirst("gitdir: ".count)).trimmingCharacters(in: .whitespaces)
            let clone = String(line.dropFirst("gitdir: ".count)[..<range.lowerBound])
            let resolved = URL(filePath: clone).standardizedFileURL.resolvingSymlinksInPath().path
            guard !clone.contains(".."), known.contains(resolved) || resolved.hasPrefix(repos + "/") else {
                try? fm.removeItem(at: tree)
                return
            }
            let head = (try? String(contentsOfFile: gitdir + "/HEAD", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            func run(_ arguments: [String]) async {
                _ = await ProcessRunner.run(git, arguments: ["-C", clone] + arguments, environment: env.gitVariables, timeout: 60)
            }
            await run(["worktree", "remove", "--force", tree.path])
            // The folder and the clone's record of it go first: git keeps a branch a worktree has.
            try? fm.removeItem(at: tree)
            await run(["worktree", "prune"])
            if head.hasPrefix("ref: refs/heads/" + branchPrefix) {
                let branch = String(head.dropFirst("ref: refs/heads/".count))
                if ReviewGather.isBranchName(branch) { await run(["branch", "-D", "--", branch]) }
            }
            return
        }
        try? fm.removeItem(at: tree)
    }
}

/// One git operation at a time per clone: two runs of a project never fetch into it at once.
actor CloneLock {
    static let shared = CloneLock()
    private var tails: [String: Task<Void, Never>] = [:]

    func run<T: Sendable>(_ key: String, _ body: @escaping @Sendable () async -> T) async -> T {
        let previous = tails[key]
        let task = Task<T, Never> {
            await previous?.value
            return await body()
        }
        tails[key] = Task { _ = await task.value }
        return await task.value
    }
}
