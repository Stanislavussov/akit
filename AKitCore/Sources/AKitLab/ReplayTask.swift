import AKitFoundation
import Foundation

/// A task made from a commit: redo it from its parent; the commit's own tests judge it.
/// Cached in `~/.akit/lab/tasks/<sha>.json` once validated.
public struct ReplayTask: Codable, Sendable, Hashable {
    public var schema = 1
    public var repo: String
    public var commit: String
    /// The commit's parent: where the agent starts.
    public var base: String
    public var subject: String
    /// The commit message plus the fixed instruction.
    public var prompt: String
    /// Folder of the Package.swift the tests belong to, relative to the repository ("" = root).
    public var package: String
    /// The commit's test files, copied in after the agent is done.
    public var testFiles: [String]
    /// Fail on the base, pass on the commit: what the agent has to make pass.
    public var failToPass: [TestName]
    /// Pass on both: what the agent must not break.
    public var passToPass: [TestName]
    public var validatedAt: Date
    /// Things worth knowing, e.g. the tests don't build on the base.
    public var notes: [String]

    public static let instruction = "Implement this in the repository. Build and tests must pass. Commit when done."

    public var shortCommit: String { String(commit.prefix(7)) }
}

public enum ReplayTasks {
    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
        public init(message: String) { self.message = message }
    }

    /// The commit's facts, before validation: nothing is built.
    public struct Draft: Sendable, Hashable {
        public var repo: URL
        public var commit: String
        public var base: String
        public var subject: String
        public var message: String
        public var package: String
        public var testFiles: [String]
        public var tests: [TestName]
    }

    public static func cached(_ commit: String, env: HarnessEnvironment) -> ReplayTask? {
        LabStore.read(ReplayTask.self, from: file(commit, env: env))
    }

    static func file(_ commit: String, env: HarnessEnvironment) -> URL {
        LabPaths(env: env).tasks.appending(path: "\(commit).json")
    }

    /// Reads the commit: parent, message, test files and the tests they declare.
    public static func draft(commit reference: String, repo: URL, env: HarnessEnvironment) async throws -> Draft {
        guard let root = await LabGit.output(["rev-parse", "--show-toplevel"], in: repo, env: env) else {
            throw Failure(message: "\(repo.path) is not a git repository.")
        }
        let repo = URL(filePath: root, directoryHint: .isDirectory)
        guard let commit = await LabGit.output(["rev-parse", "--verify", "--quiet", "\(reference)^{commit}"], in: repo, env: env) else {
            throw Failure(message: "No commit \(reference) in \(repo.path).")
        }
        let parents = (await LabGit.output(["rev-list", "--parents", "-n", "1", commit], in: repo, env: env) ?? "")
            .split(separator: " ").dropFirst().map(String.init)
        guard parents.count == 1, let base = parents.first else {
            throw Failure(message: parents.isEmpty ? "\(reference) has no parent." : "\(reference) is a merge; pick one of its commits.")
        }
        let message = await LabGit.output(["log", "-1", "--format=%B", commit], in: repo, env: env) ?? ""
        let subject = await LabGit.output(["log", "-1", "--format=%s", commit], in: repo, env: env) ?? ""
        let changed = (await LabGit.output(["diff-tree", "--no-commit-id", "--name-only", "-r", "--diff-filter=AM", commit],
                                           in: repo, env: env) ?? "")
            .split(separator: "\n").map(String.init).filter(TestNames.isTestFile)
        guard !changed.isEmpty else { throw Failure(message: "\(String(commit.prefix(7))) changes no test files, so nothing can judge a replay.") }

        // The package of each test file: the nearest folder with a Package.swift at the commit.
        var packages: [String: [String]] = [:]
        for path in changed {
            var folder = (path as NSString).deletingLastPathComponent
            var found: String?
            for _ in 0..<32 {
                let manifest = folder.isEmpty ? "Package.swift" : "\(folder)/Package.swift"
                if await LabGit.run(["cat-file", "-e", "\(commit):\(manifest)"], in: repo, env: env)?.succeeded == true {
                    found = folder
                    break
                }
                if folder.isEmpty { break }
                folder = (folder as NSString).deletingLastPathComponent
            }
            if let found { packages[found, default: []].append(path) }
        }
        guard let (package, files) = packages.max(by: { $0.value.count < $1.value.count }) else {
            throw Failure(message: "The commit's tests are not in a Swift package (SwiftPM only for now).")
        }
        var tests: [TestName] = []
        for path in files {
            let source = await LabGit.output(["show", "\(commit):\(path)"], in: repo, env: env) ?? ""
            tests += TestNames.parse(source)
        }
        guard !tests.isEmpty else { throw Failure(message: "No tests found in \(files.joined(separator: ", ")).") }
        return Draft(repo: repo, commit: commit, base: base, subject: subject, message: message, package: package,
                     testFiles: files, tests: Array(Set(tests)).sorted())
    }

    /// The prompt: the commit message without trailers, then the fixed instruction.
    static func prompt(message: String) -> String {
        let lines = message.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            line.firstMatch(of: /^(Co-Authored-By|Signed-off-by|Change-Id):/.ignoresCase()) == nil
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + ReplayTask.instruction
    }

    /// Runs the tests on the base (with the commit's test files) and on the commit, keeps the
    /// ones that tell the two apart, and caches the task. Throws when no test fails on the base.
    public static func validate(_ draft: Draft, env: HarnessEnvironment, out: @escaping @Sendable (String) -> Void) async throws -> ReplayTask {
        let folder = LabPaths(env: env).tasks.appending(path: "\(draft.commit)-check", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: folder.path) { _ = try? Trash.move(folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { _ = try? Trash.move(folder) }
        let log = try? FileHandle(forWritingTo: {
            let url = folder.deletingLastPathComponent().appending(path: "\(draft.commit)-check.log")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            return url
        }())
        defer { try? log?.close() }

        out("Checking \(String(draft.commit.prefix(7))) “\(draft.subject)”: \(draft.tests.count) tests in \(draft.testFiles.count) file(s).")
        let work = folder.appending(path: "work", directoryHint: .isDirectory)
        try await IsolatedClone.make(at: work, from: draft.repo, commit: draft.base, env: env)
        try await IsolatedClone.copyTests(draft.testFiles, from: draft.repo, commit: draft.commit, into: work, env: env)
        let package = draft.package.isEmpty ? work : work.appending(path: draft.package, directoryHint: .isDirectory)
        let runner = SwiftTests(package: package, folder: work, env: env, log: log, out: out)

        out("On the base \(String(draft.base.prefix(7))) with the commit's tests:")
        let baseBuilds = await runner.build()
        let onBase = baseBuilds ? await runner.run(draft.tests) : [:]
        guard !Cancellation.isCancelled else { throw CancellationError() }

        out("On the commit:")
        try await IsolatedClone.checkout(draft.commit, in: work, from: draft.repo, env: env)
        guard await runner.build() else { throw Failure(message: "The commit itself doesn't build; it can't be a task.") }
        let onCommit = await runner.run(draft.tests)
        guard !Cancellation.isCancelled else { throw CancellationError() }

        let failToPass = draft.tests.filter { onCommit[$0] == .passed && onBase[$0] != .passed }
        let passToPass = draft.tests.filter { onCommit[$0] == .passed && onBase[$0] == .passed }
        var notes: [String] = []
        if !baseBuilds { notes.append("The commit's tests don't build on the base: the agent has to add the same API.") }
        let dropped = draft.tests.filter { onCommit[$0] != .passed }
        if !dropped.isEmpty { notes.append("Left out, not passing on the commit itself: \(dropped.map(\.id).joined(separator: ", ")).") }
        guard !failToPass.isEmpty else {
            throw Failure(message: "No test fails on the base and passes on the commit, so a replay can't be judged.")
        }
        let task = ReplayTask(repo: draft.repo.path, commit: draft.commit, base: draft.base, subject: draft.subject,
                              prompt: prompt(message: draft.message), package: draft.package, testFiles: draft.testFiles,
                              failToPass: failToPass, passToPass: passToPass, validatedAt: .now, notes: notes)
        try FileManager.default.createDirectory(at: LabPaths(env: env).tasks, withIntermediateDirectories: true)
        try LabStore.write(task, to: file(draft.commit, env: env))
        out("Task ready: \(failToPass.count) fail-to-pass, \(passToPass.count) pass-to-pass.")
        notes.forEach { out("  \($0)") }
        return task
    }

    /// The cached task, else a new one checked now.
    public static func task(commit: String, repo: URL, env: HarnessEnvironment,
                            out: @escaping @Sendable (String) -> Void) async throws -> ReplayTask {
        if let cached = cached(commit, env: env) { return cached }
        let draft = try await draft(commit: commit, repo: repo, env: env)
        if let cached = cached(draft.commit, env: env) { return cached }
        return try await validate(draft, env: env, out: out)
    }
}

/// A repository that holds only the base commit's history: no refs, no remote, and not the
/// commit being replayed, so `git log --all` or `git show <sha>` can't reveal the answer
/// (a worktree would share the refs and objects of the real repository).
enum IsolatedClone {
    static func make(at folder: URL, from repo: URL, commit: String, env: HarnessEnvironment) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await git(["init", "-q"], in: folder, env: env)
        try await git(["fetch", "-q", "--no-tags", repo.path, commit], in: folder, env: env, timeout: 600)
        try await git(["checkout", "-q", "--detach", "FETCH_HEAD"], in: folder, env: env)
    }

    /// Validation only: brings in the commit and checks it out, test files included.
    static func checkout(_ commit: String, in folder: URL, from repo: URL, env: HarnessEnvironment) async throws {
        try await git(["fetch", "-q", "--no-tags", repo.path, commit], in: folder, env: env, timeout: 600)
        try await git(["checkout", "-q", "--force", "--detach", "FETCH_HEAD"], in: folder, env: env)
    }

    /// The commit's version of each test file, written into the work folder.
    static func copyTests(_ paths: [String], from repo: URL, commit: String, into folder: URL, env: HarnessEnvironment) async throws {
        for path in paths {
            guard let result = await LabGit.run(["show", "\(commit):\(path)"], in: repo, env: env), result.succeeded else {
                throw ReplayTasks.Failure(message: "Couldn't read \(path) at \(String(commit.prefix(7))).")
            }
            let target = folder.appending(path: path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            // ProcessRunner joins stdout and stderr; `git show` of a blob writes nothing to stderr on success.
            try Data(result.output.utf8).write(to: target)
        }
    }

    private static func git(_ arguments: [String], in folder: URL, env: HarnessEnvironment, timeout: TimeInterval = 60) async throws {
        guard let result = await LabGit.run(arguments, in: folder, env: env, timeout: timeout), result.succeeded else {
            throw ReplayTasks.Failure(message: "git \(arguments.prefix(2).joined(separator: " ")) failed in \(folder.path).")
        }
    }
}

/// Signs that a replay saw the answer: its tool calls or their results mention the commit's
/// hash, or it read Claude Code's own session history (files or a session search tool). The
/// subject line doesn't count: it is in the prompt, and the agent's own commit reuses it.
enum LeakCheck {
    static func leaks(in transcript: URL, task: ReplayTask) -> [String] {
        guard let data = try? Data(contentsOf: transcript), let entries = try? JSONLines.objects(in: data) else { return [] }
        var text = ""
        var usedSearch = false
        for entry in entries {
            let blocks = (entry["message"] as? JSONLines.Object)?["content"] as? [JSONLines.Object] ?? []
            for block in blocks {
                switch block["type"] as? String {
                case "tool_use":
                    text += JSONLines.pretty(block["input"]) + "\n"
                    if (block["name"] as? String ?? "").contains("session_search") { usedSearch = true }
                case "tool_result": text += JSONLines.text(of: block["content"]) + "\n"
                default: break
                }
            }
        }
        var found: [String] = []
        if text.contains(task.shortCommit) { found.append("the commit \(task.shortCommit)") }
        if text.contains(".claude/projects") || usedSearch { found.append("Claude Code's session history") }
        return found
    }
}

extension ReplayTasks {
    public struct Candidate: Sendable, Hashable, Identifiable {
        public var id: String { commit }
        public var commit: String
        public var subject: String
        /// Already checked: the cached task.
        public var task: ReplayTask?
    }

    /// Recent commits (no merges) that change Swift test files: the ones that can become tasks.
    public static func candidates(repo: URL, limit: Int = 60, env: HarnessEnvironment) async -> [Candidate] {
        guard let log = await LabGit.output(["log", "--no-merges", "-n", "\(limit)", "--format=%H%x09%s", "--",
                                             "*Tests/*.swift", "*Tests.swift"], in: repo, env: env) else { return [] }
        return log.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            return Candidate(commit: parts[0], subject: parts[1], task: cached(parts[0], env: env))
        }
    }
}
