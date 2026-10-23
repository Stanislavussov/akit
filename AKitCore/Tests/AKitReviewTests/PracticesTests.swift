import AKitFoundation
@testable import AKitReview
import Foundation
import Testing

/// The decisions of 2026-10-23 (`docs/design/review.md`, R20–R26): built-in rules, every Pi
/// server in the passes, issues from before the change, the confidence scale, the verifier's
/// model, the inline caps.
struct PracticesTests {
    func place(_ plan: ReviewPlanFile, _ id: String) -> ReviewPlacement? { plan.placements.first { $0.findingID == id } }

    @Test func thePassesReadThroughEveryServerButRiskyOnes() {
        let access = ReviewMCPAccess(extraServers: ["figma"])
        func kind(_ tool: String, _ server: String, inPasses: Bool = true) -> ReviewMCPPolicy.Kind {
            ReviewMCPPolicy.kind(server: server, tool: tool, access: access, inPasses: inPasses)
        }
        #expect(kind("query-docs", "context7") == .read && kind("resolve-library-id", "context7") == .read)
        #expect(kind("resolve_discussion", "context7") == .blocked && kind("resolve-library-id-and-thread", "gitlab") == .blocked,
                "only the exact name reads; resolving a thread never runs")
        #expect(kind("get_page", "notion") == .read)
        #expect(kind("get_page", "notion", inPasses: false) == .blocked, "the fetch and send passes keep the run's own servers")
        #expect(kind("create_page", "notion") == .blocked && kind("create_draft_note", "notion") == .blocked)
        #expect(kind("fetch_url", "web-fetch") == .blocked && kind("read_file", "filesystem") == .blocked, "risky servers only when named")
        #expect(access.passPatterns == ["mcp__*"])
        // An open server's tool with a reading verb first but a word that acts anywhere never runs.
        for (tool, server) in [("execute_query", "warehouse"), ("query", "warehouse"), ("get_or_create_issue", "linear"),
                               ("find_and_delete_page", "notion"), ("list__x", "notion"), ("get_secret", "vault"), ("read_item", "1password-cli")] {
            #expect(kind(tool, server) == .blocked, "\(tool) on \(server)")
        }
        #expect(ReviewMCPPolicy.kind(server: "linear", tool: "issue_lookup", readOnlyHint: true, access: access, inPasses: true) == .read)
        #expect(ReviewMCPPolicy.kind(server: "gitlab", tool: "execute_graphql_query", access: access, inPasses: true) == .blocked)
        #expect(ReviewMCPPolicy.kind(server: "gitlab", tool: "get_merge_request", access: access, inPasses: true) == .read,
                "the run's own servers keep their rules")
        #expect(ReviewMCPAccess(allServers: false).passPatterns == ReviewMCPAccess(allServers: false).toolPatterns)
        #expect(try! ReviewMCPAccess.parse(["all_servers": false], where: "t").allServers == false)
        #expect(try! ReviewMCPAccess.parse([:], where: "t").allServers)
        // The extension keeps the same lists.
        let source = ReviewExtension.source
        for word in ReviewMCPAccess.riskyServerWords + ReviewMCPAccess.riskyServerParts { #expect(source.contains("\"\(word)\""), "\(word)") }
        #expect(source.contains("tooMuchFor(event.input)") && source.contains("const openArgumentLimit = \(ReviewMCPPolicy.openArgumentLimit);"))
        for word in ReviewMCPPolicy.actingWords { #expect(source.contains("\"\(word)\""), "\(word)") }
        #expect(source.contains("everyServer && !risky(server)") && source.contains("return serverBase(server) && writePatterns"))
    }

    @Test func anIssueFromBeforeTheChangeNeverGoesToGitLab() throws {
        var old = PlanTests.finding("f1")
        old.preExisting = true
        var judged = PlanTests.finding("f2")
        judged.verifier?.preExisting = true
        var notOld = PlanTests.finding("f3")
        notOld.preExisting = true
        notOld.verifier?.preExisting = false
        let plan = try PlanTests.plan([old, judged, notOld])
        #expect(place(plan, "f1")?.place == .preExisting && place(plan, "f2")?.place == .preExisting)
        #expect(place(plan, "f3")?.place == .inline, "the verifier's say wins")
        #expect(!plan.requests.contains { $0.findingID == "f1" || $0.findingID == "f2" })
        #expect(!(plan.requests.first { $0.kind == .summary }?.proposed.contains("Problem f1") ?? false))
        #expect(try PlanTests.plan([old], forced: ["f1"]).placements.first?.place == .inline, "Move Inline still works")

        let raw: [String: Any] = ["title": "t", "evidence": "e", "why": "w", "severity": "high", "confidence": 0.9, "preExisting": true]
        #expect(ReviewCandidates.finding(raw, role: "r", id: "f1")?.preExisting == true)
        let home = TempHome()
        home.write("v.json", #"{"verdicts":[{"id":"f1","verdict":"confirmed","note":"n","preExisting":true}]}"#)
        let applied = ReviewCandidates.apply(verdictsFile: home.url.appending(path: "v.json"), to: [PlanTests.finding("f1", verdict: nil)])
        #expect(applied.first?.isPreExisting == true)
    }

    @Test func aDiscussionKeepsTheVerifiersSayOnBeforeTheChange() {
        var earlier = PlanTests.finding("f1")
        earlier.verifier?.preExisting = true
        let home = TempHome()
        home.write("v.json", #"{"verdicts":[{"id":"f1","verdict":"confirmed","note":"raise it","severity":"critical"}]}"#)
        let after = ReviewCandidates.apply(verdictsFile: home.url.appending(path: "v.json"), to: [earlier], keepingUnmentioned: true)
        #expect(after.first?.isPreExisting == true && after.first?.finalSeverity == .critical)
        #expect(ReviewDiscuss.opening.contains("preExisting"))
    }

    @Test func picksMovedInlineTakeTheirPlacesInTheCap() throws {
        let findings = (1...4).map { PlanTests.finding("f\($0)", severity: .high, confidence: 0.9 - Double($0) / 100) }
        let plan = try PlanTests.plan(findings, spec: try PlanTests.spec(maxInline: 2), forced: ["f4"])
        #expect(plan.requests.filter { $0.kind == .create }.compactMap(\.findingID).sorted() == ["f1", "f4"])
    }

    @Test func oldRunsKeepTheirVerifier() throws {
        var spec = try PlanTests.spec()
        spec.verifier = Sourced(ReviewModelChoice(model: ""), .builtIn)
        #expect(spec.verifierProblem != nil)
        spec.version = 1
        #expect(spec.verifierProblem == nil, "a run made before R25 used the passes' model")
    }

    @Test func theProfilesAllServersSwitchIsOneLine() {
        #expect(ReviewConfigEditor.settingMCP("all_servers", "false", in: "mcp:\n  servers: [gitlab]\n") == "mcp:\n  all_servers: false\n  servers: [gitlab]\n")
        #expect(ReviewConfigEditor.settingMCP("all_servers", "true", in: "mcp: { servers: [gitlab], all_servers: false }\n")
            == "mcp: { servers: [gitlab], all_servers: true }\n")
        #expect(ReviewConfigEditor.settingMCP("all_servers", "false", in: "x: 1\n") == "x: 1\nmcp:\n  all_servers: false\n")
    }

    @Test func atMostFiveInlineAndThreeOfThemMedium() throws {
        let spec = try PlanTests.spec(maxInline: 5)
        #expect(spec.posting.maxInlineMedium == Sourced(3, .builtIn))
        let findings = (1...5).map { PlanTests.finding("m\($0)", severity: .medium, confidence: 0.9 - Double($0) / 100) }
            + [PlanTests.finding("h1", severity: .high)]
        let plan = try PlanTests.plan(findings, spec: spec)
        #expect(plan.requests.filter { $0.kind == .create }.map(\.findingID) == ["h1", "m1", "m2", "m3"])
        #expect(place(plan, "m4")?.place == .summary && place(plan, "m4")?.reason.contains("medium") == true)
        #expect(try ReviewSettingsPatch.parse(["posting": ["max_inline_medium": 1]], where: "t").maxInlineMedium == 1)
        let catalog = ReviewCatalog.load(home: FileManager.default.temporaryDirectory.appending(path: "none-\(UUID())"), brain: nil)
        let built = try ReviewResolver.resolve(catalog: catalog, profile: nil, choices: ReviewRunChoices(), mergeRequest: FakeMergeRequest.ref, id: "x").spec
        #expect(built.posting.maxInline == Sourced(5, .builtIn))
        #expect(ReviewResolver.describe(built).contains("max_inline_medium: 3  [built-in]"))
    }

    @Test func aRunNeedsTheUsersVerifierModel() throws {
        let catalog = ReviewCatalog.load(home: FileManager.default.temporaryDirectory.appending(path: "none-\(UUID())"), brain: nil)
        var choices = ReviewRunChoices()
        choices.settings.passes = ReviewModelChoice(model: "a/m1")
        let none = try ReviewResolver.resolve(catalog: catalog, profile: nil, choices: choices, mergeRequest: FakeMergeRequest.ref, id: "x").spec
        #expect(none.verifier.value.model.isEmpty, "no longer the passes' model")
        #expect(none.verifierProblem?.contains("--verifier-model") == true)
        #expect(ReviewResolver.describe(none).contains("verifier: not set"))
        choices.settings.verifier = ReviewModelChoice(model: "b/m2")
        #expect(try ReviewResolver.resolve(catalog: catalog, profile: nil, choices: choices, mergeRequest: FakeMergeRequest.ref, id: "x").spec
            .verifierProblem == nil)
    }

    @Test func languageRulesFollowTheChangedFiles() {
        #expect(ReviewLanguageRules.sets(for: ["src/App.tsx", "README.md"]).map(\.id) == ["ts-react"])
        #expect(ReviewLanguageRules.sets(for: ["a.mjs"]).map(\.id) == ["ts-react"])
        #expect(ReviewLanguageRules.sets(for: ["Sources/A.swift", "docs/x.md"]).isEmpty)
        let text = ReviewLanguageRules.text(ReviewLanguageRules.sets(for: ["a.ts"]))
        #expect(text.contains("Built-in rules: TypeScript") && text.contains("useEffect") && text.contains("Safe path"))
    }

    @Test func thePromptsCarryTheScaleAndTheNewLimits() throws {
        var spec = try PlanTests.spec()
        spec.verifier = Sourced(ReviewModelChoice(model: "b/m2"), .run)
        let system = ReviewPrompts.system(spec: spec, hasWorktree: true)
        for text in ["0.25 = you couldn't verify it", "preExisting: true", "eslint-disable", "a documentation server (context7",
                     "never put code of the change"] {
            #expect(system.contains(text), "\(text)")
        }
        let verifier = ReviewPrompts.verifier(candidates: "", brief: nil, spec: spec)
        #expect(verifier.contains("0.75: verified in the code") && verifier.contains("`preExisting: true`") && verifier.contains("@ts-ignore"))
    }
}

/// Part (b) of 2026-10-23 (R27, R30, R33, R34): the question before the passes, the history,
/// the mode of a run, the risk map.
struct PracticesBeforeTests {
    @Test func gitLabSaysDraftAndPipeline() {
        let object: JSONObject = ["iid": 7, "source_branch": "x", "draft": true, "head_pipeline": ["status": "failed", "sha": "abc"]]
        let mr = GitLabJSON.mergeRequest(object)
        #expect(mr?.draft == true && mr?.pipelineStatus == "failed" && mr?.pipelineSHA == "abc")
        #expect(GitLabJSON.mergeRequest(["iid": 7, "source_branch": "x", "work_in_progress": true])?.draft == true)
        #expect(GitLabJSON.mergeRequest(["iid": 7, "source_branch": "x"])?.draft == nil)
        // Two answers of one merge request: the diff refs from one, the pipeline from the other.
        let calls = [ReviewMCPCall(pass: "fetch", tool: "mcp__gitlab__get_merge_request", input: #"{"iid":7}"#,
                                   text: [#"{"iid":7,"source_branch":"x","head_pipeline":{"status":"failed","sha":"h"}}"#], structured: nil, isError: false),
                     ReviewMCPCall(pass: "fetch", tool: "mcp__gitlab__get_merge_request", input: #"{"iid":7}"#,
                                   text: [#"{"iid":7,"source_branch":"x","diff_refs":{"base_sha":"b","start_sha":"s","head_sha":"h"}}"#],
                                   structured: nil, isError: false)]
        let read = ReviewMCPData.read(calls, iid: 7).mergeRequest
        #expect(read?.diffRefs?.headSHA == "h" && read?.pipelineStatus == "failed")
    }

    @Test func aDraftARedPipelineOrAReviewedCommitAskFirst() throws {
        let home = TempHome()
        var spec = try PlanTests.spec()
        spec.headSHA = "h1234567890"
        let paths = ReviewPaths(home: home.url)
        let folder = paths.run("run-b")
        try ReviewJSON.write(spec, to: folder.appending(path: "run.json"))
        var mr = GitLabMergeRequest(iid: 7, title: "t", description: "", state: "opened", author: "bob", sourceBranch: "x", targetBranch: "main",
                                    labels: [], webURL: "", diffRefs: nil, projectID: nil)
        mr.draft = true
        mr.pipelineStatus = "failed"
        mr.pipelineSHA = "h1234567890"
        try ReviewJSON.write(ReviewSnapshot(mergeRequest: mr, versions: [], diffs: [], discussions: [], drafts: [], user: "me", gathered: .now),
                             to: folder.appending(path: "gitlab/snapshot.json"))
        #expect(ReviewPasses.concerns(folder: folder, spec: spec, home: home.url).count == 2)
        let earlier = paths.run("run-a")
        try ReviewJSON.write(spec, to: earlier.appending(path: "run.json"))
        #expect(ReviewPasses.concerns(folder: folder, spec: spec, home: home.url).count == 2, "an earlier run without passes doesn't count")
        home.write(".akit/local/review/runs/run-a/findings.json", "{}")
        #expect(ReviewPasses.concerns(folder: folder, spec: spec, home: home.url).last?.contains("run run-a") == true)
        mr.pipelineSHA = "older"
        try ReviewJSON.write(ReviewSnapshot(mergeRequest: mr, versions: [], diffs: [], discussions: [], drafts: [], user: "me", gathered: .now),
                             to: folder.appending(path: "gitlab/snapshot.json"))
        #expect(!ReviewPasses.concerns(folder: folder, spec: spec, home: home.url).contains { $0.contains("pipeline") },
                "a pipeline of an older commit says nothing of this one")
    }

    @Test func anotherProjectsMergeRequestIsNeverThisOne() {
        func call(_ input: String, _ answer: String) -> ReviewMCPCall {
            ReviewMCPCall(pass: "fetch", tool: "mcp__gitlab__x", input: input, text: [answer], structured: nil, isError: false)
        }
        let calls = [
            call(#"{"iid":7}"#, #"{"iid":7,"source_branch":"a","web_url":"https://g/team/app/-/merge_requests/7","diff_refs":{"base_sha":"b","start_sha":"s","head_sha":"h"}}"#),
            call(#"{"sha":"c1"}"#, #"[{"iid":7,"source_branch":"z","draft":true,"web_url":"https://g/other/x/-/merge_requests/7"}]"#),
            call(#"{"merge_request_iid":3}"#, #"[{"diff":"@@ -1 +1 @@\n-a\n+b\n","new_path":"old.ts","old_path":"old.ts"}]"#),
            call(#"{"id":7,"merge_request_iid":3}"#, #"[{"id":"d9","notes":[{"id":1,"body":"x","author":{"username":"a"}}]}]"#),
        ]
        let data = ReviewMCPData.read(calls, iid: 7, project: "team/app")
        #expect(data.mergeRequest?.sourceBranch == "a" && data.mergeRequest?.draft == nil, "!7 of another project says nothing of this one")
        #expect(data.diffs.isEmpty, "an earlier merge request's diff is its own")
        #expect(data.discussions.isEmpty, "a project id equal to the iid doesn't make a thread this one's")
        #expect(ReviewMCPData.number(in: ["merge_request_id": 900, "merge_request_iid": 3]) == 3)
    }

    @Test func theDevelopersOwnChangeGetsTheSelfReviewLimits() throws {
        var spec = try PlanTests.spec(maxInline: 5)
        spec.posting.maxInline = Sourced(5, .builtIn)
        spec.applyMode(own: false)
        #expect(spec.ownChange == false && spec.posting.severityThreshold.value == .medium)
        spec.applyMode(own: true)
        #expect(spec.posting.severityThreshold.value == .low && spec.posting.maxInline.value == 10 && spec.posting.maxInlineMedium?.value == 10)
        var chosen = try PlanTests.spec(maxInline: 2)
        chosen.applyMode(own: true)
        #expect(chosen.posting.maxInline == Sourced(2, .run), "what the run set stays")
        #expect(ReviewResolver.describe(spec).contains("mode: your own change"))
    }

    @Test func historyHasTheBlameAndEarlierThreads() async throws {
        let home = TempHome()
        let repo = home.url.appending(path: "repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        home.git(repo, "init", "-q", "-b", "main")
        home.write("repo/a.ts", "one\ntwo\nthree\n")
        home.git(repo, "add", "a.ts")
        home.git(repo, "commit", "-q", "-m", "Fix the race in two")
        let base = home.git(repo, "rev-parse", "HEAD")
        let diff = GitLabFileDiff(oldPath: "a.ts", newPath: "a.ts", diff: "@@ -2,1 +2,1 @@\n-two\n+TWO\n")
        let text = await ReviewGather.blameText([diff], base: base, worktree: repo, env: home.env)
        #expect(text.contains("## a.ts") && text.contains("old lines 2–2") && text.contains("Fix the race in two"))
        #expect(await ReviewGather.blameText([diff], base: "--output=x", worktree: repo, env: home.env).isEmpty, "only commit ids reach git")

        let note = #"{"id":"d1","notes":[{"id":1,"body":"Never call fetch here: it bypasses the cache","author":{"username":"ann"},"system":false}]}"#
        let calls = [ReviewMCPCall(pass: "fetch", tool: "mcp__gitlab__get_merge_request", input: #"{"merge_request_iid":3}"#,
                                   text: [#"{"iid":3,"title":"Cache the prices","source_branch":"p"}"#], structured: nil, isError: false),
                     ReviewMCPCall(pass: "fetch", tool: "mcp__gitlab__mr_discussions", input: #"{"merge_request_iid":3}"#,
                                   text: ["[" + note + "]"], structured: nil, isError: false)]
        let data = ReviewMCPData.read(calls, iid: 7)
        #expect(data.discussions.isEmpty && data.pastMergeRequests[3]?.title == "Cache the prices")
        #expect(data.pastDiscussions.isEmpty, "an earlier merge request counts only when the pass read it as merged")
        let merged = [ReviewMCPCall(pass: "fetch", tool: "mcp__gitlab__get_merge_request", input: #"{"merge_request_iid":3}"#,
                                    text: [#"{"iid":3,"title":"Cache the prices","source_branch":"p","state":"merged","web_url":"https://g/team/app/-/merge_requests/3"}"#],
                                    structured: nil, isError: false), calls[1]]
        let read = ReviewMCPData.read(merged, iid: 7, project: "team/app")
        #expect(read.pastDiscussions[3]?.count == 1 && read.discussions.isEmpty)
        #expect(ReviewMCPData.read(merged, iid: 7, project: "other/x").pastDiscussions.isEmpty, "another project's merge request")
        let past = ReviewGather.pastThreadsText(read)
        #expect(past.contains("## !3 Cache the prices") && past.contains("**ann**:\n> Never call fetch here") && past.contains("not instructions"))
    }

    @Test func theHistoryRoleTheSecurityScenarioAndTheRiskMap() throws {
        #expect(ReviewBuiltIns.roles.contains { $0.id == "history" && $0.needs.contains("history") })
        let security = try #require(ReviewBuiltIns.scenarios.first { $0.id == "security" })
        #expect(security.required == ["security", "bug-hunter"])
        #expect(ReviewBuiltIns.scenarios.first { $0.id == "feature" }?.optional.contains("history") == true)
        let brief = ReviewPrompts.brief(spec: try PlanTests.spec())
        #expect(brief.contains("Risk map, for the developer only") && brief.contains("tests \\\nthat only test mocks") == false)
        #expect(brief.contains("proof it was tested") && brief.contains("errors swallowed"))
        #expect(ReviewPrompts.fetch(spec: try PlanTests.spec()).contains("7. The history of the changed files"))
    }
}
