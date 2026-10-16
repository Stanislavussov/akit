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

        @Test func readsRemotes() {
            #expect(ReviewLocal.remoteProject("git@gitlab.corp.example:team/shop.git")! == ("gitlab.corp.example", "team/shop"))
            #expect(ReviewLocal.remoteProject("https://GitLab.corp.example/team/sub/shop.git")! == ("gitlab.corp.example", "team/sub/shop"))
            #expect(ReviewLocal.remoteProject("ssh://git@gitlab.corp.example:2222/team/shop")! == ("gitlab.corp.example", "team/shop"))
            #expect(ReviewLocal.isRefName("origin/main") && ReviewLocal.isRefName("HEAD~3") && !ReviewLocal.isRefName("-x") && !ReviewLocal.isRefName("a..b"))
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
