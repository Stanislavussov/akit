import AKitFoundation
@testable import AKitReview
import Foundation
import Testing

/// Checks without a model (`docs/design/review.md`, "Checks without a model"): the quote must be
/// in the file, inline only on changed lines, not over a person's open thread, secrets in added
/// lines, and the size of the change.
struct ChecksTests {
    func place(_ plan: ReviewPlanFile, _ id: String) -> ReviewPlacement? { plan.placements.first { $0.findingID == id } }

    @Test func aQuoteThatIsNotInTheFileStaysInAKit() throws {
        var missing = PlanTests.finding("f1")
        missing.evidenceFound = false
        var found = PlanTests.finding("f2", line: 3)
        found.evidenceFound = true
        let plan = try PlanTests.plan([missing, found])
        #expect(place(plan, "f1")?.place == .onlyInAKit && place(plan, "f1")?.reason.contains("isn't in src/A.swift") == true)
        #expect(place(plan, "f2")?.place == .inline)
        #expect(try PlanTests.plan([missing], forced: ["f1"]).placements.first?.place == .inline, "the user's own pick still goes inline")
    }

    @Test func theAnchorRecordsWhetherTheQuoteIsThere() {
        let home = TempHome()
        home.write("wt/a.swift", "let a = 1\nlog(token)\n")
        let worktree = home.url.appending(path: "wt")
        var real = ReviewFinding(id: "f1", role: "r", file: "a.swift", line: 2, title: "t", evidence: "log(token)", why: "w", severity: .high, confidence: 0.9)
        ReviewCandidates.anchor(&real, worktree: worktree)
        var invented = real
        invented.evidence = "print(secretToken)"
        invented.evidenceFound = nil
        ReviewCandidates.anchor(&invented, worktree: worktree)
        var noQuote = real
        noQuote.evidence = ""
        noQuote.evidenceFound = nil
        ReviewCandidates.anchor(&noQuote, worktree: worktree)
        #expect(real.evidenceFound == true && invented.evidenceFound == false && noQuote.evidenceFound == nil)
        // How models quote: a diff marker, a line number, an ellipsis, other spacing.
        for quote in ["+    log(token)", "2: log(token)", "let a = ... log(token)", "log( token)\nlog(token)", "let  a = 1"] {
            var finding = real
            finding.evidence = quote
            finding.evidenceFound = nil
            ReviewCandidates.anchor(&finding, worktree: worktree)
            #expect(finding.evidenceFound == true, "\(quote)")
        }
        #expect(ReviewCandidates.verifierInput([invented], worktree: worktree).contains("this quote is not in the file"))
    }

    @Test func inlineOnlyOnLinesTheChangeTouches() throws {
        let plan = try PlanTests.plan([PlanTests.finding("f1", line: 2), PlanTests.finding("f2", line: 40)])
        #expect(place(plan, "f1")?.place == .inline)
        #expect(place(plan, "f2")?.place == .summary && place(plan, "f2")?.reason.contains("Not on a line the change touches") == true)
    }

    @Test func aPersonsOpenThreadOnTheLinesWins() throws {
        func thread(_ id: String, author: String, line: Int, resolved: Bool = false, body: String = "Why is this here?",
                    head: String = "h1234567890") -> GitLabDiscussion {
            let position = GitLabPosition(baseSHA: "b", startSHA: "s", headSHA: head, oldPath: "src/A.swift", newPath: "src/A.swift", oldLine: nil, newLine: line)
            return GitLabDiscussion(id: id, notes: [GitLabNote(id: 1, body: body, author: author, resolvable: true, resolved: resolved, position: position)])
        }
        let findings = [PlanTests.finding("f1", line: 2)]
        let open = try PlanTests.plan(findings, discussions: [thread("d1", author: "bob", line: 3)])
        #expect(open.placements.first?.place == .onlyInAKit && open.placements.first?.reason.hasPrefix("bob already has an open thread") == true)
        #expect(try PlanTests.plan(findings, discussions: [thread("d1", author: "bob", line: 3, resolved: true)]).placements.first?.place == .inline)
        #expect(try PlanTests.plan(findings, discussions: [thread("d1", author: "bob", line: 9)]).placements.first?.place == .inline, "two lines away at most")
        #expect(try PlanTests.plan(findings, discussions: [thread("d1", author: "bob", line: 3, head: "older")]).placements.first?.place == .inline,
                "a thread on an older version: its line numbers point elsewhere")
        var secret = PlanTests.finding("f1", line: 2)
        secret.role = ReviewScan.role
        #expect(try PlanTests.plan([secret], discussions: [thread("d1", author: "bob", line: 3)]).placements.first?.place == .inline,
                "a secret is reported whatever else is said there")
        var ignoredSecret = PlanTests.finding("f2", file: "gen/X.generated.swift", line: 1)
        ignoredSecret.role = ReviewScan.role
        #expect(try PlanTests.plan([ignoredSecret]).placements.first?.place == .inline, "and in an ignored path")
        let ours = thread("d1", author: "me", line: 2, body: "Text\n" + ReviewNotes.meta(fingerprint: "other", role: "r", severity: nil, run: "x"))
        #expect(try PlanTests.plan(findings, discussions: [ours]).placements.first?.place == .inline, "AKit's own thread is the rerun rules' business")
    }

    @Test func theScanCountsLinesAndFindsSecretsWithoutKeepingThem() {
        let token = "ghp_" + String(repeating: "x7", count: 18)
        let diffs = [
            GitLabFileDiff(oldPath: "src/A.swift", newPath: "src/A.swift", diff: "@@ -1,3 +5,4 @@\n a\n-b\n+let key = \"\(token)\"\n+c2\n d\n"),
            GitLabFileDiff(oldPath: "gen/X.generated.swift", newPath: "gen/X.generated.swift", diff: "@@ -1 +1 @@\n-a\n+GITHUB_TOKEN=\(token)\n"),
            GitLabFileDiff(oldPath: "big.json", newPath: "big.json", diff: "@@ -0,0 +1 @@\n+\"k\": \"\(token)\"\n", tooLarge: true),
            GitLabFileDiff(oldPath: "empty.json", newPath: "empty.json", diff: "", tooLarge: true),
            GitLabFileDiff(oldPath: "Tests/LoginTests.swift", newPath: "Tests/LoginTests.swift", diff: "@@ -0,0 +1 @@\n+let password = \"Summer2024!x\"\n"),
            GitLabFileDiff(oldPath: "src/Seed.swift", newPath: "src/Seed.swift", diff: "@@ -0,0 +1 @@\n+let password = \"Summer2024!x\"\n"),
        ]
        let scan = ReviewScan.make(diffs: diffs, secretFiles: [".env"]) { $0.hasSuffix(".generated.swift") }
        #expect(scan.changedLines == 6, "ignored files don't count; a diff over GitLab's limits that git made does")
        #expect(scan.secrets.map(\.file) == [".env", "src/A.swift", "gen/X.generated.swift", "big.json", "src/Seed.swift"],
                "ignored files are scanned; a test's password isn't a leak")
        #expect(scan.secrets[0].line == nil && scan.secrets[1].line == 6)
        #expect(scan.secrets[1].strong && scan.secrets.last?.strong == false)
        let encoded = String(decoding: (try? JSONEncoder().encode(scan)) ?? Data(), as: UTF8.self)
        #expect(!encoded.contains(token) && encoded.contains(SecretFilter.mask))
        let long = ReviewScan.around(String(repeating: "a", count: 500) + SecretFilter.mask + String(repeating: "b", count: 500))
        #expect(long.count < 200 && long.contains(SecretFilter.mask))
    }

    @Test func aRoleFindingOnTheSecretsLineIsMergedIntoTheScans() {
        let home = TempHome()
        home.write("gen/X.generated.swift", "GITHUB_TOKEN=x\n")
        var existing = ReviewFinding(id: "f1", role: "security", file: "gen/X.generated.swift", line: 1, title: "Unused variable", evidence: "x",
                                     why: "w", severity: .low, confidence: 0.6, verifier: .init(verdict: .confirmed, note: "ok"))
        existing.fingerprint = ReviewCandidates.fingerprints(existing, worktree: home.url).current
        existing.evidenceFound = false
        let secrets = [ReviewScan.Secret(file: "gen/X.generated.swift", line: 1, evidence: "GITHUB_TOKEN=[secret hidden]"),
                       .init(file: "src/A.swift", line: 3, evidence: "API_TOKEN=[secret hidden]"),
                       .init(file: "src/A.swift", line: 9, evidence: "API_TOKEN=[secret hidden]"),
                       .init(file: "src/Seed.swift", line: 1, evidence: "password = [secret hidden]", strong: false)]
        let result = ReviewScan.addSecrets(ReviewScan(changedLines: 3, secrets: secrets), to: [existing], worktree: home.url)
        #expect(result.count == 5)
        #expect(result[0].verifier?.verdict == .merged && result[0].verifier?.into == "f2")
        let scanned = result[1]
        #expect(scanned.role == "secret-scan" && scanned.title == "A secret in the change" && scanned.finalSeverity == .critical)
        #expect(scanned.verifier?.verdict == .confirmed && scanned.related == ["security:Unused variable"])
        #expect(scanned.fingerprints.contains(existing.fingerprint!), "the role's draft or thread still counts as found")
        #expect(result[2].fingerprint != result[3].fingerprint, "two masked lines alike in one file stay two secrets")
        #expect(result[4].finalSeverity == .high && result[4].title == "A password in the change")
        let plan = try? PlanTests.plan(result)
        #expect(plan?.placements.first { $0.findingID == "f2" }?.place != .onlyInAKit)
    }

    @Test func maxChangedLinesComesFromTheLevels() throws {
        let catalog = ReviewCatalog.load(home: FileManager.default.temporaryDirectory.appending(path: "none-\(UUID())"), brain: nil)
        var choices = ReviewRunChoices()
        #expect(try ReviewResolver.resolve(catalog: catalog, profile: nil, choices: choices, mergeRequest: FakeMergeRequest.ref, id: "x").spec
            .maxChangedLines == Sourced(6000, .builtIn))
        choices.settings.maxChangedLines = 300
        let spec = try ReviewResolver.resolve(catalog: catalog, profile: nil, choices: choices, mergeRequest: FakeMergeRequest.ref, id: "x").spec
        #expect(spec.maxChangedLines == Sourced(300, .run))
        #expect(ReviewResolver.describe(spec).contains("max_changed_lines: 300  [run]"))
        #expect(try ReviewSettingsPatch.parse(["cost": ["max_changed_lines": 800]], where: "t").maxChangedLines == 800)
        #expect(throws: (any Error).self) { try ReviewSettingsPatch.parse(["cost": ["max_changed_lines": 0]], where: "t") }
    }
}

extension ReviewProcessTests {
    struct SizeGateTests {
        /// Over `max_changed_lines` (6000 by default) the review only alerts and goes on.
        @Test func aBigChangeAlertsAndGoesOn() async throws {
            let run = try await ReviewRunFixture.make()
            let scan = try #require(ReviewJSON.read(ReviewScan.self, from: run.folder.appending(path: "scan.json")), "Gather writes the scan")
            #expect(scan.changedLines > 0)
            try ReviewJSON.write(ReviewScan(changedLines: 7000), to: run.folder.appending(path: "scan.json"))
            run.playTypicalRun()
            let alerts = LockedBox<[String]>([])
            let options = ReviewPasses.Options(alert: { message in alerts.update { $0.append(message) } })
            _ = try await ReviewPasses.run(folder: run.folder, env: run.home.env, options: options)
            #expect(alerts.value.contains { $0.contains("7000 changed lines, over max_changed_lines 6000") })
            #expect(FileManager.default.fileExists(atPath: run.home.url.appending(path: "fake/args-brief.txt").path), "the passes ran")
        }
    }
}

/// A value a `@Sendable` closure can change.
final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func update(_ change: (inout Value) -> Void) { lock.withLock { change(&stored) } }
}
