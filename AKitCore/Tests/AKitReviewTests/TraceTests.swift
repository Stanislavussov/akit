import AKitFoundation
@testable import AKitReview
import Foundation
import Testing

/// R68 (`docs/design/review.md`, "Causes, not symptoms"): a finding carries its path from the
/// cause to the harm; AKit checks each step's quote and keeps a finding without a step beyond its
/// own lines out of the merge request.
struct TraceTests {
    static let file = """
        func load(id: String?) -> User {
            let user = cache[id ?? ""]
            return user!
        }

        func screen() {
            let user = load(id: route.id)
            title = user.name
        }
        """

    func worktree() -> (TempHome, URL) {
        let home = TempHome()
        home.write("wt/src/A.swift", Self.file)
        home.write("wt/src/Route.swift", "struct Route {\n    var id: String?\n}\n")
        return (home, home.url.appending(path: "wt"))
    }

    func finding(trace: [ReviewFinding.TraceStep]?) -> ReviewFinding {
        var finding = ReviewFinding(id: "f1", role: "bug-hunter", file: "src/A.swift", line: 3, title: "Crash on a missing user",
                                    evidence: "return user!", why: "w", severity: .high, confidence: 0.9)
        finding.trace = trace
        return finding
    }

    @Test func aStepBeyondTheAnchorMakesAFindingTraced() {
        let (home, worktree) = worktree()
        _ = home
        var traced = finding(trace: [
            .init(file: "src/Route.swift", line: 2, quote: "var id: String?", note: "the route may have no id"),
            .init(file: "src/A.swift", line: 3, quote: "return user!", note: "force unwrap"),
            .init(file: "src/A.swift", line: 9, quote: "let user = load(id: route.id)", note: "the screen calls it"),
        ])
        ReviewCandidates.checkTrace(&traced, worktree: worktree)
        #expect(traced.traced == true)
        #expect(traced.trace?.allSatisfy { $0.found == true } == true)
        #expect(traced.trace?[2].line == 7, "a misnumbered step moves to its quote")
    }

    @Test func onlyTheAnchoredLinesOrAnInventedQuoteIsNoTrace() {
        let (home, worktree) = worktree()
        _ = home
        var own = finding(trace: [.init(file: "src/A.swift", line: 3, quote: "return user!", note: "force unwrap")])
        ReviewCandidates.checkTrace(&own, worktree: worktree)
        #expect(own.traced == false, "the finding's own line is no trace")
        var near = finding(trace: [.init(file: "src/A.swift", line: 2, quote: "let user = cache[id ?? \"\"]", note: "read from the cache")])
        ReviewCandidates.checkTrace(&near, worktree: worktree)
        #expect(near.traced == true, "where the value comes from, a line above")
        var invented = finding(trace: [.init(file: "src/Other.swift", line: 4, quote: "let session = Session.current()", note: "made up")])
        ReviewCandidates.checkTrace(&invented, worktree: worktree)
        #expect(invented.traced == false && invented.trace?.first?.found == nil, "a file that isn't there can't be checked")
        var short = finding(trace: [.init(file: "src/A.swift", line: 8, quote: "user", note: "too short to tell")])
        ReviewCandidates.checkTrace(&short, worktree: worktree)
        #expect(short.traced == false, "a short piece counts only as a whole line")
        var none = finding(trace: nil)
        ReviewCandidates.checkTrace(&none, worktree: worktree)
        #expect(none.traced == false)
        #expect(ReviewCandidates.verifierInput([none], worktree: worktree).contains("Trace: none"))
    }

    @Test func withoutAWorktreeOrForAQuestionAKitCantTell() {
        var noTree = finding(trace: nil)
        ReviewCandidates.checkTrace(&noTree, worktree: nil)
        #expect(noTree.traced == nil)
        let (home, worktree) = worktree()
        _ = home
        var question = finding(trace: nil)
        question.kind = .question
        ReviewCandidates.checkTrace(&question, worktree: worktree)
        #expect(question.traced == nil)
        var carried = finding(trace: nil)
        carried.carriedFrom = "run-1"
        ReviewCandidates.checkTrace(&carried, worktree: worktree)
        #expect(carried.traced == nil, "a finding from before R68 keeps its say")
    }

    @Test func theVerifiersTraceCounts() throws {
        let (home, worktree) = worktree()
        let verdicts = home.write("run/passes/verifier.json", """
            {"verdicts": [{"id": "f1", "verdict": "confirmed", "note": "real", "confidence": 0.9,
              "trace": [{"file": "src/A.swift", "line": 8, "quote": "title = user.name", "note": "the screen reads it"}]}]}
            """)
        var untraced = finding(trace: nil)
        ReviewCandidates.checkTrace(&untraced, worktree: worktree)
        let applied = ReviewCandidates.apply(verdictsFile: verdicts, to: [untraced], worktree: worktree)
        #expect(applied.first?.traced == true)
        #expect(applied.first?.verifier?.trace?.first?.found == true)
    }

    @Test func anUntracedFindingStaysInAKit() throws {
        var untraced = PlanTests.finding("f1")
        untraced.traced = false
        var traced = PlanTests.finding("f2", line: 3)
        traced.traced = true
        var unknown = PlanTests.finding("f3", line: 1)
        unknown.traced = nil
        let plan = try PlanTests.plan([untraced, traced, unknown])
        let first = plan.placements.first { $0.findingID == "f1" }
        #expect(first?.place == .onlyInAKit && first?.reason.hasPrefix("No traced path") == true)
        #expect(plan.placements.first { $0.findingID == "f2" }?.place == .inline)
        #expect(plan.placements.first { $0.findingID == "f3" }?.place == .inline, "nil: AKit couldn't tell")
        #expect(try PlanTests.plan([untraced], forced: ["f1"]).placements.first?.place == .inline, "Move Inline still wins")
    }

    @Test func aRolesTraceComesThroughTheCandidates() throws {
        let (home, worktree) = worktree()
        home.write("run/passes/role-bug-hunter.json", """
            {"findings": [{"file": "src/A.swift", "line": 3, "title": "Crash", "evidence": "return user!", "why": "w", "severity": "high",
              "confidence": 0.9, "trace": [{"file": "./src/A.swift", "line": 7, "quote": "let user = load(id: route.id)", "note": "the caller"},
              {"file": "src/A.swift", "quote": ""}]}]}
            """)
        let spec = try PlanTests.spec()
        let found = ReviewCandidates.collect(folder: home.url.appending(path: "run"), spec: spec, worktree: worktree)
        #expect(found.first?.trace?.count == 1, "a step without a quote can't be checked, so it isn't one")
        #expect(found.first?.trace?.first?.file == "src/A.swift")
        #expect(found.first?.traced == true)
    }

    @Test func aDoNotCommentItemWithAColonStaysText() throws {
        let role = try #require(ReviewBuiltIns.roles.first { $0.id == "bug-hunter" })
        #expect(role.doNotComment.contains("pure speculation: nothing in the changed lines points to the problem"))
        #expect(ReviewYAML.strings([["a": "b"], "c"]) == ["a: b", "c"], "an unquoted `- a: b` a person wrote")
    }

    @Test func theExtensionAsksForATrace() {
        let text = ReviewExtension.source
        #expect(text.contains("trace is missing: the path from the cause to the harm"))
        #expect(text.contains("function traceProblems"))
    }
}
