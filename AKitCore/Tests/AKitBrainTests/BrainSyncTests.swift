import Foundation
import Testing
import AKitCommandLine
import AKitFoundation
@testable import AKitBrain

/// Two Macs' brains sharing a bare remote, all in a temporary fake home.
struct BrainSyncTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-sync-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var env: HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home, variables: [
            "HOME": home.path, "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
            "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
        ], executableSearchPaths: [URL(filePath: "/usr/bin")])
    }

    var remote: URL { home.appending(path: "remote.git") }
    var macA: URL { home.appending(path: "a/registry") }
    var macB: URL { home.appending(path: "b/registry") }

    @discardableResult
    func git(_ directory: URL, _ args: String...) async throws -> String {
        let result = try #require(await ProcessRunner.run(URL(filePath: "/usr/bin/git"), arguments: args,
                                                           directory: directory, environment: env.variables, timeout: 10))
        #expect(result.succeeded, "git \(args.joined(separator: " ")): \(result.output)")
        return result.output
    }

    func write(_ root: URL, _ path: String, _ text: String) throws {
        let url = root.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func commit(_ root: URL, _ path: String, _ text: String) async throws {
        try write(root, path, text)
        try await git(root, "add", "--all")
        try await git(root, "commit", "-qm", "Change \(path)")
    }

    func read(_ root: URL, _ path: String) -> String? {
        try? String(contentsOf: root.appending(path: path), encoding: .utf8)
    }

    /// Mac A creates the brain and pushes it; Mac B clones it.
    func setUp() async throws {
        try await BrainSetup.create(at: macA, env: env)
        try await git(home, "init", "--quiet", "--bare", "--initial-branch=main", remote.path)
        try await git(macA, "remote", "add", "origin", remote.path)
        try await git(macA, "push", "--quiet", "-u", "origin", "main")
        try fm.createDirectory(at: macB.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await git(home, "clone", "--quiet", remote.path, macB.path)
    }

    @Test func noRemoteIsReportedAndRefused() async throws {
        try await BrainSetup.create(at: macA, env: env)
        let status = try #require(await BrainSync.status(of: macA, env: env, fetch: true))
        #expect(!status.hasRemote && !status.isInSync)
        await #expect(throws: BrainSync.Failure.self) { try await BrainSync.sync(macA, env: env) }
        #expect(await BrainSync.status(of: home, env: env, fetch: false) == nil)  // not a repo
    }

    @Test func pushesFromOneMacAndPullsOnTheOther() async throws {
        try await setUp()
        try await commit(macA, "layers/core/layer.yaml", "name: core\nskills: []\n# changed\n")
        #expect(await BrainSync.status(of: macA, env: env, fetch: false)?.ahead == 1)

        let pushed = try await BrainSync.sync(macA, env: env)
        #expect(pushed.pushed == 1 && pushed.pulled == 0)
        #expect(await BrainSync.status(of: macA, env: env, fetch: false)?.isInSync == true)

        let before = try #require(await BrainSync.status(of: macB, env: env, fetch: false))
        #expect(before.behind == 0)  // not fetched yet
        #expect(await BrainSync.status(of: macB, env: env, fetch: true)?.behind == 1)

        let pulled = try await BrainSync.sync(macB, env: env)
        #expect(pulled.pulled == 1 && pulled.pushed == 0)
        #expect(pulled.pulledPaths == ["layers/core/layer.yaml"])
        #expect(pulled.changesCore(in: Brain.load(from: macB)))
        #expect(read(macB, "layers/core/layer.yaml")?.contains("# changed") == true)
    }

    @Test func pullKeepsUncommittedEditsElsewhere() async throws {
        try await setUp()
        try await commit(macA, "skills/tdd/SKILL.md", "---\nname: tdd\n---\n")
        try await BrainSync.sync(macA, env: env)
        try write(macB, "README.md", "edited by hand\n")

        let outcome = try await BrainSync.sync(macB, env: env)
        #expect(outcome.pulled == 1)
        #expect(!outcome.changesCore(in: Brain.load(from: macB)))  // tdd isn't in core
        #expect(read(macB, "skills/tdd/SKILL.md") != nil)
        #expect(read(macB, "README.md") == "edited by hand\n")
        #expect(await BrainSync.status(of: macB, env: env, fetch: false)?.changed == ["README.md"])
    }

    @Test func bothMacsCommittedPutsLocalCommitsOnTop() async throws {
        try await setUp()
        try await commit(macA, "skills/a/SKILL.md", "a\n")
        try await BrainSync.sync(macA, env: env)
        try await commit(macB, "skills/b/SKILL.md", "b\n")

        let outcome = try await BrainSync.sync(macB, env: env)
        #expect(outcome.pulled == 1 && outcome.pushed == 1)
        try await BrainSync.sync(macA, env: env)
        for mac in [macA, macB] {
            #expect(read(mac, "skills/a/SKILL.md") == "a\n" && read(mac, "skills/b/SKILL.md") == "b\n")
            #expect(await BrainSync.status(of: mac, env: env, fetch: false)?.isInSync == true)
        }
    }

    @Test func workMacRebaseCarriesTheBrainsOwnIdentityUnsigned() async throws {
        try await setUp()
        try await commit(macA, "skills/a/SKILL.md", "a\n")
        try await BrainSync.sync(macA, env: env)
        try await commit(macB, "skills/b/SKILL.md", "b\n")
        try MachineProfile(kind: .work, name: "work").save(home: home)
        // The work identity in the environment, and a global signing setting with a work key.
        try write(home, ".gitconfig", "[user]\n\tname = Work Name\n\temail = work@corp.example\n\tsigningkey = WORKKEY\n[commit]\n\tgpgsign = true\n")
        var work = env
        work.variables.merge(["GIT_COMMITTER_NAME": "Work Name", "GIT_COMMITTER_EMAIL": "work@corp.example",
                              "GIT_AUTHOR_NAME": "Work Name", "GIT_AUTHOR_EMAIL": "work@corp.example", "EMAIL": "work@corp.example"]) { $1 }

        // Without a name and email of its own the rebase would take the global ones: refused, nothing changed.
        let head = try await git(macB, "rev-parse", "HEAD")
        await #expect(throws: BrainSync.Failure.self) { try await BrainSync.sync(macB, env: work) }
        #expect(try await git(macB, "rev-parse", "HEAD") == head)
        try await git(macB, "config", "--local", "user.email", "me@example.com")
        await #expect(throws: BrainSync.Failure.self) { try await BrainSync.sync(macB, env: work) }
        try await git(macB, "config", "--local", "user.name", "Me")

        let outcome = try await BrainSync.sync(macB, env: work)
        #expect(outcome.pulled == 1 && outcome.pushed == 1)
        #expect(try await git(macB, "log", "-1", "--format=%an <%ae>|%cn <%ce>") == "Test <test@example.com>|Me <me@example.com>\n")
        #expect(!(try await git(macB, "cat-file", "-p", "HEAD").contains("gpgsig")))
    }

    @Test func conflictIsUndoneAndReported() async throws {
        try await setUp()
        try await commit(macA, "README.md", "from A\n")
        try await BrainSync.sync(macA, env: env)
        try await commit(macB, "README.md", "from B\n")
        let head = try await git(macB, "rev-parse", "HEAD")

        await #expect {
            try await BrainSync.sync(macB, env: env)
        } throws: { error in
            (error as? BrainSync.Failure)?.message.contains("README.md") == true
        }
        #expect(try await git(macB, "rev-parse", "HEAD") == head)
        #expect(read(macB, "README.md") == "from B\n")
        #expect(!fm.fileExists(atPath: macB.appending(path: ".git/rebase-merge").path))
    }

    @Test func divergedWithUncommittedEditsIsRefused() async throws {
        try await setUp()
        try await commit(macA, "skills/a/SKILL.md", "a\n")
        try await BrainSync.sync(macA, env: env)
        try await commit(macB, "skills/b/SKILL.md", "b\n")
        try write(macB, "README.md", "edited by hand\n")

        await #expect(throws: BrainSync.Failure.self) { try await BrainSync.sync(macB, env: env) }
        #expect(read(macB, "README.md") == "edited by hand\n")
        #expect(read(macB, "skills/a/SKILL.md") == nil)
    }

    @Test func pushesToAnUpstreamWithAnotherName() async throws {
        try await setUp()
        try await git(macB, "branch", "--quiet", "-m", "main", "master")
        try await git(macB, "branch", "--quiet", "--set-upstream-to=origin/main")
        try await commit(macB, "skills/b/SKILL.md", "b\n")

        #expect(try await BrainSync.sync(macB, env: env).pushed == 1)
        #expect(try await BrainSync.sync(macA, env: env).pulled == 1)
        #expect(read(macA, "skills/b/SKILL.md") == "b\n")
    }

    @Test func halfDoneGitStateBlocksSync() async throws {
        try await setUp()
        try await git(macB, "checkout", "--quiet", "--detach")
        let detached = try #require(await BrainSync.status(of: macB, env: env, fetch: false))
        #expect(detached.problem?.contains("detached") == true)
        await #expect(throws: BrainSync.Failure.self) { try await BrainSync.sync(macB, env: env) }

        try await git(macB, "checkout", "--quiet", "main")
        try fm.createDirectory(at: macB.appending(path: ".git/rebase-merge"), withIntermediateDirectories: true)
        #expect(await BrainSync.status(of: macB, env: env, fetch: false)?.problem?.contains("rebase") == true)
    }

    @Test func changedPathsHandleSpacesAndRenames() async throws {
        try await setUp()
        try write(macB, "skills/my skill/SKILL.md", "x\n")
        try await git(macB, "mv", "README.md", "READ ME.md")
        let changed = try #require(await BrainSync.status(of: macB, env: env, fetch: false)?.changed)
        #expect(Set(changed) == ["READ ME.md", "skills/my skill/"])
    }

    @Test func cliSyncReportsWhatHappened() async throws {
        try await setUp()
        try await commit(macA, "layers/core/layer.yaml", "name: core\nskills: []\n# changed\n")

        func akit(_ root: URL) async -> (code: Int32, out: String) {
            var out: [String] = []
            let code = await AKitCLI.run(["sync", "--brain", root.path], env: env, cwd: home,
                                         out: { out.append($0) }, err: { out.append($0) }, hardwareHash: { "test-hardware" })
            return (code, out.joined(separator: "\n"))
        }
        #expect(await akit(macA) == (0, "Pushed 1 commit."))
        let pulled = await akit(macB)
        #expect(pulled.code == 0 && pulled.out.contains("Pulled 1 commit.") && pulled.out.contains("akit apply --home"))
        #expect(await akit(macB) == (0, "The brain is in sync with its remote."))
    }
}
