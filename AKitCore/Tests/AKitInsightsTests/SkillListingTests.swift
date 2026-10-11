import Foundation
import Testing
import AKitBrain
import AKitFoundation
@testable import AKitCommandLine
@testable import AKitInsights

/// `akit stats listing` and the Skill Listing box: Claude Code's listing per session against its
/// budget. Same fixtures as `RecommenderTests` (a fake home, a temporary index).
extension RecommenderTests {
    /// A main Claude session with one request of `model` and `context` tokens, listing `skills`
    /// (name → description characters; nil: by name only).
    func listingSession(_ id: String, model: String = "claude-opus-4-6", context: Int = 50_000, skills: [String: Int?], daysAgo: Int = 2,
                        in db: IndexDatabase) throws {
        let ts = at(daysAgo)
        try session(id, started: ts, in: db)
        for (skill, chars) in skills { try listing(id, skill, at: ts, hash: chars == nil ? nil : "h-\(skill)", chars: chars ?? 0, in: db) }
        try db.run("""
            INSERT INTO requests(harness, event_key, session_key, ts, model, input, cache_read, cache_write, is_subagent, source_id, parser_version)
            VALUES('claude', ?, ?, ?, ?, ?, 0, 0, 0, 0, 1)
            """, UUID().uuidString, "claude:\(id)", ts + 60, model, context)
    }

    func defaults(env budget: Int? = nil) -> ListingReport.Settings {
        .init(fraction: 0.01, fractionFrom: "default", maxDescChars: 1536, maxDescCharsFrom: "default", envBudget: budget,
              file: "~/.claude/settings.json", problems: [])
    }

    @Test func theBudgetFollowsClaudeCodesFormula() {
        #expect(SkillListing.charsPerToken(model: "claude-opus-4-6") == 4 && SkillListing.charsPerToken(model: "claude-opus-4-6[1m]") == 4)
        #expect(SkillListing.charsPerToken(model: "claude-sonnet-4-5-20250929") == 4 && SkillListing.charsPerToken(model: nil) == 4)
        #expect(SkillListing.charsPerToken(model: "claude-opus-5-5") == 3 && SkillListing.charsPerToken(model: "claude-sonnet-5") == 3)
        #expect(SkillListing.budget(context: 200_000, model: "claude-opus-4-6", fraction: 0.01, envBudget: nil) == 8_000)
        #expect(SkillListing.budget(context: 1_000_000, model: "claude-opus-4-6", fraction: 0.01, envBudget: nil) == 40_000)
        #expect(SkillListing.budget(context: 200_000, model: "claude-opus-5-5", fraction: 0.01, envBudget: nil) == 6_000)
        #expect(SkillListing.budget(context: 200_000, model: "claude-opus-4-6", fraction: 0.01, envBudget: 12_345) == 12_345)
        #expect(SkillListing.roundUp(0.01301) == 0.014)
    }

    @Test func sessionsOverBudgetAndTheFractionThatKeepsEveryDescription() throws {
        let db = try database()
        // 40 skills of 200 characters: 40 × (2–3 + 4 + 200) + 39 ≈ 8.3k characters, over 8,000 at 200k.
        let many = Dictionary(uniqueKeysWithValues: (0..<40).map { ("s\($0)", Optional(200)) })
        try listingSession("big", skills: many, in: db)
        // The same listing over budget as Claude Code sent it: 10 of them by name only.
        var dropped = many
        for index in 30..<40 { dropped["s\(index)"] = .some(nil) }
        try listingSession("cut", skills: dropped, in: db)
        // A small one, and one in a 1M context (a request above 200k), which fits.
        try listingSession("small", skills: ["s0": 200, "s1": 200], in: db)
        try listingSession("wide", context: 400_000, skills: many, in: db)

        let report = try SkillListing.report(db, days: 30, settings: defaults(), now: now)
        #expect(report.sessions.count == 4 && report.sessions.overBudget == 2, "\(report.sessions)")
        let full = (0..<40).reduce(0) { $0 + "s\($1)".count + 4 + 200 } + 39
        #expect(report.now.neededFraction == SkillListing.roundUp(Double(full) / 800_000))
        #expect(report.sessions.medianBudget == 8_000)
        // The cut session lost 10 descriptions: ≈ (10 × 200 restored characters) / 4.
        #expect(report.now.extraTokensPerRequest > 0)
        #expect(report.raiseTo == report.now.neededFraction, "no recommendation: raising is the only fix")

        // The recommendations take 10 skills out of the listing: every session fits, so Raise is not offered.
        let fixed = try SkillListing.report(db, days: 30, settings: defaults(), dropping: Set((30..<40).map { "s\($0)" }), now: now)
        #expect(fixed.afterFixes?.overBudget == 0 && fixed.afterFixes?.neededFraction == nil && fixed.raiseTo == nil)
        #expect(fixed.fixSkills.count == 10)
        // The shell's budget wins.
        let env = try SkillListing.report(db, days: 30, settings: defaults(env: 20_000), now: now)
        #expect(env.sessions.overBudget == 0 && env.notes.first?.hasPrefix("SLASH_COMMAND_TOOL_CHAR_BUDGET is set") == true)

        let text = AKitCLI.listingText(report)
        #expect(text.contains("4 sessions: listing median") && text.contains("2 over budget (50%)"), "\(text)")
        #expect(text.contains("  2. Then raise skillListingBudgetFraction to \(report.raiseTo ?? 0) in ~/.claude/settings.json"))
    }

    @Test func settingsComeFromTheUserAndProjectFilesNeverTheLocalOne() throws {
        try write(".claude/settings.json", #"{"skillListingBudgetFraction": 0.02, "skillListingMaxDescChars": 500, "apiKeyHelper": "secret-helper"}"#)
        let project = home.appending(path: "Projects/app")
        try write("Projects/app/.claude/settings.json", #"{"skillListingBudgetFraction": 0.03}"#)
        try write("Projects/app/.claude/settings.local.json", #"{"skillListingBudgetFraction": 0.5}"#)
        let user = SkillListing.settings(env: env, project: nil)
        #expect(user.fraction == 0.02 && user.maxDescChars == 500 && user.fractionFrom == "~/.claude/settings.json" && user.envBudget == nil)
        let scoped = SkillListing.settings(env: env, project: project, environment: ["SLASH_COMMAND_TOOL_CHAR_BUDGET": "9000"])
        #expect(scoped.fraction == 0.03 && scoped.fractionFrom == "~/Projects/app/.claude/settings.json" && scoped.maxDescChars == 500)
        #expect(scoped.envBudget == 9000 && scoped.file == "~/Projects/app/.claude/settings.json")

        try write(".claude/settings.json", #"{"skillListingBudgetFraction": 2}"#)
        let wrong = SkillListing.settings(env: env, project: nil)
        #expect(wrong.fraction == 0.01 && wrong.problems.first?.contains("must be a number above 0 and at most 1") == true)
    }

    @Test func raiseBudgetChangesOnlyThatKeyAfterABackup() throws {
        try write(".claude/settings.json", "{\n  \"apiKeyHelper\": \"secret-helper\",\n  \"model\": \"opus\"\n}\n")
        let settings = SkillListing.settings(env: env, project: nil)
        let change = try SkillListing.raise(to: 0.014, settings: settings, env: env)
        let shown = change.diff.map { line -> String in
            switch line {
            case .added(let text), .removed(let text), .same(let text): text
            }
        }.joined(separator: "\n")
        #expect(shown.contains("skillListingBudgetFraction") && !shown.contains("secret-helper"), "\(shown)")
        let backup = try SettingsFile.apply(change, home: home)
        #expect(backup != nil)
        let after = try read(".claude/settings.json")
        #expect(after.contains("\"skillListingBudgetFraction\": 0.014") && after.contains("\"apiKeyHelper\": \"secret-helper\""))
        #expect(SkillListing.settings(env: env, project: nil).fraction == 0.014)
    }
}
