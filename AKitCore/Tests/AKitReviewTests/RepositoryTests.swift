import AKitFoundation
@testable import AKitReview
import Foundation
import Testing

/// AKit's own clone, the run's branch, setup commands and what git saves the fetch pass.
struct RepositoryUnitTests {
    @Test func profileReadsSetupCloneAndCloneURL() throws {
        let profile = try ReviewProfile.parse("""
        gitlab: { host: https://g, project_path: a/b }
        clone_url: git@g:a/b.git
        setup:
          - npm ci
          - { name: gen, run: "npm run gen", timeout_s: 60 }
        """, slug: "b")
        #expect(profile.cloneURL == "git@g:a/b.git" && profile.clone)
        #expect(profile.setup.map(\.name) == ["setup-1", "gen"])
        #expect(profile.setup.map(\.run) == ["npm ci", "npm run gen"])
        #expect(profile.setup.map(\.timeoutSeconds) == [900, 60])
        #expect(try ReviewProfile.parse("gitlab: { host: https://g, project_path: a/b }\nclone: false\n", slug: "b").clone == false)
        #expect(throws: (any Error).self) { try ReviewProfile.parse("gitlab: { host: https://g, project_path: a/b }\nclone_url: /tmp/x\n", slug: "b") }
        #expect(throws: (any Error).self) { try ReviewProfile.parse("gitlab: { host: https://g, project_path: a/b }\nclone_url: --upload-pack=x\n", slug: "b") }
        #expect(throws: (any Error).self) { try ReviewProfile.parse("gitlab: { host: https://g, project_path: a/b }\nsetup: npm ci\n", slug: "b") }
    }

    @Test func cloneFolderAndURLs() {
        let home = URL(filePath: "/Users/me")
        #expect(ReviewRepository.folder(home: home, host: "https://GitLab.corp:8443/", projectPath: "team/app")?.path
                == "/Users/me/.akit/local/review/repos/gitlab.corp_8443/team/app")
        #expect(ReviewRepository.folder(home: home, host: "https://g", projectPath: "team/../x") == nil)
        #expect(ReviewRepository.cloneURLs(host: "https://gitlab.corp", projectPath: "team/app", profile: nil)
                == ["git@gitlab.corp:team/app.git", "https://gitlab.corp/team/app.git"])
        #expect(ReviewRepository.branch(for: "20261101-120000-app-7") == "akit-review/20261101-120000-app-7")
        #expect(!ReviewRepository.isCloneURL("ext::sh -c x") && !ReviewRepository.isCloneURL("file:///tmp/x"))
    }

    @Test func gitNamesTheEarlierMergeRequestsOfTheProject() {
        let log = "Fix login\n\nSee merge request team/app!12\n\u{1e}Merge branch 'x'\n\nSee merge request other/lib!99\n\u{1e}"
            + "Squash\n\nSee merge request team/app!12\n\u{1e}Old\n\nSee merge request !8\n"
        #expect(ReviewRepository.mergeRequestNumbers(in: log, projectPath: "Team/App") == [12, 8])
    }

    @Test func setupSaveSetsOnlyTheSetupKey() throws {
        let home = TempHome()
        home.write(".akit/local/review/projects/b.yaml", "project: b\ngitlab: { host: https://g, project_path: a/b }\nsetup:\n  - npm i\n  - make\nconstraints: []\n")
        let save = try ReviewConfigEditor.setup(["npm ci", "echo \"hi\""], profile: "b", home: home.url, brain: home.url.appending(path: "brain"))
        #expect(save.new == "project: b\ngitlab: { host: https://g, project_path: a/b }\nconstraints: []\nsetup: [\"npm ci\",\"echo \\\"hi\\\"\"]\n"
                || save.new == "project: b\ngitlab: { host: https://g, project_path: a/b }\nsetup: [\"npm ci\",\"echo \\\"hi\\\"\"]\nconstraints: []\n")
        #expect(try ReviewProfile.parse(save.new, slug: "b").setup.map(\.run) == ["npm ci", "echo \"hi\""])
        let cleared = try ReviewConfigEditor.setup([], profile: "b", home: home.url, brain: home.url.appending(path: "brain"))
        #expect(!cleared.new.contains("setup") && cleared.new.contains("constraints: []"))
        home.write(".akit/local/review/projects/c.yaml", "gitlab: { host: https://g, project_path: a/c }\nsetup:\n  - { name: deps, run: npm ci, timeout_s: 3600 }\n")
        #expect(throws: (any Error).self) { try ReviewConfigEditor.setup(["npm ci"], profile: "c", home: home.url, brain: home.url) }
    }

    @Test func removalRunsGitOnlyInAKnownClone() async throws {
        let home = TempHome()
        let other = home.url.appending(path: "other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        home.git(other, "init", "-q", "-b", "main")
        home.git(other, "commit", "-q", "--allow-empty", "-m", "x")
        home.git(other, "branch", "akit-review/x")
        // A worktree whose .git file the merge request's code pointed at another repository.
        home.write("tree/.git", "gitdir: \(other.path)/.git/worktrees/x\n")
        await ReviewRepository.removeWorktree(home.url.appending(path: "tree"), clones: [], env: home.env)
        #expect(!FileManager.default.fileExists(atPath: home.url.appending(path: "tree").path))
        #expect(home.git(other, "branch", "--list", "akit-review/x").contains("akit-review/x"))
    }

    @Test func testFilesByName() {
        let home = TempHome()
        home.write("tree/src/Chart.tsx", "x")
        home.write("tree/src/Chart.test.tsx", "x")
        home.write("tree/src/__tests__/ChartState.tsx", "x")
        home.write("tree/node_modules/lib/Chart.test.tsx", "x")
        let text = ReviewGather.testFilesText(["src/Chart.tsx", "src/Other.ts"], worktree: home.url.appending(path: "tree"))
        #expect(text.contains("`src/Chart.tsx`: `src/Chart.test.tsx`, `src/__tests__/ChartState.tsx`"))
        #expect(!text.contains("node_modules"))
        #expect(text.contains("No test file by name: `src/Other.ts`"))
    }

    @Test func fetchPromptSkipsWhatGitKnows() throws {
        var spec = try ReviewRuns.plan(mr: FakeMergeRequest.ref, project: nil, choices: ReviewRunChoices(), env: TempHome().env, brain: nil)
        let plain = ReviewPrompts.fetch(spec: spec)
        #expect(plain.contains("diffs_first") && plain.contains("Spend at most 25 calls"))
        spec.repository = ReviewRepository.Use(clone: "/x", owned: true, branch: nil,
                                               plan: .init(head: "a1b2c3d4", base: "b1b2c3d4", files: ["a.ts"], earlier: ["a.ts": [12, 8]]))
        let planned = ReviewPrompts.fetch(spec: spec)
        #expect(!planned.contains("diffs_first") && planned.contains("Don't read the diff versions or the changed files' diffs"))
        #expect(!planned.contains("Its diff versions") && plain.contains("skip the versions when no tool reads them"))
        #expect(planned.contains("!12, !8") && !planned.contains("Spend at most 25 calls"))
    }
}

extension ReviewProcessTests {
    struct RepositoryTests {
        /// A "GitLab" repository: main with an earlier merge request, the merge request's head
        /// under refs/merge-requests/7/head.
        func remote(_ home: TempHome) throws -> (url: URL, head: String) {
            let repo = home.url.appending(path: "remote/app")
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            home.git(repo, "init", "-q", "-b", "main")
            home.write("remote/app/src/Auth.swift", "import Foundation\nfunc auth(header: String) {\n}\n")
            home.git(repo, "add", "src")
            home.git(repo, "commit", "-q", "-m", "Add auth\n\nSee merge request team/app!3")
            home.git(repo, "checkout", "-q", "-b", "fix/COL-41-auth-log")
            home.write("remote/app/src/Auth.swift", "import Foundation\nfunc auth(header: String) {\n    log(\"Auth: \\(header)\")\n}\n")
            home.git(repo, "commit", "-q", "-am", "Log auth")
            let head = home.git(repo, "rev-parse", "HEAD")
            home.git(repo, "checkout", "-q", "main")
            home.git(repo, "update-ref", "refs/merge-requests/7/head", head)
            return (repo, head)
        }

        @Test func ownCloneBranchSetupAndRemoval() async throws {
            let home = TempHome()
            let (remote, head) = try remote(home)
            let clone = try #require(ReviewRepository.folder(home: home.url, host: "https://gitlab.test", projectPath: "team/app"))
            // The first clone from a local "GitLab"; every run after it fetches.
            #expect(await ReviewRepository.ensureClone(at: clone, urls: [remote.path], iid: 7, env: home.env, progress: { _ in }) == nil)
            home.write(".akit/local/review/projects/app.yaml", """
            gitlab: { host: https://gitlab.test, project_path: team/app }
            setup: ["echo installed > installed.txt"]
            """)
            FakeMergeRequest.serve(home, head: head, diff: "@@ -1,3 +1,4 @@\n import Foundation\n func auth(header: String) {\n+    log(\"Auth: \\(header)\")\n }\n")
            try ReviewRunFixture.prepare(home)
            var choices = ReviewRunFixture.choices
            choices.setup = ["test -f installed.txt", "false", "echo never"]
            let result = try await ReviewRuns.start(mr: FakeMergeRequest.ref, project: nil, choices: choices, env: home.env, brain: nil)
            let folder = ReviewPaths(home: home.url).run(result.spec.id)
            let worktree = folder.appending(path: "worktree")
            let branch = "akit-review/\(result.spec.id)"
            #expect(result.spec.repository?.owned == true && result.spec.repository?.branch == branch)
            #expect(result.spec.repository?.plan?.head == head)
            #expect(result.spec.repository?.plan?.earlier["src/Auth.swift"] == [3])
            #expect(home.git(clone, "branch", "--list", branch).contains(branch))
            #expect(FileManager.default.fileExists(atPath: worktree.appending(path: "installed.txt").path))
            let setup = try String(contentsOf: folder.appending(path: "context/setup.md"), encoding: .utf8)
            #expect(setup.contains("`test -f installed.txt`: done") && setup.contains("`false`: failed") && setup.contains("Not run after it: `echo never`"))
            #expect(result.gaps.contains { $0.system == "setup" && $0.needed == "Setup command run-setup-2" })
            let history = try String(contentsOf: folder.appending(path: "context/history.md"), encoding: .utf8)
            #expect(history.contains("`src/Auth.swift`: !3"))
            let args = try String(contentsOf: home.url.appending(path: "fake/args-fetch.txt"), encoding: .utf8)
            #expect(args.contains("or the changed files' diffs") && args.contains("!3"))

            await ReviewGather.removeWorktree(run: folder, env: home.env)
            #expect(!FileManager.default.fileExists(atPath: worktree.path))
            #expect(home.git(clone, "branch", "--list", branch).isEmpty)
            #expect(!home.git(clone, "worktree", "list").contains(worktree.path))
        }

        /// R61: a run unused for 14 days loses its worktree and branch; restoring makes both
        /// again at the same commit and runs the setup commands.
        @Test func cleanupRemovesOldWorktreesAndRestoreMakesThemAgain() async throws {
            let home = TempHome()
            let (remote, head) = try remote(home)
            let clone = try #require(ReviewRepository.folder(home: home.url, host: "https://gitlab.test", projectPath: "team/app"))
            #expect(await ReviewRepository.ensureClone(at: clone, urls: [remote.path], iid: 7, env: home.env, progress: { _ in }) == nil)
            home.write(".akit/local/review/projects/app.yaml", """
            gitlab: { host: https://gitlab.test, project_path: team/app }
            setup: ["echo installed > installed.txt"]
            """)
            FakeMergeRequest.serve(home, head: head, diff: "@@ -1,3 +1,4 @@\n import Foundation\n func auth(header: String) {\n+    log(\"Auth: \\(header)\")\n }\n")
            try ReviewRunFixture.prepare(home)
            let result = try await ReviewRuns.start(mr: FakeMergeRequest.ref, project: nil, choices: ReviewRunFixture.choices, env: home.env, brain: nil)
            let folder = ReviewPaths(home: home.url).run(result.spec.id)
            let worktree = folder.appending(path: "worktree")
            let branch = "akit-review/\(result.spec.id)"
            #expect(FileManager.default.fileExists(atPath: worktree.appending(path: "installed.txt").path))

            // Used today: nothing to remove.
            #expect(ReviewCleanup.candidates(home: home.url).isEmpty)
            let old = Date.now.addingTimeInterval(-20 * 86_400)
            for file in FileWalk.children(of: folder) where !file.hasDirectoryPath {
                try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
            }
            #expect(ReviewCleanup.candidates(home: home.url).map(\.id) == [result.spec.id])
            #expect(ReviewCleanup.candidates(home: home.url, skip: [result.spec.id]).isEmpty)
            #expect(ReviewCleanup.candidates(home: home.url, days: 30).isEmpty)

            let pruned = await ReviewCleanup.pruneOld(env: home.env)
            #expect(pruned.map(\.id) == [result.spec.id] && pruned[0].bytes > 0)
            #expect(!FileManager.default.fileExists(atPath: worktree.path))
            #expect(home.git(clone, "branch", "--list", branch).isEmpty)
            #expect(FileManager.default.fileExists(atPath: folder.appending(path: "run.json").path))
            #expect(try ReviewWorkflow.load(folder).removed?.worktrees == ["worktree"])
            #expect(ReviewCleanup.removed(folder)?.days == 14)
            #expect(ReviewCleanup.candidates(home: home.url).isEmpty)

            let restored = await ReviewCleanup.restore(folder, env: home.env)
            #expect(restored == nil)
            #expect(home.git(worktree, "rev-parse", "HEAD") == head)
            #expect(home.git(clone, "branch", "--list", branch).contains(branch))
            #expect(FileManager.default.fileExists(atPath: worktree.appending(path: "installed.txt").path))
            #expect(ReviewCleanup.removed(folder) == nil)
            // Restored counts as used.
            #expect(ReviewCleanup.candidates(home: home.url).isEmpty)
            #expect(await ReviewCleanup.prune(folder, env: home.env) == nil)
            #expect(FileManager.default.fileExists(atPath: worktree.appending(path: ".git").path))
        }

        /// R65: a new run of the merge request takes the earlier run's worktree: a push is pulled,
        /// a rewritten branch is reset to origin; the earlier run can make a new one.
        @Test func newRunTakesTheEarlierWorktreeAndUpdatesIt() async throws {
            let home = TempHome()
            let (remote, head) = try remote(home)
            let clone = try #require(ReviewRepository.folder(home: home.url, host: "https://gitlab.test", projectPath: "team/app"))
            #expect(await ReviewRepository.ensureClone(at: clone, urls: [remote.path], iid: 7, env: home.env, progress: { _ in }) == nil)
            home.write(".akit/local/review/projects/app.yaml", "gitlab: { host: https://gitlab.test, project_path: team/app }\n")
            let diff = "@@ -1,3 +1,4 @@\n import Foundation\n func auth(header: String) {\n+    log(\"Auth: \\(header)\")\n }\n"
            FakeMergeRequest.serve(home, head: head, diff: diff)
            try ReviewRunFixture.prepare(home)
            let first = try await ReviewRuns.start(mr: FakeMergeRequest.ref, project: nil, choices: ReviewRunFixture.choices, env: home.env, brain: nil)
            let firstFolder = ReviewPaths(home: home.url).run(first.spec.id)
            #expect(first.spec.repository?.reusedFrom == nil)
            // Something only this worktree has: installed packages, say.
            home.write(".akit/local/review/runs/\(first.spec.id)/worktree/node_modules.txt", "kept")

            // The author pushes once more: the next run pulls it.
            home.git(remote, "checkout", "-q", "fix/COL-41-auth-log")
            home.write("remote/app/src/Auth.swift", "import Foundation\nfunc auth(header: String) {\n    log(\"Auth: \\(header)\")\n    check()\n}\n")
            home.git(remote, "commit", "-q", "-am", "Check auth")
            let pushed = home.git(remote, "rev-parse", "HEAD")
            home.git(remote, "update-ref", "refs/merge-requests/7/head", pushed)
            FakeMergeRequest.serve(home, head: pushed, diff: diff)
            try await Task.sleep(for: .seconds(1.1))   // a new run id (seconds)
            let lines = LockedBox<[String]>([])
            let second = try await ReviewRuns.start(mr: FakeMergeRequest.ref, project: nil, choices: ReviewRunFixture.choices, env: home.env,
                                                    brain: nil, options: .init(progress: { line in lines.update { $0.append(line) } }))
            let secondTree = ReviewPaths(home: home.url).run(second.spec.id).appending(path: "worktree")
            #expect(second.spec.repository?.reusedFrom == first.spec.id)
            #expect(home.git(secondTree, "rev-parse", "HEAD") == pushed)
            #expect(FileManager.default.fileExists(atPath: secondTree.appending(path: "node_modules.txt").path))
            #expect(lines.value.contains { $0.contains("(pull)") }, "\(lines.value)")
            #expect(home.git(clone, "branch", "--list", "akit-review/\(second.spec.id)").contains(second.spec.id))
            #expect(home.git(clone, "branch", "--list", "akit-review/\(first.spec.id)").isEmpty)
            #expect(!FileManager.default.fileExists(atPath: firstFolder.appending(path: "worktree").path))
            #expect(ReviewCleanup.removed(firstFolder)?.movedTo == second.spec.id)

            // A setup command rewrote a tracked file: the next run doesn't read that edit.
            home.write(".akit/local/review/runs/\(second.spec.id)/worktree/src/Auth.swift", "edited by setup\n")
            // The author rewrites the branch: the pull fails, the reset to origin takes the new head.
            home.write("remote/app/src/Auth.swift", "import Foundation\nfunc auth(header: String) {\n    log(\"Auth!\")\n}\n")
            home.git(remote, "commit", "-q", "--amend", "-am", "Check auth, rewritten")
            let rewritten = home.git(remote, "rev-parse", "HEAD")
            home.git(remote, "update-ref", "refs/merge-requests/7/head", rewritten)
            FakeMergeRequest.serve(home, head: rewritten, diff: diff)
            try await Task.sleep(for: .seconds(1.1))
            lines.update { $0 = [] }
            let third = try await ReviewRuns.start(mr: FakeMergeRequest.ref, project: nil, choices: ReviewRunFixture.choices, env: home.env,
                                                   brain: nil, options: .init(progress: { line in lines.update { $0.append(line) } }))
            let thirdTree = ReviewPaths(home: home.url).run(third.spec.id).appending(path: "worktree")
            #expect(third.spec.repository?.reusedFrom == second.spec.id)
            #expect(home.git(thirdTree, "rev-parse", "HEAD") == rewritten)
            #expect(lines.value.contains { $0.contains("reset to origin/fix/COL-41-auth-log") }, "\(lines.value)")
            #expect(home.git(thirdTree, "status", "--porcelain", "--untracked-files=no").isEmpty)
            #expect(FileManager.default.fileExists(atPath: thirdTree.appending(path: "node_modules.txt").path))

            // The first run gets a worktree of its own again, at its own commit.
            #expect(await ReviewCleanup.restore(firstFolder, env: home.env) == nil)
            #expect(home.git(firstFolder.appending(path: "worktree"), "rev-parse", "HEAD") == head)
            #expect(home.git(thirdTree, "rev-parse", "HEAD") == rewritten)
        }

        @Test func mergeBaseFromGitWhenGitLabGivesNoRefs() async throws {
            let home = TempHome()
            let (remote, head) = try remote(home)
            let clone = home.url.appending(path: "clone")
            #expect(await ReviewRepository.ensureClone(at: clone, urls: [remote.path], iid: 7, env: home.env, progress: { _ in }) == nil)
            let source = ReviewRepository.Source(checkout: clone, owned: true)
            let base = await ReviewRepository.mergeBase(source, head: head, target: "main", env: home.env)
            #expect(base == home.git(remote, "rev-parse", "main"))
            let plan = await ReviewRepository.plan(source, ref: FakeMergeRequest.ref, env: home.env)
            #expect(plan?.head == head && plan?.files == ["src/Auth.swift"])
        }
    }
}
