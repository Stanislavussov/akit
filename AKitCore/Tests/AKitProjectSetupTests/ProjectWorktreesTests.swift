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

    @Test func conflictsStayAndOnlyStaleLinksIntoTheMainCheckoutGo() async throws {
        let brain = try await f.setUpBrain()
        try await f.initRepo()
        try await f.apply(f.answers(), brain: brain)
        try await addTree()
        // The branch has its own AGENTS.md and its own skill folder; an old AKit link, a link elsewhere.
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
        #expect(status.stale == [".agents/skills/old"])

        let outcome = ProjectWorktrees.sync(f.project, env: f.env)
        #expect(outcome.removed.map(ProjectWorktrees.realPath) == [ProjectWorktrees.realPath(tree.path) + "/.agents/skills/old"])
        #expect(f.read("AGENTS.md", in: tree) == "# Branch\n")
        #expect(f.read(".agents/skills/own/SKILL.md", in: tree) == "own")
        #expect(destination(".agents/skills/elsewhere") == f.home.path)
        #expect(f.read(".claude", in: tree) == "x")
        #expect(destination(".agents/skills/tdd") != nil)
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
