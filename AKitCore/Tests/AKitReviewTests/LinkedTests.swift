import AKitFoundation
@testable import AKitReview
import Foundation
import Testing

struct LinkedTests {
    static let app = "https://gitlab.test/team/app/-/merge_requests/7"
    static let api = "https://gitlab.test/team/api/-/merge_requests/7"

    @Test func readsTheMergeRequestList() throws {
        let entries = try ReviewLinked.entries("\(Self.app)\n\n  \(Self.api) a1b2c3d  \nhttps://gitlab.test/web/app/-/merge_requests/3@0123456789abcdef\n")
        #expect(entries.map(\.mergeRequest.label) == ["team/app!7", "team/api!7", "web/app!3"])
        #expect(entries.map(\.fromCommit) == [nil, "a1b2c3d", "0123456789abcdef"])
        #expect(throws: ReviewLinked.Failure.self) { try ReviewLinked.entries("\(Self.app)\n\(Self.app)/diffs") }
        #expect(throws: ReviewLinked.Failure.self) { try ReviewLinked.entries("\(Self.app) main") }
        #expect(throws: ReviewLinked.Failure.self) { try ReviewLinked.entries("\(Self.app) a1b2c3d extra") }
        #expect(throws: ReviewLinked.Failure.self) { try ReviewLinked.entries("not a link") }
        #expect(throws: ReviewLinked.Failure.self) {
            try ReviewLinked.entries((1...7).map { "https://gitlab.test/team/app/-/merge_requests/\($0)" }.joined(separator: "\n"))
        }
    }

    @Test func keysAndPaths() throws {
        let main = try #require(MergeRequestRef.parse(Self.app))
        let refs = try [Self.api, "https://gitlab.test/web/app/-/merge_requests/3", "https://gitlab.test/x/API/-/merge_requests/1"]
            .map { try #require(MergeRequestRef.parse($0)) }
        #expect(ReviewLinked.keys(main: main, linked: refs) == ["api", "app-2", "api-2"], "never the first's name, never twice")
        #expect(ReviewLinked.split("@api/src/routes.ts")! == ("api", "src/routes.ts"))
        #expect(ReviewLinked.split("src/@api/x.ts") == nil && ReviewLinked.split("@api") == nil && ReviewLinked.split(nil) == nil)
        #expect(ReviewLinked.path("api", "src/a.ts") == "@api/src/a.ts")
    }

    /// From a commit: a finding off the lines after it stays in AKit, one on them goes inline.
    @Test func aFindingBeforeTheCommitStaysInAKit() throws {
        var spec = try PlanTests.spec()
        spec.since = ReviewSince(asked: "abc1234", commit: String(repeating: "a", count: 40), changed: ["src/A.swift": [.init(start: 40, end: 41)]])
        var plan = try PlanTests.plan([PlanTests.finding("f1")], spec: spec)
        let placement = try #require(plan.placements.first { $0.findingID == "f1" })
        #expect(placement.place == .onlyInAKit && placement.reason.contains("after abc1234"))
        plan = try PlanTests.plan([PlanTests.finding("f1")], spec: spec, forced: ["f1"])
        #expect(plan.placements.first { $0.findingID == "f1" }?.place == .inline, "moved inline by hand")
        spec.since?.changed = ["src/A.swift": [.init(start: 2, end: 2)]]
        plan = try PlanTests.plan([PlanTests.finding("f1")], spec: spec)
        #expect(plan.placements.first { $0.findingID == "f1" }?.place == .inline)
    }

    /// From a commit: AKit's threads and drafts off the reviewed lines are neither fixed nor gone.
    @Test func threadsAndDraftsBeforeTheCommitStayAlone() throws {
        var spec = try PlanTests.spec()
        spec.since = ReviewSince(asked: "abc1234", commit: String(repeating: "a", count: 40), changed: ["src/A.swift": [.init(start: 40, end: 41)]])
        func position(_ line: Int) -> GitLabPosition {
            GitLabPosition(baseSHA: "b", startSHA: "s", headSHA: "h", oldPath: "src/A.swift", newPath: "src/A.swift", oldLine: nil, newLine: line)
        }
        let old = GitLabDiscussion(id: "t1", notes: [GitLabNote(id: 1, body: "x\n" + ReviewNotes.meta(fingerprint: "fp-old", role: "security", severity: .high, run: "r0"),
                                                               author: "me", resolvable: true, position: position(2))])
        let new = GitLabDiscussion(id: "t2", notes: [GitLabNote(id: 2, body: "y\n" + ReviewNotes.meta(fingerprint: "fp-new", role: "security", severity: .high, run: "r0"),
                                                               author: "me", resolvable: true, position: position(40))])
        let drafts = [GitLabDraft(id: 7, note: "z\n" + ReviewNotes.meta(fingerprint: "fp-d1", role: "bug-hunter", severity: .high, run: "r0"), position: position(2)),
                      GitLabDraft(id: 8, note: "w\n" + ReviewNotes.meta(fingerprint: "fp-d2", role: "bug-hunter", severity: .high, run: "r0"), position: position(41))]
        let plan = try PlanTests.plan([], spec: spec, drafts: drafts, discussions: [old, new])
        #expect(plan.requests.filter { $0.kind == .reply }.map(\.discussionID) == ["t2"], "only the thread on the reviewed lines looks fixed")
        #expect(plan.requests.filter { $0.kind == .delete }.map(\.draftID) == [8])
    }

    /// Only a linked merge request Gather read makes a path linked; a monorepo's own `@scope/…` stays.
    @Test func aScopeFolderOfTheFirstRepositoryIsNotLinked() throws {
        var spec = try PlanTests.spec()
        #expect(ReviewLinked.key(of: "@scope/pkg/index.ts", spec: spec) == nil)
        spec.linked = [ReviewLinkedChange(key: "scope", mergeRequest: FakeMergeRequest.ref)]
        #expect(ReviewLinked.key(of: "@scope/pkg/index.ts", spec: spec) == nil, "not read")
        spec.linked?[0].headSHA = "abc1234"
        #expect(ReviewLinked.key(of: "@scope/pkg/index.ts", spec: spec) == "scope")
        let entries = try ReviewLinked.entries("https://me@gitlab.test/team/app/-/merge_requests/7")
        #expect(entries.first?.mergeRequest.projectPath == "team/app" && entries.first?.fromCommit == nil)
        #expect(throws: ReviewLinked.Failure.self) { try ReviewLinked.entries("\(Self.app)\nhttps://gitlab.test/Team/App/-/merge_requests/7") }
    }

    /// A linked finding is read from the linked worktree beside the run's.
    @Test func aLinkedFileIsReadFromItsWorktree() throws {
        let home = TempHome()
        home.write("run/worktree/.git", "gitdir: x\n")
        home.write("run/worktree/src/a.ts", "main\n")
        home.write("run/linked/api/worktree/.git", "gitdir: y\n")
        home.write("run/linked/api/worktree/src/a.ts", "linked\n")
        let worktree = home.url.appending(path: "run/worktree")
        #expect(ReviewCandidates.fileLines("src/a.ts", worktree: worktree) == ["main", ""])
        #expect(ReviewCandidates.fileLines("@api/src/a.ts", worktree: worktree) == ["linked", ""])
        #expect(ReviewCandidates.fileLines("@api/../../x", worktree: worktree) == nil)
        #expect(ReviewCandidates.fileLines("@web/src/a.ts", worktree: worktree) == nil, "no such linked worktree")
        // The fingerprint is the repository's: the same as a review of that merge request alone.
        let finding = PlanTests.finding("f1", file: "@api/src/a.ts", line: 1)
        var alone = finding
        alone.file = "src/a.ts"
        #expect(ReviewCandidates.fingerprint(finding, worktree: worktree)
                == ReviewCandidates.fingerprint(alone, worktree: home.url.appending(path: "run/linked/api/worktree")))
    }
}

extension ReviewProcessTests {
    struct LinkedRunTests {
        static let apiRef = MergeRequestRef(host: "https://gitlab.test", projectPath: "team/api", iid: 7)

        /// The first merge request (`team/app!7`) and a linked one in another project with the same
        /// number (`team/api!7`), each with its checkout and profile.
        func setUp() throws -> (home: TempHome, head: String, apiHead: String) {
            let (home, head) = try GatherTests().setUp()
            let repo = home.url.appending(path: "work/api")
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            home.git(repo, "init", "-q", "-b", "main")
            home.write("work/api/src/routes.ts", "export const routes = {\n  orders: \"/v2/orders\",\n};\n")
            home.git(repo, "add", "src")
            home.git(repo, "commit", "-q", "-m", "Add routes")
            let apiHead = home.git(repo, "rev-parse", "HEAD")
            home.write(".akit/local/review/projects/api.yaml", """
            gitlab: { host: https://gitlab.test, project_path: team/api }
            checkout: ~/work/api
            """)
            FakeMergeRequest.serve(home, head: apiHead, diff: "@@ -1,2 +1,3 @@\n export const routes = {\n+  orders: \"/v2/orders\",\n };\n",
                                   path: "src/routes.ts", workItems: false, branch: "feature/orders-v2", ref: Self.apiRef, pass: "fetch-api")
            return (home, head, apiHead)
        }

        @Test func aLinkedMergeRequestIsReviewedWithTheFirst() async throws {
            let (home, head, apiHead) = try setUp()
            var choices = ReviewRunFixture.choices
            choices.linked = [ReviewMergeRequestEntry(mergeRequest: Self.apiRef)]
            let result = try await ReviewRuns.start(mr: FakeMergeRequest.ref, project: nil, choices: choices, env: home.env, brain: nil)
            let folder = ReviewPaths(home: home.url).run(result.spec.id)
            let linked = try #require(result.spec.linked?.first)
            #expect(linked.key == "api" && linked.project == "api" && linked.headSHA == apiHead)
            #expect(result.spec.headSHA == head && result.snapshot.mergeRequest.webURL.contains("/team/app/"), "the same iid never mixes")
            #expect(!result.snapshot.diffs.contains { $0.newPath.contains("routes") })
            func context(_ name: String) throws -> String { try String(contentsOf: folder.appending(path: "context/\(name)"), encoding: .utf8) }
            #expect(try context("linked/api/diff.patch").contains("+++ b/@api/src/routes.ts"))
            #expect(try context("linked/api/merge-request.md").contains("@api/<path>"))
            #expect(try context("README.md").contains("linked/api/diff.patch"))
            #expect(FileManager.default.fileExists(atPath: ReviewLinked.worktree(folder, key: "api").appending(path: "src/routes.ts").path))
            let linkedSnapshot = try #require(ReviewJSON.read(ReviewSnapshot.self, from: ReviewLinked.snapshotFile(folder, key: "api")))
            #expect(linkedSnapshot.mergeRequest.webURL.contains("/team/api/") && linkedSnapshot.refs?.headSHA == apiHead)
            #expect(try String(contentsOf: folder.appending(path: "prompts/fetch-api.md"), encoding: .utf8).contains("project `team/api`"))

            let run = ReviewRunFixture(home: home, head: head, folder: folder)
            run.fake("role-bug-hunter", """
            {"findings":[
              {"file":"src/Auth.swift","line":3,"side":"new","title":"Hlavička se celá zapisuje do logu","evidence":"log(\\"Auth: \\\\(header)\\")",
               "why":"Token se dostane do logu","severity":"high","confidence":0.9},
              {"file":"@api/src/routes.ts","line":2,"side":"new","title":"Frontend volá starou cestu","evidence":"orders: \\"/v2/orders\\",",
               "why":"Aplikace stále volá /v1/orders, které API už nemá","severity":"high","confidence":0.9}
            ]}
            """)
            run.fake("verifier", """
            {"verdicts":[{"id":"f1","verdict":"confirmed","note":"ano","confidence":0.95},{"id":"f2","verdict":"confirmed","note":"ano","confidence":0.95}]}
            """)
            try await ReviewPasses.run(folder: folder, env: home.env)
            let system = try String(contentsOf: folder.appending(path: "prompts/system.md"), encoding: .utf8)
            #expect(system.contains("`@api/<path>`") && system.contains("../linked/api/worktree/<path>"))
            let env = try String(contentsOf: home.url.appending(path: "fake/env-role-bug-hunter.txt"), encoding: .utf8)
            #expect(env.contains(ReviewLinked.worktree(folder, key: "api").path), "the roles may read the linked worktree")
            let findings = try #require(ReviewWorkflow.load(folder).findings?.findings)
            #expect(findings.first { $0.file == "@api/src/routes.ts" }?.evidenceFound == true, "the quote is checked in the linked file")

            let plan = try #require(ReviewWorkflow.load(folder).plan)
            #expect(plan.requests.map(\.kind) == [.create, .summary, .create, .summary])
            let apiCreate = plan.requests[2]
            #expect(apiCreate.mergeRequest == Self.apiRef && apiCreate.file == "@api/src/routes.ts")
            #expect(apiCreate.position?.newPath == "src/routes.ts" && apiCreate.position?.headSHA == apiHead && apiCreate.position?.newLine == 2)
            #expect(plan.requests[0].mergeRequest == nil && plan.requests[0].position?.headSHA == head)
            #expect(plan.requests[3].mergeRequest == Self.apiRef && plan.requests[3].proposed.contains(String(apiHead.prefix(10))))

            try ReviewWorkflow.decide(folder, request: apiCreate.id, decision: .approved)
            home.write("fake/send-log.jsonl", #"{"request":"\#(apiCreate.id)","tool":"mcp__gitlab__create_draft_note","isError":false,"text":"{\"id\": 77}"}"# + "\n")
            let report = try await ReviewWorkflow.send(folder, env: home.env)
            #expect(report.sent == [apiCreate.id] && report.failed.isEmpty)
            let data = try Data(contentsOf: home.url.appending(path: "fake/approved-send-1.json"))
            let approved = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
            let mr = try #require(approved.first?["mr"] as? [String: Any])
            #expect(mr["iid"] as? Int == 7 && (mr["projects"] as? [Any])?.first as? String == "team/api")
            #expect(approved.first?["path"] as? String == "src/routes.ts")
            let prompt = try String(contentsOf: folder.appending(path: "prompts/send-1.md"), encoding: .utf8)
            #expect(prompt.contains("project `team/api`") && !prompt.contains("project `team/app`"))
            let after = try #require(ReviewJSON.read(ReviewSnapshot.self, from: ReviewLinked.snapshotFile(folder, key: "api")))
            #expect(after.drafts.map(\.id) == [77], "the linked snapshot learns its draft")
            #expect(try ReviewWorkflow.load(folder).snapshot?.drafts.isEmpty == true)

            // Planned again (Move Inline, a discussion): the sent draft isn't proposed again.
            let again = try await ReviewWorkflow.plan(folder, env: home.env)
            #expect(!again.requests.contains { $0.mergeRequest == Self.apiRef && $0.kind == .create && !$0.isSent })

            // Deleting the run takes the linked worktree out of its clone too.
            await ReviewLinked.removeWorktrees(run: folder, env: home.env)
            #expect(!FileManager.default.fileExists(atPath: ReviewLinked.worktree(folder, key: "api").path))
            #expect(home.git(home.url.appending(path: "work/api"), "worktree", "list").split(separator: "\n").count == 1)
        }

        /// A linked merge request that can't be read is a gap; the first is still reviewed.
        @Test func anUnreadableLinkedMergeRequestIsAGap() async throws {
            let (home, _, _) = try setUp()
            try FileManager.default.removeItem(at: home.url.appending(path: "fake/calls-fetch-api"))
            var choices = ReviewRunFixture.choices
            choices.linked = [ReviewMergeRequestEntry(mergeRequest: Self.apiRef, fromCommit: "abcdef1")]
            let result = try await ReviewRuns.start(mr: FakeMergeRequest.ref, project: nil, choices: choices, env: home.env, brain: nil)
            #expect(result.spec.linked?.first?.headSHA == nil)
            #expect(result.gaps.contains { $0.needed == "The linked merge request team/api!7" })
            #expect(!result.snapshot.diffs.isEmpty)
        }

        /// From a commit: Gather resolves it in the worktree and lists the lines after it.
        @Test func fromACommitListsTheLinesAfterIt() async throws {
            let (home, first) = try GatherTests().setUp()
            let repo = home.url.appending(path: "work/app")
            home.write("work/app/src/Auth.swift", "import Foundation\nfunc auth(header: String) {\n    log(\"Auth header: \\(header)\")\n}\n")
            home.git(repo, "commit", "-q", "-am", "Change the log")
            let head = home.git(repo, "rev-parse", "HEAD")
            FakeMergeRequest.serve(home, head: head, diff: "@@ -1,3 +1,4 @@\n import Foundation\n func auth(header: String) {\n+    log(\"Auth header: \\(header)\")\n }\n")
            var choices = ReviewRunFixture.choices
            choices.fromCommit = String(first.prefix(8))
            let result = try await ReviewRuns.start(mr: FakeMergeRequest.ref, project: nil, choices: choices, env: home.env, brain: nil)
            let since = try #require(result.spec.since)
            #expect(since.commit == first && since.asked == String(first.prefix(8)))
            #expect(since.changed["src/Auth.swift"] == [.init(start: 3, end: 3)])
            let folder = ReviewPaths(home: home.url).run(result.spec.id)
            #expect(try String(contentsOf: folder.appending(path: "context/since-commit.md"), encoding: .utf8).contains("`src/Auth.swift`: lines 3"))
            #expect(ReviewPrompts.system(spec: result.spec, hasWorktree: true).contains("context/since-commit.md"))

            // A commit that isn't part of the merge request: the whole merge request, with a gap.
            choices.fromCommit = "deadbeef"
            let other = try await ReviewRuns.start(mr: FakeMergeRequest.ref, project: nil, choices: choices, env: home.env, brain: nil)
            #expect(other.spec.since == nil && other.gaps.contains { $0.needed == "The changes after deadbeef" })
            choices.fromCommit = "main"
            await #expect(throws: ReviewRuns.Failure.self) {
                _ = try await ReviewRuns.start(mr: FakeMergeRequest.ref, project: nil, choices: choices, env: home.env, brain: nil)
            }
        }
    }
}
