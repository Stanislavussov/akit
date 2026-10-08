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
    /// for it. A `repo` that is gone (a removed worktree) gives its nearest ancestor whose
    /// `.git` is a folder, below the home folder; any other layout gives the folder itself.
    public static func mainFolder(of repo: String) -> URL {
        func resolved(_ path: String, from base: URL) -> URL {
            let full = path.hasPrefix("/") ? path : (base.path as NSString).appendingPathComponent(path)
            return URL(filePath: full, directoryHint: .isDirectory).standardizedFileURL.resolvingSymlinksInPath()
        }
        let folder = URL(filePath: repo, directoryHint: .isDirectory).standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: folder.path) else { return enclosingRepository(of: folder.path) ?? folder }
        // A linked worktree's `.git` is a file: "gitdir: <main>/.git/worktrees/<name>".
        guard let text = try? String(contentsOf: folder.appending(path: ".git"), encoding: .utf8), text.hasPrefix("gitdir:") else {
            return folder
        }
        let gitDir = resolved(text.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines), from: folder)
        guard let common = try? String(contentsOf: gitDir.appending(path: "commondir"), encoding: .utf8) else { return folder }
        let commonDir = resolved(common.trimmingCharacters(in: .whitespacesAndNewlines), from: gitDir)
        return commonDir.lastPathComponent == ".git" ? commonDir.deletingLastPathComponent() : folder
    }

    /// The nearest ancestor of a missing folder whose `.git` is a folder (a main checkout),
    /// e.g. `<main>` for a removed `<main>/.claude/worktrees/<name>`. Stops below `/` and the
    /// home folder, which may hold a dotfiles repository that is no task's repository.
    private static func enclosingRepository(of path: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath().path
        var current = path
        for _ in 0..<64 {
            let parent = (current as NSString).deletingLastPathComponent
            guard parent != current, !parent.isEmpty, parent != "/", parent != home else { return nil }
            current = parent
            let folder = URL(filePath: current, directoryHint: .isDirectory)
            // Symlinks resolve only on a path that exists (`/var` → `/private/var`).
            if FileWalk.isDirectory(folder.appending(path: ".git")) { return folder.resolvingSymlinksInPath() }
        }
        return nil
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
