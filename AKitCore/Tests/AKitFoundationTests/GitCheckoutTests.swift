import Foundation
import Testing
@testable import AKitFoundation

/// Reading git's own files without running git: the origin URL, the remote names, the `.git`
/// pointer of a worktree. Folders in a temporary directory.
final class GitCheckoutTests {
    let root: URL
    let fm = FileManager.default

    init() throws {
        root = fm.temporaryDirectory.appending(path: "akit-gitcheckout-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func write(_ path: String, _ text: String) throws {
        let url = root.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    static let config = """
        [core]
        \tbare = false
        [remote "upstream"]
        \turl = git@example.com:them/app.git
        [remote "origin"]
        \tfetch = +refs/heads/*:refs/remotes/origin/*
        \tURL = "https://example.com/me/app.git"
        [branch "main"]
        \tremote = origin
        """

    @Test func theOriginAndTheRemoteNamesComeFromTheConfigText() {
        #expect(GitCheckout.originURL(inConfig: Self.config) == "https://example.com/me/app.git")
        #expect(GitCheckout.originURL(inConfig: "[remote \"upstream\"]\n\turl = x\n") == nil)
        #expect(GitCheckout.remoteNames(inConfig: Self.config) == ["upstream", "origin"])
        #expect(GitCheckout.remoteNames(inConfig: "[core]\n\tbare = false\n") == [])
        // An include may add remotes: the caller asks git.
        #expect(GitCheckout.remoteNames(inConfig: Self.config + "\n[include]\n\tpath = more.conf\n") == nil)
        #expect(GitCheckout.remoteNames(inConfig: "[includeIf \"gitdir:~/work/\"]\n\tpath = work.conf\n") == nil)
        #expect(GitCheckout.gitdirPointer("gitdir: ../.git/worktrees/b\n") == "../.git/worktrees/b")
        #expect(GitCheckout.gitdirPointer("gitdir:   \n") == nil && GitCheckout.gitdirPointer("nothing") == nil)
    }

    @Test func aWorktreeReadsItsMainCheckoutsOrigin() throws {
        try write("main/.git/config", Self.config)
        try write("main/.git/worktrees/b/commondir", "../..\n")
        try write("b/.git", "gitdir: ../main/.git/worktrees/b\n")
        #expect(GitCheckout.originURL(of: root.appending(path: "main")) == "https://example.com/me/app.git")
        #expect(GitCheckout.originURL(of: root.appending(path: "b")) == "https://example.com/me/app.git")
        #expect(GitCheckout.originURL(of: root) == nil)
    }
}
