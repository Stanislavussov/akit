import AKitFoundation
@testable import AKitReview
import Foundation
import Testing

/// A merge request reviewed before: GitLab is asked only for what can change (`ReviewReuse`).
extension ReviewProcessTests {
    struct ReuseTests {
        static let diff = "@@ -1,3 +1,4 @@\n import Foundation\n func auth(header: String) {\n+    log(\"Auth: \\(header)\")\n }\n"

        func again(_ run: ReviewRunFixture) async throws -> URL {
            try await Task.sleep(for: .seconds(1.1))   // a new run id (seconds)
            try? FileManager.default.removeItem(at: run.home.url.appending(path: "fake/args-fetch.txt"))
            let second = try await ReviewRuns.start(mr: FakeMergeRequest.ref, project: nil, choices: ReviewRunFixture.choices, env: run.home.env, brain: nil)
            return ReviewPaths(home: run.home.url).run(second.spec.id)
        }

        func spec(_ folder: URL) throws -> ReviewRunSpec {
            try #require(ReviewJSON.read(ReviewRunSpec.self, from: folder.appending(path: "run.json")))
        }

        /// AKit's own clone fetches the merge request's head before each run (a push shows), and
        /// git's head decides: the same head reads nothing from GitLab, a new one only the merge request.
        @Test func theSameHeadAfterNoSendRunsNoFetchPass() async throws {
            let home = TempHome()
            let (remote, head) = try RepositoryTests().remote(home)
            let clone = try #require(ReviewRepository.folder(home: home.url, host: "https://gitlab.test", projectPath: "team/app"))
            #expect(await ReviewRepository.ensureClone(at: clone, urls: [remote.path], iid: 7, env: home.env, progress: { _ in }) == nil)
            home.write(".akit/local/review/projects/app.yaml", "gitlab: { host: https://gitlab.test, project_path: team/app }\n")
            FakeMergeRequest.serve(home, head: head, diff: Self.diff)
            try ReviewRunFixture.prepare(home)
            func start(full: Bool = false) async throws -> URL {
                try? FileManager.default.removeItem(at: home.url.appending(path: "fake/args-fetch.txt"))
                var choices = ReviewRunFixture.choices
                choices.fullReview = full
                let run = try await ReviewRuns.start(mr: FakeMergeRequest.ref, project: nil, choices: choices, env: home.env, brain: nil)
                return ReviewPaths(home: home.url).run(run.spec.id)
            }
            let first = try await start()
            #expect(try spec(first).gatherReused == nil, "the first review reads everything")

            try await Task.sleep(for: .seconds(1.1))   // a new run id (seconds)
            let same = try await start()
            let reused = try #require(try spec(same).gatherReused)
            let firstSnapshot = try #require(ReviewJSON.read(ReviewSnapshot.self, from: first.appending(path: "gitlab/snapshot.json")))
            #expect(reused.run == first.lastPathComponent && reused.whole && reused.hasUser && reused.linksRead.isEmpty)
            #expect(reused.answered == firstSnapshot.gathered, "the answers keep their own time")
            #expect(!FileManager.default.fileExists(atPath: home.url.appending(path: "fake/args-fetch.txt").path), "no fetch pass")
            #expect(try spec(same).headSHA == head)
            let snapshot = try #require(ReviewJSON.read(ReviewSnapshot.self, from: same.appending(path: "gitlab/snapshot.json")))
            #expect(snapshot.mergeRequest.title == "AB#41 Log less in auth" && snapshot.user == "me" && snapshot.discussions.count == 2)
            #expect(snapshot.gathered == firstSnapshot.gathered)
            #expect(FileManager.default.fileExists(atPath: same.appending(path: "context/work-items.md").path))
            // A day later the same head reads the merge request again: people may have changed drafts or threads.
            let later = try #require(ReviewReuse.plan(folder: same, spec: spec(same), home: home.url, now: firstSnapshot.gathered + ReviewReuse.maxWholeAge + 1))
            #expect(!later.whole && later.answered == nil)
            // Full review reads GitLab again.
            let full = try spec(same)
            var asked = full
            asked.fullReview = true
            #expect(ReviewReuse.plan(folder: same, spec: asked, home: home.url)?.whole == false)
            // The first run sends its drafts after the second copied its answers: no run takes them whole any more.
            home.write(".akit/local/review/runs/\(first.lastPathComponent)/send/log.jsonl", #"{"request":"r1","tool":"x","isError":false}"# + "\n")
            try await Task.sleep(for: .seconds(1.1))
            let afterSend = try await start()
            #expect(try spec(afterSend).gatherReused?.whole == false && spec(afterSend).gatherReused?.run == same.lastPathComponent)
            #expect(FileManager.default.fileExists(atPath: home.url.appending(path: "fake/args-fetch.txt").path))
            #expect(ReviewMCPData.calls(in: same, pass: "fetch").count == ReviewMCPData.calls(in: first, pass: "fetch").count)

            // The author pushes: git sees it, so the fetch pass runs, for the merge request only.
            home.git(remote, "checkout", "-q", "fix/COL-41-auth-log")
            home.write("remote/app/src/Auth.swift", "import Foundation\nfunc auth(header: String) {\n    log(\"Auth: \\(header)\")\n    check()\n}\n")
            home.git(remote, "commit", "-q", "-am", "Check auth")
            let pushed = home.git(remote, "rev-parse", "HEAD")
            home.git(remote, "update-ref", "refs/merge-requests/7/head", pushed)
            FakeMergeRequest.serve(home, head: pushed, diff: Self.diff, workItems: false)
            try await Task.sleep(for: .seconds(1.1))
            let after = try await start()
            #expect(try spec(after).gatherReused?.whole == false && spec(after).gatherReused?.run == afterSend.lastPathComponent)
            #expect(FileManager.default.fileExists(atPath: home.url.appending(path: "fake/args-fetch.txt").path), "the fetch pass ran")
            #expect(try spec(after).headSHA == pushed)
            let items = try String(contentsOf: after.appending(path: "context/work-items.md"), encoding: .utf8)
            #expect(items.contains("Token in logs"), "the work items come from the earlier run")
        }

        /// The earlier run sent drafts: its threads and drafts are old. The fetch pass reads them
        /// again, and only them; the work items and the user come from the earlier run.
        @Test func afterASendOnlyTheMergeRequestIsReadAgain() async throws {
            let run = try await ReviewRunFixture.make()
            run.home.write(".akit/local/review/runs/\(run.folder.lastPathComponent)/send/log.jsonl", #"{"request":"r1","tool":"x","isError":false}"# + "\n")
            let draft: [String: Any] = ["id": 501, "note": "🤖 a draft", "author_id": 5, "position": [
                "position_type": "text", "base_sha": "b1b1b1b1", "start_sha": "c1c1c1c1", "head_sha": run.head,
                "old_path": "src/Auth.swift", "new_path": "src/Auth.swift", "new_line": 3]]
            // GitLab now answers with the draft and without the tracker's items: those must come from the earlier run.
            FakeMergeRequest.serve(run.home, head: run.head, diff: Self.diff, drafts: [draft], workItems: false)
            let folder = try await again(run)

            let second = try spec(folder)
            #expect(second.gatherReused?.whole == false && second.gatherReused?.run == run.folder.lastPathComponent)
            let prompt = try String(contentsOf: folder.appending(path: "prompts/fetch.md"), encoding: .utf8)
            #expect(prompt.contains("Nothing from the tracker") && prompt.contains("AKit knows the signed-in user"))
            #expect(prompt.contains("3. Every discussion thread") && prompt.contains("4. Your own pending draft notes"))
            let snapshot = try #require(ReviewJSON.read(ReviewSnapshot.self, from: folder.appending(path: "gitlab/snapshot.json")))
            #expect(snapshot.drafts.map(\.id) == [501], "the new answer, no stale copy")
            #expect(snapshot.discussions.count == 2, "no thread twice")
            let items = try String(contentsOf: folder.appending(path: "context/work-items.md"), encoding: .utf8)
            #expect(items.contains("Token in logs") && items.contains("Auth hardening"))
        }

        /// What a push or a comment changes is never copied when only part is reused.
        @Test func onlyAnswersAboutTheMergeRequestAreFresh() async throws {
            let run = try await ReviewRunFixture.make()
            let spec = try spec(run.folder)
            let calls = ReviewMCPData.calls(in: run.folder, pass: "fetch")
            let fresh = Set(calls.filter { ReviewReuse.isFresh($0, spec: spec) }.map(\.tool))
            #expect(fresh == ["mcp__gitlab__get_merge_request", "mcp__gitlab__list_merge_request_versions",
                              "mcp__gitlab__get_merge_request_diffs", "mcp__gitlab__mr_discussions"], "\(fresh)")
            let failed = ReviewMCPCall(pass: "fetch", tool: "mcp__gitlab__mr_discussions", input: FakeMergeRequest.input, text: ["500"],
                                       structured: nil, isError: true)
            let failedItem = ReviewMCPCall(pass: "fetch", tool: "mcp__azure_devops__wit_get_work_item", input: #"{"id":40}"#, text: ["404"],
                                           structured: nil, isError: true)
            let prose = ReviewMCPCall(pass: "fetch", tool: "akit_submit_context", input: "{}", text: ["The MR has 3 threads"], structured: nil, isError: false)
            #expect(ReviewReuse.isFresh(failed, spec: spec) && ReviewReuse.isFresh(failedItem, spec: spec) && ReviewReuse.isFresh(prose, spec: spec),
                    "a failure is tried again, never copied")
        }
    }
}
