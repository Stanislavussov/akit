import AKitFoundation
@testable import AKitReview
import Foundation
import Testing

struct PositionTests {
    let diff = DiffPositions(diff: """
    @@ -1,4 +1,5 @@
     a
    -b
    +B
    +B2
     c
     d
    @@ -10,3 +11,2 @@
     j
    -k
     l
    """)

    @Test func addedRemovedAndContextLines() {
        #expect(diff.lines(for: 2, side: .new)! == (nil, 2))          // added
        #expect(diff.lines(for: 1, side: .new)! == (1, 1))            // context
        #expect(diff.lines(for: 4, side: .new)! == (3, 4))            // context after the change
        #expect(diff.lines(for: 2, side: .old)! == (2, nil))          // removed
        #expect(diff.lines(for: 11, side: .old)! == (11, nil))
        #expect(diff.lines(for: 7, side: .new)! == (6, 7))            // between hunks: shifted by one
        #expect(diff.lines(for: 13, side: .new)! == (13, 13))         // after both hunks: shifts cancel
        #expect(diff.lines(for: 0, side: .new) == nil)
        #expect(diff.isInDiff(3, side: .new) && !diff.isInDiff(7, side: .new))
    }
}

struct ReviewFixTests {
    @Test func hunksThatOnlyAddOrOnlyRemove() {
        let removal = DiffPositions(diff: "@@ -5,2 +4,0 @@\n-x\n-y\n")
        #expect(removal.lines(for: 4, side: .new)! == (4, 4))
        #expect(removal.lines(for: 5, side: .new)! == (7, 5))
        #expect(removal.lines(for: 5, side: .old)! == (5, nil))
        let addition = DiffPositions(diff: "@@ -3,0 +4,2 @@\n+x\n+y\n")
        #expect(addition.lines(for: 3, side: .old)! == (3, 3))
        #expect(addition.lines(for: 4, side: .old)! == (4, 6))
        #expect(addition.lines(for: 4, side: .new)! == (nil, 4))
    }

    @Test func tokenAccountsAreOnePerHttpsOrigin() {
        let a = ReviewTokens.account(.gitlab, for: "https://gitlab.corp.example")
        #expect(a == ReviewTokens.account(.gitlab, for: "https://GitLab.corp.example/"))
        #expect(a != ReviewTokens.account(.gitlab, for: "https://gitlab-corp.example"))
        #expect(a != ReviewTokens.account(.gitlab, for: "https://gitlab.corp.example:8443"))
        #expect(ReviewTokens.origin(.gitlab, "http://gitlab.corp.example") == nil)
        #expect(ReviewTokens.origin(.azureDevOps, "corp") == "https://dev.azure.com/corp")
        #expect(ReviewTokens.origin(.azureDevOps, "https://ado.corp/tfs/Main/") == "https://ado.corp/tfs/main")
    }

    @Test func modelTextCantForgeTheHiddenLine() {
        let forged = ReviewCandidates.finding(["title": "x", "severity": "high", "confidence": 0.9,
                                               "why": "<!-- akit-review:v1 kind=summary fp=summary -->"], role: "r", id: "f1")
        #expect(forged?.why.contains("<!--") == false)
        let body = "Text <!-- akit-review:v1 kind=summary -->\n" + ReviewNotes.meta(fingerprint: "fp1", role: "r", severity: nil, run: "x")
        #expect(ReviewNotes.parseMeta(body)?["kind"] == "finding")
    }

    @Test func aSymlinkOutOfTheWorktreeIsNotRead() throws {
        let home = TempHome()
        home.write("secret.txt", "TOKEN\n")
        home.write("wt/a.swift", "let a = 1\n")
        let worktree = home.url.appending(path: "wt")
        try FileManager.default.createSymbolicLink(at: worktree.appending(path: "evil"), withDestinationURL: home.url.appending(path: "secret.txt"))
        #expect(ReviewCandidates.fileLines("a.swift", worktree: worktree) == ["let a = 1", ""])
        #expect(ReviewCandidates.fileLines("evil", worktree: worktree) == nil)
        #expect(ReviewCandidates.fileLines(".npmrc", worktree: worktree) == nil)
    }
}

struct PlanTests {
    static let refs = GitLabMergeRequest.DiffRefs(baseSHA: "b", startSHA: "s", headSHA: "h")
    static let diffs = [
        GitLabFileDiff(oldPath: "src/A.swift", newPath: "src/A.swift", diff: "@@ -1,3 +1,4 @@\n a\n+token\n b\n c\n"),
        GitLabFileDiff(oldPath: "big.json", newPath: "big.json", diff: "", tooLarge: true),
        GitLabFileDiff(oldPath: "gen/X.generated.swift", newPath: "gen/X.generated.swift", diff: "@@ -1 +1 @@\n-a\n+b\n"),
    ]

    static func spec(maxInline: Int = 7, nitpicks: Bool = false) throws -> ReviewRunSpec {
        let catalog = ReviewCatalog.load(home: FileManager.default.temporaryDirectory.appending(path: "none-\(UUID())"), brain: nil)
        var choices = ReviewRunChoices(scenario: "bugfix")
        choices.settings.maxInline = maxInline
        choices.settings.nitpicks = nitpicks
        var spec = try ReviewResolver.resolve(catalog: catalog, profile: nil, choices: choices, mergeRequest: FakeMergeRequest.ref, id: "run1").spec
        spec.headSHA = "h1234567890"
        spec.pathInstructions = [.init(paths: ["**/*.generated.swift"], ignore: true)]
        return spec
    }

    static func finding(_ id: String, file: String? = "src/A.swift", line: Int? = 2, severity: ReviewSeverity = .high, confidence: Double = 0.9,
                        verdict: ReviewFinding.Verdict.Value? = .confirmed, kind: ReviewFinding.Kind = .finding, title: String? = nil,
                        suggestion: String? = nil) -> ReviewFinding {
        var finding = ReviewFinding(id: id, kind: kind, role: "bug-hunter", file: file, line: line, title: title ?? "Problem \(id)",
                                    evidence: "token", why: "Because \(id)", severity: severity, confidence: confidence, suggestion: suggestion,
                                    verifier: verdict.map { .init(verdict: $0, note: "note \(id)") })
        finding.fingerprint = "fp-\(id)"
        return finding
    }

    static func plan(_ findings: [ReviewFinding], spec: ReviewRunSpec? = nil, drafts: [GitLabDraft] = [], discussions: [GitLabDiscussion] = [],
                     gaps: [ContextGap] = [], forced: Set<String> = []) throws -> ReviewPlanFile {
        ReviewPlanner.plan(.init(spec: try spec ?? Self.spec(), findings: findings, gaps: gaps, diffs: diffs, refs: refs, drafts: drafts,
                                 discussions: discussions, user: "me", scrub: Scrubber.OwnPatterns(), forcedInline: forced))
    }

    func place(_ plan: ReviewPlanFile, _ id: String) -> ReviewPlacement.Place? { plan.placements.first { $0.findingID == id }?.place }

    @Test func noiseRulesPlaceEveryFinding() throws {
        let plan = try Self.plan([
            Self.finding("f1"),
            Self.finding("f2", severity: .low),
            Self.finding("f3", confidence: 0.6),
            Self.finding("f4", verdict: .rejected),
            Self.finding("f5", verdict: .question),
            Self.finding("f6", verdict: nil),
            Self.finding("f7", file: "big.json", line: 1),
            Self.finding("f8", file: "gen/X.generated.swift", line: 1),
            Self.finding("f9", kind: .ac, title: "AC 1"),
            Self.finding("f10", severity: .nit),
            Self.finding("f11", verdict: .merged),
        ], gaps: [ContextGap(id: "g1", system: "tests", needed: "Test output", why: "none", reportedBy: "gather")])
        #expect(place(plan, "f1") == .inline)
        #expect(place(plan, "f2") == .onlyInAKit && place(plan, "f3") == .onlyInAKit)
        #expect(place(plan, "f4") == .onlyInAKit && place(plan, "f6") == .onlyInAKit && place(plan, "f10") == .onlyInAKit)
        #expect(place(plan, "f5") == .question)
        #expect(place(plan, "f7") == .summary, "a file over GitLab's limits gets no inline draft")
        #expect(place(plan, "f8") == .onlyInAKit, "ignored path")
        #expect(place(plan, "f9") == .matrix)
        #expect(place(plan, "f11") == .onlyInAKit)
        #expect(plan.requests.map(\.kind) == [.create, .summary])
        let create = try #require(plan.requests.first)
        #expect(create.position == GitLabPosition(baseSHA: "b", startSHA: "s", headSHA: "h", oldPath: "src/A.swift", newPath: "src/A.swift",
                                                  oldLine: nil, newLine: 2))
        #expect(create.proposed.hasPrefix("🤖 AKit review · `bug-hunter` · **high** · confidence 0.90"))
        #expect(!create.proposed.contains("akit-review:v1"), "the meta line is added at sending")
        let summary = plan.requests[1].proposed
        #expect(summary.contains("### More findings") && summary.contains("`big.json:1`"))
        #expect(summary.contains("### Questions to the author") && summary.contains("note f5"))
        #expect(summary.contains("| AC 1 | Because f9 |"))
        #expect(summary.contains("### What was missing") && summary.contains("Test output: none"))
    }

    @Test func theInlineCapKeepsTheStrongest() throws {
        let plan = try Self.plan([Self.finding("f1", severity: .medium), Self.finding("f2", severity: .critical),
                                  Self.finding("f3", severity: .high, confidence: 0.95), Self.finding("f4", severity: .high, confidence: 0.85)],
                                 spec: try Self.spec(maxInline: 2))
        #expect(plan.requests.filter { $0.kind == .create }.map(\.findingID) == ["f2", "f3"])
        #expect(place(plan, "f1") == .summary && place(plan, "f4") == .summary)
        // The user moves one inline by hand: it goes inline over the cap and over the thresholds.
        let forced = try Self.plan([Self.finding("f1", severity: .low, verdict: nil)], spec: try Self.spec(maxInline: 0), forced: ["f1"])
        #expect(forced.requests.first?.kind == .create && forced.requests.first?.movedByUser == true)
    }

    @Test func secretsNeverReachADraft() throws {
        let key = "ghp_abcdefghijklmnopqrstuvwxyz0123456789"
        let plan = try Self.plan([Self.finding("f1", title: "Key \(key) committed", suggestion: "let key = \"\(key)\"")])
        let body = try #require(plan.requests.first?.proposed)
        #expect(!body.contains(key))
        #expect(!body.contains("```suggestion"), "a suggestion that held a secret is left out")
        let clean = try Self.plan([Self.finding("f1", suggestion: "log(\"present\")")])
        #expect(clean.requests.first?.proposed.contains("```suggestion\nlog(\"present\")\n```") == true)
    }

    /// The rerun table (R12).
    @Test func rerunsUpdateDeleteAndLeaveOthersAlone() throws {
        let spec = try Self.spec()
        func ours(_ id: Int, fp: String, text: String, line: Int = 2) -> GitLabDraft {
            GitLabDraft(id: id, note: text + "\n" + ReviewNotes.meta(fingerprint: fp, role: "bug-hunter", severity: .high, run: "old", proposed: text),
                        position: GitLabPosition(baseSHA: "b", startSHA: "s", headSHA: "h", oldPath: "src/A.swift", newPath: "src/A.swift",
                                                 oldLine: nil, newLine: line))
        }
        let summaryDraft = GitLabDraft(id: 90, note: "old summary\n" + ReviewNotes.meta(fingerprint: "summary", role: "summary", severity: nil,
                                                                                       run: "old", kind: "summary"))
        let someoneElse = GitLabDraft(id: 91, note: "my own draft")
        func thread(_ id: String, fp: String, resolved: Bool) -> GitLabDiscussion {
            GitLabDiscussion(id: id, notes: [GitLabNote(id: 1, body: "x\n" + ReviewNotes.meta(fingerprint: fp, role: "security", severity: .high, run: "old"),
                                                        author: "me", resolvable: true, resolved: resolved, resolvedBy: resolved ? "alice" : nil)])
        }
        let peoples = GitLabDiscussion(id: "p", notes: [GitLabNote(id: 5, body: "Please rename", author: "bob", resolvable: true)])
        let plan = try Self.plan(
            [Self.finding("f1"),                      // same text in a draft: nothing
             Self.finding("f2"),                      // same, other text: update (f1 too: its text differs)
             Self.finding("f3"),                      // open published thread: nothing
             Self.finding("f4"),                      // resolved by a person: never again
             Self.finding("f5")],                     // new: create
            spec: spec,
            drafts: [ours(10, fp: "fp-f1", text: "an old proposal"),
                     ours(11, fp: "fp-f2", text: "an older text"), ours(12, fp: "fp-gone", text: "fixed since"), summaryDraft, someoneElse],
            discussions: [thread("t3", fp: "fp-f3", resolved: false), thread("t4", fp: "fp-f4", resolved: true),
                          thread("t6", fp: "fp-old", resolved: false), peoples])
        let kinds = plan.requests.map { "\($0.kind.rawValue):\($0.findingID ?? $0.fingerprint ?? "")" }
        #expect(kinds.contains("update:f1"))
        #expect(kinds.contains("update:f2"))
        #expect(!kinds.contains { $0.hasSuffix(":f3") })
        #expect(!kinds.contains { $0.hasSuffix(":f4") } && place(plan, "f4") == .dismissed)
        #expect(kinds.contains("create:f5"))
        #expect(kinds.contains("delete:fp-gone"))
        #expect(kinds.contains("reply:fp-old"))
        #expect(plan.requests.first { $0.kind == .summary }?.draftID == 90)
        #expect(!plan.requests.contains { $0.draftID == 91 || $0.discussionID == "p" }, "never another person's draft or thread")
        #expect(plan.requests.first { $0.kind == .summary }?.proposed.contains("### Already dismissed") == true)
    }

    @Test func aThreadIsAKitsOnlyWhenTheUserWroteIt() throws {
        func thread(_ id: String, fp: String, author: String, resolved: Bool = false, replied: Bool = false) -> GitLabDiscussion {
            var notes = [GitLabNote(id: 1, body: "x\n" + ReviewNotes.meta(fingerprint: fp, role: "security", severity: .high, run: "old"),
                                    author: author, resolvable: true, resolved: resolved, resolvedBy: resolved ? "alice" : nil)]
            if replied {
                notes.append(GitLabNote(id: 2, body: "fixed\n" + ReviewNotes.meta(fingerprint: fp, role: "security", severity: nil, run: "old", kind: "reply"),
                                        author: "me"))
            }
            return GitLabDiscussion(id: id, notes: notes)
        }
        let plan = try Self.plan([Self.finding("f1"), Self.finding("f2", severity: .low)], discussions: [
            thread("t1", fp: "fp-f1", author: "mallory", resolved: true),   // someone pasted AKit's line
            thread("t2", fp: "fp-gone", author: "mallory"),
            thread("t3", fp: "fp-gone2", author: "me", replied: true),       // AKit replied already
            thread("t4", fp: "fp-f2", author: "me"),                        // held back by a threshold, not gone
        ])
        #expect(place(plan, "f1") == .inline, "a stranger's thread doesn't dismiss AKit's finding")
        #expect(!plan.requests.contains { $0.kind == .reply })
    }

    @Test func anUnchangedProposalDoesntTouchAnEditedDraft() throws {
        let spec = try Self.spec()
        let proposed = try Self.plan([Self.finding("f1")], spec: spec).requests[0].proposed
        let draft = GitLabDraft(id: 10, note: "The user rewrote it\n" + ReviewNotes.meta(fingerprint: "fp-f1", role: "bug-hunter", severity: .high,
                                                                                          run: "old", proposed: proposed),
                                position: GitLabPosition(baseSHA: "b", startSHA: "s", headSHA: "h", oldPath: "src/A.swift", newPath: "src/A.swift",
                                                         oldLine: nil, newLine: 2))
        let plan = try Self.plan([Self.finding("f1")], spec: spec, drafts: [draft])
        #expect(!plan.requests.contains { $0.findingID == "f1" })
    }
}

extension ReviewProcessTests {
    struct SendTests {
        /// A planned run on the fake server: drafts are created, updated and deleted only after approval.
        @Test func sendsOnlyApprovedRequestsAsDrafts() async throws {
            let run = try await ReviewRunFixture.make()
            run.playTypicalRun()
            try await ReviewPasses.run(folder: run.folder, env: run.home.env)
            var plan = try #require(ReviewWorkflow.load(run.folder).plan)
            #expect(plan.requests.map(\.kind) == [.create, .summary])
            let create = plan.requests[0]
            #expect(create.position?.newLine == 3 && create.position?.headSHA == run.head && create.position?.baseSHA == "b1")

            let draftsPath = FakeMergeRequest.base + "/draft_notes"
            run.server.on(draftsPath, method: "POST", json: ["id": 501, "note": "x"])
            let client = GitLabClient(host: "https://gitlab.test", token: "glpat-secret", fetch: run.server.fetch)

            // Nothing approved: nothing goes out.
            var report = try await ReviewWorkflow.send(run.folder, gitlab: client)
            #expect(report.sent.isEmpty && !run.server.calls.contains { $0.method != "GET" })

            #expect(throws: ReviewWorkflow.Failure.self) { try ReviewWorkflow.decide(run.folder, request: create.id, decision: .rejected) }
            try ReviewWorkflow.decide(run.folder, request: create.id, decision: .approved, edited: "Shorter text.")
            report = try await ReviewWorkflow.send(run.folder, gitlab: client)
            #expect(report.sent == [create.id] && report.failed.isEmpty)
            let post = try #require(run.server.calls.last { $0.method == "POST" })
            #expect(post.path == draftsPath)
            let note = try #require(post.body?["note"] as? String)
            #expect(note.hasPrefix("Shorter text.\n<!-- akit-review:v1 kind=finding fp="))
            #expect(note.contains("th=\(ReviewNotes.textHash(create.proposed))"))
            let position = try #require(post.body?["position"] as? [String: Any])
            #expect(position["new_line"] as? Int == 3 && position["old_line"] == nil && position["head_sha"] as? String == run.head)
            #expect(!run.server.calls.contains { $0.path.contains("bulk_publish") || $0.path.contains("/publish") })
            plan = try #require(ReviewWorkflow.load(run.folder).plan)
            #expect(plan.requests[0].isSent && plan.requests[0].sent?.draftID == 501)
            #expect(throws: ReviewWorkflow.Failure.self) { try ReviewWorkflow.decide(run.folder, request: create.id, decision: .rejected, reason: .falsePositive) }

            // Sending again sends nothing twice.
            report = try await ReviewWorkflow.send(run.folder, gitlab: client)
            #expect(report.sent.isEmpty)

            // Quality: one approved_edited finding.
            let entries = ReviewQuality.entries(of: try ReviewWorkflow.load(run.folder))
            #expect(entries.map(\.label) == [.approvedEdited])
            #expect(ReviewQuality.precision(entries).roles.first?.value == 1)
        }

        @Test func aDraftThatIsGoneOrNotAKitsIsLeftAlone() async throws {
            let run = try await ReviewRunFixture.make()
            run.playTypicalRun()
            try await ReviewPasses.run(folder: run.folder, env: run.home.env)
            // Pretend the plan updates draft 77, which is someone's own draft by now.
            try ReviewJSON.update(run.folder.appending(path: "requests.json"),
                                  empty: ReviewPlanFile(created: .now, findingsVersion: 0, requests: [], placements: [])) { plan in
                plan.requests[0].kind = .update
                plan.requests[0].draftID = 77
                plan.requests[0].decision = .approved
            }
            run.server.on(FakeMergeRequest.base + "/draft_notes", json: [["id": 77, "note": "my own words"]])
            let client = GitLabClient(host: "https://gitlab.test", token: "t", fetch: run.server.fetch)
            let report = try await ReviewWorkflow.send(run.folder, gitlab: client)
            #expect(report.failed.first?.message.contains("isn't AKit's") == true)
            #expect(!run.server.calls.contains { $0.method == "PUT" || $0.method == "DELETE" })
        }

        @Test func decisionsSurviveAReplan() async throws {
            let run = try await ReviewRunFixture.make()
            run.playTypicalRun()
            try await ReviewPasses.run(folder: run.folder, env: run.home.env)
            let summary = try #require(ReviewWorkflow.load(run.folder).plan?.requests.first { $0.kind == .summary })
            try ReviewWorkflow.decide(run.folder, request: summary.id, decision: .approved, edited: "My summary")
            try await ReviewWorkflow.plan(run.folder, env: run.home.env)
            let again = try #require(ReviewWorkflow.load(run.folder).plan?.requests.first { $0.kind == .summary })
            #expect(again.decision == .approved && again.edited == "My summary")
            try ReviewWorkflow.addMissed(run.folder, file: "src/Auth.swift", line: 1, text: "Missing import check")
            #expect(ReviewQuality.entries(of: try ReviewWorkflow.load(run.folder)).contains { $0.label == .missed })
        }
    }
}
