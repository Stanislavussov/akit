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
