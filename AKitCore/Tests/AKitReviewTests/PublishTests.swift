import AKitFoundation
@testable import AKitReview
import Foundation
import Testing

extension ReviewProcessTests {
    /// GitLab's own MCP server has no draft notes, only `save_merge_request_review`, which
    /// publishes at once (R66): its comment methods carry an approved request, but go through only
    /// after the user's Publish Now… (`AKIT_REVIEW_PUBLISH=1`).
    struct PublishTests {
        static let tool = "mcp__gitlab__save_merge_request_review"
        static var mr: [String: Any] { ["projects": ["team/app", 41], "iid": 7] }
        static var position: [String: Any] { ["position_type": "text", "base_sha": "b", "start_sha": "s", "head_sha": "h",
                                              "old_path": "src/A.swift", "new_path": "src/A.swift", "new_line": 3] }
        /// r1 on a diff line, r2 a reply, r3 on the merge request, r4 a draft update.
        static var approved: [[String: Any]] { [
            ["id": "r1", "action": "create", "body": "Text A\n<!-- ai-review:v1 -->", "mr": mr, "position": position, "path": "src/A.swift", "line": 3],
            ["id": "r2", "action": "create", "body": "Reply B", "discussion_id": "abc", "mr": mr],
            ["id": "r3", "action": "create", "body": "Summary C", "mr": mr],
            ["id": "r4", "action": "update", "draft_id": 5, "body": "Changed D", "mr": mr],
        ] }

        static func diffNote(_ change: [String: Any?] = [:]) -> [String: Any] {
            var input: [String: Any?] = ["project_id": "team/app", "merge_request_iid": 7, "method": "create_diff_note", "body": "Text A\n<!-- ai-review:v1 -->",
                                         "old_path": "src/A.swift", "new_path": "src/A.swift", "new_line": 3]
            input.merge(change) { $1 }
            return input.compactMapValues { $0 }
        }

        static var reply: [String: Any] { ["project_id": "41", "merge_request_iid": "7", "method": "reply_discussion", "body": "Reply B",
                                           "discussion_id": "abc"] }
        static var note: [String: Any] { ["project_id": "team/app", "merge_request_iid": 7, "method": "create_note", "body": "Summary C"] }

        /// Calls the extension's `tool_call` (and `tool_result` for a call it lets through) with a fake `pi`.
        static let harness = """
        import { pathToFileURL } from "node:url";
        const mod = await import(pathToFileURL(process.argv[2]).href);
        const handlers = {};
        mod.default({ registerTool() {}, on: (e, h) => { handlers[e] = h; }, appendEntry() {}, getAllTools: () => [] });
        const calls = JSON.parse(process.argv[3]);
        const out = [];
        for (const [i, call] of calls.entries()) {
          const id = "c" + i;
          const r = await handlers.tool_call({ toolName: call.tool, toolCallId: id, input: call.input }, { cwd: process.cwd() });
          out.push(r?.block ? "blocked: " + r.reason : "allowed");
          if (!r?.block) {
            await handlers.tool_result({ toolName: call.tool, toolCallId: id, input: call.input, isError: call.error === true,
              content: [{ type: "text", text: call.error === true ? "timed out" : JSON.stringify({ id: 900 + i }) }] });
          }
        }
        console.log(JSON.stringify(out));
        """

        /// What the extension says to each call, in order.
        func calls(_ home: TempHome, _ calls: [[String: Any]], mode: String = "send", publish: Bool = false) throws -> [String] {
            let node = try #require(ExtensionKnowledgeTests.node, "node is needed: Pi runs on it")
            let run = home.url.appending(path: "run")
            home.write("run/send/approved.json", String(decoding: try JSONSerialization.data(withJSONObject: Self.approved), as: UTF8.self))
            let ext = home.write("ext/akit-review.ts", ReviewExtension.source)
            let harness = home.write("ext/send-harness.mjs", Self.harness)
            var environment = ["PATH": "/usr/bin:/bin", "HOME": home.url.path, "AKIT_REVIEW_RUN": run.path, "AKIT_REVIEW_MODE": mode,
                               "AKIT_REVIEW_PASS": mode == "send" ? "send-1" : "role-x"]
            if publish { environment["AKIT_REVIEW_PUBLISH"] = "1" }
            let list = String(decoding: try JSONSerialization.data(withJSONObject: calls), as: UTF8.self)
            let result = try #require(ProcessRunner.runAndWait(node, arguments: [harness.path, ext.path, list], environment: environment, timeout: 60))
            #expect(result.succeeded, "\(result.output)")
            let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let last = String(text.split(separator: "\n").last ?? "")
            return try #require(try JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String])
        }

        func lines(_ home: TempHome, _ file: String) -> [[String: Any]] {
            ((try? String(contentsOf: home.url.appending(path: "run/\(file)"), encoding: .utf8)) ?? "").split(separator: "\n")
                .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        }

        @Test func thePolicyKnowsThePublishTool() {
            let access = ReviewMCPAccess(extraServers: ["figma"], read: ["*merge_request*"])
            func kind(_ tool: String, server: String = "gitlab", hint: Bool = false, _ access: ReviewMCPAccess = access) -> ReviewMCPPolicy.Kind {
                ReviewMCPPolicy.kind(server: server, tool: tool, readOnlyHint: hint, access: access, inPasses: true)
            }
            #expect(kind("save_merge_request_review") == .publish, "a base server")
            #expect(kind("save_merge_request_review", hint: true) == .publish, "never a read, even marked read-only or matching a read pattern")
            #expect(kind("save_merge_request_review", server: "figma") == .blocked, "a context server never writes")
            #expect(kind("save_merge_request_review", server: "docs", ReviewMCPAccess(allServers: true)) == .blocked, "an open server")
            #expect(kind("save_merge_request_review", server: "docs", hint: true, ReviewMCPAccess(allServers: true)) == .blocked)
            #expect(kind("save_note") == .blocked && kind("save_merge_request_review_x", ReviewMCPAccess()) == .blocked, "only the exact name")
            #expect(kind("create_draft_note") == .write, "draft tools as before")
            #expect(ReviewMCPPolicy.publishMethods == ["create_note", "create_diff_note", "reply_discussion"])
            // The extension has the same rule, before the open-server check.
            #expect(ReviewExtension.source.contains(#"if (tool.toLowerCase() === publishTool) return serverBase(server) ? "publish" : "blocked";"#))
            #expect(ReviewExtension.source.contains(#"const publishMethods = ["create_note", "create_diff_note", "reply_discussion"];"#))
        }

        /// Without the user's yes, a matching call is blocked and logged as needing it; the model is
        /// told not to retry.
        @Test func withoutPublishAMatchingCallWaitsForTheUser() throws {
            let home = TempHome()
            let said = try calls(home, [["tool": Self.tool, "input": Self.diffNote()], ["tool": Self.tool, "input": Self.reply],
                                        ["tool": Self.tool, "input": Self.diffNote(["body": "Other text"])]])
            #expect(said[0].contains("has no draft notes") && said[0].contains("Don't retry"), "\(said)")
            #expect(said[1].contains("has no draft notes"))
            #expect(said[2].contains("another text"), "a call that matches nothing isn't logged")
            let log = lines(home, "send/log.jsonl")
            #expect(log.map { $0["request"] as? String } == ["r1", "r2"])
            #expect(log.allSatisfy { $0["needsPublish"] as? Bool == true && $0["isError"] as? Bool == true && $0["tool"] as? String == Self.tool })
            #expect(lines(home, "mcp/blocked.jsonl").count == 3)
        }

        @Test func withPublishTheCommentMethodsGoThrough() throws {
            let home = TempHome()
            let said = try calls(home, [["tool": Self.tool, "input": Self.diffNote()], ["tool": Self.tool, "input": Self.reply],
                                        ["tool": Self.tool, "input": Self.note], ["tool": Self.tool, "input": Self.note]],
                                 publish: true)
            #expect(Array(said.prefix(3)) == ["allowed", "allowed", "allowed"], "\(said)")
            #expect(said[3].hasPrefix("blocked: "), "each request once")
            // A started line before each answer: a pass that dies mid-call still tells AKit.
            let log = lines(home, "send/log.jsonl")
            #expect(log.map { $0["request"] as? String } == ["r1", "r1", "r2", "r2", "r3", "r3"])
            #expect(log.enumerated().allSatisfy { index, line in
                index % 2 == 0 ? line["started"] as? Bool == true && line["isError"] == nil
                    : line["needsPublish"] == nil && line["isError"] as? Bool == false
            })
        }

        /// A failed publish may have published: its request stays claimed, so it is never tried twice.
        @Test func aFailedPublishIsNeverRetried() throws {
            let home = TempHome()
            let said = try calls(home, [["tool": Self.tool, "input": Self.note, "error": true], ["tool": Self.tool, "input": Self.note]],
                                 publish: true)
            #expect(said[0] == "allowed" && said[1].hasPrefix("blocked: "), "\(said)")
            let log = lines(home, "send/log.jsonl")
            #expect(log.count == 2 && log[0]["started"] as? Bool == true && log[1]["isError"] as? Bool == true)
        }

        /// The text is text, the project a path or a number, the merge request a whole number.
        @Test func publishArgumentsHaveTheirTypes() throws {
            let home = TempHome()
            let wrong: [[String: Any]] = [
                Self.note.merging(["body": ["Summary C"]]) { $1 },
                Self.note.merging(["project_id": ["team/app"]]) { $1 },
                Self.note.merging(["merge_request_iid": "7a"]) { $1 },
                Self.note.merging(["merge_request_iid": 7.5]) { $1 },
                Self.note.merging(["merge_request_iid": [7]]) { $1 },
            ]
            let said = try calls(home, wrong.map { ["tool": Self.tool, "input": $0] } + [["tool": Self.tool, "input": Self.note]], publish: true)
            #expect(said.dropLast().allSatisfy { $0.hasPrefix("blocked: ") }, "\(said)")
            #expect(said.last == "allowed")
        }

        @Test func withPublishEverythingElseStaysBlocked() throws {
            let home = TempHome()
            let wrong: [(String, [String: Any])] = [
                ("never calls", Self.diffNote(["method": "approve"])),
                ("never calls", Self.diffNote(["method": "unapprove"])),
                ("never calls", ["project_id": "team/app", "merge_request_iid": 7, "method": "resolve_discussion", "discussion_id": "abc", "resolved": true]),
                ("never calls", ["project_id": "team/app", "merge_request_iid": 7, "method": "submit_review", "summary": "x"]),
                ("never calls", Self.diffNote(["method": "post_duo_review"])),
                ("never calls", Self.diffNote(["method": nil])),
                ("the argument internal", Self.diffNote(["internal": true])),
                ("the argument url", Self.diffNote(["url": "https://gitlab.test/team/app/-/merge_requests/7"])),
                ("another place in the diff", Self.diffNote(["new_line": 4])),
                ("another place in the diff", Self.diffNote(["new_path": "src/B.swift"])),
                ("another place in the diff", Self.diffNote(["old_line": 2])),
                ("another place in the diff", Self.diffNote(["old_path": "src/Old.swift"])),
                ("another text", Self.diffNote(["body": "Text A"])),
                ("another project", Self.diffNote(["project_id": "team/other"])),
                ("another merge request", Self.diffNote(["merge_request_iid": 8])),
                // Another method: blocked; the reason is that of a request with the call's method.
                ("another text", ["project_id": "team/app", "merge_request_iid": 7, "method": "create_note", "body": "Reply B"]),
                ("another text", ["project_id": "team/app", "merge_request_iid": 7, "method": "create_note", "body": "Text A\n<!-- ai-review:v1 -->"]),
                ("another thread", Self.reply.merging(["discussion_id": "other"]) { $1 }),
                ("a position the request doesn't have", Self.note.merging(["new_path": "src/A.swift", "new_line": 3]) { $1 }),
            ]
            let said = try calls(home, wrong.map { ["tool": Self.tool, "input": $0.1] } + [["tool": Self.tool, "input": Self.diffNote()]], publish: true)
            for (index, (why, _)) in wrong.enumerated() {
                #expect(said[index].hasPrefix("blocked: ") && said[index].contains(why), "\(index): \(said[index])")
            }
            #expect(said.last == "allowed", "the right call still goes through after all of them")
            #expect(lines(home, "send/log.jsonl").map { $0["request"] as? String } == ["r1", "r1"], "started, then the answer")
        }

        /// An update or a delete touches a draft, which this server lacks; outside the send pass the
        /// tool never runs.
        @Test func onlyCreateRequestsAndOnlyTheSendPass() throws {
            let home = TempHome()
            let update: [String: Any] = ["project_id": "team/app", "merge_request_iid": 7, "method": "create_note", "body": "Changed D"]
            #expect(try calls(home, [["tool": Self.tool, "input": update]], publish: true)[0].contains("blocked"))
            let review = try calls(TempHome(), [["tool": Self.tool, "input": Self.note]], mode: "review", publish: true)
            #expect(review[0].contains("Only Send Drafts writes"), "\(review)")
        }
    }

    struct PublishSendTests {
        /// The send pass's log says the server can only publish: the requests wait, the host is
        /// remembered; Publish Now… sends them with AKIT_REVIEW_PUBLISH and they are no drafts.
        @Test func needsPublishThenPublish() async throws {
            let run = try await ReviewRunFixture.make()
            run.playTypicalRun()
            try await ReviewPasses.run(folder: run.folder, env: run.home.env)
            let plan = try #require(ReviewWorkflow.load(run.folder).plan)
            for request in plan.requests { try ReviewWorkflow.decide(run.folder, request: request.id, decision: .approved) }
            let host = FakeMergeRequest.ref.host
            #expect(!ReviewWorkflow.publishesDirectly(host: host, env: run.home.env))
            run.home.write("fake/send-log.jsonl", """
            {"request":"r1","tool":"mcp__gitlab__save_merge_request_review","needsPublish":true,"isError":true,"text":"Not sent"}
            {"request":"r2","tool":"mcp__gitlab__save_merge_request_review","needsPublish":true,"isError":true,"text":"Not sent"}

            """)
            var report = try await ReviewWorkflow.send(run.folder, env: run.home.env)
            #expect(report.sent.isEmpty && report.needsPublish == ["r1", "r2"])
            #expect(report.failed.map(\.message) == [ReviewWorkflow.needsPublishMessage, ReviewWorkflow.needsPublishMessage])
            #expect(ReviewWorkflow.publishesDirectly(host: host, env: run.home.env))
            #expect(try ReviewWorkflow.load(run.folder).plan?.requests.allSatisfy { !$0.isSent } == true)
            let plain = try String(contentsOf: run.home.url.appending(path: "fake/env-send-1.txt"), encoding: .utf8)
            #expect(!plain.contains("AKIT_REVIEW_PUBLISH"))
            let prompt = try String(contentsOf: run.folder.appending(path: "prompts/send-1.md"), encoding: .utf8)
            #expect(prompt.contains("`save_merge_request_review`") && prompt.contains("don't retry it"))

            let drafts = try ReviewWorkflow.load(run.folder).snapshot?.drafts ?? []
            Self.fakeGit(run, head: run.head)
            run.home.write("fake/send-log.jsonl", """
            {"request":"r1","tool":"mcp__gitlab__save_merge_request_review","isError":false,"text":"{\\"note\\": {\\"id\\": 901}}"}
            {"request":"r2","tool":"mcp__gitlab__save_merge_request_review","isError":false,"text":"Done: {\\"id\\": 902}"}

            """)
            report = try await ReviewWorkflow.send(run.folder, env: run.home.env, publish: true)
            #expect(report.sent == ["r1", "r2"] && report.published == ["r1", "r2"] && report.failed.isEmpty && report.needsPublish.isEmpty)
            let sent = try #require(try ReviewWorkflow.load(run.folder).plan?.requests)
            #expect(sent.map { $0.sent?.published } == [true, true] && sent.map { $0.sent?.noteID } == [901, 902])
            #expect(sent.allSatisfy { $0.isSent })
            #expect(try ReviewWorkflow.load(run.folder).snapshot?.drafts == drafts, "a published comment is no draft")
            let env = try String(contentsOf: run.home.url.appending(path: "fake/env-send-2.txt"), encoding: .utf8)
            #expect(env.contains("AKIT_REVIEW_PUBLISH=1"))
            let published = try String(contentsOf: run.folder.appending(path: "prompts/send-2.md"), encoding: .utf8)
            #expect(published.contains("the user agreed to publish these comments right away"))
            #expect(ReviewWorkflow.publishesDirectly(host: host, env: run.home.env))

            // Try Drafts Again forgets it.
            try ReviewWorkflow.setPublishesDirectly(false, host: host, env: run.home.env)
            #expect(!ReviewWorkflow.publishesDirectly(host: host, env: run.home.env))
        }

        /// A fake git: `ls-remote` prints `~/fake/mr-head` (or fails with `~/fake/git-fail`), the rest is real git.
        static func fakeGit(_ run: ReviewRunFixture, head: String) {
            run.home.write("fake/mr-head", "\(head)\trefs/merge-requests/7/head\n")
            run.home.write("bin/git", """
            #!/bin/sh
            case "$*" in *ls-remote*)
              printf '%s\\n' "$*" >> "$HOME/fake/git-args.txt"
              if [ -f "$HOME/fake/git-fail" ]; then echo "fatal: could not read from remote repository" >&2; exit 128; fi
              cat "$HOME/fake/mr-head"; exit 0 ;;
            esac
            exec /usr/bin/git "$@"
            """, executable: true)
        }

        static func approveAll(_ run: ReviewRunFixture) async throws {
            run.playTypicalRun()
            try await ReviewPasses.run(folder: run.folder, env: run.home.env)
            for request in try #require(try ReviewWorkflow.load(run.folder).plan).requests {
                try ReviewWorkflow.decide(run.folder, request: request.id, decision: .approved)
            }
        }

        /// A published diff note lands on GitLab's latest diff: it goes only while the merge
        /// request's head is the reviewed one; a comment on the merge request still goes.
        @Test func aDiffNoteIsPublishedOnlyOnTheReviewedHead() async throws {
            let run = try await ReviewRunFixture.make()
            try await Self.approveAll(run)
            Self.fakeGit(run, head: String(repeating: "f", count: 40))
            run.home.write("fake/send-log.jsonl", #"{"request":"r2","tool":"mcp__gitlab__save_merge_request_review","isError":false,"text":"{\"id\": 7}"}"# + "\n")
            var report = try await ReviewWorkflow.send(run.folder, env: run.home.env, publish: true)
            #expect(report.failed.map(\.id) == ["r1"] && report.failed[0].message == ReviewWorkflow.headMovedMessage)
            #expect(report.published == ["r2"])
            let approved = try String(contentsOf: run.home.url.appending(path: "fake/approved-send-1.json"), encoding: .utf8)
            #expect(!approved.contains(#""id" : "r1""#), "r1 never reached the pass")
            let args = try String(contentsOf: run.home.url.appending(path: "fake/git-args.txt"), encoding: .utf8)
            #expect(args.contains("core.hooksPath=/dev/null ls-remote origin refs/merge-requests/7/head"), "\(args)")

            // git can't tell: the same, with git's reason.
            run.home.write("fake/git-fail", "")
            report = try await ReviewWorkflow.send(run.folder, env: run.home.env, publish: true)
            #expect(report.failed.first?.message.hasPrefix("AKit couldn't check the merge request's head: git ls-remote failed: fatal: could not read") == true,
                    "\(report.failed)")

            // The reviewed head: it goes.
            try FileManager.default.removeItem(at: run.home.url.appending(path: "fake/git-fail"))
            Self.fakeGit(run, head: run.head)
            run.home.write("fake/send-log.jsonl", #"{"request":"r1","tool":"mcp__gitlab__save_merge_request_review","isError":false,"text":"{\"id\": 8}"}"# + "\n")
            report = try await ReviewWorkflow.send(run.folder, env: run.home.env, publish: true)
            #expect(report.published == ["r1"] && report.failed.isEmpty, "\(report.failed)")
        }

        /// A publish that started and didn't clearly fail may be in the merge request: it is not
        /// sent again until the user approves it again; a clear refusal (4xx) is a normal failure.
        @Test func anUncertainPublishWaitsForTheUser() async throws {
            let run = try await ReviewRunFixture.make()
            try await Self.approveAll(run)
            Self.fakeGit(run, head: run.head)
            run.home.write("fake/send-log.jsonl", """
            {"request":"r1","tool":"mcp__gitlab__save_merge_request_review","started":true}
            {"request":"r2","tool":"mcp__gitlab__save_merge_request_review","started":true}
            {"request":"r2","tool":"mcp__gitlab__save_merge_request_review","isError":true,"text":"500 Internal Server Error"}

            """)
            var report = try await ReviewWorkflow.send(run.folder, env: run.home.env, publish: true)
            #expect(report.failed.map(\.message) == [ReviewWorkflow.uncertainMessage, ReviewWorkflow.uncertainMessage])
            #expect(report.needsPublish.isEmpty && report.sent.isEmpty)
            var plan = try #require(try ReviewWorkflow.load(run.folder).plan)
            #expect(plan.requests.allSatisfy { $0.isUncertain && !$0.isSent })

            // Nothing goes again by itself.
            report = try await ReviewWorkflow.send(run.folder, env: run.home.env, publish: true)
            #expect(report.sent.isEmpty && report.failed.isEmpty && run.args("send-2").isEmpty)

            // Approved again: it goes; a 400 is GitLab's clear no.
            try ReviewWorkflow.decide(run.folder, request: "r2", decision: .approved)
            run.home.write("fake/send-log.jsonl", """
            {"request":"r2","tool":"mcp__gitlab__save_merge_request_review","started":true}
            {"request":"r2","tool":"mcp__gitlab__save_merge_request_review","isError":true,"text":"400 Bad Request: body is too long"}

            """)
            report = try await ReviewWorkflow.send(run.folder, env: run.home.env, publish: true)
            #expect(report.failed.map(\.id) == ["r2"] && report.failed[0].message.hasPrefix("GitLab: 400 Bad Request"))
            plan = try #require(try ReviewWorkflow.load(run.folder).plan)
            #expect(plan.requests[0].isUncertain && !plan.requests[1].isUncertain)
        }

        /// The login shell may export anything: only a confirmed send publishes.
        @Test func theLoginShellCantTurnPublishingOn() async throws {
            let run = try await ReviewRunFixture.make()
            try await Self.approveAll(run)
            let shell = run.home.write("bin/fake-shell", "#!/bin/sh\nexport AKIT_REVIEW_PUBLISH=1 FAKE_SHELL_SEEN=1\neval \"$4\"\n", executable: true)
            var env = run.home.env
            env.variables["SHELL"] = shell.path
            _ = try await ReviewWorkflow.send(run.folder, env: env)
            let seen = try String(contentsOf: run.home.url.appending(path: "fake/env-send-1.txt"), encoding: .utf8)
            #expect(seen.contains("FAKE_SHELL_SEEN=1"), "the pass took the login shell's variables")
            #expect(!seen.contains("AKIT_REVIEW_PUBLISH"))
        }

        /// Pi's answer names none of several skipped requests: the generic text each, the answer once.
        @Test func anAnswerWithoutTheIdsIsSaidOnce() async throws {
            let run = try await ReviewRunFixture.make()
            try await Self.approveAll(run)
            try run.answer("send-1", "I found no tool to write with.")
            let report = try await ReviewWorkflow.send(run.folder, env: run.home.env)
            #expect(report.failed.map(\.message) == ["The send pass didn't send it.", "The send pass didn't send it."])
            #expect(report.note == "Pi's answer: I found no tool to write with.")
        }

        @Test func publishNowKeepsWhatTheFirstSendDid() {
            var first = ReviewWorkflow.SendReport()
            first.sent = ["r1"]
            first.failed = [("r2", ReviewWorkflow.needsPublishMessage), ("r3", "GitLab: 400")]
            first.needsPublish = ["r2"]
            var later = ReviewWorkflow.SendReport()
            later.sent = ["r2"]
            later.published = ["r2"]
            let merged = first.merged(with: later)
            #expect(merged.sent == ["r1", "r2"] && merged.published == ["r2"] && merged.needsPublish.isEmpty)
            #expect(merged.failed.map(\.id) == ["r3"])
        }

        @Test func piSaysWhyItSkippedARequest() {
            let answer = "r1 — created draft 502\nr10 — something else\nr2 — Not sent: no draft tool here; token glpat-abcdefghijklmnopqrstu"
            let said = ReviewWorkflow.piSaid(answer, about: "r2")
            #expect(said?.hasPrefix("Pi: r2 — Not sent: no draft tool here;") == true)
            #expect(said?.contains("glpat-abcdefghijklmnopqrstu") == false, "masked")
            #expect(ReviewWorkflow.piSaid(answer, about: "r1") == "Pi: r1 — created draft 502", "not r10's line")
            #expect(ReviewWorkflow.piSaid("All done.", about: "r3") == "Pi: All done.", "no line names it: the answer's start")
            #expect(ReviewWorkflow.piSaid("All done.", about: "r3", only: false) == nil, "not for one of several requests")
            #expect(ReviewWorkflow.piSaid("  \n", about: "r3") == nil && ReviewWorkflow.piSaid(nil, about: "r3") == nil)
        }
    }
}
