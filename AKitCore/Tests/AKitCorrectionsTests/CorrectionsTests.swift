import Foundation
import Testing
import AKitErrorAnalysis
import AKitFoundation
import AKitInsights
import AKitSessions
@testable import AKitCorrections

/// Corrections by code: excerpts, the checks of the model's answer, the rule's text and the verdict.
struct CorrectionsTests {
    func excerpt(_ id: String, session: String, step: Int, project: String? = "akit", words: String = "no, run the tests") -> CorrectionExcerpt {
        CorrectionExcerpt(id: id, sessionKey: session, file: nil, project: project, step: step, kind: .pushback, words: words,
                          before: [], started: nil)
    }

    var pick: CorrectionPick {
        CorrectionPick(excerpts: [excerpt("s1.r1", session: "claude:a", step: 4), excerpt("s1.r2", session: "claude:a", step: 9),
                                  excerpt("s2.r1", session: "pi:b", step: 3, project: "web")],
                       sessions: 2, input: "", cut: 0)
    }

    // MARK: - The answer

    @Test func checksDropUnknownIdsAndSingleSessionPatterns() throws {
        let answer = """
        Here you go:
        ```json
        {"patterns": [
          {"title": "Claims done without running the tests", "reactionIds": ["s1.r1", "S2.R1", "s9.r1"],
           "rule": ["When you finish a change, run the tests.", "- Say which command ran."]},
          {"title": "One session only", "reactionIds": ["s1.r1", "s1.r2"], "rule": ["x"]},
          {"title": "", "reactionIds": ["s1.r1", "s2.r1"], "rule": ["y"]}
        ]}
        ```
        """
        let patterns = try Corrections.checked(answer: answer, pick: pick, now: Date(timeIntervalSince1970: 0))
        #expect(patterns.count == 1)
        let pattern = try #require(patterns.first)
        #expect(pattern.reactions.map(\.id) == ["s1.r1", "s2.r1"])
        #expect(pattern.rule == ["When you finish a change, run the tests.", "Say which command ran."])
        #expect(pattern.reactions.allSatisfy { $0.words == "no, run the tests" })
        // Two projects: global.
        #expect(pattern.scope == nil && pattern.id.hasPrefix("p-") && pattern.sessions == 2)
    }

    @Test func checksReadLenientShapesAndCutTitlesAndRules() throws {
        let answer = #"[{"title": "one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen", "reactions": "s1.r2, s2.r1", "rule": "a\nb\nc\nd\ne"}]"#
        let pattern = try #require(try Corrections.checked(answer: answer, pick: pick, now: Date()).first)
        #expect(pattern.title.hasSuffix("fifteen…"))
        #expect(pattern.rule == ["a", "b", "c", "d"])
        #expect(throws: Corrections.Failure.self) { try Corrections.checked(answer: "no json here", pick: pick, now: Date()) }
    }

    @Test func oneProjectGivesThatScopeAndTheSameReactionsTheSameID() throws {
        let local = CorrectionPick(excerpts: [excerpt("s1.r1", session: "claude:a", step: 4), excerpt("s2.r1", session: "claude:c", step: 2)],
                                   sessions: 2, input: "", cut: 0)
        let answer = #"{"patterns":[{"title":"t","reactionIds":["s2.r1","s1.r1"],"rule":["r"]}]}"#
        let first = try #require(try Corrections.checked(answer: answer, pick: local, now: Date()).first)
        let again = try #require(try Corrections.checked(answer: #"{"patterns":[{"title":"other","reactionIds":["s1.r1","s2.r1"],"rule":["r"]}]}"#,
                                                          pick: local, now: Date()).first)
        #expect(first.scope == "akit" && first.id == again.id)
    }

    // MARK: - State

    @Test func appliedAndDismissedPatternsAreNotShownAgain() {
        let pattern = CorrectionPattern(id: "p-1", title: "Runs no tests", rule: ["r"], reactions: [excerpt("s1.r1", session: "claude:a", step: 4)],
                                        scope: nil, found: Date())
        var state = CorrectionsState(patterns: [pattern])
        #expect(state.shown == [pattern])
        state.rules = [CorrectionRule(id: "p-2", title: "runs no TESTS", rule: ["r"], scope: nil, target: "global", applied: Date(), places: [])]
        #expect(state.shown.isEmpty)
        state.rules = [CorrectionRule(id: "p-2", title: "other", rule: ["r"], scope: nil, target: "global", applied: Date(), places: ["claude:a#4"])]
        #expect(state.shown.isEmpty)
        state.rules = []
        state.dismiss(pattern)
        #expect(state.shown.isEmpty && state.dismissed == ["p-1", "runs no tests"])
    }

    // MARK: - Rule text

    @Test func addingPutsTheBulletUnderOneHeading() {
        let bullet = CorrectionRules.bullet(["Run the tests after a change.", "Say which command ran."])
        #expect(bullet == "- Run the tests after a change.\n  Say which command ran.")
        #expect(CorrectionRules.adding(bullet, to: "") == "## Rules from corrections\n\n\(bullet)\n")
        let first = CorrectionRules.adding(bullet, to: "# Project\n\nText.\n")
        #expect(first == "# Project\n\nText.\n\n## Rules from corrections\n\n\(bullet)\n")
        let second = CorrectionRules.adding("- Ask first.", to: first + "\n## Later\n\nMore.\n")
        #expect(second == "# Project\n\nText.\n\n## Rules from corrections\n\n\(bullet)\n- Ask first.\n\n## Later\n\nMore.\n")
    }

    @Test func removingTakesTheBulletAndAnEmptyHeadingOut() throws {
        let bullet = CorrectionRules.bullet(["Run the tests.", "Say which."])
        let one = CorrectionRules.adding(bullet, to: "# Project\n\nText.\n")
        #expect(CorrectionRules.removing(bullet, from: one) == "# Project\n\nText.\n")
        let two = CorrectionRules.adding("- Ask first.", to: one + "\n## Later\n\nMore.\n")
        #expect(CorrectionRules.removing(bullet, from: two) == "# Project\n\nText.\n\n## Rules from corrections\n\n- Ask first.\n\n## Later\n\nMore.\n")
        let alone = try #require(CorrectionRules.removing("- Ask first.", from: CorrectionRules.adding("- Ask first.", to: "")))
        #expect(alone.isEmpty)
        #expect(CorrectionRules.removing("- Not there.", from: one) == nil)
        #expect(CorrectionRules.removing(bullet, from: "No heading") == nil)
    }

    @Test func crlfFilesAndHeadingVariantsKeepTheirLineEnds() throws {
        let file = "# Project\r\n\r\n## rules  from Corrections\r\n\r\n- Ask first.\r\n"
        let added = CorrectionRules.adding("- Run the tests.", to: file)
        #expect(added == "# Project\r\n\r\n## rules  from Corrections\r\n\r\n- Ask first.\r\n- Run the tests.\r\n")
        #expect(CorrectionRules.contains("- Run the tests.", in: added) && !CorrectionRules.contains("- Other.", in: added))
        #expect(CorrectionRules.removing("- Run the tests.", from: added) == file)
        let fresh = CorrectionRules.adding("- A.", to: "Text.\r\n")
        #expect(fresh == "Text.\r\n\r\n## Rules from corrections\r\n\r\n- A.\r\n")
    }

    @Test func ruleLinesKeepBoldAndSplitCRLF() throws {
        let answer = #"{"patterns":[{"title":"t","reactionIds":["s1.r1","s2.r1"],"rule":"**Always** run tests.\r\n- Say which."}]}"#
        let pattern = try #require(try Corrections.checked(answer: answer, pick: pick, now: Date()).first)
        #expect(pattern.rule == ["**Always** run tests.", "Say which."])
    }

    @Test func projectFileIsTheOneTheHarnessesRead() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "akit-corrections-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(CorrectionRules.projectFile(in: folder, harnesses: ["pi"]).lastPathComponent == "AGENTS.md")
        #expect(CorrectionRules.projectFile(in: folder, harnesses: ["claude", "pi"]).lastPathComponent == "CLAUDE.md")
        try Data().write(to: folder.appending(path: "AGENTS.md"))
        #expect(CorrectionRules.projectFile(in: folder, harnesses: ["claude"]).lastPathComponent == "AGENTS.md")
        try Data().write(to: folder.appending(path: "CLAUDE.md"))
        #expect(CorrectionRules.projectFile(in: folder, harnesses: ["claude"]).lastPathComponent == "CLAUDE.md")
        #expect(CorrectionRules.projectFile(in: folder, harnesses: ["pi"]).lastPathComponent == "AGENTS.md")
    }

    // MARK: - Verdict

    func sessions(_ count: Int, corrected: Int, model: String = "opus", start: Date) -> [CorrectedSession] {
        (0..<count).map { index in
            CorrectedSession(key: "claude:\(model)-\(start.timeIntervalSince1970)-\(index)", harness: "claude", file: nil, cwd: nil, project: nil,
                             started: start.addingTimeInterval(Double(index) * 60), harnessVersion: "2.1.\(index)", model: model,
                             interrupts: 0, pushbacks: index < corrected ? 1 : 0, refusals: 0, badRatings: 0)
        }
    }

    var rule: CorrectionRule {
        CorrectionRule(id: "p-1", title: "t", rule: ["r"], scope: nil, target: "global", applied: Date(timeIntervalSince1970: 1_000_000), places: [])
    }

    @Test func verdictWaitsForTenSessionsOnTheSameModel() {
        let applied = rule.applied
        let before = sessions(8, corrected: 4, start: applied.addingTimeInterval(-86_400))
        let waiting = CorrectionVerdict.judge(rule, before: before, after: sessions(6, corrected: 0, start: applied), now: applied)
        #expect(waiting.status == .waiting && waiting.note.hasPrefix("4 more sessions on claude · opus"))
        let otherModel = CorrectionVerdict.judge(rule, before: before, after: sessions(12, corrected: 0, model: "sonnet", start: applied), now: applied)
        #expect(otherModel.status == .waiting && otherModel.group == nil)
    }

    @Test func verdictComparesShares() {
        let applied = rule.applied
        let before = sessions(10, corrected: 5, start: applied.addingTimeInterval(-86_400))
        #expect(CorrectionVerdict.judge(rule, before: before, after: sessions(10, corrected: 2, start: applied), now: applied).status == .fewer)
        #expect(CorrectionVerdict.judge(rule, before: before, after: sessions(10, corrected: 5, start: applied), now: applied).status == .noChange)
        let more = CorrectionVerdict.judge(rule, before: before, after: sessions(10, corrected: 8, start: applied), now: applied)
        #expect(more.status == .more && more.offersRemove && more.before?.corrected == 5 && more.after?.corrected == 8)
        var removed = rule
        removed.removed = applied
        #expect(CorrectionVerdict.judge(removed, before: before, after: [], now: applied).status == .removed)
    }

    // MARK: - Excerpts

    @Test func excerptsTakeTheWordsAfterAnInterruptAndTheStepsBefore() {
        let items = [
            TranscriptItem(id: 0, kind: .user, text: "Add a button", timestamp: nil),
            TranscriptItem(id: 1, kind: .assistant, text: "I'll edit the view.", timestamp: nil),
            TranscriptItem(id: 2, kind: .toolCall(name: "Edit"), text: "file_path: View.swift", timestamp: nil),
            TranscriptItem(id: 3, kind: .toolResult(name: "Edit", isError: false), text: "ok", timestamp: nil),
            TranscriptItem(id: 4, kind: .assistant, text: String(repeating: "x", count: 500), timestamp: nil),
            TranscriptItem(id: 5, kind: .user, text: "[Request interrupted by user]", timestamp: nil),
            TranscriptItem(id: 6, kind: .user, text: "use the existing style instead", timestamp: nil),
            TranscriptItem(id: 7, kind: .assistant, text: "Done.", timestamp: nil),
            TranscriptItem(id: 8, kind: .user, text: "no, that is not what I asked", timestamp: nil),
        ]
        let session = CorrectedSession(key: "claude:a", harness: "claude", file: "/x.jsonl", cwd: nil, project: "akit", started: nil,
                                       harnessVersion: nil, model: nil, interrupts: 1, pushbacks: 1, refusals: 0, badRatings: 0)
        let found = CorrectionExcerpts.excerpts(of: items, ratings: [], session: session, prefix: "s1")
        #expect(found.map(\.id) == ["s1.r1", "s1.r3"])
        #expect(found[0].kind == .interrupt && found[0].words == "use the existing style instead")
        #expect(found[0].before.map(\.label) == ["tool Edit", "result", "agent"])
        #expect(found[0].before[2].text.count == CorrectionExcerpts.stepLimit + 1)
        #expect(found[1].words == "no, that is not what I asked" && found[1].before.map(\.label) == ["agent"])
        let text = CorrectionExcerpts.text(found, session: session, number: 1)
        #expect(text.contains("## Session s1 · claude · project akit"))
        #expect(text.contains("> s1.r1 · interrupt · user: \"use the existing style instead\""))
    }
}
