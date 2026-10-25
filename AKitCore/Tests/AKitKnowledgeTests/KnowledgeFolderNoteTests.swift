import Foundation
import Testing
import AKitFoundation
@testable import AKitKnowledge

/// K27: notes for folders on this Mac (another repository, a local wiki), where a note's system
/// is on this Mac (`KnowledgeLocal`), and lint of `path:`.
final class KnowledgeFolderNoteTests {
    deinit { try? FileManager.default.removeItem(at: home) }

    let home: URL
    let fm = FileManager.default

    init() throws { home = try FakeHome.make("akit-kb-folder") }

    var env: HarnessEnvironment { FakeHome.env(home) }

    func folder(_ path: String) throws -> URL {
        let url = home.appending(path: path, directoryHint: .isDirectory)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func write(_ url: URL, _ text: String) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test func aRepositoryGetsItsRemoteWithoutCredentialsAndTheReadmeLine() async throws {
        let repo = try folder("Projects/shop-api")
        _ = try await FakeHome.git(["init", "-q"], in: repo, env: env)
        _ = try await FakeHome.git(["remote", "add", "origin", "https://bob:ghp_secret1234567890@github.com/shop/api.git"], in: repo, env: env)
        try write(repo.appending(path: "README.md"), "# shop-api\n\n[![ci](https://x/badge.svg)](https://x)\n\n```\nmake run\n```\nOrders and payments API. Runs on Fly.\n")
        let plan = try KnowledgeFolderNote.plan(folder: repo, area: "shop", home: home)
        #expect(plan.note == "shop/shop-api")
        #expect(plan.kind == "service")
        #expect(plan.repo == "https://github.com/shop/api.git")
        #expect(plan.path == "~/Projects/shop-api")
        #expect(plan.text == "---\nkind: service\nrepo: https://github.com/shop/api.git\npath: ~/Projects/shop-api\n---\n# shop-api\n\nOrders and payments API.\n")
    }

    @Test func aFolderWithoutGitIsAFolderNoteAndTheDescriptionIsTheCallers() throws {
        let wiki = try folder("Documents/team wiki")
        try write(wiki.appending(path: "index.md"), "How we deploy.\n")
        let plain = try KnowledgeFolderNote.plan(folder: wiki, area: "shop", name: "wiki", home: home)
        #expect(plain.kind == "folder" && plain.repo == nil)
        #expect(plain.text == "---\nkind: folder\npath: ~/Documents/team wiki\n---\n# wiki\n\nHow we deploy.\n")
        #expect(try KnowledgeFolderNote.plan(folder: wiki, area: "shop", description: "", home: home).description == nil)
        #expect(try KnowledgeFolderNote.plan(folder: wiki, area: "shop", description: " Our runbooks. ", home: home).description == "Our runbooks.")
        // A README line with a token stays out of the base.
        try write(wiki.appending(path: "index.md"), "token ghp_abcdefghijklmnopqrstuvwxyz0123456789\n")
        #expect(try KnowledgeFolderNote.plan(folder: wiki, area: "shop", home: home).description == nil)
    }

    @Test func valuesThatYAMLWouldMisreadAreQuoted() {
        #expect(KnowledgeFolderNote.yaml("~/Projects/a") == "~/Projects/a")
        #expect(KnowledgeFolderNote.yaml("git@github.com:a/b.git") == "git@github.com:a/b.git")
        #expect(KnowledgeFolderNote.yaml("~/a: b") == "\"~/a: b\"")
        #expect(KnowledgeFolderNote.yaml("~/a #b") == "\"~/a #b\"")
        #expect(KnowledgeFolderNote.withoutCredentials("git@github.com:a/b.git") == "git@github.com:a/b.git")
        #expect(KnowledgeFolderNote.withoutCredentials("https://github.com/a/b.git") == "https://github.com/a/b.git")
        // A token in the query, a password holding "/" or "@": cut. An ssh user stays.
        #expect(KnowledgeFolderNote.withoutCredentials("https://gitlab.example.com/x.git?private_token=abc") == "https://gitlab.example.com/x.git")
        #expect(KnowledgeFolderNote.withoutCredentials("https://u:ab/c@d@host/x.git") == "https://host/x.git")
        #expect(KnowledgeFolderNote.withoutCredentials("ssh://git@github.com/org/x.git") == "ssh://git@github.com/org/x.git")
    }

    @Test func theReadmeLineSkipsFrontmatterCommentsAndLists() throws {
        let wiki = try folder("wiki")
        try write(wiki.appending(path: "index.md"), "---\ntags: [home]\n---\n<!--\nhidden\n-->\n- a list\nThe team wiki.\n")
        #expect(KnowledgeFolderNote.readmeLine(in: wiki) == "The team wiki.")
    }

    @Test func aFolderInsideARepositoryIsAServiceOfThatRepository() async throws {
        let mono = try folder("Projects/mono"), api = try folder("Projects/mono/packages/api")
        _ = try await FakeHome.git(["init", "-q"], in: mono, env: env)
        _ = try await FakeHome.git(["remote", "add", "origin", "git@example.com:shop/mono.git"], in: mono, env: env)
        let plan = try KnowledgeFolderNote.plan(folder: api, area: "shop", home: home)
        #expect(plan.kind == "service" && plan.repo == "git@example.com:shop/mono.git" && plan.path == "~/Projects/mono/packages/api")
        // Lint: the clone at path: is known wherever it lies, and files: are relative to its top.
        try write(mono.appending(path: "src/a.ts"), "")
        let base = KnowledgeBase(root: try folder("kb"))
        try write(base.noteFile("shop/api"), "---\nkind: service\nrepo: git@example.com:shop/mono.git\npath: ~/Projects/mono/packages/api\nfiles: [src/a.ts]\n---\n# api\n")
        #expect(KnowledgeLint.run(base, projects: KnowledgeLint.Projects(), home: home).isEmpty)
    }

    @Test func theBaseRefusesItselfAnExistingNoteAndWhatIsNoFolder() throws {
        let base = KnowledgeBase(root: try folder("kb"))
        try write(base.noteFile("shop/wiki"), "# wiki\n")
        let wiki = try folder("wiki")
        #expect(throws: KnowledgeBase.Failure.self) { try base.plan(folder: base.root, area: "shop", home: self.home) }
        #expect(throws: KnowledgeBase.Failure.self) { try base.plan(folder: base.root.appending(path: "areas"), area: "shop", home: self.home) }
        #expect(throws: KnowledgeBase.Failure.self) { try base.plan(folder: wiki, area: "shop", home: self.home) }
        #expect(throws: KnowledgeBase.Failure.self) { try base.plan(folder: self.home.appending(path: "nothing"), area: "shop", home: self.home) }
        #expect(throws: KnowledgeBase.Failure.self) { try base.plan(folder: wiki, area: "a/b", home: self.home) }
        #expect(try base.plan(folder: wiki, area: "shop", name: "wiki-2", home: home).note == "shop/wiki-2")
    }

    @Test func theLocalFolderIsThePathThenAHomeRepoThenTheRemotesClone() throws {
        let clone = try folder("Projects/orders-api"), own = try folder("Code/orders")
        let local = KnowledgeLocal(projects: KnowledgeLint.Projects(copies: ["example.com/shop/orders-api": clone]), home: home)
        func note(_ front: String) -> KnowledgeNote { KnowledgeNote(text: "---\n\(front)\n---\n# n\n") }
        #expect(local.label(of: note("repo: git@example.com:shop/orders-api.git")) == "~/Projects/orders-api")
        #expect(local.label(of: note("repo: git@example.com:shop/orders-api.git\npath: ~/Code/orders")) == "~/Code/orders")
        #expect(local.label(of: note("repo: git@example.com:shop/orders-api.git\npath: ~/gone")) == "~/Projects/orders-api")
        #expect(local.label(of: note("repo: ~/Code/orders")) == "~/Code/orders")
        #expect(local.label(of: note("path: \(own.path)")) == "~/Code/orders")
        #expect(local.label(of: note("repo: git@example.com:shop/other.git")) == nil)
        #expect(local.label(of: note("kind: flow")) == nil)
    }

    @Test func lintChecksThePathFolderAndReadsFilesInIt() throws {
        let code = try folder("Code/orders")
        try write(code.appending(path: "src/a.ts"), "")
        let base = KnowledgeBase(root: try folder("kb"))
        try write(base.noteFile("shop/a"), "---\nkind: service\npath: ~/Code/orders\nfiles: [src/a.ts, src/b.ts]\n---\n# a\n")
        try write(base.noteFile("shop/b"), "---\nkind: folder\npath: ~/gone\n---\n# b\n")
        try write(base.noteFile("shop/c"), "---\nkind: folder\npath: wiki\n---\n# c\n")
        let found = KnowledgeLint.run(base, projects: KnowledgeLint.Projects(), home: home).map { "\($0.rule.rawValue) \($0.file) \($0.link ?? "")" }
        #expect(found == ["missing-file areas/shop/a.md src/b.ts", "missing-home-path areas/shop/b.md ~/gone", "missing-home-path areas/shop/c.md wiki"])
    }
}
