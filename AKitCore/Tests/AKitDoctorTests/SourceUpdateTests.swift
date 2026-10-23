import Foundation
import Testing
import AKitFoundation
@testable import AKitDoctor

/// The app's Update button: new commits on the build's branch in a temporary source folder.
struct SourceUpdateTests {
    let home: URL
    let source: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-update-\(UUID().uuidString)")
        source = home.appending(path: "Projects/akit")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
    }

    var env: HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home, variables: [
            "HOME": home.path, "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
            "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
        ], executableSearchPaths: [URL(filePath: "/usr/bin")])
    }

    @discardableResult
    func git(_ arguments: String...) async throws -> String {
        let result = try #require(await ProcessRunner.run(URL(filePath: "/usr/bin/git"), arguments: ["-C", source.path] + arguments,
                                                          environment: env.gitVariables, timeout: 30))
        #expect(result.succeeded, "git \(arguments.joined(separator: " ")): \(result.output)")
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func commit(_ message: String) async throws -> String {
        try Data(message.utf8).write(to: source.appending(path: "README.md"))
        try await git("add", "README.md")
        try await git("commit", "-q", "-m", message)
        return try await git("rev-parse", "--short", "HEAD")
    }

    func setUp() async throws -> String {
        try await git("init", "-q", "-b", "master")
        let first = try await commit("First")
        try await git("tag", "-a", "v2026.10.16", "-m", "First feature")
        return first
    }

    @Test func noNewCommitsIsUpToDate() async throws {
        let built = try await setUp()
        #expect(await SourceUpdate.check(source: source, branch: "master", commit: built, env: env) == .upToDate)
    }

    @Test func newCommitsOnTheBranchAreAnUpdate() async throws {
        let built = try await setUp()
        _ = try await commit("Add the update button")
        let head = try await commit("Merge branch 'self-update'")
        try await git("tag", "-a", "v2026.10.17", "HEAD~1", "-m", "Update button")
        guard case .available(let update) = await SourceUpdate.check(source: source, branch: "master", commit: built, env: env) else {
            Issue.record("no update found")
            return
        }
        #expect(update.commits == 2)
        #expect(update.subjects == ["Merge branch 'self-update'", "Add the update button"])
        #expect(update.head == head)
        #expect(update.version == "2026.10.17 + 1")
        #expect(!update.hasUncommittedChanges)
    }

    @Test func uncommittedChangesAreReported() async throws {
        let built = try await setUp()
        _ = try await commit("Second")
        try Data("work in progress".utf8).write(to: source.appending(path: "README.md"))
        guard case .available(let update) = await SourceUpdate.check(source: source, branch: "master", commit: built, env: env) else {
            Issue.record("no update found")
            return
        }
        #expect(update.hasUncommittedChanges)
        #expect(update.version == "2026.10.16 + 1")
    }

    @Test func anotherBranchCheckedOutIsNoUpdate() async throws {
        let built = try await setUp()
        try await git("switch", "-q", "-c", "feature")
        _ = try await commit("Feature work")
        #expect(await SourceUpdate.check(source: source, branch: "master", commit: built, env: env) == .otherBranch("feature"))
    }

    @Test func unknownCommitOrFolder() async throws {
        _ = try await setUp()
        guard case .unknown = await SourceUpdate.check(source: source, branch: "master", commit: "0123456", env: env) else {
            Issue.record("a missing commit must not count as an update")
            return
        }
        guard case .unknown = await SourceUpdate.check(source: home, branch: "master", commit: "0123456", env: env) else {
            Issue.record("a folder without git must not count as an update")
            return
        }
    }
}

/// A release pushed from another Mac: the check fetches the upstream branch; Update pulls it.
struct SourceUpdateOriginTests {
    let base = FileManager.default.temporaryDirectory.appending(path: "akit-origin-\(UUID().uuidString)")
    var origin: URL { base.appending(path: "origin.git") }
    var other: URL { base.appending(path: "other") }
    var source: URL { base.appending(path: "Projects/akit") }

    var env: HarnessEnvironment {
        HarnessEnvironment(homeDirectory: base, variables: [
            "HOME": base.path, "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
            "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
        ], executableSearchPaths: [URL(filePath: "/usr/bin")])
    }

    @discardableResult
    func git(_ folder: URL, _ arguments: String...) async throws -> String {
        let result = try #require(await ProcessRunner.run(URL(filePath: "/usr/bin/git"), arguments: ["-C", folder.path] + arguments,
                                                          environment: env.gitVariables, timeout: 30))
        #expect(result.succeeded, "git \(arguments.joined(separator: " ")): \(result.output)")
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func commit(_ folder: URL, _ message: String, file: String = "README.md") async throws {
        try Data(message.utf8).write(to: folder.appending(path: file))
        try await git(folder, "add", file)
        try await git(folder, "commit", "-q", "-m", message)
    }

    /// origin with one release; this Mac's clone built at it; another Mac's clone that pushes.
    func setUp() async throws -> String {
        try FileManager.default.createDirectory(at: base.appending(path: "Projects"), withIntermediateDirectories: true)
        try await git(base, "init", "-q", "--bare", "-b", "master", origin.path)
        try await git(base, "clone", "-q", origin.path, other.path)
        try await commit(other, "First")
        try await git(other, "tag", "-a", "v2026.10.17", "-m", "Update button")
        try await git(other, "push", "-q", "origin", "master", "--tags")
        try await git(base, "clone", "-q", origin.path, source.path)
        return try await git(source, "rev-parse", "--short", "HEAD")
    }

    @Test func aReleasePushedElsewhereIsAnUpdate() async throws {
        let built = try await setUp()
        #expect(await SourceUpdate.check(source: source, branch: "master", commit: built, env: env, fetch: true) == .upToDate)
        try await commit(other, "Review practices")
        try await git(other, "tag", "-a", "v2026.10.23", "-m", "Review")
        try await git(other, "push", "-q", "origin", "master", "--tags")
        #expect(await SourceUpdate.check(source: source, branch: "master", commit: built, env: env) == .upToDate, "without fetch: the folder only")
        guard case .available(let update) = await SourceUpdate.check(source: source, branch: "master", commit: built, env: env, fetch: true) else {
            Issue.record("no update found")
            return
        }
        #expect(update.needsPull && update.upstream == "origin/master" && update.version == "2026.10.23" && update.subjects == ["Review practices"])
        #expect(try await git(source, "rev-parse", "--short", "HEAD") == built, "the check never changes the folder")
        #expect(await SourceUpdate.pull(source: source, env: env) == nil)
        #expect(try await git(source, "log", "-1", "--format=%s") == "Review practices")
    }

    @Test func aFolderWithoutUpstreamOnlyLooksAtItself() async throws {
        let built = try await setUp()
        try await git(source, "branch", "--unset-upstream")
        try await commit(other, "Pushed elsewhere")
        try await git(other, "push", "-q", "origin", "master")
        #expect(await SourceUpdate.check(source: source, branch: "master", commit: built, env: env, fetch: true) == .upToDate)
    }

    @Test func theUsersOwnSSHCommandStays() {
        var plain = env
        plain.variables["GIT_SSH_COMMAND"] = nil
        #expect(SourceUpdate.networkVariables(plain)["GIT_SSH_COMMAND"] == "ssh -o BatchMode=yes")
        #expect(SourceUpdate.networkVariables(plain, sshCommand: "ssh -i ~/.ssh/work")["GIT_SSH_COMMAND"] == "ssh -i ~/.ssh/work -o BatchMode=yes")
        var own = env
        own.variables["GIT_SSH_COMMAND"] = "ssh -J jump"
        #expect(SourceUpdate.networkVariables(own)["GIT_SSH_COMMAND"] == "ssh -J jump -o BatchMode=yes")
        var wrapper = env
        wrapper.variables["GIT_SSH"] = "/usr/local/bin/my-ssh"
        #expect(SourceUpdate.networkVariables(wrapper)["GIT_SSH_COMMAND"] == nil)
        #expect(SourceUpdate.networkVariables(plain)["GIT_TERMINAL_PROMPT"] == "0")
    }

    @Test func aFolderWithItsOwnCommitsIsNeverPulled() async throws {
        let built = try await setUp()
        try await commit(other, "Pushed elsewhere")
        try await git(other, "push", "-q", "origin", "master")
        try await commit(source, "Local work", file: "LOCAL.md")
        guard case .available(let update) = await SourceUpdate.check(source: source, branch: "master", commit: built, env: env, fetch: true) else {
            Issue.record("the local commit is an update of its own")
            return
        }
        #expect(!update.needsPull && update.subjects == ["Local work"], "diverged: the folder's own commit, no pull")
        #expect(update.upstreamAhead == 1, "and origin's release is named, to merge by hand")
        #expect(await SourceUpdate.pull(source: source, env: env) != nil, "a pull that isn't a fast-forward fails")
    }
}
