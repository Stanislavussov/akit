import Foundation
import Testing
import AKitBrain
@testable import AKitInsights
@testable import AKitFoundation

/// `ProjectRecords.projectID(ofFolder:projectsRoot:)` (skill modes) gives a folder the same id
/// `LiveFolderResolver` gives a session there. Real git repositories in a temporary fake home.
struct FolderProjectIDTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-folder-id-\(UUID().uuidString)")
        try fm.createDirectory(at: home.appending(path: "Projects"), withIntermediateDirectories: true)
    }

    var env: HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home, variables: [
            "HOME": home.path, "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
            "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
        ], executableSearchPaths: [URL(filePath: "/usr/bin")])
    }

    var root: String { BindingPaths.canonical(home.appending(path: "Projects").path) }

    func git(_ arguments: String..., in folder: URL) async throws {
        let git = try #require(env.findExecutable("git"))
        let result = try #require(await ProcessRunner.run(git, arguments: arguments, directory: folder,
                                                          environment: env.variables.merging(["PATH": env.pathForChildProcesses]) { $1 },
                                                          timeout: 30))
        #expect(result.succeeded, "git \(arguments): \(result.output)")
    }

    func repository(at folder: URL, remote: String? = nil) async throws {
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try await git("init", "-q", "-b", "main", in: folder)
        try await git("commit", "-q", "--allow-empty", "-m", "start", in: folder)
        if let remote { try await git("remote", "add", "origin", remote, in: folder) }
    }

    /// Both ids for a folder; the resolver's is nil when it finds no repository.
    func ids(_ folder: URL) -> (folder: String?, live: String?) {
        (ProjectRecords.projectID(ofFolder: folder, projectsRoot: root), LiveFolderResolver(projectsRoot: root).repository(for: folder.path)?.projectID)
    }

    @Test func aMainCheckoutAndItsLinkedWorktreeShareTheRemoteID() async throws {
        let app = home.appending(path: "Projects/app")
        try await repository(at: app, remote: "git@gitlab.example.com:team/app.git")
        try fm.createDirectory(at: app.appending(path: "Sources/Deep"), withIntermediateDirectories: true)
        let tree = home.appending(path: "trees/app-feature")
        try await git("worktree", "add", "-q", "-b", "feature", tree.path, in: app)
        for folder in [app, app.appending(path: "Sources/Deep"), tree] {
            let found = ids(folder)
            #expect(found.folder == "gitlab.example.com/team/app", "\(folder.path)")
            #expect(found.folder == found.live, "\(folder.path)")
        }
    }

    @Test func withoutOriginEveryWorktreeGetsTheMainCheckoutsLocalID() async throws {
        let tool = home.appending(path: "Projects/group/tool")
        try await repository(at: tool)
        let tree = home.appending(path: "elsewhere/tool-fix")
        try await git("worktree", "add", "-q", "-b", "fix", tree.path, in: tool)
        for folder in [tool, tree] {
            let found = ids(folder)
            #expect(found.folder == "local/group/tool", "\(folder.path)")
            #expect(found.folder == found.live, "\(folder.path)")
        }
    }

    @Test func privateTmpAndTmpAreOneFolder() async throws {
        let name = "akit-folder-id-\(UUID().uuidString)"
        let real = URL(filePath: "/private/tmp/\(name)/repo", directoryHint: .isDirectory)
        defer { try? fm.removeItem(atPath: "/private/tmp/\(name)") }
        try await repository(at: real)
        let viaTmp = URL(filePath: "/tmp/\(name)/repo", directoryHint: .isDirectory)
        let first = ids(real), second = ids(viaTmp)
        #expect(first.folder != nil)
        #expect(first.folder == second.folder)
        #expect(first.folder == first.live && second.folder == second.live)
    }

    @Test func aConfigOver64KBStillGivesTheRemoteID() async throws {
        let big = home.appending(path: "Projects/big")
        try await repository(at: big)
        let config = big.appending(path: ".git/config")
        let padding = String(repeating: "# a long comment line to make the config large\n", count: 1_600)  // ≈ 77 KB
        try Data((padding + (try String(contentsOf: config, encoding: .utf8)) + "[remote \"origin\"]\n\turl = https://example.com/team/big.git\n").utf8)
            .write(to: config)
        let found = ids(big)
        #expect(found.folder == "example.com/team/big")
        #expect(found.folder == found.live)
    }

    @Test func aLinkedDotGitIsFollowed() async throws {
        let real = home.appending(path: "store/real")
        try await repository(at: real, remote: "git@example.com:team/linked.git")
        let checkout = home.appending(path: "Projects/linked")
        try fm.createDirectory(at: checkout, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: checkout.appending(path: ".git"), withDestinationURL: real.appending(path: ".git"))
        let found = ids(checkout)
        #expect(found.folder == "example.com/team/linked")
        #expect(found.folder == found.live)
        // Without origin: the id of the folder holding the link, the same in both.
        try await git("remote", "remove", "origin", in: real)
        let local = ids(checkout)
        #expect(local.folder == "local/linked" && local.folder == local.live)
    }

    @Test func aFolderOutsideGitHasNoProject() throws {
        let plain = home.appending(path: "Projects/plain")
        try fm.createDirectory(at: plain, withIntermediateDirectories: true)
        #expect(ProjectRecords.projectID(ofFolder: plain, projectsRoot: root) == nil)
    }
}
