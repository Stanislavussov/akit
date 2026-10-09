import Foundation
import Testing
import AKitBrain
import AKitFoundation
@testable import AKitProjectSetup

/// Links of a local-only project's AKit files in its git worktrees.
struct ProjectWorktreesTests {
    let f: GitProjectFixture
    let fm = FileManager.default

    init() throws { f = try GitProjectFixture("worktrees") }

    var tree: URL { f.home.appending(path: "trees/task-x") }
    /// The main checkout as git names it (links point there).
    var main: String { ProjectWorktrees.realPath(f.project.path) }

    func addTree() async throws {
        try await f.git("worktree", "add", "-q", "-b", "x", tree.path)
    }

    func destination(_ path: String) -> String? { try? fm.destinationOfSymbolicLink(atPath: tree.appending(path: path).path) }

    @Test func aNewWorktreeGetsLinksOnSync() async throws {
        let brain = try await f.setUpBrain()
        try await f.initRepo()
        try await f.apply(f.answers(), brain: brain)
        try await addTree()

        let before = try #require(ProjectWorktrees.status(of: f.project, env: f.env))
        let worktree = try #require(before.worktrees.first)
        #expect(before.worktrees.count == 1 && worktree.branch == "x")
        #expect(worktree.lacks == [".agents/skills/review", ".agents/skills/tdd", ".claude/skills", "AGENTS.md", "CLAUDE.md"])

        let outcome = ProjectWorktrees.sync(f.project, env: f.env)
        #expect(outcome.created.count == 5 && outcome.problems.isEmpty, "\(outcome)")
        #expect(destination(".agents/skills/tdd") == main + "/.agents/skills/tdd")
        #expect(f.read(".agents/skills/tdd/SKILL.md", in: tree)?.contains("name: tdd") == true)
        #expect(f.read("AGENTS.md", in: tree) == "# Task\n")
        // Real folders for the parents; git sees nothing new in the worktree (the exclude is shared).
        #expect(destination(".agents") == nil && destination(".agents/skills") == nil)
        #expect(try await f.git("status", "--porcelain", "--untracked-files=all", in: tree).isEmpty)

        let after = try #require(ProjectWorktrees.status(of: f.project, env: f.env))
        #expect(after.worktrees.first?.links.allSatisfy { $0.state == .linked } == true && !after.needsSync)
        #expect(!ProjectWorktrees.sync(f.project, env: f.env).changed)
    }

    @Test func applyLinksIntoWorktreesAndRemovesTheLinksOfDroppedUnits() async throws {
        let brain = try await f.setUpBrain()
        try await f.initRepo()
        try await addTree()
        let plan = f.plan(f.answers(), brain: brain)
        #expect(plan.notes.contains { $0.hasPrefix("Apply also links them into the repository's other worktrees: ") })

        let outcome = try await f.apply(f.answers(), brain: brain)
        #expect(outcome.notes.contains { $0.hasPrefix("Linked into worktrees: ") })
        #expect(destination(".agents/skills/review") == main + "/.agents/skills/review")

        try await f.apply(f.answers(review: false), brain: brain)
        #expect(destination(".agents/skills/review") == nil)
        #expect(!fm.fileExists(atPath: tree.appending(path: ".agents/skills/review").path))
        #expect(destination(".agents/skills/tdd") != nil)

        // Committed again: every link leaves the worktree.
        try await f.apply(f.answers(review: false, localOnly: false), brain: brain)
        #expect(destination(".agents/skills/tdd") == nil && destination(".claude/skills") == nil && destination("AGENTS.md") == nil)
    }

    @Test func conflictsStayAndSyncRemovesNoLinkAKitDidntJustDrop() async throws {
        let brain = try await f.setUpBrain()
        try await f.initRepo()
        try await f.apply(f.answers(), brain: brain)
        try await addTree()
        // The branch has its own AGENTS.md and its own skill folder; a link into the main
        // checkout AKit can't know as its own, a link elsewhere.
        try Data("# Branch\n".utf8).write(to: tree.appending(path: "AGENTS.md"))
        let skills = tree.appending(path: ".agents/skills")
        try fm.createDirectory(at: skills.appending(path: "own"), withIntermediateDirectories: true)
        try Data("own".utf8).write(to: skills.appending(path: "own/SKILL.md"))
        try fm.createSymbolicLink(atPath: skills.appending(path: "old").path, withDestinationPath: main + "/.agents/skills/old")
        try fm.createSymbolicLink(atPath: skills.appending(path: "elsewhere").path, withDestinationPath: f.home.path)
        // A real file where a link's parent folder should be.
        try Data("x".utf8).write(to: tree.appending(path: ".claude"))

        let status = try #require(ProjectWorktrees.status(of: f.project, env: f.env)?.worktrees.first)
        #expect(Set(status.conflicts) == ["AGENTS.md", ".claude/skills"])
        #expect(status.stale.isEmpty)

        let outcome = ProjectWorktrees.sync(f.project, env: f.env)
        #expect(outcome.removed.isEmpty)
        #expect(f.read("AGENTS.md", in: tree) == "# Branch\n")
        #expect(f.read(".agents/skills/own/SKILL.md", in: tree) == "own")
        #expect(destination(".agents/skills/old") == main + "/.agents/skills/old")
        #expect(destination(".agents/skills/elsewhere") == f.home.path)
        #expect(f.read(".claude", in: tree) == "x")
        #expect(destination(".agents/skills/tdd") != nil)
    }

    @Test func withoutABlockSyncRemovesNoLink() async throws {
        try await f.initRepo()
        try await addTree()
        try fm.createDirectory(at: tree.appending(path: ".agents/skills"), withIntermediateDirectories: true)
        try fm.createDirectory(at: tree.appending(path: ".claude"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: tree.appending(path: ".claude/skills").path, withDestinationPath: main + "/.claude/skills")
        try fm.createSymbolicLink(atPath: tree.appending(path: ".agents/skills/mine").path, withDestinationPath: main + "/.agents/skills/mine")
        let status = try #require(ProjectWorktrees.status(of: f.project, env: f.env))
        #expect(status.units.isEmpty && !status.needsSync)
        #expect(!ProjectWorktrees.sync(f.project, env: f.env).changed)
        #expect(destination(".claude/skills") != nil && destination(".agents/skills/mine") != nil)
    }

    @Test func unitsThatLeaveTheCheckoutAreIgnored() async throws {
        try await f.initRepo()
        try await addTree()
        // Edited by hand: a unit that climbs out of the checkout, which exists there.
        try f.write("Projects/shared/x", "x")
        try Data("\(LocalOnly.startMarker)\n/../shared/x\n/a/../../shared/x\n\(LocalOnly.endMarker)\n".utf8).write(to: f.excludeFile)
        let status = try #require(ProjectWorktrees.status(of: f.project, env: f.env))
        #expect(status.units.isEmpty)
        #expect(!ProjectWorktrees.sync(f.project, env: f.env).changed)
        #expect(!fm.fileExists(atPath: f.home.appending(path: "trees/shared").path))
    }

    @Test func aLinkedSkillsFolderInAWorktreeIsLeftAlone() async throws {
        let brain = try await f.setUpBrain()
        try await f.initRepo()
        try await f.apply(f.answers(), brain: brain)
        try await addTree()
        // The worktree's .agents/skills is a link to a folder elsewhere, holding a link of `review`.
        let elsewhere = f.home.appending(path: "elsewhere/skills")
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: elsewhere.appending(path: "review").path, withDestinationPath: main + "/.agents/skills/review")
        try fm.createDirectory(at: tree.appending(path: ".agents"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: tree.appending(path: ".agents/skills").path, withDestinationPath: elsewhere.path)

        let status = try #require(ProjectWorktrees.status(of: f.project, env: f.env)?.worktrees.first)
        #expect(Set(status.conflicts) == [".agents/skills/review", ".agents/skills/tdd"])
        ProjectWorktrees.sync(f.project, env: f.env)
        #expect(!fm.fileExists(atPath: elsewhere.appending(path: "tdd").path), "no link made through the linked folder")

        // Dropping `review` doesn't reach through the link either.
        try await f.apply(f.answers(review: false), brain: brain)
        #expect((try? fm.destinationOfSymbolicLink(atPath: elsewhere.appending(path: "review").path)) == main + "/.agents/skills/review")
    }

    @Test func aWorktreeInsideTheMainCheckoutGetsItsLinks() async throws {
        let brain = try await f.setUpBrain()
        try await f.initRepo()
        try await f.apply(f.answers(), brain: brain)
        let nested = f.project.appending(path: ".claude/worktrees/x")
        try await f.git("worktree", "add", "-q", "-b", "x", nested.path)
        let status = try #require(ProjectWorktrees.status(of: f.project, env: f.env))
        #expect(status.worktrees.count == 1 && status.worktrees.first?.lacks.count == 5, "\(status)")
        let outcome = ProjectWorktrees.sync(f.project, env: f.env)
        #expect(outcome.created.count == 5 && outcome.problems.isEmpty, "\(outcome)")
        #expect(f.read(".agents/skills/tdd/SKILL.md", in: nested)?.contains("name: tdd") == true)
        #expect(ProjectWorktrees.status(of: f.project, env: f.env)?.needsSync == false)
        #expect(!ProjectWorktrees.sync(f.project, env: f.env).changed)
    }

    @Test func porcelainRecordsAreParsedWithoutGit() {
        let output = [
            "worktree /main", "HEAD 1111", "branch refs/heads/main", "",
            "worktree /trees/with space", "HEAD 2222", "branch refs/heads/feature/x", "",
            "worktree /trees/locked", "HEAD 3333", "branch refs/heads/l", "locked because", "",
            "worktree /trees/detached", "HEAD 4444", "detached", "",
            "worktree /trees/gone", "HEAD 5555", "branch refs/heads/g", "prunable gitdir file points to non-existent location", "",
            // `git worktree add` is still checking it out.
            "worktree /trees/new", "HEAD 6666", "branch refs/heads/n", "locked initializing", "",
            "worktree /bare.git", "bare", "", "",
        ].joined(separator: "\0")
        let listed = ProjectWorktrees.listed(fromPorcelain: output)
        #expect(listed.map(\.folder.path) == ["/main", "/trees/with space", "/trees/locked", "/trees/detached"])
        #expect(listed.map(\.branch) == ["main", "feature/x", "l", nil])
        #expect(ProjectWorktrees.listed(fromPorcelain: "").isEmpty)
    }

    @Test func aLinkAnotherSyncJustMadeCountsAsLinked() throws {
        let folder = f.home.appending(path: "links")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appending(path: "AGENTS.md").path
        #expect(try ProjectWorktrees.makeLink(at: path, to: "/main/AGENTS.md"))
        // The same link is there already (a sync raced this one): no new link, no problem.
        #expect(try ProjectWorktrees.makeLink(at: path, to: "/main/AGENTS.md") == false)
        // Something else is there: still an error.
        #expect(throws: (any Error).self) { try ProjectWorktrees.makeLink(at: path, to: "/other/AGENTS.md") }
    }

    @Test func gitCheckoutReadsARelativeGitdirAndStopsAtTheRoot() throws {
        // A linked worktree's `.git` file and its `commondir`, both relative; no git run.
        let common = f.home.appending(path: "repo/.git")
        let record = common.appending(path: "worktrees/x")
        try fm.createDirectory(at: record, withIntermediateDirectories: true)
        try Data("../..\n".utf8).write(to: record.appending(path: "commondir"))
        let tree = f.home.appending(path: "trees/x")
        try fm.createDirectory(at: tree, withIntermediateDirectories: true)
        try Data("gitdir: ../../repo/.git/worktrees/x\n".utf8).write(to: tree.appending(path: ".git"))
        let checkout = try #require(GitCheckout.at(tree))
        #expect(checkout.gitDir.standardizedFileURL.path == record.standardizedFileURL.path)
        #expect(checkout.commonDir.standardizedFileURL.path == common.standardizedFileURL.path)
        #expect(checkout.isLinkedWorktree)
        #expect(checkout.mainFolder?.standardizedFileURL.path == f.home.appending(path: "repo").standardizedFileURL.path)
        #expect(GitCheckout.containing(tree.appending(path: "a/b"))?.folder.standardizedFileURL.path == tree.standardizedFileURL.path)
        #expect(GitCheckout.containing(URL(filePath: "/")) == nil)
    }

    @Test func forgetTakesEveryLinkOutOfTheWorktrees() async throws {
        let brain = try await f.setUpBrain()
        try await f.initRepo()
        try await addTree()
        try await f.apply(f.answers(), brain: brain)
        #expect(destination("CLAUDE.md") != nil)
        let preview = try #require(ProjectForget.preview(id: f.id, folder: f.project, forHome: false, brain: brain, store: f.store, env: f.env))
        try await ProjectForget.run(preview, keepFiles: false, brain: brain, home: f.home, env: f.env, trash: f.trash)
        for path in [".agents/skills/tdd", ".agents/skills/review", ".claude/skills", "AGENTS.md", "CLAUDE.md"] {
            #expect(destination(path) == nil, "\(path)")
        }
    }

    @Test func aRepositoryWithoutWorktreesNeedsNoGit() async throws {
        let brain = try await f.setUpBrain()
        try await f.initRepo()
        try await f.apply(f.answers(), brain: brain)
        let status = try #require(ProjectWorktrees.status(of: f.project, env: f.env))
        #expect(status.worktrees.isEmpty && status.units.count == 5)
        #expect(ProjectWorktrees.status(of: f.home, env: f.env) == nil)
    }

    @Test func theMainCheckoutWinsOverItsWorktrees() async throws {
        try await f.initRepo()
        try await addTree()
        #expect(GitCheckout.at(tree)?.isLinkedWorktree == true)
        #expect(GitCheckout.at(f.project)?.isLinkedWorktree == false)
        #expect(GitCheckout.preferred([tree, f.project]) == f.project)
        #expect(GitCheckout.preferred([tree]) == tree)
        #expect(GitCheckout.at(tree)?.mainFolder.map { ProjectWorktrees.realPath($0.path) } == main)
    }
}
