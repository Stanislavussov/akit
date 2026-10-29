import AKitFoundation
import Foundation

/// "From commit" (2026-10-25): the developer asked to review only what changed after a commit of
/// the merge request. The diff, the positions and the context stay the whole merge request
/// (merge base..head, so GitLab's line numbers hold); findings off these lines stay in AKit.
public struct ReviewSince: Codable, Sendable, Hashable {
    /// What the developer typed (`a1b2c3d`).
    public var asked: String
    /// The full commit id git resolved it to.
    public var commit: String
    /// New-side lines changed between `commit` and the head, by path.
    public var changed: [String: [ReviewRerunInfo.Range]]

    public init(asked: String, commit: String, changed: [String: [ReviewRerunInfo.Range]]) {
        self.asked = asked
        self.commit = commit
        self.changed = changed
    }

    /// Whether a line changed after the commit (±2 lines, as a rerun counts).
    public func touches(file: String?, line: Int?) -> Bool {
        ReviewRerunInfo(previousRun: "", previousHead: commit, changed: changed).touches(file: file, line: line)
    }
}

/// Another merge request reviewed in the same run (`ReviewRunSpec.linked`): a change that goes
/// with the first one, often in another repository (a frontend and its API). The roles read every
/// change at once; each finding goes to drafts in its own merge request. Its files are named
/// `@<key>/<path>` in the findings, its worktree is `<run>/linked/<key>/worktree`.
public struct ReviewLinkedChange: Codable, Sendable, Hashable {
    /// Short and unique in the run: the project's last path segment (`api`, `api-2`).
    public var key: String
    public var mergeRequest: MergeRequestRef
    /// The project profile's slug; nil when none matched.
    public var project: String?
    /// The commit to review from, as typed; nil = the merge base.
    public var fromCommit: String?
    /// Filled by Gather: the commit its worktree and findings refer to; nil when it couldn't be read.
    public var headSHA: String?
    /// Filled by Gather when `fromCommit` resolved.
    public var since: ReviewSince?

    public init(key: String, mergeRequest: MergeRequestRef, project: String? = nil, fromCommit: String? = nil) {
        self.key = key
        self.mergeRequest = mergeRequest
        self.project = project
        self.fromCommit = fromCommit
    }
}

/// One line of the Merge requests field (or one argument of `akit review`): the address and an
/// optional commit to review from.
public struct ReviewMergeRequestEntry: Sendable, Hashable {
    public var mergeRequest: MergeRequestRef
    public var fromCommit: String?

    public init(mergeRequest: MergeRequestRef, fromCommit: String? = nil) {
        self.mergeRequest = mergeRequest
        self.fromCommit = fromCommit
    }
}

public enum ReviewLinked {
    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// The most merge requests one run takes: every one costs a fetch pass and adds its diff.
    public static let maxMergeRequests = 6

    /// `URL`, `URL COMMIT` or `URL@COMMIT`. A commit is 7–40 hex characters.
    public static func entry(_ text: String) throws -> ReviewMergeRequestEntry {
        var words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty, words.count <= 2 else {
            throw Failure(message: "\(text): one merge request address per line, then a commit to review from if you want one.")
        }
        var commit = words.count == 2 ? words.removeLast() : nil
        var address = words[0]
        // `URL@COMMIT`, only when what follows the last `@` is a commit (`https://me@host/…` stays whole).
        if commit == nil, let at = address.lastIndex(of: "@"), isCommit(String(address[address.index(after: at)...])) {
            commit = String(address[address.index(after: at)...])
            address = String(address[..<at])
        }
        guard let mr = MergeRequestRef.parse(address) else {
            throw Failure(message: "\(address) is not a merge request address (https://HOST/GROUP/PROJECT/-/merge_requests/N).")
        }
        if let commit {
            guard isCommit(commit) else { throw Failure(message: "\(commit) is not a commit id (7–40 hex characters).") }
        }
        return ReviewMergeRequestEntry(mergeRequest: mr, fromCommit: commit)
    }

    /// Every non-empty line of the field; no address twice, at most `maxMergeRequests`.
    public static func entries(_ text: String) throws -> [ReviewMergeRequestEntry] {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return try checked(lines.map(entry))
    }

    public static func checked(_ entries: [ReviewMergeRequestEntry]) throws -> [ReviewMergeRequestEntry] {
        var seen = Set<String>()
        for entry in entries where !seen.insert(entry.mergeRequest.url.lowercased()).inserted {
            throw Failure(message: "\(entry.mergeRequest.label) is in the list twice.")
        }
        guard entries.count <= maxMergeRequests else {
            throw Failure(message: "At most \(maxMergeRequests) merge requests in one review.")
        }
        return entries
    }

    static func isCommit(_ text: String) -> Bool {
        text.range(of: "^[0-9a-fA-F]{7,40}$", options: .regularExpression) != nil
    }

    /// Keys for the linked merge requests: the project's last path segment, lowercased, unique
    /// in the run (`main` is the first merge request's, never taken).
    public static func keys(main: MergeRequestRef, linked: [MergeRequestRef]) -> [String] {
        func base(_ ref: MergeRequestRef) -> String {
            let last = ref.projectPath.split(separator: "/").last.map(String.init) ?? "mr"
            let slug = last.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? String($0) : "-" }.joined()
            return slug.isEmpty ? "mr" : slug
        }
        var taken: Set<String> = [base(main)]
        return linked.map { ref in
            var key = base(ref)
            var number = 2
            while taken.contains(key) {
                key = "\(base(ref))-\(number)"
                number += 1
            }
            taken.insert(key)
            return key
        }
    }

    /// `@api/src/routes.ts` → (`api`, `src/routes.ts`); nil for a path of the first merge request.
    public static func split(_ path: String?) -> (key: String, path: String)? {
        guard let path, path.hasPrefix("@"), let slash = path.firstIndex(of: "/") else { return nil }
        let key = String(path[path.index(after: path.startIndex)..<slash])
        let rest = String(path[path.index(after: slash)...])
        guard !key.isEmpty, !rest.isEmpty else { return nil }
        return (key, rest)
    }

    public static func path(_ key: String, _ path: String) -> String { "@\(key)/\(path)" }

    /// The key of a linked merge request of this run that Gather read, when the file is one of
    /// its files; nil for the first merge request's files (a monorepo's own `@scope/…` too).
    public static func key(of file: String?, spec: ReviewRunSpec) -> String? {
        guard let split = split(file), (spec.linked ?? []).contains(where: { $0.key == split.key && $0.headSHA != nil }) else { return nil }
        return split.key
    }

    /// The path in its own repository: `@key/` taken off when that linked worktree is beside
    /// `worktree`. Fingerprints use it, so they don't depend on the run's key (`api`, `api-2`)
    /// and match a review of that merge request alone.
    static func repoPath(_ path: String, worktree: URL?) -> String {
        guard let worktree, let linked = split(path),
              FileManager.default.fileExists(atPath: self.worktree(worktree.deletingLastPathComponent(), key: linked.key).appending(path: ".git").path)
        else { return path }
        return linked.path
    }

    /// Removes the linked worktrees from the clones they were added to (the clone is named in
    /// each worktree's `.git` file), then their folders.
    public static func removeWorktrees(run folder: URL, env: HarnessEnvironment) async {
        for tree in FileWalk.children(of: folder.appending(path: "linked")).map({ $0.appending(path: "worktree") }) {
            let link = (try? String(contentsOf: tree.appending(path: ".git"), encoding: .utf8)) ?? ""
            if let line = link.split(separator: "\n").first, line.hasPrefix("gitdir: "),
               let range = line.range(of: "/.git/worktrees/"), let git = env.findExecutable("git") {
                let clone = String(line.dropFirst("gitdir: ".count)[..<range.lowerBound])
                _ = await ProcessRunner.run(git, arguments: ["-C", clone, "worktree", "remove", "--force", tree.path],
                                            environment: env.gitVariables, timeout: 60)
            }
            try? FileManager.default.removeItem(at: tree)
        }
    }

    public static func folder(_ run: URL, key: String) -> URL { run.appending(path: "linked/\(key)", directoryHint: .isDirectory) }
    public static func worktree(_ run: URL, key: String) -> URL { folder(run, key: key).appending(path: "worktree", directoryHint: .isDirectory) }
    public static func snapshotFile(_ run: URL, key: String) -> URL { folder(run, key: key).appending(path: "snapshot.json") }

    /// The linked worktrees that exist, for the passes' read roots.
    static func worktrees(_ run: URL, spec: ReviewRunSpec) -> [URL] {
        (spec.linked ?? []).map { worktree(run, key: $0.key) }
            .filter { FileManager.default.fileExists(atPath: $0.appending(path: ".git").path) }
    }

    /// The `@key/` path of every file of a diff, for the pack and the scan.
    static func prefixed(_ diffs: [GitLabFileDiff], key: String) -> [GitLabFileDiff] {
        diffs.map { diff in
            var diff = diff
            diff.oldPath = path(key, diff.oldPath)
            diff.newPath = path(key, diff.newPath)
            return diff
        }
    }

    /// The commit a developer typed, resolved in the worktree, when it is part of the change:
    /// an ancestor of the head. nil and why not otherwise.
    /// `base`: the merge request's base commit; the commit must come after it when git knows it.
    static func resolve(_ asked: String, head: String, base: String = "", worktree: URL, env: HarnessEnvironment) async -> (commit: String?, problem: String?) {
        guard isCommit(asked) else { return (nil, "\(asked) is not a commit id.") }
        guard let git = env.findExecutable("git") else { return (nil, "git is not installed.") }
        func run(_ arguments: [String]) async -> ProcessRunner.Result? {
            await ProcessRunner.run(git, arguments: ["-C", worktree.path] + arguments, environment: env.gitVariables, timeout: 30)
        }
        guard let parsed = await run(["rev-parse", "--verify", "--quiet", "\(asked)^{commit}"]), parsed.succeeded else {
            return (nil, "git doesn't know the commit \(asked) in the checkout.")
        }
        let commit = parsed.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ReviewGather.isCommitID(commit) else { return (nil, "git doesn't know the commit \(asked) in the checkout.") }
        guard await run(["merge-base", "--is-ancestor", commit, head])?.succeeded == true else {
            return (nil, "\(asked) is not in the history of the merge request's head \(head.prefix(10)).")
        }
        if ReviewGather.isCommitID(base), await run(["cat-file", "-e", "\(base)^{commit}"])?.succeeded == true,
           await run(["merge-base", "--is-ancestor", base, commit])?.succeeded != true {
            return (nil, "\(asked) is not a commit of this merge request: it comes before the merge base \(base.prefix(10)).")
        }
        return (commit, nil)
    }

    /// `context/since-….md`: the lines a review from a commit looks at.
    static func sinceText(_ since: ReviewSince, label: String, prefix: String? = nil, patch: String, limit: Int = 200_000) -> String {
        var text = "# \(label): changes after commit \(since.asked)\n\nThe developer asked to review only what changed after commit "
            + "\(since.commit.prefix(10)). Report findings only on the lines below; the rest of the diff is context.\n\n"
        if since.changed.isEmpty { text += "Nothing changed after it: the commit is the head.\n" }
        for (path, ranges) in since.changed.sorted(by: { $0.key < $1.key }) {
            let name = prefix.map { ReviewLinked.path($0, path) } ?? path
            text += "- `\(name)`: " + (ranges == [.wholeFile] ? "the whole file (deleted or renamed)"
                : "lines " + ranges.map { $0.start == $0.end ? "\($0.start)" : "\($0.start)–\($0.end)" }.joined(separator: ", ")) + "\n"
        }
        if !patch.isEmpty { text += "\n```diff\n" + String(patch.prefix(limit)) + (patch.count > limit ? "\n… (cut)" : "") + "\n```\n" }
        return text
    }
}

extension ReviewRunSpec {
    /// Every merge request of the run: the first, then the linked ones.
    public var mergeRequests: [MergeRequestRef] { [mergeRequest] + (linked ?? []).map(\.mergeRequest) }

    /// `team/app!7 + team/api!12`.
    public var label: String { mergeRequests.map(\.label).joined(separator: " + ") }

    /// The name people read in the runs list: the title Gather saved, else the address.
    public var name: String { title ?? label }

    /// A title on one line, at most 120 characters, or nil when it says nothing.
    static func readableTitle(_ text: String?, limit: Int = 120) -> String? {
        guard let text else { return nil }
        let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        if line.isEmpty { return nil }
        return line.count > limit ? String(line.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…" : line
    }
}

extension ReviewGather {
    /// What Gather got for one linked merge request.
    struct LinkedResult {
        var change: ReviewLinkedChange
        /// Files for `context/`.
        var files: [(name: String, about: String, text: String)] = []
        /// Its diffs with `@key/` paths, for the scan and the language rules.
        var diffs: [GitLabFileDiff] = []
        var secretFiles: [String] = []
        var gaps: [(system: String, needed: String, why: String, how: String, effect: String)] = []
    }

    /// One linked merge request: its own fetch pass (`fetch-<key>`), so its answers never mix
    /// with another project's (the same iid can exist in both), its worktree and its diff. A
    /// linked merge request that can't be read is a gap, not a failure: the run reviews the rest.
    static func gatherLinked(_ change: ReviewLinkedChange, spec: ReviewRunSpec, profile: ReviewProfile?, folder: URL, env: HarnessEnvironment,
                             options: ReviewPasses.Options) async -> LinkedResult {
        var result = LinkedResult(change: change)
        let ref = change.mergeRequest
        let key = change.key
        func gap(_ system: String, _ needed: String, _ why: String, how: String = "", effect: String = "") {
            result.gaps.append((system, needed, why, how, effect))
        }
        options.progress("Reading the linked \(ref.label) through Pi's MCP servers…")
        var fetchSpec = spec
        fetchSpec.mergeRequest = ref
        fetchSpec.links = []
        fetchSpec.workItems = []
        fetchSpec.linked = nil
        fetchSpec.tracker = profile?.tracker
        let pass = "fetch-\(key)"
        do {
            try await ReviewPasses.fetch(folder: folder, spec: fetchSpec, env: env, options: options, name: pass)
        } catch {
            gap("mcp", "The linked merge request \(ref.label)", "Its fetch pass failed: \(SecretFilter.masked(error.localizedDescription))",
                how: "Check Pi and its MCP servers (akit review check).", effect: "Its changes aren't in the review.")
            return result
        }
        let data = ReviewMCPData.read(ReviewMCPData.calls(in: folder, pass: pass).filter(spec.access.answeredByBase), iid: ref.iid,
                                      project: ref.projectPath)
        guard let mr = data.mergeRequest else {
            gap("gitlab", "The linked merge request \(ref.label)", "Its fetch pass read no merge request that AKit understands.",
                how: "Check that Pi's GitLab MCP server can read that project.", effect: "Its changes aren't in the review.")
            return result
        }
        var snapshot = ReviewSnapshot(mergeRequest: mr, versions: data.versions, diffs: data.diffs, discussions: data.discussions,
                                      drafts: data.drafts, user: data.user ?? "", gathered: .now)
        guard let refs = snapshot.refs, isCommitID(refs.headSHA), refs.baseSHA.isEmpty || isCommitID(refs.baseSHA),
              refs.startSHA.isEmpty || isCommitID(refs.startSHA) else {
            gap("gitlab", "The commits of \(ref.label)", "What its fetch pass read has no diff refs that are commit ids.",
                effect: "Its changes aren't in the review.")
            return result
        }
        let head = refs.headSHA
        let worktree = ReviewLinked.worktree(folder, key: key)
        let checkout = profile?.checkout.map { env.expand($0) }
        if let checkout {
            options.progress("Making a worktree of \(ref.label) at \(head.prefix(10))…")
            try? FileManager.default.createDirectory(at: worktree.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let problem = await makeWorktree(checkout: checkout, at: worktree, head: head, iid: ref.iid, env: env) {
                gap("repository", "Full files of \(ref.label) at \(head.prefix(10))", problem,
                    how: "Check the profile's checkout and that git can fetch from it.",
                    effect: "Only its diff can be read: findings that need the whole file are less certain.")
            }
        } else {
            gap("repository", "Full files of \(ref.label)", "No project profile with a checkout matches \(ref.projectPath).",
                how: "Add a profile with checkout: <path of your clone> in Review Settings….",
                effect: "Only its diff can be read: findings that need the whole file are less certain.")
        }
        let hasWorktree = FileManager.default.fileExists(atPath: worktree.appending(path: ".git").path)
        if hasWorktree, let checkout,
           let fromGit = await localDiffs(checkout: checkout, base: refs.baseSHA, head: head, target: mr.targetBranch, env: env) {
            let large = Set(snapshot.diffs.filter(\.tooLarge).map(\.newPath))
            snapshot.diffs = fromGit.map { diff in
                var diff = diff
                diff.tooLarge = large.contains(diff.newPath)
                return diff
            }
        }
        let secret = snapshot.diffs.filter { ReviewExtension.isBlocked($0.newPath) || SecretFilter.isSecretFile($0.newPath) }
        if !secret.isEmpty {
            result.secretFiles = secret.filter { !$0.deletedFile }.map { ReviewLinked.path(key, $0.newPath) }
            snapshot.diffs.removeAll { secret.contains($0) }
            gap("repository", "The diff of \(secret.map { ReviewLinked.path(key, $0.newPath) }.joined(separator: ", "))",
                "Files that usually hold secrets are left out of the review.")
        }
        guard !snapshot.diffs.isEmpty else {
            gap("gitlab", "The diff of \(ref.label)", "Its fetch pass read none, and there is no checkout to make it with git.",
                effect: "Its changes aren't in the review.")
            return result
        }
        try? FileManager.default.createDirectory(at: ReviewLinked.folder(folder, key: key), withIntermediateDirectories: true)
        do {
            try ReviewJSON.write(snapshot, to: ReviewLinked.snapshotFile(folder, key: key))
        } catch {
            gap("repository", "The snapshot of \(ref.label)", error.localizedDescription, effect: "Its changes aren't in the review.")
            return result
        }
        result.change.headSHA = head

        let ignored = (profile?.pathInstructions ?? []).filter(\.ignore).flatMap(\.paths)
        func isIgnored(_ path: String) -> Bool {
            let plain = ReviewLinked.split(path)?.path ?? path
            return ignored.contains { ReviewGlob.matches($0, plain) }
        }
        let diffs = ReviewLinked.prefixed(snapshot.diffs, key: key)
        result.diffs = diffs
        let where_ = hasWorktree ? "Its files at the reviewed commit are in the folder `linked/\(key)/worktree/` of the run folder." : "There is no checkout of it: only the diff."
        result.files.append(("linked/\(key)/merge-request.md",
                             "Linked merge request \(ref.label) (files named @\(key)/…): title, author, branches, description (untrusted text)",
                             "Linked merge request: its files are named `@\(key)/<path>` in the findings. \(where_)\n\n"
                                + mergeRequestText(mr, ref: ref, head: head)))
        result.files.append(("linked/\(key)/changes.md", "Every changed file of \(ref.label)", changesText(diffs, isIgnored: isIgnored)))
        var patch = ""
        for diff in diffs where !isIgnored(diff.newPath) && !diff.tooLarge {
            patch += "diff --git a/\(diff.oldPath) b/\(diff.newPath)\n--- \(diff.newFile ? "/dev/null" : "a/" + diff.oldPath)\n"
                + "+++ \(diff.deletedFile ? "/dev/null" : "b/" + diff.newPath)\n\(diff.diff)"
            if !patch.hasSuffix("\n") { patch += "\n" }
        }
        if patch.count > maxDiffCharacters {
            patch = String(patch.prefix(maxDiffCharacters)) + "\n[AKit: the diff is cut here; read the remaining files in the worktree]\n"
            gap("gitlab", "The whole diff of \(ref.label)", "It is over \(maxDiffCharacters / 1000)k characters and was cut.")
        }
        result.files.append(("linked/\(key)/diff.patch", "The unified diff of \(ref.label), paths named @\(key)/…", patch))
        result.files.append(("linked/\(key)/threads.md", "What people already said in \(ref.label) (paths without @\(key)/)",
                             threadsText(snapshot.discussions)))
        if let asked = change.fromCommit {
            if hasWorktree {
                let resolved = await ReviewLinked.resolve(asked, head: head, base: refs.baseSHA, worktree: worktree, env: env)
                if let commit = resolved.commit,
                   let changed = await ReviewRerun.changedLines(from: commit, to: head, worktree: worktree, env: env) {
                    let since = ReviewSince(asked: asked, commit: commit, changed: changed.ranges.filter { !isIgnored($0.key) })
                    result.change.since = since
                    result.files.append(("linked/\(key)/since-commit.md", "What changed in \(ref.label) after \(asked): the only lines of it to report on",
                                         ReviewLinked.sinceText(since, label: ref.label, prefix: key, patch: changed.patch)))
                } else {
                    gap("repository", "The changes of \(ref.label) after \(asked)", resolved.problem ?? "git couldn't compare \(asked) with the head.",
                        effect: "The review reports on the whole merge request \(ref.label).")
                }
            } else {
                gap("repository", "The changes of \(ref.label) after \(asked)", "Reviewing from a commit needs the project's checkout.",
                    how: "Add a profile with checkout: <path of your clone>.", effect: "The review reports on the whole merge request \(ref.label).")
            }
        }
        return result
    }
}
