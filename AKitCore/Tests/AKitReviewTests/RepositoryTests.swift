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
        #expect(!planned.contains("diffs_first") && planned.contains("Don't read the changed files' diffs"))
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
            #expect(args.contains("Don't read the changed files' diffs") && args.contains("!3"))

            await ReviewGather.removeWorktree(run: folder, env: home.env)
            #expect(!FileManager.default.fileExists(atPath: worktree.path))
            #expect(home.git(clone, "branch", "--list", branch).isEmpty)
            #expect(!home.git(clone, "worktree", "list").contains(worktree.path))
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
