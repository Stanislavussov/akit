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
