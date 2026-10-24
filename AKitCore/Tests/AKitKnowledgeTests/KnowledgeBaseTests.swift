import Foundation
import Testing
import AKitBrain
import AKitFoundation
@testable import AKitKnowledge

/// Bases in a temporary fake home: create, refusals, identity, base choice, commits.
struct KnowledgeBaseTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = URL(filePath: FileWalk.realPath(fm.temporaryDirectory) ?? fm.temporaryDirectory.path)
            .appending(path: "akit-kb-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    /// Git never reads the real user's config: the global one is /dev/null, the system one is off.
    func env(_ extra: [String: String] = [:]) -> HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home,
                           variables: ["HOME": home.path, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"].merging(extra) { $1 },
                           executableSearchPaths: [URL(filePath: "/usr/bin")])
    }

    func git(_ args: String..., in folder: URL, env: HarnessEnvironment? = nil) async throws -> String {
        let result = try #require(await ProcessRunner.run(URL(filePath: "/usr/bin/git"), arguments: args, directory: folder,
                                                           environment: (env ?? self.env()).variables, timeout: 20))
        #expect(result.succeeded, "git \(args.joined(separator: " ")): \(result.output)")
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func write(_ url: URL, _ text: String) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func work() throws { try MachineProfile(kind: .work, name: "work").save(home: home) }

    @Test func createMakesAFolderARepoAndOneCommit() async throws {
        let base = try await KnowledgeBase.create(world: "work", env: env())
        #expect(base.root.path == home.appending(path: ".akit/local/knowledge/work").path)
        #expect(FileWalk.isDirectory(base.areasFolder) && FileWalk.isDirectory(base.inboxFolder))
        let ignore = try String(contentsOf: base.root.appending(path: ".gitignore"), encoding: .utf8)
        for entry in [".akit-index.sqlite*", ".akit-index.lock", ".akit-queue.lock", ".akit-pending.json", ".akit-misses.log", ".obsidian/"] {
            #expect(ignore.split(separator: "\n").contains(Substring(entry)), "\(entry)")
        }
        #expect(try await git("remote", in: base.root).isEmpty)
        #expect(try await git("log", "--format=%s", in: base.root) == "Create the knowledge base")
        #expect(try await git("status", "--porcelain", in: base.root).isEmpty)
        #expect(KnowledgeBase.isBase(base.root))
        #expect(KnowledgeBase.all(home: home) == [base])
    }

    @Test func identityFallsBackToAKitWithoutAGitConfig() async throws {
        let base = try await KnowledgeBase.create(world: "work", env: env())
        #expect(try await git("log", "-1", "--format=%an <%ae>", in: base.root) == "AKit <akit@localhost>")
        #expect(try await git("config", "--local", "user.name", in: base.root) == "AKit")
    }

    @Test func identityIsTheUsersOwnWhenGitHasOne() async throws {
        let config = home.appending(path: "gitconfig")
        try write(config, "[user]\n\tname = Jane Doe\n\temail = jane@example.com\n")
        let mine = env(["GIT_CONFIG_GLOBAL": config.path])
        let base = try await KnowledgeBase.create(world: "personal", env: mine)
        #expect(try await git("log", "-1", "--format=%an <%ae>", in: base.root, env: mine) == "Jane Doe <jane@example.com>")
        let local = await ProcessRunner.run(URL(filePath: "/usr/bin/git"), arguments: ["config", "--local", "--get", "user.name"],
                                            directory: base.root, environment: mine.variables, timeout: 20)
        #expect(local?.status == 1, "no local identity of its own")
    }

    @Test func refusesInsideTheBrain() async throws {
        let inside = Brain.defaultRoot(home: home).appending(path: "knowledge")
        await #expect(throws: KnowledgeBase.Failure.self) { try await KnowledgeBase.create(at: inside, env: env()) }
        let custom = home.appending(path: "brain")
        await #expect(throws: KnowledgeBase.Failure.self) {
            try await KnowledgeBase.create(at: custom.appending(path: "kb"), env: env(), brainRoot: custom)
        }
        #expect(!fm.fileExists(atPath: inside.path))
    }

    @Test func workMacRefusesAFolderOutsideAkitLocal() async throws {
        try work()
        let outside = home.appending(path: "Documents/kb")
        do {
            try await KnowledgeBase.create(at: outside, env: env())
            Issue.record("created outside ~/.akit/local on a work Mac")
        } catch {
            #expect(error.message.contains("work Mac"))
        }
        #expect(!fm.fileExists(atPath: outside.path))
        // Inside it is fine.
        #expect(try await KnowledgeBase.create(world: "work", env: env()).root.path.hasSuffix(".akit/local/knowledge/work"))
    }

    @Test func personalMacMayUseAnyFolderOutsideTheBrain() async throws {
        let folder = home.appending(path: "Documents/kb")
        #expect(KnowledgeBase.isBase(try await KnowledgeBase.create(at: folder, env: env()).root))
    }

    @Test func refusesARepoWithARemoteAndAFolderWithFiles() async throws {
        let vault = home.appending(path: "vault")
        try fm.createDirectory(at: vault, withIntermediateDirectories: true)
        _ = try await git("init", "-q", in: vault)
        _ = try await git("remote", "add", "origin", "git@example.com:me/vault.git", in: vault)
        do {
            try await KnowledgeBase.create(at: vault, env: env())
            Issue.record("a repo with a remote became a base")
        } catch {
            #expect(error.message.contains("remote"))
        }
        let full = home.appending(path: "full")
        try write(full.appending(path: "a.txt"), "x")
        await #expect(throws: KnowledgeBase.Failure.self) { try await KnowledgeBase.create(at: full, env: env()) }
        await #expect(throws: KnowledgeBase.Failure.self) { try await KnowledgeBase.create(world: "../up", env: env()) }
    }

    @Test func aRepoWithoutARemoteBecomesABaseOnce() async throws {
        let vault = home.appending(path: "vault")
        try write(vault.appending(path: ".gitignore"), ".DS_Store")
        _ = try await git("init", "-q", in: vault)
        let base = try await KnowledgeBase.create(at: vault, env: env())
        let ignore = try String(contentsOf: vault.appending(path: ".gitignore"), encoding: .utf8)
        #expect(ignore.hasPrefix(".DS_Store\n.akit-index.sqlite*\n"))
        #expect(KnowledgeBase.isBase(base.root))
        await #expect(throws: KnowledgeBase.Failure.self) { try await KnowledgeBase.create(at: vault, env: env()) }
    }

    @Test func commitRefusedWhileARemoteIsSet() async throws {
        let base = try await KnowledgeBase.create(world: "work", env: env())
        _ = try await git("remote", "add", "origin", "git@example.com:me/kb.git", in: base.root)
        try write(base.areasFolder.appending(path: "a/x.md"), "# x\n")
        await #expect(throws: KnowledgeGit.Failure.self) {
            try await KnowledgeGit(base: base.root, env: env()).commit(paths: ["areas/a/x.md"], message: "x")
        }
        #expect(try await git("rev-list", "--count", "HEAD", in: base.root) == "1")
        #expect(await KnowledgeGit(base: base.root, env: env()).remotes() == ["origin"])
    }

    @Test func newNoteCommitsOnlyItsOwnFile() async throws {
        let base = try await KnowledgeBase.create(world: "work", env: env())
        // A pending edit of another note, staged even: it must stay out of the new note's commit.
        try write(base.areasFolder.appending(path: "payments/billing.md"), "# billing\n")
        _ = try await git("add", "areas/payments/billing.md", in: base.root)
        let path = try await base.newNote(area: "payments", name: "orders-api", kind: "service", env: env())
        #expect(path == "areas/payments/orders-api.md")
        #expect(try await git("show", "--name-only", "--format=%s", "HEAD", in: base.root) == "Add note payments/orders-api\n\nareas/payments/orders-api.md")
        #expect(try String(contentsOf: base.root.appending(path: path), encoding: .utf8) == "---\nkind: service\n---\n# orders-api\n")
        #expect(try await git("status", "--porcelain", in: base.root) == "A  areas/payments/billing.md")
        await #expect(throws: KnowledgeBase.Failure.self) { try await base.newNote(area: "payments", name: "orders-api", kind: nil, env: env()) }
        await #expect(throws: KnowledgeBase.Failure.self) { try await base.newNote(area: "../x", name: "y", kind: nil, env: env()) }
        await #expect(throws: KnowledgeBase.Failure.self) { try await base.newNote(area: "a", name: ".hidden", kind: nil, env: env()) }
    }

    @Test func commitOfNothingChangedMakesNoCommit() async throws {
        let base = try await KnowledgeBase.create(world: "work", env: env())
        let git = KnowledgeGit(base: base.root, env: env())
        #expect(try await git.commit(paths: [".gitignore"], message: "again") == false)
        #expect(try await git.commit(paths: ["areas/none.md"], message: "gone") == false)
        await #expect(throws: KnowledgeGit.Failure.self) { try await git.commit(paths: ["../outside"], message: "x") }
        // A deletion is committed too.
        try write(base.areasFolder.appending(path: "a/x.md"), "# x\n")
        #expect(try await git.commit(paths: ["areas/a/x.md"], message: "add"))
        try fm.removeItem(at: base.areasFolder.appending(path: "a/x.md"))
        #expect(try await git.commit(paths: ["areas/a/x.md"], message: "remove"))
        #expect(try await self.git("ls-files", "areas", in: base.root).isEmpty)
    }

    @Test func aHeldLockMakesACommitWaitThenFail() async throws {
        let base = try await KnowledgeBase.create(world: "work", env: env())
        let lock = try BaseLock.acquire(base.root.appending(path: KnowledgeBase.queueLockName), timeout: 0)
        try write(base.areasFolder.appending(path: "a/x.md"), "# x\n")
        let started = Date.now
        await #expect(throws: KnowledgeGit.Failure.self) {
            try await KnowledgeGit(base: base.root, env: env()).commit(paths: ["areas/a/x.md"], message: "x", lockTimeout: 0.3)
        }
        #expect(Date.now.timeIntervalSince(started) >= 0.3)
        lock.release()
        #expect(try await KnowledgeGit(base: base.root, env: env()).commit(paths: ["areas/a/x.md"], message: "x"))
    }

    @Test func areasAndNotesAreListed() async throws {
        let base = try await KnowledgeBase.create(world: "work", env: env())
        try write(base.areasFolder.appending(path: "payments/orders-api.md"), "---\nkind: service\n---\n# Orders API\n")
        try write(base.areasFolder.appending(path: "payments/flows/order-to-billing.md"), "---\nkind: flow\n---\ntext\n")
        try write(base.areasFolder.appending(path: "payments/maps/overview.excalidraw"), "{}")
        try write(base.areasFolder.appending(path: "logistics/warehouse.md"), "# Warehouse\n")
        #expect(base.areas() == [.init(name: "logistics", notes: 1, maps: 0), .init(name: "payments", notes: 2, maps: 1)])
        let notes = try base.notes(area: "payments")
        #expect(notes.map(\.id) == ["payments/flows/order-to-billing", "payments/orders-api"])
        #expect(notes[1] == .init(id: "payments/orders-api", area: "payments", path: "areas/payments/orders-api.md", kind: "service", title: "Orders API"))
        #expect(notes[0].title == "order-to-billing")
        #expect(try base.notes().count == 3)
        #expect(throws: KnowledgeBase.Failure.self) { try base.notes(area: "nope") }
        #expect(base.linkTargets() == KnowledgeLinks(notes: ["logistics/warehouse", "payments/flows/order-to-billing", "payments/orders-api"],
                                                     maps: ["payments/maps/overview"]))
    }

    // MARK: - Base choice

    func makeBase(_ name: String) throws -> URL {
        let root = KnowledgeBase.world(name, home: home)
        try fm.createDirectory(at: root.appending(path: "areas"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appending(path: ".git"), withIntermediateDirectories: true)
        return root
    }

    func choose(_ option: String? = nil, folder: URL? = nil) async throws -> String? {
        try await KnowledgeBase.choose(option: option, folder: folder ?? home, env: env(), projectsRoot: home.appending(path: "Projects"))?.name
    }

    @Test func noBaseIsNil() async throws {
        #expect(try await choose() == nil)
    }

    @Test func theOnlyBaseIsChosen() async throws {
        _ = try makeBase("mine")
        #expect(try await choose() == "mine")
    }

    @Test func severalBasesTakeTheMachineKindsName() async throws {
        _ = try makeBase("personal")
        _ = try makeBase("work")
        #expect(try await choose() == "personal")
        try work()
        #expect(try await choose() == "work")
    }

    @Test func severalBasesWithoutAMatchListThem() async throws {
        _ = try makeBase("a")
        _ = try makeBase("b")
        do {
            _ = try await choose()
            Issue.record("chose one of two")
        } catch let failure as KnowledgeBase.Failure {
            #expect(failure.message.contains("a (~/.akit/local/knowledge/a)") && failure.message.contains("b (~/.akit/local/knowledge/b)"))
        }
    }

    @Test func theOptionWinsByWorldOrPath() async throws {
        _ = try makeBase("personal")
        let other = home.appending(path: "Documents/kb")
        try fm.createDirectory(at: other.appending(path: "areas"), withIntermediateDirectories: true)
        try fm.createDirectory(at: other.appending(path: ".git"), withIntermediateDirectories: true)
        _ = try makeBase("work")
        #expect(try await choose("work") == "work")
        #expect(try await choose(other.path) == "kb")
        #expect(try await choose("~/Documents/kb") == "kb")
        #expect(try await choose("./Documents/kb", folder: home) == "kb")
        await #expect(throws: KnowledgeBase.Failure.self) { try await choose("none") }
        await #expect(throws: KnowledgeBase.Failure.self) { try await choose("/no/such/kb") }
    }

    @Test func theProjectsFocusEntryBeatsTheOthers() async throws {
        _ = try makeBase("personal")
        _ = try makeBase("side")
        let project = home.appending(path: "Projects/shop")
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        _ = try await git("init", "-q", in: project)
        _ = try await git("remote", "add", "origin", "git@example.com:me/shop.git", in: project)
        let id = await ProjectRecords.projectID(for: project, projectsRoot: home.appending(path: "Projects"), env: env())
        try write(KnowledgeBase.focusFile(home: home), #"{"projects": {"\#(id)": {"base": "side", "area": "payments"}}}"#)
        #expect(try await choose(folder: project) == "side")
        #expect(try await choose(folder: home) == "personal")
        #expect(try await choose("personal", folder: project) == "personal")
    }
}
