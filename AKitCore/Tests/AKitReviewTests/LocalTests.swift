import AKitFoundation
import AKitLab
@testable import AKitReview
import Foundation
import Testing

extension ReviewProcessTests {
    /// A review of a local workspace: no GitLab, a range of commits and the uncommitted changes.
    struct LocalTests {
        /// `main` with one commit, a feature branch with two, an edited file, a new file and a new
        /// `.env` in the working tree.
        func workspace() throws -> (home: TempHome, repo: URL) {
            let home = TempHome()
            let repo = home.url.appending(path: "work/shop")
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            home.git(repo, "init", "-q", "-b", "main")
            home.write("work/shop/src/Cart.swift", "struct Cart {\n    var items: [String] = []\n}\n")
            home.git(repo, "add", ".")
            home.git(repo, "commit", "-q", "-m", "Add the cart")
            home.git(repo, "checkout", "-q", "-b", "feature/AB#41-total")
            home.write("work/shop/src/Cart.swift", "struct Cart {\n    var items: [String] = []\n    var total: Int { items.count }\n}\n")
            home.git(repo, "commit", "-q", "-am", "Add a total")
            home.write("work/shop/src/Price.swift", "let vat = 21\n")
            home.git(repo, "add", ".")
            home.git(repo, "commit", "-q", "-m", "Add VAT")
            home.write("work/shop/src/Cart.swift", "struct Cart {\n    var items: [String] = []\n    var total: Int { items.count * 2 }\n}\n")
            home.write("work/shop/src/New.swift", "let fresh = true\n")
            home.write("work/shop/.env", "API_TOKEN=glpat-abcdefghijklmnopqrst\n")
            try ReviewRunFixture.prepare(home)
            return (home, repo)
        }

        @Test func inspectsTheRangeAndTheUncommittedChanges() async throws {
            let (home, repo) = try workspace()
            let inspection = try await ReviewLocal.inspect(path: repo.appending(path: "src"), env: home.env)
            #expect(inspection.path.hasSuffix("/work/shop") && inspection.repository == "shop", "the top folder, from a subfolder")
            #expect(inspection.branch == "feature/AB#41-total" && inspection.baseRef == "main")
            #expect(inspection.commits.map(\.subject) == ["Add VAT", "Add a total"])
            #expect(inspection.uncommitted.sorted() == [" M src/Cart.swift", "?? .env", "?? src/New.swift"])
            #expect(inspection.suggestedMode == .all)
            #expect(inspection.summary.hasPrefix("2 commits since main ("))
            #expect(inspection.summary.hasSuffix("and 3 uncommitted files."))

            // Nothing on main itself: no commits since a base, no changes.
            home.git(repo, "stash", "-u", "-q")
            home.git(repo, "checkout", "-q", "main")
            let clean = try await ReviewLocal.inspect(path: repo, env: home.env)
            #expect(clean.suggestedMode == nil && clean.summary.hasPrefix("Nothing to review"))
            await #expect(throws: ReviewLocal.Failure.self) { try await ReviewLocal.target(clean, mode: .all, env: home.env) }
            await #expect(throws: ReviewLocal.Failure.self) { try await ReviewLocal.inspect(path: repo, baseRef: "--output=/tmp/x", env: home.env) }
            await #expect(throws: ReviewLocal.Failure.self) { try await ReviewLocal.inspect(path: home.url, env: home.env) }
        }

        /// The uncommitted changes become a commit object; the workspace's index, files and branch stay.
        @Test func aSnapshotLeavesTheWorkspaceAlone() async throws {
            let (home, repo) = try workspace()
            home.git(repo, "add", "src/New.swift")   // something staged too
            let statusBefore = home.git(repo, "status", "--porcelain")
            let headBefore = home.git(repo, "rev-parse", "HEAD")
            let inspection = try await ReviewLocal.inspect(path: repo, env: home.env)
            let target = try await ReviewLocal.target(inspection, mode: .uncommitted, env: home.env)
            #expect(home.git(repo, "status", "--porcelain") == statusBefore)
            #expect(home.git(repo, "rev-parse", "HEAD") == headBefore && home.git(repo, "branch", "--show-current") == "feature/AB#41-total")
            #expect(target.base == headBefore && target.head != headBefore && target.commits.isEmpty && target.baseRef == "HEAD")
            #expect(home.git(repo, "rev-parse", "\(target.head)^") == headBefore)
            #expect(home.git(repo, "show", "\(target.head):src/Cart.swift").contains("items.count * 2"))
            #expect(home.git(repo, "show", "\(target.head):src/New.swift") == "let fresh = true")

            let commits = try await ReviewLocal.target(inspection, mode: .commits, env: home.env)
            #expect(commits.head == headBefore && commits.base == inspection.mergeBase && commits.uncommitted.isEmpty)
        }

        @Test func reviewsAWorkspaceWithoutGitLab() async throws {
            let (home, repo) = try workspace()
            let inspection = try await ReviewLocal.inspect(path: repo, env: home.env)
            let target = try await ReviewLocal.target(inspection, mode: .all, env: home.env)
            let result = try await ReviewRuns.startLocal(target, project: nil, choices: ReviewRunFixture.choices, env: home.env, brain: nil)
            let folder = ReviewPaths(home: home.url).run(result.spec.id)
            #expect(result.spec.id.hasSuffix("-shop-local") && result.spec.mergeRequest.label == "shop (local)")
            #expect(result.spec.local?.mode == .all && result.spec.headSHA == target.head)
            #expect(!FileManager.default.fileExists(atPath: home.url.appending(path: "fake/args-fetch.txt").path), "no fetch pass")

            func context(_ name: String) throws -> String { try String(contentsOf: folder.appending(path: "context/\(name)"), encoding: .utf8) }
            let story = try context("merge-request.md")
            #expect(story.contains("Add VAT") && story.contains("Add a total") && story.contains("There is no merge request"))
            let diff = try context("diff.patch")
            #expect(diff.contains("+    var total: Int { items.count * 2 }") && diff.contains("+let vat = 21") && diff.contains("+let fresh = true"))
            #expect(!diff.contains("glpat-") && !diff.contains(".env"), "a secret file never enters the pack")
            #expect(result.gaps.contains { $0.needed.contains(".env") })
            #expect(result.gaps.contains { $0.needed == "Work items #41" && $0.why.contains("doesn't read the tracker") })
            #expect(FileManager.default.fileExists(atPath: folder.appending(path: "worktree/src/New.swift").path))
            #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "worktree/.env").path))

            let run = try await ReviewRunFixture(home: home, head: target.head, folder: folder).playAndRun()
            #expect(run.plan != nil)
            await #expect(throws: ReviewWorkflow.Failure.self) { try await ReviewWorkflow.send(folder, env: home.env) }
            await ReviewGather.removeWorktree(run: folder, checkout: target.path, env: home.env)
            #expect(home.git(repo, "worktree", "list").split(separator: "\n").count == 1)
        }

        /// Base and Head by a word of a branch, a tag, a commit's subject or its id.
        @Test func findsPointsByNameMessageOrID() async throws {
            let (home, repo) = try workspace()
            home.git(repo, "tag", "-a", "v1", "-m", "First", "main")
            let all = try await ReviewLocal.points(path: repo, env: home.env)
            #expect(all.first?.kind == .branch, "refs before commits")
            #expect(Set(all.filter { $0.kind != .commit }.map(\.name)) == ["main", "feature/AB#41-total", "v1"])
            // Same-second commits: their order is git's.
            #expect(Set(all.filter { $0.kind == .commit }.map(\.subject)) == ["Add VAT", "Add a total", "Add the cart"])
            home.git(repo, "tag", "tree-tag", home.git(repo, "write-tree"))
            #expect(try await ReviewLocal.points(path: repo, query: "tree-tag", env: home.env).isEmpty, "a tag on a tree is no point")

            let byBranch = try await ReviewLocal.points(path: repo, query: "41 TOTAL", env: home.env)
            #expect(byBranch.map(\.name) == ["feature/AB#41-total"], "every word, any case")
            let byMessage = try await ReviewLocal.points(path: repo, query: "vat", env: home.env)
            #expect(byMessage.count == 2 && byMessage.contains { $0.kind == .branch } && byMessage.contains { $0.kind == .commit && $0.subject == "Add VAT" })
            let tag = try await ReviewLocal.points(path: repo, query: "v1", env: home.env).first { $0.kind == .tag }
            #expect(tag?.sha == home.git(repo, "rev-parse", "main") && tag?.subject == "First" && tag?.date.isEmpty == false && tag?.author.isEmpty == false,
                    "an annotated tag gives its commit, the commit's author and date, and its own message")

            let first = home.git(repo, "rev-parse", "main")
            let byID = try await ReviewLocal.points(path: repo, query: String(first.prefix(7)), env: home.env)
            #expect(byID.contains { $0.kind == .commit && $0.sha == first && $0.name == String(first.prefix(12)) })
            #expect(try await ReviewLocal.points(path: repo, query: "nothing-like-this", env: home.env).isEmpty)
            await #expect(throws: ReviewLocal.Failure.self) { try await ReviewLocal.points(path: home.url, env: home.env) }
        }

        /// Head: another commit than the workspace's HEAD reviews that range, without the uncommitted changes.
        @Test func reviewsUpToAnotherHead() async throws {
            let (home, repo) = try workspace()
            let middle = home.git(repo, "rev-parse", "HEAD~1")
            let inspection = try await ReviewLocal.inspect(path: repo, headRef: "HEAD~1", env: home.env)
            #expect(inspection.head == middle && inspection.headRef == "HEAD~1" && inspection.branch == "HEAD~1")
            #expect(inspection.commits.map(\.subject) == ["Add a total"] && inspection.uncommitted.isEmpty)
            #expect(inspection.suggestedMode == .commits)
            let target = try await ReviewLocal.target(inspection, mode: .commits, env: home.env)
            #expect(target.head == middle && target.headRef == "HEAD~1" && target.base == home.git(repo, "rev-parse", "main"))

            // The workspace's own branch by name is still HEAD, with its changes.
            let same = try await ReviewLocal.inspect(path: repo, headRef: "feature/AB#41-total", env: home.env)
            #expect(same.headRef == nil && same.uncommitted.count == 3 && same.commits.count == 2)
            // Base and Head together: only the commits between them.
            let between = try await ReviewLocal.inspect(path: repo, baseRef: "HEAD~1", headRef: "HEAD", env: home.env)
            #expect(between.commits.map(\.subject) == ["Add VAT"])
            await #expect(throws: ReviewLocal.Failure.self) { try await ReviewLocal.inspect(path: repo, headRef: "no-such-branch", env: home.env) }
            await #expect(throws: ReviewLocal.Failure.self) { try await ReviewLocal.inspect(path: repo, headRef: "--all", env: home.env) }
        }

        @Test func readsRemotes() {
            #expect(ReviewLocal.remoteProject("git@gitlab.corp.example:team/shop.git")! == ("gitlab.corp.example", "team/shop"))
            #expect(ReviewLocal.remoteProject("https://GitLab.corp.example/team/sub/shop.git")! == ("gitlab.corp.example", "team/sub/shop"))
            #expect(ReviewLocal.remoteProject("ssh://git@gitlab.corp.example:2222/team/shop")! == ("gitlab.corp.example", "team/shop"))
            #expect(ReviewLocal.isRefName("origin/main") && ReviewLocal.isRefName("HEAD~3") && !ReviewLocal.isRefName("-x") && !ReviewLocal.isRefName("a..b"))
            #expect(ReviewLocal.isRefName("feature/AB#41-total") && ReviewLocal.isRefName("v1.2+build") && ReviewLocal.isRefName("main^"))
            #expect(!ReviewLocal.isRefName("main@{1}") && !ReviewLocal.isRefName("a b") && !ReviewLocal.isRefName("x:y") && !ReviewLocal.isRefName("a\\b"))
        }
    }
}

extension ReviewRunFixture {
    /// Plays the typical findings in this run and runs its passes.
    func playAndRun() async throws -> ReviewWorkflow.Run {
        fake("role-bug-hunter", #"{"findings":[]}"#)
        try await ReviewPasses.run(folder: folder, env: home.env)
        return try ReviewWorkflow.load(folder)
    }
}
