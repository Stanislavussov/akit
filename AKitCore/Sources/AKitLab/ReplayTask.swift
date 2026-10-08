import AKitFoundation
import AKitSessions
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
        // One check of a commit at a time (the app's Check Now and a queued replay); the second
        // takes the first one's result.
        let tasks = LabPaths(env: env).tasks
        try FileManager.default.createDirectory(at: tasks, withIntermediateDirectories: true)
        return try await FileLock.holding(tasks.appending(path: "\(draft.commit).lock")) {
            if let done = cached(draft.commit, env: env) { return done }
            return try await check(draft, env: env, out: out)
        }
    }

    private static func check(_ draft: Draft, env: HarnessEnvironment, out: @escaping @Sendable (String) -> Void) async throws -> ReplayTask {
        let folder = LabPaths(env: env).tasks
            .appending(path: "\(draft.commit)-check-\(UUID().uuidString.prefix(8).lowercased())", directoryHint: .isDirectory)
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
        // FETCH_HEAD names the source repository's path; the agent must not find it there.
        try? FileManager.default.removeItem(at: folder.appending(path: ".git/FETCH_HEAD"))
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
        guard !Cancellation.isCancelled else { throw CancellationError() }
        guard let result = await LabGit.run(arguments, in: folder, env: env, timeout: timeout), result.succeeded else {
            throw ReplayTasks.Failure(message: "git \(arguments.prefix(2).joined(separator: " ")) failed in \(folder.path).")
        }
    }
}

/// Signs that a replay saw the answer, in its tool calls and its subagents' (Claude Code
/// writes a `Task` subagent's calls to `<session>/subagents/*.jsonl`, older versions as
/// side-chain lines of the session file). In a call's whole input, the text it writes
/// included (a script written and then run counts), and in tool results: the commit's hash.
/// In a call's whole input: the real repository (the task's folder, the replay's and their
/// main folders) and the Trash (earlier clones with the answer go there). Only in what a call
/// asks for (`pathLikeInput`), since AKit's own sources mention them and editing those is no
/// leak: AKit's Lab folder (run.json and the task cache name the commit) and Claude Code's
/// session history; a `session_search` tool too. The subject line is not a sign: it is in the
/// prompt, and the agent's own commit usually reuses it. Tool results aren't searched for
/// paths: Claude Code itself mentions `~/.claude/projects` when it saves a long output there.
public enum LeakCheck {
    /// What a tool call asks for: a shell command, the path or file pattern a file tool reads
    /// or searches (`Grep`'s `path` and `glob`, not its `pattern`, a content regex), the path
    /// a file tool writes (not its content). An unknown tool's whole input. Names of Claude
    /// Code and Pi tools alike, in any case (Pi's grep, find and ls take the same arguments).
    public static func pathLikeInput(tool: String, input: Any?) -> String {
        let keys: [String]
        switch tool.lowercased() {
        case "bash": keys = ["command"]
        case "write", "edit", "multiedit", "notebookedit", "read": keys = ["file_path", "notebook_path", "path"]
        case "grep": keys = ["path", "glob"]
        case "glob", "find", "ls": keys = ["pattern", "path"]
        default: return JSONLines.pretty(input)
        }
        let object = input as? JSONLines.Object ?? [:]
        return keys.compactMap { object[$0] as? String }.joined(separator: "\n")
    }

    /// One tool call as the signs read it.
    public struct Call: Sendable, Hashable {
        public var name: String
        /// The whole input, the text a call writes included.
        public var input: String
        /// What the call asks for (`pathLikeInput`).
        public var asks: String

        /// `input`: the parsed JSON input, or text that isn't JSON (taken whole for both).
        public init(name: String, input: Any?) {
            self.name = name
            self.input = JSONLines.pretty(input)
            asks = input is String ? self.input : LeakCheck.pathLikeInput(tool: name, input: input)
        }
    }

    /// The tool calls of a Claude Code session's subagents: side-chain lines of the session
    /// file and the files in `<session>/subagents/`.
    public static func subagentCalls(of transcript: URL) -> [Call] {
        (blocks(in: transcript, sidechainOnly: true) + subagentFiles(of: transcript).flatMap { blocks(in: $0) })
            .filter { $0["type"] as? String == "tool_use" }
            .map { Call(name: $0["name"] as? String ?? "", input: $0["input"]) }
    }

    /// The real repository as the signs look for it: each folder and its main folder (the
    /// repository of a worktree), as given, standardized and with symlinks resolved.
    public static func repositoryPaths(_ folders: [String]) -> Set<String> {
        let all = folders.filter { !$0.isEmpty }.flatMap { [$0, LabGit.mainFolder(of: $0).path] }
        return Set(all.flatMap { path -> [String] in
            let url = URL(filePath: path).standardizedFileURL
            return [url.path, url.resolvingSymlinksInPath().path, (path as NSString).standardizingPath]
        }).filter { $0 != "/" && !$0.isEmpty }
    }

    static func leaks(in transcript: URL, task: ReplayTask, repo: URL, env: HarnessEnvironment) -> [String] {
        signs(toolCalls(in: transcript), task: task, repo: repo, env: env)
    }

    /// A control cell of a commit task: only the signs that error analysis's own check of a
    /// cell (the real repository, the session history, the Trash) doesn't look for.
    static func commitSigns(in transcript: URL, task: ReplayTask, env: HarnessEnvironment) -> [String] {
        signs(toolCalls(in: transcript), task: task, repo: nil, env: env)
    }

    private static func signs(_ calls: ToolCalls, task: ReplayTask, repo: URL?, env: HarnessEnvironment) -> [String] {
        let inputs = calls.calls.map(\.input).joined(separator: "\n")
        let asks = calls.calls.map(\.asks).joined(separator: "\n")
        var found: [String] = []
        // The hash as a word of its own (any length from the short form), not inside another hex string.
        let hash = (try? Regex("\\b\(task.shortCommit)[0-9a-f]*\\b"))
        if let hash, (inputs + "\n" + calls.results).contains(hash) { found.append("the commit \(task.shortCommit)") }
        if let repo, repositoryPaths([repo.path, task.repo]).contains(where: { inputs.contains($0) }) {
            found.append("the real repository")
        }
        // `~/.akit/lab`, `$HOME/.akit/lab`, `/Users/me/.akit/lab` alike.
        if asks.contains(".akit/lab") { found.append("AKit's Lab folder") }
        if repo != nil, asks.contains(".claude/projects") || calls.calls.contains(where: { $0.name.contains("session_search") }) {
            found.append("Claude Code's session history")
        }
        // Finished clones and a commit's validation folder go to the Trash (control cells check it in error analysis).
        if repo != nil, inputs.contains("/.Trash") { found.append("the Trash") }
        return found
    }

    private struct ToolCalls {
        var calls: [Call] = []
        var results = ""
    }

    /// The session's tool calls and results, its subagents' included.
    private static func toolCalls(in transcript: URL) -> ToolCalls {
        var calls = ToolCalls()
        for block in blocks(in: transcript) + subagentFiles(of: transcript).flatMap({ blocks(in: $0) }) {
            switch block["type"] as? String {
            case "tool_use": calls.calls.append(Call(name: block["name"] as? String ?? "", input: block["input"]))
            case "tool_result": calls.results += JSONLines.text(of: block["content"]) + "\n"
            default: break
            }
        }
        return calls
    }

    /// The content blocks of a Claude Code transcript file's messages.
    private static func blocks(in file: URL, sidechainOnly: Bool = false) -> [JSONLines.Object] {
        guard let data = try? Data(contentsOf: file), let entries = try? JSONLines.objects(in: data) else { return [] }
        return entries.filter { !sidechainOnly || ClaudeLogFormat.isSidechain($0) }
            .flatMap { ($0["message"] as? JSONLines.Object)?["content"] as? [JSONLines.Object] ?? [] }
    }

    /// `<session>/subagents/*.jsonl` next to `<session>.jsonl`, one level only.
    private static func subagentFiles(of transcript: URL) -> [URL] {
        FileWalk.children(of: transcript.deletingPathExtension().appending(path: "subagents")).filter { $0.pathExtension == "jsonl" }
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
                                             "*Tests/*.swift"], in: repo, env: env) else { return [] }
        return log.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            return Candidate(commit: parts[0], subject: parts[1], task: cached(parts[0], env: env))
        }
    }
}
