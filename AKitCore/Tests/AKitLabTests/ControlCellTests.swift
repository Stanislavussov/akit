import Foundation
import Testing
import AKitFoundation
@testable import AKitLab

/// The Lab side of a control cell: the patch, the test-file guard and the test command.
struct ControlCellTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-controlcell-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var env: HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home, variables: [
            "HOME": home.path, "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "T", "GIT_AUTHOR_EMAIL": "t@example.com",
            "GIT_COMMITTER_NAME": "T", "GIT_COMMITTER_EMAIL": "t@example.com",
        ], executableSearchPaths: [URL(filePath: "/usr/bin"), URL(filePath: "/bin")])
    }

    func git(_ args: String..., in folder: URL) async -> String? { await LabGit.output(args, in: folder, env: env) }

    func write(_ path: String, _ text: String, in folder: URL) throws {
        let url = folder.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func read(_ path: String, in folder: URL) -> String? { try? String(contentsOf: folder.appending(path: path), encoding: .utf8) }

    @Test func patchChangesOnlyTheClone() async throws {
        let repo = home.appending(path: "repo")
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        _ = await git("init", "-q", "-b", "master", in: repo)
        try write("CLAUDE.md", "# Rules\n- Be brief.", in: repo)
        _ = await git("add", "-A", in: repo)
        _ = await git("commit", "-q", "-m", "Start", in: repo)
        let base = try #require(await git("rev-parse", "HEAD", in: repo))

        let work = home.appending(path: "work")
        try await IsolatedClone.make(at: work, from: repo, commit: base, env: env)
        try await ControlPatch(file: "CLAUDE.md", text: "- Run the tests before saying done.").apply(in: work, env: env)
        try await ControlPatch(file: ".claude/skills/check/SKILL.md", text: "# Check\n").apply(in: work, env: env)

        #expect(read("CLAUDE.md", in: work) == "# Rules\n- Be brief.\n\n- Run the tests before saying done.\n")
        #expect(read(".claude/skills/check/SKILL.md", in: work) == "# Check\n")
        // The clone looks clean to the agent, as the baseline's does.
        #expect(await git("status", "--porcelain", in: work) == "")
        // The user's repository is untouched.
        #expect(read("CLAUDE.md", in: repo) == "# Rules\n- Be brief.")
        #expect(!fm.fileExists(atPath: repo.appending(path: ".claude").path))
        #expect(await git("status", "--porcelain", in: repo) == "")
        #expect(await git("rev-parse", "HEAD", in: repo) == base)

        for path in ["../outside.md", "/tmp/x.md", "~/CLAUDE.md", ".git/config", "a/../../b"] {
            #expect(throws: LabWorker.Failure.self) { try ControlPatch(file: path, text: "x").target(in: work) }
        }
    }

    @Test func guardSeesDroppedAndChangedTests() throws {
        let folder = home.appending(path: "guarded")
        try write("Tests/ValueTests.swift", "@Test func one() {}\n@Test func two() {}\nfunc testOld() {}\n", in: folder)
        try write("web/app.test.js", "it('works', () => {})\ntest('more', () => {})\n", in: folder)
        try write("py/test_value.py", "def test_value():\n    pass\n", in: folder)
        try write("Sources/Value.swift", "@Test func notATestFile() {}\n", in: folder)
        try write("node_modules/x/Tests/a.swift", "@Test func dependency() {}\n", in: folder)
        try write(".build/Tests/b.swift", "@Test func built() {}\n", in: folder)

        let before = TestFiles.state(of: folder)
        #expect(Set(before.hashes.keys) == ["Tests/ValueTests.swift", "web/app.test.js", "py/test_value.py"])
        #expect(before.markers == 6)

        // A new test file is fine; it changes nothing that existed.
        try write("Tests/MoreTests.swift", "@Test func three() {}\n", in: folder)
        let added = TestFiles.state(of: folder)
        #expect(added.markers == 7 && before.hashes.allSatisfy { added.hashes[$0.key] == $0.value })

        try write("Tests/ValueTests.swift", "@Test func one() {}\n", in: folder)
        try fm.removeItem(at: folder.appending(path: "py/test_value.py"))
        let after = TestFiles.state(of: folder)
        #expect(after.markers == 4)
        #expect(before.hashes.filter { after.hashes[$0.key] != $0.value }.map(\.key).sorted() == ["Tests/ValueTests.swift", "py/test_value.py"])
    }

    @Test func testCommandPassesOnExitZeroOnly() async throws {
        let folder = home.appending(path: "tests")
        try write("value.txt", "2\n", in: folder)
        let log = home.appending(path: "check.log")
        let passed = await ControlCell.runTests(#"test "$(cat value.txt)" = 2 && echo ok"#, in: folder, limit: 30, log: log, env: env) { _ in }
        #expect(passed == ControlCell.TestCommand(passed: true, detail: "tests passed (exit 0)"))
        #expect(read("check.log", in: home)?.contains("ok") == true)
        let failed = await ControlCell.runTests("exit 3", in: folder, limit: 30, log: log, env: env) { _ in }
        #expect(failed == ControlCell.TestCommand(passed: false, detail: "tests failed (exit 3)"))
        let slow = await ControlCell.runTests("sleep 10", in: folder, limit: 1, log: log, env: env) { _ in }
        #expect(!slow.passed && slow.detail.hasPrefix("tests timed out"))
    }

    @Test func setupsAndOutcomes() throws {
        let agent = LabAgent(harness: .claudeCode, model: "opus", effort: "high")
        let variant = ControlSetup(name: "variant", agent: agent, patch: ControlPatch(file: "CLAUDE.md", text: "x"))
        #expect(variant.label == "variant · Claude Code · opus · high · + CLAUDE.md" && variant.tools.isEmpty)
        #expect(ControlSetup(name: "broken", agent: agent, readOnly: true).tools == ["--tools", "Read,Grep,Glob"])
        let pi = LabAgent(harness: .pi, model: "p/m", effort: "low")
        #expect(ControlSetup(name: "b", agent: pi).tools == ["--tools", "read,write,edit,bash,grep,find,ls"])
        #expect(ControlSetup(name: "b", agent: pi, readOnly: true).tools == ["--tools", "read,grep,find,ls"])

        // Results written before control runs still decode.
        let old = try LabStore.decoder.decode(RunResult.self, from: Data(#"{"schema":1,"leaks":[]}"#.utf8))
        #expect(old.control == nil)
        let flagged = ControlOutcome(key: "k", passed: true, oracle: "tests passed (exit 0)", changedTestFiles: ["Tests/A.swift"])
        #expect(flagged.flagged && LabWorker.resultLines(RunResult(control: flagged)).contains { $0.contains("isn't trusted") })
        #expect(!ControlOutcome(key: "k", passed: false, oracle: "x").flagged)
    }
}
