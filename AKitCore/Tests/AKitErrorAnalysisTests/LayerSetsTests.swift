import Foundation
import Testing
import AKitBrain
import AKitFoundation
@testable import AKitErrorAnalysis

/// Layer sets in a temporary home: tasks by hand, field answers, one repository per set.
struct LayerSetsTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-layersets-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var env: HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home, variables: ["HOME": home.path], executableSearchPaths: [URL(filePath: "/usr/bin")])
    }

    /// `repo`: a folder name under the home (made here), or an absolute path as it is.
    func task(_ id: String, repo: String = "akit") throws -> ControlTask {
        var repo = repo
        if !repo.hasPrefix("/") {
            repo = home.appending(path: repo).path
            try fm.createDirectory(atPath: repo, withIntermediateDirectories: true)
        }
        let task = ControlTask(id: id, title: id, repo: repo, base: String(repeating: "a", count: 40), prompt: "p", source: .reproduction,
                               oracle: .tests(command: "true"))
        try ControlTasks.save(task, env: env)
        return task
    }

    @Test func tasksAndAnswersOfASet() throws {
        let (one, two) = (try task("one-abcd"), try task("two-abcd"))
        #expect(LayerSets.load("swiftui", env: env) == nil && LayerSets.list(env: env).isEmpty)
        let made = try LayerSets.add([one], to: "swiftui", now: Date(timeIntervalSince1970: 0), env: env)
        #expect(made.tasks == ["one-abcd"] && made.createdAt == Date(timeIntervalSince1970: 0))
        // Adding again keeps one entry and the order.
        let added = try LayerSets.add([two, one], to: "swiftui", now: Date(timeIntervalSince1970: 10), env: env)
        #expect(added.tasks == ["one-abcd", "two-abcd"] && added.createdAt == Date(timeIntervalSince1970: 0)
                && added.updatedAt == Date(timeIntervalSince1970: 10))
        #expect(LayerSets.layers(holding: "two-abcd", in: LayerSets.list(env: env)) == ["swiftui"])

        try LayerSets.setAnswer("ui_check", .text("make snapshot"), in: "swiftui", env: env)
        try LayerSets.setAnswer("strict", .bool(true), in: "swiftui", env: env)
        try LayerSets.setAnswer("strict", nil, in: "swiftui", env: env)
        #expect(LayerSets.load("swiftui", env: env)?.answers == ["ui_check": .text("make snapshot")])
        let text = try String(contentsOf: EvalPaths(env: env).set("swiftui"), encoding: .utf8)
        #expect(text.contains(#""schema" : 1"#) && text.contains(#""ui_check" : "make snapshot""#))

        try LayerSets.remove(["one-abcd"], from: "swiftui", env: env)
        #expect(LayerSets.load("swiftui", env: env)?.tasks == ["two-abcd"])
        #expect(throws: LayerSets.Failure.self) { try LayerSets.remove(["one-abcd"], from: "swiftui", env: env) }
        #expect(throws: LayerSets.Failure.self) { try LayerSets.remove(["two-abcd"], from: "other", env: env) }

        // A removed task shows as missing and is skipped.
        try LayerSets.add([one], to: "swiftui", env: env)
        try fm.removeItem(at: EvalPaths(env: env).task("one-abcd"))
        let set = try #require(LayerSets.load("swiftui", env: env))
        let tasks = LayerSets.tasks(of: set, env: env)
        #expect(tasks.found.map(\.id) == ["two-abcd"] && tasks.missing == ["one-abcd"])

        // Deleting moves the file to the Trash (here: a folder of the test); the tasks stay.
        let trash = home.appending(path: "Trash")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        try LayerSets.delete("swiftui", env: env) { url in
            let target = trash.appending(path: url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: target)
            return target
        }
        #expect(LayerSets.load("swiftui", env: env) == nil && ControlTasks.load("two-abcd", env: env) != nil)
        #expect(throws: LayerSets.Failure.self) { try LayerSets.delete("swiftui", env: env) { _ in nil } }
    }

    @Test func oneRepositoryPerSetAndNoCoreSet() throws {
        let (akit, other, again) = (try task("a-abcd"), try task("b-abcd", repo: "other"), try task("c-abcd"))
        #expect(throws: LayerSets.Failure.self) { try LayerSets.add([akit, other], to: "swiftui", env: env) }
        try LayerSets.add([akit], to: "swiftui", env: env)
        #expect { try LayerSets.add([other], to: "swiftui", env: env) } throws: {
            ($0 as? LayerSets.Failure)?.message.contains("one repository") == true
        }
        try LayerSets.add([again], to: "swiftui", env: env)
        // Once the set's tasks are gone, another repository may join.
        try LayerSets.remove(["a-abcd", "c-abcd"], from: "swiftui", env: env)
        #expect(try LayerSets.add([other], to: "swiftui", env: env).tasks == ["b-abcd"])
        #expect(throws: LayerSets.Failure.self) { try LayerSets.add([akit], to: "core", env: env) }
        #expect(throws: LayerSets.Failure.self) { try LayerSets.setAnswer("x", .text("y"), in: "core", env: env) }

        // A task whose repository is gone is refused for itself; held, it doesn't fix the set's repository.
        let gone = try task("gone-abcd", repo: home.appending(path: "gone").path)
        #expect { try LayerSets.add([gone], to: "swiftui", env: env) } throws: {
            ($0 as? LayerSets.Failure)?.message.contains("gone-abcd is gone from this Mac") == true
        }
        try fm.createDirectory(at: home.appending(path: "gone"), withIntermediateDirectories: true)
        try LayerSets.add([gone], to: "solo", env: env)
        try fm.removeItem(at: home.appending(path: "gone"))
        #expect(try LayerSets.add([other], to: "solo", env: env).tasks == ["gone-abcd", "b-abcd"])
    }

    /// Worktrees of one repository count as one: the user works in worktrees.
    @Test func worktreesOfOneRepositoryShareASet() async throws {
        let repo = home.appending(path: "akit", directoryHint: .isDirectory)
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        try Data("x\n".utf8).write(to: repo.appending(path: "x.txt"))
        let variables = ["HOME": home.path, "GIT_CONFIG_NOSYSTEM": "1", "GIT_AUTHOR_NAME": "T", "GIT_AUTHOR_EMAIL": "t@example.com",
                         "GIT_COMMITTER_NAME": "T", "GIT_COMMITTER_EMAIL": "t@example.com"]
        let worktree = home.appending(path: "akit/.claude/worktrees/agent-1", directoryHint: .isDirectory)
        for args in [["init", "-q", "-b", "master"], ["add", "-A"], ["commit", "-q", "-m", "Start"], ["worktree", "add", "-q", "--detach", worktree.path]] {
            let result = await ProcessRunner.run(URL(filePath: "/usr/bin/git"), arguments: ["-C", repo.path] + args, environment: variables, timeout: 60)
            #expect(result?.succeeded == true, "\(args): \(result?.output ?? "")")
        }
        #expect(ControlTasks.mainFolder(of: worktree.path).path == ControlTasks.mainFolder(of: repo.path).path)
        #expect(ControlTasks.mainFolder(of: home.path).path == home.standardizedFileURL.resolvingSymlinksInPath().path)
        let (main, linked) = (try task("main-abcd", repo: repo.path), try task("linked-abcd", repo: worktree.path))
        #expect(try LayerSets.add([main, linked], to: "swiftui", env: env).tasks == ["main-abcd", "linked-abcd"])
        #expect(throws: LayerSets.Failure.self) { try LayerSets.add([try task("other-abcd", repo: "other")], to: "swiftui", env: env) }
    }

    @Test func writersDontLoseEachOthersTasks() async throws {
        let tasks = try (0..<12).map { try task("task-\($0)-abcd") }
        let env = env
        try await withThrowingTaskGroup(of: Void.self) { group in
            for task in tasks { group.addTask { try LayerSets.add([task], to: "swiftui", env: env) } }
            try await group.waitForAll()
        }
        #expect(Set(LayerSets.load("swiftui", env: env)?.tasks ?? []) == Set(tasks.map(\.id)))
    }

    @Test func aSetOfANewerAkitIsSkippedAndKept() throws {
        let url = EvalPaths(env: env).set("swiftui")
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let newer = #"{"schema": 2, "layer": "swiftui", "tasks": [], "answers": {}, "createdAt": "2026-10-08T10:00:00Z", "updatedAt": "2026-10-08T10:00:00Z"}"#
        try Data(newer.utf8).write(to: url)
        #expect(LayerSets.load("swiftui", env: env) == nil && LayerSets.list(env: env).isEmpty)
        #expect(LayerSets.problem("swiftui", env: env)?.contains("newer AKit") == true)
        #expect(throws: LayerSets.Failure.self) { try LayerSets.add([try task("a-abcd")], to: "swiftui", env: env) }
        #expect(try String(contentsOf: url, encoding: .utf8) == newer)
    }
}
