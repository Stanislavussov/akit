import Foundation
import Testing
import AKitFoundation
import AKitInsights
@testable import AKitErrorAnalysis
@testable import AKitLab

@Suite(.serialized)
struct FixesTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-fixes-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var env: HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home, variables: ["HOME": home.path], executableSearchPaths: [URL(filePath: "/usr/bin"), URL(filePath: "/bin")])
    }

    @Test func theHelpedRule() {
        // 50% → 15% with 40 sessions a side: helped.
        let helped = Fixes.evaluate(modeID: "m", appliedAt: .now, before: (20, 40, "opus"), after: (6, 40, "opus"), trust: .exact)
        #expect(helped.verdict == .helped && helped.probabilityLower > 0.99 && helped.probabilityHigher < 0.01)
        #expect(helped.flags.isEmpty)
        // The same change with 10 sessions a side: no conclusion.
        #expect(Fixes.evaluate(modeID: "m", appliedAt: .now, before: (5, 10, nil), after: (1, 10, nil), trust: .exact).verdict == .noConclusion)
        // A small change: not shown; a model switch and a heuristic check are flagged.
        let small = Fixes.evaluate(modeID: "m", appliedAt: .now, before: (10, 40, "opus"), after: (8, 40, "sonnet"), trust: .none)
        #expect(small.verdict == .notShown)
        #expect(small.flags.count == 2)
        #expect(abs(small.fisherP - Stats.fisherExact(10, 40, 8, 40)) < 1e-12)
    }

    @Test func minimumDetectableEffectMatchesTheDesignsGuide() throws {
        // About 30 per group: only large effects show (around 50% → 15%).
        let thirty = try #require(Fixes.minimumDetectable(from: 0.5, perSide: 30))
        #expect(thirty > 0.1 && thirty < 0.2)
        // 20% → 5% needs about 80 per group.
        let eighty = try #require(Fixes.minimumDetectable(from: 0.2, perSide: 80))
        #expect(abs(eighty - 0.05) < 0.02)
        #expect(Fixes.minimumDetectable(from: 0.05, perSide: 10) == nil)
    }

    @Test func draftsBecomeControlPatches() throws {
        let rule = FixDraft(modeID: "m", layer: .claudeMD, text: "- Run the tests before saying done.", expectedChange: "a test run before done",
                            helpedCriterion: "P ≥ 0.95", createdAt: Date(timeIntervalSince1970: 1_790_000_000))
        #expect(rule.patch == ControlPatch(file: "CLAUDE.md", text: "- Run the tests before saying done."))
        #expect(FixDraft(modeID: "m", layer: .skill, skillName: "verify", text: "x", expectedChange: "", helpedCriterion: "").patch?.file
                == ".claude/skills/verify/SKILL.md")
        #expect(FixDraft(modeID: "m", layer: .hook, text: "x", expectedChange: "", helpedCriterion: "").patch == nil)
        try FixStore(env: env).save(rule)
        #expect(FixStore(env: env).load("m") == rule)
    }

    /// Sessions started before and after T, with the mode's check verdicts.
    @Test func beforeAndAfterTOverIndexedSessions() async throws {
        let folder = home.appending(path: ".claude/projects/-w")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var verdicts: [String: CheckVerdict] = [:]
        let formatter = ISO8601DateFormatter()
        for index in 0..<40 {
            let id = String(format: "%08x-0000-4000-8000-%012x", index, index)
            let day = index < 20 ? "2026-09-10" : "2026-09-25"
            let line: [String: Any] = ["type": "user", "cwd": "/w", "sessionId": id, "timestamp": "\(day)T10:00:00Z",
                                       "message": ["role": "user", "content": "task \(index)"]]
            try Data((String(decoding: try JSONSerialization.data(withJSONObject: line), as: UTF8.self) + "\n").utf8)
                .write(to: folder.appending(path: "\(id).jsonl"))
            // Before T: 12 of 20 fail; after: 2 of 20.
            verdicts["claude:\(id)"] = CheckVerdict(positive: index < 20 ? index < 12 : index < 22, version: 1)
        }
        let database = try IndexSchema.open(InsightsPaths(env: env).database)
        _ = try await SessionImporter.importAndBind(env: env, projectsRoot: home.appending(path: "Projects"), database: database)
        try CheckStore(env: env).save(CheckResults(modeID: "large-file-read-whole", verdicts: verdicts))
        var mode = Mode(id: "large-file-read-whole", name: "Large file read whole", kind: .efficiency, definition: "d", origin: .seedPrior)
        mode.status = .active
        mode.fixAppliedAt = formatter.date(from: "2026-09-20T00:00:00Z")
        let evaluation = try #require(try Fixes.evaluate(mode, env: env, now: formatter.date(from: "2026-09-30T00:00:00Z")!))
        #expect(evaluation.before.sessions == 20 && evaluation.before.failures == 12)
        #expect(evaluation.after.sessions == 20 && evaluation.after.failures == 2)
        #expect(evaluation.verdict == .helped && evaluation.checkTrust == .exact)
    }
}
