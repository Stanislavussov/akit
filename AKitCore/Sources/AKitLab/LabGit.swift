import AKitFoundation
import Foundation

/// The few git questions Lab asks. Read-only unless the name says otherwise.
public enum LabGit {
    static func run(_ arguments: [String], in folder: URL?, env: HarnessEnvironment,
                    timeout: TimeInterval = 60) async -> ProcessRunner.Result? {
        guard let git = env.findExecutable("git") ?? Optional(URL(filePath: "/usr/bin/git")) else { return nil }
        return await ProcessRunner.run(git, arguments: (folder.map { ["-C", $0.path] } ?? []) + arguments,
                                       environment: env.gitVariables, timeout: timeout)
    }

    /// Trimmed output of a successful command; nil when it failed.
    static func output(_ arguments: [String], in folder: URL?, env: HarnessEnvironment,
                       timeout: TimeInterval = 60) async -> String? {
        guard let result = await run(arguments, in: folder, env: env, timeout: timeout), result.succeeded else { return nil }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `master` or `main`, whichever the repository has.
    static func mainBranch(in folder: URL, env: HarnessEnvironment) async -> String? {
        for name in ["master", "main"] where await output(["rev-parse", "--verify", "--quiet", "refs/heads/\(name)"],
                                                           in: folder, env: env) != nil {
            return name
        }
        return nil
    }

    /// Marks each commit with whether the main branch contains it. Unchanged when `folder`
    /// is gone or isn't a repository.
    static func markMerged(_ commits: [LabCommit], in folder: URL?, env: HarnessEnvironment) async -> [LabCommit] {
        guard !commits.isEmpty, let folder, FileManager.default.fileExists(atPath: folder.path),
              let main = await mainBranch(in: folder, env: env) else { return commits }
        var marked = commits
        for index in marked.indices {
            guard let result = await run(["merge-base", "--is-ancestor", marked[index].sha, main], in: folder, env: env),
                  result.exitedNormally, !result.timedOut else { continue }
            // 0 = ancestor, 1 = not; anything else (an unknown sha) stays unknown.
            if result.status == 0 { marked[index].onMainBranch = true } else if result.status == 1 { marked[index].onMainBranch = false }
        }
        return marked
    }

    /// The main folder of a repository, also when `repo` is a linked worktree: worktrees of
    /// one repository share its git folder (what `git rev-parse --git-common-dir` names), read
    /// here from `.git` and `commondir`. Layer sets and layer evals take one repository by this
    /// folder; the project's answers and `project_name` come from it, and the leak signs look
    /// for it. Any other layout, or a folder that is gone, gives the folder itself
    /// (`mainFolder(ofGone:base:env:)` for a removed worktree).
    public static func mainFolder(of repo: String) -> URL {
        func resolved(_ path: String, from base: URL) -> URL {
            let full = path.hasPrefix("/") ? path : (base.path as NSString).appendingPathComponent(path)
            return URL(filePath: full, directoryHint: .isDirectory).standardizedFileURL.resolvingSymlinksInPath()
        }
        let folder = URL(filePath: repo, directoryHint: .isDirectory).standardizedFileURL.resolvingSymlinksInPath()
        // A linked worktree's `.git` is a file: "gitdir: <main>/.git/worktrees/<name>".
        guard let text = try? String(contentsOf: folder.appending(path: ".git"), encoding: .utf8), text.hasPrefix("gitdir:") else {
            return folder
        }
        let gitDir = resolved(text.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines), from: folder)
        guard let common = try? String(contentsOf: gitDir.appending(path: "commondir"), encoding: .utf8) else { return folder }
        let commonDir = resolved(common.trimmingCharacters(in: .whitespacesAndNewlines), from: gitDir)
        return commonDir.lastPathComponent == ".git" ? commonDir.deletingLastPathComponent() : folder
    }

    /// The main checkout of a worktree that is gone, when it can be proven: the gone folder
    /// is `<main>/.claude/worktrees/<name>` (Claude Code's layout), or an ancestor's
    /// `.git/worktrees/*/gitdir` still names `<gone>/.git` (git's record of it); and `<main>`
    /// has a `.git` folder holding the commit `base`. Ancestors are searched up to, not
    /// including, the environment's home folder and `/` (a dotfiles repository may live in
    /// home). nil otherwise: the task stays blocked as gone. Runs git (`cat-file`) only on a
    /// candidate.
    public static func mainFolder(ofGone path: String, base: String, env: HarnessEnvironment) -> URL? {
        let gone = canonical(path)
        guard !FileManager.default.fileExists(atPath: gone) else { return nil }
        let stops = Set(["/", "", env.homeDirectory.standardizedFileURL.path, canonical(env.homeDirectory.path)])
        var candidates: [String] = []
        let worktrees = (gone as NSString).deletingLastPathComponent
        if worktrees.hasSuffix("/.claude/worktrees") { candidates.append(String(worktrees.dropLast("/.claude/worktrees".count))) }
        var current = gone
        for _ in 0..<64 {
            let parent = (current as NSString).deletingLastPathComponent
            guard parent != current, !stops.contains(parent) else { break }
            current = parent
            for record in FileWalk.children(of: URL(filePath: current).appending(path: ".git/worktrees")) {
                guard let named = try? String(contentsOf: record.appending(path: "gitdir"), encoding: .utf8) else { continue }
                if canonical(named.trimmingCharacters(in: .whitespacesAndNewlines)) == gone + "/.git" { candidates.append(current) }
            }
        }
        let git = env.findExecutable("git") ?? URL(filePath: "/usr/bin/git")
        for candidate in candidates where !stops.contains(candidate) && FileWalk.isDirectory(URL(filePath: candidate).appending(path: ".git")) {
            let found = ProcessRunner.runAndWait(git, arguments: ["-C", candidate, "cat-file", "-e", "\(base)^{commit}"],
                                                 environment: env.gitVariables, timeout: 10)
            if found?.succeeded == true { return URL(filePath: candidate, directoryHint: .isDirectory) }
        }
        return nil
    }

    /// A path standardized, with the symlinks of its nearest existing ancestor resolved
    /// (`/var/x/gone` → `/private/var/x/gone`), so gone paths compare with recorded ones.
    private static func canonical(_ path: String) -> String {
        var existing = URL(filePath: path).standardizedFileURL.path
        var rest: [String] = []
        for _ in 0..<64 where !FileManager.default.fileExists(atPath: existing) {
            let parent = (existing as NSString).deletingLastPathComponent
            guard parent != existing else { break }
            rest.insert((existing as NSString).lastPathComponent, at: 0)
            existing = parent
        }
        let base = URL(filePath: existing).resolvingSymlinksInPath().path
        return rest.reduce(base) { ($0 as NSString).appendingPathComponent($1) }
    }
}

/// Session analysis as the app and `akit lab analyze` show it: transcript metrics, then git.
public enum LabAnalysis {
    /// `project` is the folder the session ran in, for checking its commits (default: the
    /// transcript's own `cwd`).
    public static func analyze(file: URL, project: URL? = nil, env: HarnessEnvironment) async throws -> SessionMetrics {
        var metrics = try SessionAnalyzer.analyze(file: file)
        let folder = project ?? LabPaths.folder(ofTranscript: file)
        metrics.commits = await LabGit.markMerged(metrics.commits, in: folder, env: env)
        return metrics
    }
}
