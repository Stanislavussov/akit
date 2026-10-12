import Foundation
import Testing
import AKitFoundation
@testable import AKitBrain

/// The brain's own git name and email, in a temporary fake home whose global identity is the work one.
struct BrainGitTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-brain-git-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try Data("[user]\n\tname = Work Name\n\temail = work@corp.example\n".utf8).write(to: home.appending(path: ".gitconfig"))
    }

    var env: HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home, variables: [
            "HOME": home.path, "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Work Name", "GIT_AUTHOR_EMAIL": "work@corp.example",
            "GIT_COMMITTER_NAME": "Work Name", "GIT_COMMITTER_EMAIL": "work@corp.example",
        ], executableSearchPaths: [URL(filePath: "/usr/bin")])
    }

    var root: URL { Brain.defaultRoot(home: home) }

    @discardableResult
    func git(_ args: String...) async throws -> String {
        let result = try #require(await ProcessRunner.run(URL(filePath: "/usr/bin/git"), arguments: args,
                                                           directory: root, environment: env.variables, timeout: 10))
        #expect(result.succeeded, "git \(args.joined(separator: " ")): \(result.output)")
        return result.output
    }

    @Test func aNewBrainHasNoIdentityOfItsOwnAndTheGlobalOneIsNotOffered() async throws {
        try await BrainSetup.create(at: root, env: env)
        #expect(await BrainGit.ownIdentity(brain: root, env: env) == BrainGit.Identity())
        // An empty value counts as none.
        try await git("config", "--local", "user.email", "")
        #expect(await BrainGit.ownIdentity(brain: root, env: env)?.email == nil)
    }

    @Test func aFolderThatIsNotARepoHasNoIdentity() async throws {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(await BrainGit.ownIdentity(brain: root, env: env) == nil)
        await #expect(throws: BrainGit.Failure.self) {
            try await BrainGit.setOwnIdentity(name: "Me", email: "me@example.com", brain: root, env: env)
        }
        #expect(!fm.fileExists(atPath: root.appending(path: ".git").path))
    }

    @Test func settingTheIdentityWritesOnlyTheBrainsConfigAndLetsAWorkMacCommit() async throws {
        try await BrainSetup.create(at: root, env: env)
        try MachineProfile(kind: .work, name: "work").save(home: home)
        let head = try await git("rev-parse", "HEAD")
        let global = try String(contentsOf: home.appending(path: ".gitconfig"), encoding: .utf8)

        // The refusal says where to set it.
        let problem = try #require(await BrainGit.commitProblem(brain: root, env: env))
        #expect(problem.contains("Settings") && problem.contains("config user.email") && !problem.contains("()"), "\(problem)")

        let saved = try await BrainGit.setOwnIdentity(name: "  Me Myself ", email: " me@example.com\n", brain: root, env: env)
        #expect(saved == BrainGit.Identity(name: "Me Myself", email: "me@example.com"))
        #expect(saved.isComplete)
        #expect(await BrainGit.ownIdentity(brain: root, env: env) == saved)
        #expect(try await git("config", "--local", "--get", "user.name") == "Me Myself\n")
        #expect(await BrainGit.commitProblem(brain: root, env: env) == nil)
        // Nothing committed, nothing changed in the working tree, and the global config is as it was.
        #expect(try await git("rev-parse", "HEAD") == head)
        #expect(try await git("status", "--porcelain") == "")
        #expect(try String(contentsOf: home.appending(path: ".gitconfig"), encoding: .utf8) == global)
    }

    @Test func aKeySetTwiceIsReplacedByTheOneSaved() async throws {
        try await BrainSetup.create(at: root, env: env)
        try await git("config", "--local", "--add", "user.email", "old@example.com")
        try await git("config", "--local", "--add", "user.email", "older@example.com")
        try await BrainGit.setOwnIdentity(name: "Me", email: "me@example.com", brain: root, env: env)
        #expect(try await git("config", "--local", "--get-all", "user.email") == "me@example.com\n")
    }

    @Test func aBadNameOrEmailIsRefusedAndNothingIsWritten() async throws {
        try await BrainSetup.create(at: root, env: env)
        for (name, email) in [("", "me@example.com"), ("Me", ""), ("Me", "not-an-email"), ("Me", "me @example.com"), ("Me\nToo", "me@example.com")] {
            await #expect(throws: BrainGit.Failure.self, "\(name)|\(email)") {
                try await BrainGit.setOwnIdentity(name: name, email: email, brain: root, env: env)
            }
        }
        #expect(await BrainGit.ownIdentity(brain: root, env: env) == BrainGit.Identity())
    }
}
