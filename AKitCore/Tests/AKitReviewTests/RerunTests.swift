import AKitFoundation
import AKitLab
@testable import AKitReview
import Foundation
import Testing

extension ReviewProcessTests {
    struct DiscussTests {
        @Test func theScriptForksTheVerifierSession() async throws {
            let run = try await ReviewRunFixture.make()
            run.playTypicalRun()
            try await ReviewPasses.run(folder: run.folder, env: run.home.env)
            let script = try await ReviewDiscuss.script(run.folder, env: run.home.env)
            let text = try String(contentsOf: script, encoding: .utf8)
            #expect(text.contains("'--fork'") && text.contains("fork-0001"))
            #expect(text.contains("export AKIT_REVIEW_PASS='discuss'"))
            #expect(text.contains("'fake/strong'") && text.contains("'--no-extensions'") && text.contains("'builtin:mcp'"))
            #expect(text.contains("export AKIT_REVIEW_MODE='review'"))
            #expect(FileManager.default.isExecutableFile(atPath: script.path))
            let syntax = ProcessRunner.runAndWait(URL(filePath: "/bin/sh"), arguments: ["-n", script.path], environment: [:], timeout: 10)
            #expect(syntax?.succeeded == true, "\(syntax?.output ?? "")")
        }

        @Test func aDiscussionMakesANewVersion() async throws {
            let run = try await ReviewRunFixture.make()
            run.playTypicalRun()
            try await ReviewPasses.run(folder: run.folder, env: run.home.env)
            #expect(ReviewDiscuss.pending(run.folder).isEmpty)
            // The developer convinced Pi that f1 is wrong, and Pi found one more problem.
            run.home.write(".akit/local/review/runs/\(run.folder.lastPathComponent)/passes/discuss-1792000000000.json", """
            {"pass":"discuss","verdicts":[{"id":"f1","verdict":"rejected","note":"The log is local only"}],
             "findings":[{"file":"src/Auth.swift","line":2,"title":"auth() has no rate limit","evidence":"func auth(header: String) {",
                          "why":"Brute force","severity":"medium","confidence":0.85}]}
            """)
            #expect(ReviewDiscuss.pending(run.folder).count == 1)
            let changes = try #require(try await ReviewDiscuss.apply(run.folder, env: run.home.env))
            #expect(changes.version == 2)
            #expect(changes.changed == ["f1: confirmed → rejected"])
            #expect(changes.added == ["f3: auth() has no rate limit"])
            let loaded = try ReviewWorkflow.load(run.folder)
            #expect(loaded.findings?.version == 2 && loaded.findings?.source == "discuss")
            #expect(loaded.finding("f2")?.verifier?.verdict == .confirmed, "a finding the discussion didn't mention keeps its verdict")
            #expect(FileManager.default.fileExists(atPath: run.folder.appending(path: "findings-v1.json").path))
            let creates = loaded.plan?.requests.filter { $0.kind == .create }.map(\.findingID)
            #expect(creates == ["f3"], "f1 left the drafts, f3 joined them")
            #expect(loaded.placement("f1")?.place == .onlyInAKit)
            #expect(ReviewDiscuss.pending(run.folder).isEmpty)
            #expect(try await ReviewDiscuss.apply(run.folder, env: run.home.env) == nil)
        }
    }

    struct RerunTests {
        /// After a push: a new run of the same merge request sees the drafts the first one sent.
        @Test func aSecondRunDoesntRepeatItself() async throws {
            let run = try await ReviewRunFixture.make()
            run.playTypicalRun()
            try await ReviewPasses.run(folder: run.folder, env: run.home.env)
            let first = try #require(ReviewWorkflow.load(run.folder).plan?.requests.first { $0.kind == .create })
            try ReviewWorkflow.decide(run.folder, request: first.id, decision: .approved)
            run.home.write("fake/send-log.jsonl", #"{"request":"\#(first.id)","tool":"mcp__gitlab__create_draft_note","isError":false,"text":"{\"id\": 501}"}"# + "\n")
            _ = try await ReviewWorkflow.send(run.folder, env: run.home.env)
            let sent = try Data(contentsOf: run.home.url.appending(path: "fake/approved-send-1.json"))
            let body = try #require((try JSONSerialization.jsonObject(with: sent) as? [[String: Any]])?.first?["body"] as? String)
            // GitLab now holds that draft (as the user's own, pending): the next fetch reads it.
            let draft: [String: Any] = ["id": 501, "note": body, "author_id": 5, "position": [
                "position_type": "text", "base_sha": "b1", "start_sha": "s1", "head_sha": run.head,
                "old_path": "src/Auth.swift", "new_path": "src/Auth.swift", "new_line": 3]]
            FakeMergeRequest.serve(run.home, head: run.head, diff: "@@ -1,3 +1,4 @@\n import Foundation\n func auth(header: String) {\n+    log(\"Auth: \\(header)\")\n }\n",
                                   drafts: [draft])
            run.home.write("fake/send-log.jsonl", "")

            // The same review again: same finding, same fingerprint, same text → no request for it.
            let choices = ReviewRunFixture.choices
            try await Task.sleep(for: .seconds(1.1))   // a new run id (seconds)
            let second = try await ReviewRuns.start(mr: FakeMergeRequest.ref, project: nil, choices: choices, env: run.home.env, brain: nil)
            let folder = ReviewPaths(home: run.home.url).run(second.spec.id)
            try await ReviewPasses.run(folder: folder, env: run.home.env)
            let again = try ReviewWorkflow.load(folder)
            #expect(again.finding("f1")?.fingerprint == first.fingerprint)
            #expect(!(again.plan?.requests ?? []).contains { $0.kind == .create || $0.kind == .update }, "\(again.plan?.requests.map(\.kind) ?? [])")

            // The problem is fixed in a later push: AKit proposes to delete its pending draft.
            run.home.write("fake/role-bug-hunter.json", #"{"findings":[]}"#)
            run.home.write("fake/role-tests.json", #"{"findings":[]}"#)
            try await Task.sleep(for: .seconds(1.1))
            let third = try await ReviewRuns.start(mr: FakeMergeRequest.ref, project: nil, choices: choices, env: run.home.env, brain: nil)
            let thirdFolder = ReviewPaths(home: run.home.url).run(third.spec.id)
            try await ReviewPasses.run(folder: thirdFolder, env: run.home.env)
            let delete = try #require(ReviewWorkflow.load(thirdFolder).plan?.requests.first { $0.kind == .delete })
            #expect(delete.draftID == 501 && delete.decision == .pending)
        }
    }
}
