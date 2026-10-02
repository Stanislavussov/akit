import Foundation
import Testing
import AKitFoundation
import AKitInsights
import AKitLab
import AKitSessions
@testable import AKitErrorAnalysis

/// Control tasks from sessions and reproductions, in a temporary home with a temporary
/// repository as the user's.
@Suite(.serialized)
struct ControlTasksTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-controltasks-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var env: HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home, variables: [
            "HOME": home.path, "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "T", "GIT_AUTHOR_EMAIL": "t@example.com",
            "GIT_COMMITTER_NAME": "T", "GIT_COMMITTER_EMAIL": "t@example.com",
        ], executableSearchPaths: [URL(filePath: "/usr/bin"), URL(filePath: "/bin")])
    }

    @discardableResult
    func git(_ args: String..., in folder: URL) async -> String? {
        let result = await ProcessRunner.run(URL(filePath: "/usr/bin/git"), arguments: ["-C", folder.path] + args,
                                             environment: env.gitVariables, timeout: 60)
        return result?.succeeded == true ? result?.output.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    /// A repository with two commits; returns the root and the first commit.
    func repository() async throws -> (repo: URL, base: String) {
        let repo = home.appending(path: "repo")
        try fm.createDirectory(at: repo.appending(path: "Sources"), withIntermediateDirectories: true)
        await git("init", "-q", "-b", "master", in: repo)
        try Data("let x = 1\n".utf8).write(to: repo.appending(path: "Sources/x.swift"))
        await git("add", "-A", in: repo)
        await git("commit", "-q", "-m", "Start", in: repo)
        let base = try #require(await git("rev-parse", "HEAD", in: repo))
        try Data("let x = 2\n".utf8).write(to: repo.appending(path: "Sources/x.swift"))
        await git("commit", "-q", "-am", "Later", in: repo)
        return (repo, base)
    }

    /// A Claude Code session that ran in `folder`; `prompt` nil = no user turn.
    func session(_ id: String, in folder: URL, prompt: String?) throws -> SessionSummary {
        let dir = home.appending(path: ".claude/projects/-repo")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var lines: [[String: Any]] = []
        if let prompt {
            lines.append(["type": "user", "cwd": folder.path, "sessionId": id, "timestamp": "2026-10-01T10:00:00Z",
                          "message": ["role": "user", "content": prompt]])
        }
        lines.append(["type": "assistant", "cwd": folder.path, "sessionId": id, "timestamp": "2026-10-01T10:00:02Z",
                      "message": ["id": "m-\(id)", "model": "claude-opus-5-5", "role": "assistant",
                                  "content": [["type": "text", "text": "On it"]], "usage": ["input_tokens": 10, "output_tokens": 5]]])
        let text = lines.map { String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n") + "\n"
        let file = dir.appending(path: "\(id).jsonl")
        try Data(text.utf8).write(to: file)
        let info = JSONLines.fileInfo(file)
        return SessionSummary(harness: .claudeCode, file: file, title: "t", project: folder, started: nil, modified: info.modified,
                              size: info.size)
    }

    /// The capture hook's spool line for a session start, imported into the index.
    func recordHead(_ head: String, session id: String) async throws {
        _ = Spool.append(["v": 1, "kind": "session_start", "harness": "claude", "session_id": id, "ts": Spool.milliseconds(Date()),
                          "head": head], home: home)
        let database = try IndexSchema.open(InsightsPaths(env: env).database)
        _ = try await SessionImporter.importAndBind(env: env, projectsRoot: home.appending(path: "Projects"), database: database)
    }

    @Test func taskFromSessionUsesTheFirstTurnAndHeadAtItsStart() async throws {
        let (repo, base) = try await repository()
        let id = "11111111-1111-4111-8111-111111111111"
        let summary = try session(id, in: repo.appending(path: "Sources"), prompt: "Fix the parser\n  keep the API")
        try await recordHead(base, session: id)
        #expect(IndexQueries.sessionHead(harness: "claude", sessionID: id, env: env) == base)

        let task = try await ControlTasks.fromSession(summary, modeID: "repeated-steps", oracle: .tests(command: "swift test"), env: env)
        #expect(task.prompt == "Fix the parser\n  keep the API")
        #expect(task.base == base && task.source == .session(key: SessionKey(harness: "claude", nativeID: id)))
        #expect(URL(filePath: task.repo).resolvingSymlinksInPath().path == repo.resolvingSymlinksInPath().path)
        #expect(task.id.hasPrefix("fix-the-parser-keep-the-") && task.title == "Fix the parser")
        #expect(task.oracle == .tests(command: "swift test") && task.modeID == "repeated-steps")

        try ControlTasks.save(task, env: env)
        #expect(fm.fileExists(atPath: home.appending(path: ".akit/lab/evals/tasks/\(task.id).json").path))
        let loaded = try #require(ControlTasks.load(task.id, env: env))
        #expect(loaded.prompt == task.prompt && loaded.source == task.source && loaded.oracle == task.oracle && loaded.base == base)
        #expect(ControlTasks.list(env: env).map(\.id) == [task.id])
    }

    @Test func sessionsThatCantBecomeTasksAreRefused() async throws {
        let (repo, base) = try await repository()
        // No HEAD recorded at the start.
        let noHead = try session("22222222-2222-4222-8222-222222222222", in: repo, prompt: "Do it")
        await #expect { try await ControlTasks.fromSession(noHead, modeID: nil, oracle: .tests(command: "make test"), env: env) } throws: {
            ($0 as? ControlTasks.Failure)?.message.contains("write a minimal reproduction instead") == true
        }
        // A head the repository doesn't have.
        await #expect { try await ControlTasks.fromSession(noHead, modeID: nil, oracle: .tests(command: "make test"),
                                                           head: String(repeating: "a", count: 40), env: env) } throws: {
            ($0 as? ControlTasks.Failure)?.message.contains("isn't in") == true
        }
        // No first user turn.
        let silent = try session("33333333-3333-4333-8333-333333333333", in: repo, prompt: nil)
        await #expect { try await ControlTasks.fromSession(silent, modeID: nil, oracle: .tests(command: "make test"), head: base, env: env) } throws: {
            ($0 as? ControlTasks.Failure)?.message.contains("no first user turn") == true
        }
        // Not in a repository.
        let outside = try session("44444444-4444-4444-8444-444444444444", in: home, prompt: "Do it")
        await #expect(throws: ControlTasks.Failure.self) {
            try await ControlTasks.fromSession(outside, modeID: nil, oracle: .tests(command: "make test"), head: base, env: env)
        }
    }

    @Test func reproductionsAndTheirOracles() async throws {
        let (repo, base) = try await repository()
        let task = try await ControlTasks.reproduction(repo: repo, base: String(base.prefix(7)), prompt: "  Read Big.swift and summarize  ",
                                                       modeID: nil, oracle: .assertion(modeID: "large-file-read-whole"), env: env)
        #expect(task.base == base && task.prompt == "Read Big.swift and summarize" && task.source == .reproduction)

        // Modes that need the user's pushback can't be single-turn assertions.
        for mode in ["user-constraint-violated", "intent-misread"] {
            await #expect { try await ControlTasks.reproduction(repo: repo, base: base, prompt: "x", modeID: mode,
                                                                oracle: .assertion(modeID: mode), env: env) } throws: {
                ($0 as? ControlTasks.Failure)?.message.contains("pushback") == true
            }
        }
        await #expect(throws: ControlTasks.Failure.self) {
            try await ControlTasks.reproduction(repo: repo, base: base, prompt: "x", modeID: nil, oracle: .assertion(modeID: "no-such-mode"), env: env)
        }
        await #expect(throws: ControlTasks.Failure.self) {
            try await ControlTasks.reproduction(repo: repo, base: "nope", prompt: "x", modeID: nil, oracle: .tests(command: "true"), env: env)
        }
        await #expect(throws: ControlTasks.Failure.self) {
            try await ControlTasks.reproduction(repo: repo, base: base, prompt: " ", modeID: nil, oracle: .tests(command: "true"), env: env)
        }

        // Removing moves the file to the Trash (here: a folder of the test).
        try ControlTasks.save(task, env: env)
        let trash = home.appending(path: "Trash")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        try ControlTasks.remove(task.id, env: env) { url in
            let target = trash.appending(path: url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: target)
            return target
        }
        #expect(ControlTasks.list(env: env).isEmpty && fm.fileExists(atPath: trash.appending(path: "\(task.id).json").path))
        #expect(throws: ControlTasks.Failure.self) { try ControlTasks.remove(task.id, env: env) { _ in nil } }
    }

    @Test func theReferenceCheckRunsTheTestsOnTheReferenceCommit() async throws {
        let (repo, base) = try await repository()
        let head = try #require(await git("rev-parse", "HEAD", in: repo))
        let remove: (URL) throws -> URL? = { try FileManager.default.removeItem(at: $0); return nil }
        let green = try await ControlTasks.reproduction(repo: repo, base: base, prompt: "Make x 2", modeID: nil,
                                                       oracle: .tests(command: "grep -q 'x = 2' Sources/x.swift"), reference: head, env: env)
        try ControlTasks.save(green, env: env)
        // Written under the file's lock, like every other analysis file.
        #expect(fm.fileExists(atPath: EvalPaths(env: env).task(green.id).appendingPathExtension("lock").path))
        // A change saved while the check runs (here: before it, with a stale copy in hand) is kept.
        var renamed = green
        renamed.title = "Renamed meanwhile"
        try ControlTasks.save(renamed, env: env)
        #expect(try await ControlTasks.checkReference(green, env: env, trash: remove).referenceGreen == true)
        #expect(ControlTasks.load(green.id, env: env)?.referenceGreen == true)
        #expect(ControlTasks.load(green.id, env: env)?.title == "Renamed meanwhile")
        let red = try await ControlTasks.reproduction(repo: repo, base: base, prompt: "Make x 3", modeID: nil,
                                                     oracle: .tests(command: "grep -q 'x = 3' Sources/x.swift"), reference: head, env: env)
        #expect(try await ControlTasks.checkReference(red, env: env, trash: remove).referenceGreen == false)
        await #expect(throws: (any Error).self) {
            _ = try await ControlTasks.checkReference(ControlTask(id: "t", title: "t", repo: repo.path, base: base, prompt: "p",
                                                                  source: .reproduction, modeID: nil, oracle: .tests(command: "true")),
                                                      env: env, trash: remove)
        }
    }
}
