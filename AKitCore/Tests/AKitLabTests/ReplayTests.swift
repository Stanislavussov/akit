import Foundation
import Testing
import AKitFoundation
@testable import AKitLab

/// Replay tasks: test names, commits as tasks, the isolated clone, leaks and comparisons.
struct ReplayTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-replay-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var env: HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home, variables: [
            "HOME": home.path, "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "T", "GIT_AUTHOR_EMAIL": "t@example.com",
            "GIT_COMMITTER_NAME": "T", "GIT_COMMITTER_EMAIL": "t@example.com",
        ], executableSearchPaths: [URL(filePath: "/usr/bin")])
    }

    @Test func testNamesFromSwiftTestingAndXCTest() {
        let source = """
            import Testing
            @Suite(.serialized)
            struct ParserTests {
                let value = "{ not a brace"   // braces in strings are rare in test files
                @Test func parsesEmpty() { }
                @Test("Named", arguments: [1, 2])
                func parsesNumbers(_ n: Int) {
                    if n > 0 { }
                }
                func helper() {}
                struct Inner {
                    @Test func deep() {}
                }
                @Test func afterInner() async throws {}
            }
            @Test func freeStanding() {}
            final class OldTests: XCTestCase {
                func testOne() {}
                func helperTwo() {}
            }
            extension OldTests {
                func testLater() {}
            }
            """
        let names = TestNames.parse(source).map(\.id)
        #expect(names.count == 7)
        #expect(Set(names) == ["ParserTests/parsesEmpty", "ParserTests/parsesNumbers", "Inner/deep", "ParserTests/afterInner",
                               "freeStanding", "OldTests/testOne", "OldTests/testLater"])
    }

    @Test func filtersMatchOnlyTheirTest() throws {
        let test = TestName(suite: "ParserTests", name: "parses")
        let regex = try Regex(test.filter)
        #expect("AKitLabTests.ParserTests/parses()".contains(regex))
        #expect(!"AKitLabTests.ParserTests/parsesMore()".contains(regex))
        #expect(!"AKitLabTests.OtherParserTests/parses()".contains(regex))
        #expect("AKitLabTests.Outer/ParserTests/parses()".contains(regex))
        let xctest = TestName(suite: "OldTests", name: "testOne", xctest: true)
        #expect("Pkg.OldTests/testOne".contains(try Regex(xctest.filter)))
        #expect(!"Pkg.OldTests/testOneMore".contains(try Regex(xctest.filter)))
        // Tasks cached before XCTest support decode as Swift Testing.
        let old = try JSONDecoder().decode(TestName.self, from: Data(#"{"suite":"S","name":"n"}"#.utf8))
        #expect(old == TestName(suite: "S", name: "n"))
        #expect(TestNames.isTestFile("AKitCore/Tests/AKitLabTests/ReplayTests.swift"))
        #expect(!TestNames.isTestFile("AKitCore/Sources/AKitLab/TestNames.swift"))
        #expect(!TestNames.isTestFile("AKitCore/Sources/AKitLab/SwiftTests.swift"))
        #expect(TestNames.isTestFile("Tests/Unit/ParserTests.swift"))
    }

    @Test func testOutcomeFromOutput() {
        let ok = ChildProcess.Exit(status: 0, exitedNormally: true, timedOut: false, cancelled: false)
        let bad = ChildProcess.Exit(status: 1, exitedNormally: true, timedOut: false, cancelled: false)
        #expect(SwiftTests.outcome(ok, output: "Executed 0 tests, with 0 failures\n✔ Test run with 1 test passed") == .passed)
        #expect(SwiftTests.outcome(ok, output: "Executed 0 tests, with 0 failures\n✔ Test run with 0 tests passed") == .notRun)
        #expect(SwiftTests.outcome(bad, output: "✘ Test run with 1 test failed") == .failed)
        #expect(SwiftTests.outcome(ChildProcess.Exit(status: 15, exitedNormally: false, timedOut: true, cancelled: false),
                                   output: "") == .timedOut)
    }

    func git(_ args: String..., in folder: URL) async -> String? { await LabGit.output(args, in: folder, env: env) }

    func write(_ path: String, _ text: String, in folder: URL) throws {
        let url = folder.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// A package whose second commit fixes `add` and adds a test for it.
    func repository() async throws -> (repo: URL, base: String, fix: String) {
        let repo = home.appending(path: "repo")
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        _ = await git("init", "-q", "-b", "master", in: repo)
        try write("Pkg/Package.swift", "// swift-tools-version: 6.0\n", in: repo)
        try write("Pkg/Sources/Lib/Lib.swift", "public func add(_ a: Int, _ b: Int) -> Int { a - b }\n", in: repo)
        try write("Pkg/Tests/LibTests/LibTests.swift", "import Testing\nstruct LibTests {\n    @Test func zero() {}\n}\n", in: repo)
        _ = await git("add", "-A", in: repo)
        _ = await git("commit", "-q", "-m", "Start", in: repo)
        let base = await git("rev-parse", "HEAD", in: repo)!
        try write("Pkg/Sources/Lib/Lib.swift", "public func add(_ a: Int, _ b: Int) -> Int { a + b }\n", in: repo)
        try write("Pkg/Tests/LibTests/LibTests.swift",
                  "import Testing\nstruct LibTests {\n    @Test func zero() {}\n    @Test func adds() {}\n}\n", in: repo)
        _ = await git("commit", "-q", "-am", "Fix add\n\nIt subtracted.\n\nCo-Authored-By: Someone <x@example.com>", in: repo)
        let fix = await git("rev-parse", "HEAD", in: repo)!
        return (repo, base, fix)
    }

    @Test func draftReadsTheCommit() async throws {
        let (repo, base, fix) = try await repository()
        let draft = try await ReplayTasks.draft(commit: String(fix.prefix(7)), repo: repo.appending(path: "Pkg"), env: env)
        #expect(draft.commit == fix && draft.base == base && draft.subject == "Fix add")
        #expect(draft.package == "Pkg" && draft.testFiles == ["Pkg/Tests/LibTests/LibTests.swift"])
        #expect(draft.tests.map(\.id) == ["LibTests/adds", "LibTests/zero"])
        #expect(ReplayTasks.prompt(message: draft.message) == "Fix add\n\nIt subtracted.\n\n" + ReplayTask.instruction)

        await #expect(throws: ReplayTasks.Failure.self) { try await ReplayTasks.draft(commit: base, repo: repo, env: env) }
        await #expect(throws: ReplayTasks.Failure.self) { try await ReplayTasks.draft(commit: "nope", repo: repo, env: env) }
    }

    @Test func cloneHoldsOnlyTheBase() async throws {
        let (repo, base, fix) = try await repository()
        let work = home.appending(path: "work")
        try await IsolatedClone.make(at: work, from: repo, commit: base, env: env)
        #expect(await git("rev-parse", "HEAD", in: work) == base)
        #expect(await git("for-each-ref", in: work) == "")
        #expect(await git("remote", in: work) == "")
        #expect(await LabGit.run(["cat-file", "-e", fix], in: work, env: env)?.succeeded == false)
        #expect(try String(contentsOf: work.appending(path: "Pkg/Sources/Lib/Lib.swift"), encoding: .utf8).contains("a - b"))

        try await IsolatedClone.copyTests(["Pkg/Tests/LibTests/LibTests.swift"], from: repo, commit: fix, into: work, env: env)
        #expect(try String(contentsOf: work.appending(path: "Pkg/Tests/LibTests/LibTests.swift"), encoding: .utf8).contains("adds"))
    }

    @Test func leaksInToolCallsOnly() throws {
        let task = ReplayTask(repo: "/r", commit: "1c9cf65aaaa", base: "b", subject: "Report layer.yaml mistakes",
                              prompt: "Report layer.yaml mistakes", package: "", testFiles: [], failToPass: [], passToPass: [],
                              validatedAt: .now, notes: [])
        func transcript(_ lines: [[String: Any]]) throws -> URL {
            let url = home.appending(path: "\(UUID().uuidString).jsonl")
            let text = try lines.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n")
            try Data(text.utf8).write(to: url)
            return url
        }
        let clean = try transcript([
            ["type": "user", "message": ["content": "Report layer.yaml mistakes"]],
            ["type": "assistant", "message": ["content": [["type": "tool_use", "name": "Bash",
                                                            "input": ["command": "git commit -m 'Report layer.yaml mistakes'"]]]]],
        ])
        #expect(LeakCheck.leaks(in: clean, task: task, repo: URL(filePath: "/r"), env: env).isEmpty)
        let leaked = try transcript([
            ["type": "assistant", "message": ["content": [["type": "tool_use", "name": "Bash",
                                                            "input": ["command": "grep -r layer ~/.claude/projects"]]]]],
            ["type": "user", "message": ["content": [["type": "tool_result", "content": "commit 1c9cf65aaaa"]]]],
        ])
        #expect(LeakCheck.leaks(in: leaked, task: task, repo: URL(filePath: "/r"), env: env).count == 2)
        // Claude Code's own note about a saved long output is not a leak; reading the real repository is.
        let saved = try transcript([
            ["type": "user", "message": ["content": [["type": "tool_result", "content": "Output saved to ~/.claude/projects/x/tool.txt"]]]],
        ])
        #expect(LeakCheck.leaks(in: saved, task: task, repo: URL(filePath: "/r"), env: env).isEmpty)
        let repoRead = try transcript([
            ["type": "assistant", "message": ["content": [["type": "tool_use", "name": "Bash", "input": ["command": "git -C /r log -p"]]]]],
            ["type": "assistant", "message": ["content": [["type": "tool_use", "name": "Read",
                                                            "input": ["file_path": home.path + "/.akit/lab/x/run.json"]]]]],
        ])
        #expect(LeakCheck.leaks(in: repoRead, task: task, repo: URL(filePath: "/r"), env: env)
                == ["the real repository", "AKit's Lab folder"])
        // A control cell of a commit task gets only the signs its own check doesn't look for.
        #expect(LeakCheck.commitSigns(in: leaked, task: task, env: env) == ["the commit 1c9cf65"])
        #expect(LeakCheck.commitSigns(in: repoRead, task: task, env: env) == ["AKit's Lab folder"])
        #expect(LeakCheck.commitSigns(in: clean, task: task, env: env).isEmpty)

        // The hash only as a word of its own; the Lab folder however it is named; the Trash.
        let other = try transcript([
            ["type": "assistant", "message": ["content": [["type": "tool_use", "name": "Bash", "input": ["command": "git show deadbeef1c9cf65"]]]]],
        ])
        #expect(LeakCheck.leaks(in: other, task: task, repo: URL(filePath: "/r"), env: env).isEmpty)
        let elsewhere = try transcript([
            ["type": "assistant", "message": ["content": [["type": "tool_use", "name": "Bash",
                                                            "input": ["command": "ls $HOME/.akit/lab && ls ~/.Trash/akit-replay-x"]]]]],
            ["type": "user", "message": ["content": [["type": "tool_result", "content": "1c9cf65aaaa: Report layer.yaml mistakes"]]]],
        ])
        #expect(LeakCheck.leaks(in: elsewhere, task: task, repo: URL(filePath: "/r"), env: env)
                == ["the commit 1c9cf65", "AKit's Lab folder", "the Trash"])
        #expect(LeakCheck.commitSigns(in: elsewhere, task: task, env: env) == ["the commit 1c9cf65", "AKit's Lab folder"])

        // What a call writes is no sign of the Lab folder or the session history: AKit's own sources mention them.
        let editing = try transcript([
            ["type": "assistant", "message": ["content": [
                ["type": "tool_use", "name": "Edit", "input": ["file_path": "/w/AKitCore/Sources/AKitLab/LabPaths.swift",
                                                              "old_string": "~/.akit/lab", "new_string": "~/.akit/lab/runs ~/.claude/projects"]],
                ["type": "tool_use", "name": "Write", "input": ["file_path": "/w/docs/lab.md", "content": "Runs live in ~/.akit/lab."]],
                ["type": "tool_use", "name": "Grep", "input": ["pattern": "akit/lab", "path": "/w/AKitCore"]],
            ]]],
        ])
        #expect(LeakCheck.leaks(in: editing, task: task, repo: URL(filePath: "/r"), env: env).isEmpty)
        // The hash, the Trash and the real repository count in the whole input: a script written, then run.
        let script = try transcript([
            ["type": "assistant", "message": ["content": [
                ["type": "tool_use", "name": "Write", "input": ["file_path": "/w/peek.sh",
                                                               "content": "ls ~/.Trash/akit-replay-x\ngit -C /r show 1c9cf65\n"]],
                ["type": "tool_use", "name": "Bash", "input": ["command": "sh /w/peek.sh"]],
            ]]],
        ])
        #expect(LeakCheck.leaks(in: script, task: task, repo: URL(filePath: "/r"), env: env)
                == ["the commit 1c9cf65", "the real repository", "the Trash"])
        // What a call reads or runs is.
        for input in [["command": "cat ~/.akit/lab/tasks/x.json"], ["file_path": home.path + "/.akit/lab/tasks/x.json"]] {
            let reading = try transcript([
                ["type": "assistant", "message": ["content": [["type": "tool_use", "name": input["command"] == nil ? "Read" : "Bash", "input": input]]]],
            ])
            #expect(LeakCheck.commitSigns(in: reading, task: task, env: env) == ["AKit's Lab folder"], "\(input)")
        }
        #expect(LeakCheck.pathLikeInput(tool: "write", input: ["path": "a.swift", "content": "x"]) == "a.swift")
        #expect(LeakCheck.pathLikeInput(tool: "WebFetch", input: ["url": "u", "n": 2]) == "2\nu")
    }

    func lines(_ entries: [[String: Any]], to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = try entries.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n")
        try Data(text.utf8).write(to: url)
    }

    func call(_ name: String, _ input: [String: Any], sidechain: Bool = false) -> [String: Any] {
        ["type": "assistant", "isSidechain": sidechain, "message": ["content": [["type": "tool_use", "name": name, "input": input]]]]
    }

    var replayTask: ReplayTask {
        ReplayTask(repo: "/r", commit: "1c9cf65aaaa", base: "b", subject: "s", prompt: "p", package: "", testFiles: [],
                   failToPass: [], passToPass: [], validatedAt: .now, notes: [])
    }

    /// Grep's pattern is a content regex, not a path: searching AKit's sources for `.akit/lab`
    /// is no sign; a file search under the Lab folder is. Claude Code and Pi alike.
    @Test func grepPatternIsNoPathButGlobIs() throws {
        let file = home.appending(path: "s.jsonl")
        for input in [["pattern": ".akit/lab", "path": "/w/AKitCore"], ["pattern": "akit/lab", "glob": "*.swift"]] {
            for name in ["Grep", "grep"] {
                try lines([call(name, input)], to: file)
                #expect(LeakCheck.commitSigns(in: file, task: replayTask, env: env).isEmpty, "\(name) \(input)")
            }
        }
        for (name, input) in [("Glob", ["pattern": "**/*.json", "path": "~/.akit/lab"]), ("Glob", ["pattern": "~/.akit/lab/tasks/*.json"]),
                              ("find", ["pattern": "*.json", "path": home.path + "/.akit/lab"]), ("ls", ["path": "~/.akit/lab"]),
                              ("Grep", ["pattern": "commit", "path": "~/.akit/lab"]), ("grep", ["pattern": "x", "glob": "~/.akit/lab/**"])] {
            try lines([call(name, input)], to: file)
            #expect(LeakCheck.commitSigns(in: file, task: replayTask, env: env) == ["AKit's Lab folder"], "\(name) \(input)")
        }
    }

    /// A subagent's tool calls count: its own file in `<session>/subagents/`, or side-chain
    /// lines of the session file (older Claude Code).
    @Test func subagentCallsAreSigns() throws {
        let file = home.appending(path: "projects/-w/session-1.jsonl")
        try lines([call("Task", ["prompt": "Find how tasks are cached", "subagent_type": "Explore"])], to: file)
        #expect(LeakCheck.commitSigns(in: file, task: replayTask, env: env).isEmpty)
        try lines([call("Read", ["file_path": "~/.akit/lab/tasks/x.json"])],
                  to: home.appending(path: "projects/-w/session-1/subagents/agent-a1.jsonl"))
        #expect(LeakCheck.commitSigns(in: file, task: replayTask, env: env) == ["AKit's Lab folder"])
        #expect(LeakCheck.subagentCalls(of: file).map(\.name) == ["Read"])
        #expect(LeakCheck.leaks(in: file, task: replayTask, repo: URL(filePath: "/r"), env: env) == ["AKit's Lab folder"])

        let old = home.appending(path: "projects/-w/session-2.jsonl")
        try lines([call("Task", ["prompt": "Look"]), call("Bash", ["command": "ls ~/.Trash"], sidechain: true)], to: old)
        #expect(LeakCheck.subagentCalls(of: old).map(\.name) == ["Bash"])
        #expect(LeakCheck.leaks(in: old, task: replayTask, repo: URL(filePath: "/r"), env: env) == ["the Trash"])
    }

    /// A worktree's repository is its main checkout: reading that is reading the real repository.
    @Test func mainCheckoutOfAWorktreeIsTheRealRepository() throws {
        let main = home.appending(path: "main", directoryHint: .isDirectory)
        let worktree = main.appending(path: ".claude/worktrees/agent-1", directoryHint: .isDirectory)
        try fm.createDirectory(at: main.appending(path: ".git/worktrees/agent-1"), withIntermediateDirectories: true)
        try fm.createDirectory(at: worktree, withIntermediateDirectories: true)
        try Data("gitdir: \(main.path)/.git/worktrees/agent-1\n".utf8).write(to: worktree.appending(path: ".git"))
        try Data("../..\n".utf8).write(to: main.appending(path: ".git/worktrees/agent-1/commondir"))
        let resolvedMain = main.standardizedFileURL.resolvingSymlinksInPath().path
        #expect(LabGit.mainFolder(of: worktree.path).path == resolvedMain)

        var task = replayTask
        task.repo = worktree.path
        let file = home.appending(path: "s.jsonl")
        for path in [main.path, resolvedMain] {
            try lines([call("Bash", ["command": "git -C \(path) log -p"])], to: file)
            #expect(LeakCheck.leaks(in: file, task: task, repo: worktree, env: env) == ["the real repository"], "\(path)")
        }
        // The main folder's paths never include `/`: an unrelated absolute path is no sign.
        #expect(!LeakCheck.repositoryPaths([worktree.path]).contains("/"))
        try lines([call("Bash", ["command": "ls /tmp"])], to: file)
        #expect(LeakCheck.leaks(in: file, task: task, repo: worktree, env: env).isEmpty)
    }

    /// The real repository is matched as a whole folder, not as the start of a longer name.
    @Test func repositoryMatchesOnAPathBoundary() throws {
        let repos = LeakCheck.repositoryPaths(["/x/akit"])
        for text in ["cat /x/akit/file", #"{"path":"/x/akit"}"#, "cd /x/akit && swift test", "/x/akit", "ls /x/akit:", "(/x/akit)"] {
            #expect(LeakCheck.mentions(text, anyOf: repos), "\(text)")
        }
        for text in ["cd /x/akit-other && ls", "/x/akit2/file", "/x/akit.git", "/x/akit_old"] {
            #expect(!LeakCheck.mentions(text, anyOf: repos), "\(text)")
        }
        #expect(!LeakCheck.mentions("~/.akit/lab/runs", anyOf: LeakCheck.repositoryPaths(["/r"])))
        // A `.` ends the name only at the end of a sentence.
        #expect(LeakCheck.mentions("see /x/akit.", anyOf: repos) && LeakCheck.mentions("in /x/akit. Then", anyOf: repos))
        #expect(!LeakCheck.mentions("/x/akit.swift", anyOf: repos))
        let file = home.appending(path: "s.jsonl")
        try lines([call("Bash", ["command": "ls /x/akit-other"]), call("Read", ["file_path": "/x/akit/Package.swift"])], to: file)
        #expect(LeakCheck.leaks(in: file, task: replayTask, repo: URL(filePath: "/x/akit"), env: env) == ["the real repository"])
        try lines([call("Bash", ["command": "ls /x/akit-other"])], to: file)
        #expect(LeakCheck.leaks(in: file, task: replayTask, repo: URL(filePath: "/x/akit"), env: env).isEmpty)
    }

    /// A repository under the home folder is also named from it: `~/…`, `$HOME/…`, `${HOME}/…`.
    @Test func repositoryUnderHomeIsNamedFromIt() throws {
        let repo = home.appending(path: "Projects/akit").path
        let file = home.appending(path: "s.jsonl")
        for command in ["sh ~/Projects/akit/install.sh", "cd $HOME/Projects/akit && git log", #"cat "${HOME}/Projects/akit/README.md""#] {
            try lines([call("Bash", ["command": command])], to: file)
            #expect(LeakCheck.leaks(in: file, task: replayTask, repo: URL(filePath: repo), env: env) == ["the real repository"], "\(command)")
        }
        try lines([call("Bash", ["command": "ls ~/Projects/akit-other $HOME/Projects ~/Projects/akit2"])], to: file)
        #expect(LeakCheck.leaks(in: file, task: replayTask, repo: URL(filePath: repo), env: env).isEmpty)
        // This Mac's home too, when the environment's is another.
        let real = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Projects/akit").path
        #expect(LeakCheck.repositoryPaths([real]).isSuperset(of: ["~/Projects/akit", "$HOME/Projects/akit", "${HOME}/Projects/akit"]))
    }

    /// Written text keeps its own line breaks: the hash at the start of a line is a word of its own.
    @Test func hashAtALineStartInWrittenText() throws {
        let file = home.appending(path: "s.jsonl")
        try lines([call("Bash", ["command": "git show \\\n1c9cf65"])], to: file)
        #expect(LeakCheck.commitSigns(in: file, task: replayTask, env: env) == ["the commit 1c9cf65"])
        try lines([call("Write", ["file_path": "/w/peek.sh", "content": "#!/bin/sh\ngit show \\\n\t1c9cf65aaaa\n"]),
                   call("Bash", ["command": "sh /w/peek.sh"])], to: file)
        #expect(LeakCheck.commitSigns(in: file, task: replayTask, env: env) == ["the commit 1c9cf65"])
    }

    /// Free text (a subagent's prompt, todos, a plan, a question) asks for nothing: no Lab or
    /// history sign, while the hash, the repository and the Trash in it still count.
    @Test func freeTextAsksForNothing() throws {
        let file = home.appending(path: "s.jsonl")
        let mentions = "Look in ~/.akit/lab/tasks and ~/.claude/projects"
        let freeText: [(String, [String: Any])] = [
            ("Task", ["prompt": mentions, "subagent_type": "Explore"]), ("Agent", ["prompt": mentions]),
            ("TodoWrite", ["todos": [["content": mentions, "status": "pending"]]]), ("ExitPlanMode", ["plan": mentions]),
            ("AskUserQuestion", ["questions": [["question": mentions]]]),
        ]
        for (name, input) in freeText {
            try lines([call(name, input)], to: file)
            #expect(LeakCheck.leaks(in: file, task: replayTask, repo: URL(filePath: "/r"), env: env).isEmpty, "\(name)")
        }
        try lines([call("Task", ["prompt": "Run git -C /r show 1c9cf65 and ls ~/.Trash"])], to: file)
        #expect(LeakCheck.leaks(in: file, task: replayTask, repo: URL(filePath: "/r"), env: env)
                == ["the commit 1c9cf65", "the real repository", "the Trash"])
    }

    /// An old task without `mainRepo` whose worktree is gone: its main folder is the nearest
    /// ancestor with a `.git` folder; none (below the home folder) leaves the path itself.
    @Test func goneWorktreeFindsItsMainFolder() throws {
        let main = home.appending(path: "main", directoryHint: .isDirectory)
        try fm.createDirectory(at: main.appending(path: ".git"), withIntermediateDirectories: true)
        try fm.createDirectory(at: main.appending(path: ".claude/worktrees"), withIntermediateDirectories: true)
        let resolvedMain = main.standardizedFileURL.resolvingSymlinksInPath().path
        #expect(LabGit.mainFolder(of: main.path + "/.claude/worktrees/gone").path == resolvedMain)
        #expect(LabGit.mainFolder(of: main.path + "/.claude/worktrees/gone/deeper/still").path == resolvedMain)
        let sibling = home.appending(path: "sibling-gone").standardizedFileURL.resolvingSymlinksInPath().path
        #expect(LabGit.mainFolder(of: sibling).path == sibling)
        #expect(LabGit.mainFolder(of: "/r").path == "/r")
        // An existing folder is never walked up from.
        let plain = home.appending(path: "main/Sources", directoryHint: .isDirectory)
        try fm.createDirectory(at: plain, withIntermediateDirectories: true)
        #expect(LabGit.mainFolder(of: plain.path).path == plain.standardizedFileURL.resolvingSymlinksInPath().path)
    }

    @Test func comparisonPerSetup() {
        let full = LabSetup(name: .full, model: "opus", effort: "high")
        let lean = LabSetup(name: .lean, model: "opus", effort: "high")
        func run(_ setup: LabSetup, _ index: Int, status: RunState.Status, passed: Bool = true, fresh: Int = 100,
                 leaked: Bool = false) -> LabRun {
            var metrics = SessionMetrics()
            metrics.freshTokens = fresh
            metrics.calls = fresh / 10
            metrics.wallSeconds = fresh
            let tests = TestOutcome(status: passed ? .passed : .failed, failToPass: .init(passed: passed ? 1 : 0, total: 1),
                                    passToPass: .init(passed: 1, total: 1))
            let spec = RunSpec(id: "\(setup.name)-\(index)", kind: .replay, title: "", createdAt: Date(timeIntervalSince1970: Double(index)),
                               folder: "/", environment: .background, akit: "/akit", commit: "abc", setup: setup)
            return LabRun(folder: URL(filePath: "/"), spec: spec, state: RunState(status: status), launch: nil,
                          result: status == .finished ? RunResult(metrics: metrics, tests: tests, leaks: leaked ? ["x"] : []) : nil)
        }
        let runs = [run(full, 1, status: .finished, fresh: 300), run(lean, 2, status: .finished, fresh: 100),
                    run(full, 3, status: .finished, passed: false, fresh: 500), run(lean, 4, status: .finished, fresh: 900, leaked: true),
                    run(full, 5, status: .finished, fresh: 400), run(lean, 6, status: .queued), run(lean, 7, status: .error)]
        let rows = LabComparison.compare(commit: "abc", runs: runs).rows
        #expect(rows.map(\.setup) == [full.label, lean.label])
        #expect(rows[0].runs == 3 && rows[0].passed == 2)
        #expect(rows[0].freshTokens == LabComparison.Spread([300, 500, 400]))
        #expect(rows[0].freshTokens?.median == 400 && rows[0].freshTokens?.min == 300)
        #expect(rows[1].runs == 1 && rows[1].leaked == 1 && rows[1].pending == 1 && rows[1].failed == 1)
        #expect(rows[1].freshTokens?.median == 100)
    }

    @Test func watchdogReadsProcesses() {
        let me = getpid()
        #expect(Watchdog.allProcesses().contains(me))
        #expect((Watchdog.footprint(of: me) ?? 0) > 1 << 20)
        #expect(Watchdog.workingFolder(of: me) == URL(filePath: fm.currentDirectoryPath).standardizedFileURL.resolvingSymlinksInPath().path)
    }
}
