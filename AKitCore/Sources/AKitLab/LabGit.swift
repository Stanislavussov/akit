import AKitFoundation
import Foundation

/// The few git questions Lab asks. Read-only unless the name says otherwise.
enum LabGit {
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
