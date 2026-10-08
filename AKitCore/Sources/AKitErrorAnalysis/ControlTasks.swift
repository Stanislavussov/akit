import AKitFoundation
import AKitInsights
import AKitLab
import AKitSessions
import Foundation

/// Where controlled evals keep their files: `~/.akit/lab/evals`. Cells are Lab runs.
public struct EvalPaths: Sendable {
    public let folder: URL

    public init(env: HarnessEnvironment) {
        folder = LabPaths(env: env).folder.appending(path: "evals", directoryHint: .isDirectory)
    }

    public var tasks: URL { folder.appending(path: "tasks", directoryHint: .isDirectory) }

    public func task(_ id: String) -> URL { tasks.appending(path: AnalysisPaths.fileName(id) + ".json") }

    /// Layer evals (`docs/design/layer-evals.md`): one folder per eval, with its manifest and overlays.
    public var layerEvals: URL { folder.appending(path: "layer-evals", directoryHint: .isDirectory) }

    public func layerEval(_ id: String) -> URL { layerEvals.appending(path: AnalysisPaths.fileName(id), directoryHint: .isDirectory) }

    /// Layer sets: the tasks and field answers of each layer.
    public var sets: URL { folder.appending(path: "sets", directoryHint: .isDirectory) }

    public func set(_ layer: String) -> URL { sets.appending(path: AnalysisPaths.fileName(layer) + ".json") }

    /// The last layer verdicts per agent, for the badge on the layer.
    public var verdicts: URL { folder.appending(path: "verdicts", directoryHint: .isDirectory) }

    public func verdict(_ layer: String) -> URL { verdicts.appending(path: AnalysisPaths.fileName(layer) + ".json") }
}

/// A fixed task for controlled evals (`docs/design/error-analysis.md`, "Controlled evals"):
/// a prompt at a commit of a repository, and the oracle that judges a cell.
/// `~/.akit/lab/evals/tasks/<id>.json`.
public struct ControlTask: Codable, Sendable, Hashable, Identifiable {
    public enum Source: Codable, Sendable, Hashable {
        /// An exemplar session: its first user turn at HEAD of its start.
        case session(key: SessionKey)
        /// A minimal reproduction the user wrote.
        case reproduction
        /// A commit, redone from its parent (its replay task in `~/.akit/lab/tasks/<sha>.json`).
        case commit(sha: String)
    }

    public enum Oracle: Codable, Sendable, Hashable {
        /// The project's test command: exit 0 passes.
        case tests(command: String)
        /// The mode's code check on the cell's transcript, a behavioural oracle.
        case assertion(modeID: String)
        /// The commit's own tests, copied in after the agent: its fail-to-pass tests must pass
        /// and its pass-to-pass tests must still pass (SwiftPM only, as replays).
        case hiddenTests(commit: String)

        /// "tests: swift test", "assertion: repeated-steps", "hidden tests of a1b2c3d".
        public var label: String {
            switch self {
            case .tests(let command): "tests: \(command)"
            case .assertion(let modeID): "assertion: \(modeID)"
            case .hiddenTests(let commit): "hidden tests of \(commit.prefix(7))"
            }
        }
    }

    public var schema = 1
    public var id: String
    public var title: String
    /// Folder of the repository.
    public var repo: String
    /// The repository's main folder when the task was made, also when `repo` is a linked
    /// worktree (which may be removed later); nil in tasks made before it was recorded.
    public var mainRepo: String?
    /// The commit the agent starts from.
    public var base: String
    public var prompt: String
    public var source: Source
    /// The mode the task is about, when it is about one.
    public var modeID: String?
    public var oracle: Oracle
    /// The asserted mode is a success mode: the cell passes when it shows, not when it doesn't.
    public var successMode: Bool?
    /// A commit on which the tests are green (the later fix), for the sanity check.
    public var reference: String?
    /// Whether the test command passed on the reference commit (nil: not checked).
    public var referenceGreen: Bool?
    public var createdAt: Date

    public init(id: String, title: String, repo: String, mainRepo: String? = nil, base: String, prompt: String, source: Source,
                modeID: String? = nil, oracle: Oracle, successMode: Bool? = nil, reference: String? = nil, createdAt: Date = .now) {
        self.id = id
        self.title = title
        self.repo = repo
        self.mainRepo = mainRepo
        self.base = base
        self.prompt = prompt
        self.source = source
        self.modeID = modeID
        self.oracle = oracle
        self.successMode = successMode
        self.reference = reference
        self.createdAt = createdAt
    }

    /// The repository's main folder: as recorded when the task was made, else found from `repo`.
    /// Layer sets and evals take one repository by it.
    public var mainFolder: URL {
        mainRepo.map { URL(filePath: $0, directoryHint: .isDirectory) } ?? ControlTasks.mainFolder(of: repo)
    }

    /// Whether the repository is still on this Mac (its main folder).
    public var repositoryExists: Bool { FileManager.default.fileExists(atPath: mainFolder.path) }

    /// Where cells clone the base commit from: the task's folder, or the main folder once a
    /// worktree is gone (worktrees share the repository's objects).
    public var cloneSource: URL {
        FileManager.default.fileExists(atPath: repo) ? URL(filePath: repo, directoryHint: .isDirectory) : mainFolder
    }
}

/// Making, listing and removing control tasks. Making one reads git and the session index;
/// nothing is sent anywhere.
public enum ControlTasks {
    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
        public init(message: String) { self.message = message }
    }

    /// Modes that show only when the user pushes back (seeds 2 and 3): one turn can't
    /// reproduce them, so they stay with production signals.
    public static let needPushback: Set<String> = ["user-constraint-violated", "intent-misread"]

    /// A task from an exemplar session: its first user turn verbatim, the repository its
    /// folder belongs to, and HEAD at its start from the session index (`head` overrides it).
    public static func fromSession(_ session: SessionSummary, modeID: String?, oracle: ControlTask.Oracle, successMode: Bool = false,
                                   reference: String? = nil, head: String? = nil, env: HarnessEnvironment) async throws -> ControlTask {
        try checkOracle(oracle)
        guard let key = SessionKey.of(session) else { throw Failure(message: "AKit can't read \(session.harness.displayName) sessions.") }
        let transcript = try SessionReader.transcript(of: session)
        let prompt = transcript.items.first { if case .user = $0.kind { true } else { false } }?.text ?? ""
        guard !prompt.isEmpty else { throw Failure(message: "The session \(key) has no first user turn to use as the prompt.") }
        guard let base = head ?? IndexQueries.sessionHead(harness: key.harness, sessionID: key.nativeID, env: env) else {
            throw Failure(message: "No HEAD was recorded at the start of \(key) (the capture hook wasn't installed then), "
                              + "so it can't become a control task; write a minimal reproduction instead.")
        }
        guard let folder = session.project else { throw Failure(message: "The session \(key) records no folder.") }
        let repo = try await repository(folder, env: env)
        let full = try await commit(base, in: repo, env: env)
        return ControlTask(id: newID(prompt), title: JSONLines.titleLine(prompt, limit: 60), repo: repo.path,
                           mainRepo: mainFolder(of: repo.path).path, base: full, prompt: prompt, source: .session(key: key), modeID: modeID, oracle: oracle,
                           successMode: successMode ? true : nil, reference: reference)
    }

    /// A minimal reproduction: the simplest request that triggers the mode, written by the user.
    public static func reproduction(repo folder: URL, base: String, prompt: String, modeID: String?, oracle: ControlTask.Oracle,
                                    successMode: Bool = false, reference: String? = nil, env: HarnessEnvironment) async throws -> ControlTask {
        try checkOracle(oracle)
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw Failure(message: "The prompt is empty.") }
        let repo = try await repository(folder, env: env)
        let full = try await commit(base, in: repo, env: env)
        return ControlTask(id: newID(prompt), title: JSONLines.titleLine(prompt, limit: 60), repo: repo.path,
                           mainRepo: mainFolder(of: repo.path).path, base: full, prompt: prompt, source: .reproduction, modeID: modeID, oracle: oracle, successMode: successMode ? true : nil,
                           reference: reference)
    }

    /// A task from a commit (`docs/design/layer-evals.md`, "Tasks and layer sets"): redo it
    /// from its parent; the commit's own tests judge the cell. The commit is checked as a
    /// replay task first (two local builds, minutes, no tokens) unless its replay task is
    /// cached. A commit that already has a control task gives that task back.
    public static func fromCommit(_ reference: String, repo: URL, env: HarnessEnvironment,
                                  out: @escaping @Sendable (String) -> Void = { _ in }) async throws -> ControlTask {
        let replay: ReplayTask
        do {
            replay = try await ReplayTasks.task(commit: reference, repo: repo, env: env, out: out)
        } catch let failure as ReplayTasks.Failure {
            throw Failure(message: failure.message)
        }
        if let existing = list(env: env).first(where: { $0.source == .commit(sha: replay.commit) }) { return existing }
        var task = ControlTask(id: newID(replay.subject), title: JSONLines.titleLine(replay.subject, limit: 60), repo: replay.repo,
                               mainRepo: mainFolder(of: replay.repo).path, base: replay.base, prompt: replay.prompt, source: .commit(sha: replay.commit),
                               oracle: .hiddenTests(commit: replay.commit), reference: replay.commit)
        // Validation ran the tests on the commit itself: they pass there.
        task.referenceGreen = true
        return task
    }

    /// An assertion needs a code check, and a mode one turn can show.
    static func checkOracle(_ oracle: ControlTask.Oracle) throws {
        switch oracle {
        case .hiddenTests:
            throw Failure(message: "Hidden tests come from a commit: make the task with --commit.")
        case .tests(let command):
            guard !command.trimmingCharacters(in: .whitespaces).isEmpty else { throw Failure(message: "The test command is empty.") }
        case .assertion(let modeID):
            guard !needPushback.contains(modeID) else {
                throw Failure(message: "\(modeID) needs the user's pushback, which a single-turn task can't reproduce; "
                                  + "follow it with production signals instead.")
            }
            guard CodeChecks.check(for: modeID) != nil else {
                throw Failure(message: "No code check for \(modeID), so it can't be an assertion. Code checks: "
                                  + CodeChecks.all.map(\.modeID).joined(separator: ", ") + ".")
            }
        }
    }

    /// `fix-the-login-bug-a1b2`: readable, unique.
    static func newID(_ prompt: String) -> String {
        let words = prompt.lowercased().split { !$0.isLetter && !$0.isNumber }.prefix(5)
        let slug = String(words.joined(separator: "-").unicodeScalars.filter(\.isASCII).prefix(40))
        let suffix = UUID().uuidString.prefix(4).lowercased()
        return slug.isEmpty ? "task-\(suffix)" : "\(slug)-\(suffix)"
    }

    /// The main folder of a task's repository, also when the task was made in a linked
    /// worktree: worktrees of one repository share its git folder (what `git rev-parse
    /// --git-common-dir` names), read here from `.git` and `commondir`. Layer sets and layer
    /// evals take one repository by this folder; the project's answers and `project_name`
    /// come from it. Any other layout gives the folder itself.
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

    static func repository(_ folder: URL, env: HarnessEnvironment) async throws -> URL {
        guard let root = await git(["rev-parse", "--show-toplevel"], in: folder, env: env) else {
            throw Failure(message: "\(folder.path) is not in a git repository.")
        }
        return URL(filePath: root, directoryHint: .isDirectory)
    }

    /// The full sha of `reference`; refuses one the repository doesn't have.
    static func commit(_ reference: String, in repo: URL, env: HarnessEnvironment) async throws -> String {
        guard let sha = await git(["rev-parse", "--verify", "--quiet", "\(reference)^{commit}"], in: repo, env: env) else {
            throw Failure(message: "The base commit \(reference) isn't in \(repo.path), so the task can't start from it.")
        }
        return sha
    }

    private static func git(_ arguments: [String], in folder: URL, env: HarnessEnvironment) async -> String? {
        guard let result = await ProcessRunner.run(env.findExecutable("git") ?? URL(filePath: "/usr/bin/git"),
                                                   arguments: ["-C", folder.path] + arguments, environment: env.gitVariables,
                                                   timeout: 60),
              result.succeeded else { return nil }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs the task's test command on its reference commit and records whether it passed: a
    /// test oracle that isn't green there can't tell a fix from noise.
    @discardableResult
    public static func checkReference(_ task: ControlTask, env: HarnessEnvironment, trash: (URL) throws -> URL? = Trash.move,
                                      out: @escaping @Sendable (String) -> Void = { _ in }) async throws -> ControlTask {
        guard case .tests(let command) = task.oracle else { throw Failure(message: "Only a test oracle has a reference to check.") }
        guard let reference = task.reference else { throw Failure(message: "The task names no reference commit (--reference SHA).") }
        let result = try await ControlCell.checkReference(repo: URL(filePath: task.repo, directoryHint: .isDirectory), commit: reference,
                                                          command: command,
                                                          log: EvalPaths(env: env).folder.appending(path: "reference-\(AnalysisPaths.fileName(task.id)).log"),
                                                          env: env, trash: trash, out: out)
        // Into the task as it is on disk now: the check takes minutes, and the file may have
        // changed meanwhile.
        let url = EvalPaths(env: env).task(task.id)
        return try JSONFile.locked(url) {
            var checked = JSONFile.read(ControlTask.self, from: url) ?? task
            checked.referenceGreen = result.passed
            try AnalysisJSON.encoder.encode(checked).write(to: url, options: .atomic)
            return checked
        }
    }

    /// Where a task's session came from (`SessionNotes.origin`). Only a Pi log's providers
    /// matter, so only Pi looks its file up in the index.
    public static func origin(of key: SessionKey, env: HarnessEnvironment) -> SendOrigin {
        let file = key.harness != "pi" ? nil : (try? AnalysisIndex.open(env: env)).flatMap { $0 }.flatMap { database in
            (try? AnalysisIndex.sessions(database))?.first { $0.key == key.description }?.file
        }
        return SessionNotes.origin(sessionKey: key.description, transcript: file)
    }

    /// Writes the task under its file's lock, so it never interleaves with another writer.
    public static func save(_ task: ControlTask, env: HarnessEnvironment) throws {
        try JSONFile.write(task, to: EvalPaths(env: env).task(task.id))
    }

    public static func load(_ id: String, env: HarnessEnvironment) -> ControlTask? {
        (try? Data(contentsOf: EvalPaths(env: env).task(id))).flatMap { try? AnalysisJSON.decoder.decode(ControlTask.self, from: $0) }
    }

    /// Every task, oldest first.
    public static func list(env: HarnessEnvironment) -> [ControlTask] {
        FileWalk.children(of: EvalPaths(env: env).tasks)
            .filter { $0.pathExtension == "json" }
            .compactMap { (try? Data(contentsOf: $0)).flatMap { try? AnalysisJSON.decoder.decode(ControlTask.self, from: $0) } }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Moves the task's file to the Trash. Its cells stay Lab runs.
    public static func remove(_ id: String, env: HarnessEnvironment, trash: (URL) throws -> URL? = Trash.move) throws {
        let file = EvalPaths(env: env).task(id)
        guard FileManager.default.fileExists(atPath: file.path) else { throw Failure(message: "No control task \(id).") }
        _ = try trash(file)
    }
}
