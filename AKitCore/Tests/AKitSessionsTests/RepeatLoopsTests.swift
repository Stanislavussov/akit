import Foundation
import Testing
@testable import AKitSessions

struct RepeatLoopsTests {
    /// Builds items in order; ids are their positions.
    struct Script {
        var items: [TranscriptItem] = []
        mutating func add(_ kind: TranscriptItem.Kind, _ text: String) {
            items.append(TranscriptItem(id: items.count, kind: kind, text: text, timestamp: Date(timeIntervalSince1970: Double(items.count))))
        }
        mutating func user(_ text: String) { add(.user, text) }
        mutating func answer(_ text: String) { add(.assistant, text) }
        mutating func edit(_ path: String) { add(.toolCall(name: "Edit"), #"{"file_path":"\#(path)","new_string":"x"}"#) }
        mutating func event(_ title: String, _ text: String) { add(.event(title), text) }
    }

    let error = "pnpm db:migrate error: relation users already exists at migrate.ts line 12"

    @Test func sameErrorPastedThreeTimesWithTheSameFixIsALoop() {
        var s = Script()
        s.event("Model", "openrouter/qwen")
        s.event("Thinking level", "low")
        s.user(error)
        s.edit("/p/0001.sql"); s.answer("Added IF NOT EXISTS to the CREATE TABLE statements. Try again.")
        s.user(error + " (second run)")
        s.edit("/p/0001.sql"); s.answer("Changed the ADD COLUMN statements. Try again.")
        s.user("still the same error " + error)
        s.edit("/p/0001.sql"); s.answer("This file looks fine. Try again.")
        let loops = RepeatLoops.find(s.items)
        #expect(loops.count == 1)
        let loop = loops[0]
        #expect(loop.asks == 3)
        #expect(loop.firstStep == 2)
        #expect(loop.lastStep == 8)
        #expect(loop.model == "openrouter/qwen")
        #expect(loop.thinking == "low")
        #expect(RepeatLoops.ongoing(s.items) == loop)
    }

    @Test func oneRepeatIsNotALoop() {
        var s = Script()
        s.user("Fix the login bug"); s.answer("I changed the token check in auth.swift.")
        s.user("still broken"); s.answer("I changed the token check in auth.swift again.")
        s.user("Now add a logout button"); s.answer("Added a logout button.")
        #expect(RepeatLoops.find(s.items).isEmpty)
    }

    @Test func differentAnswersAreNotALoop() {
        var s = Script()
        s.user("do this"); s.answer("Run the migration with the full DATABASE_URL.")
        s.user("do this"); s.answer("Let me back up the migration folder first and regenerate the snapshot.")
        s.user("do this"); s.answer("Fixed! The old migrations are archived.")
        #expect(RepeatLoops.find(s.items).isEmpty)
    }

    @Test func anEmptyAnswerIsTheHarnessNotARepeat() {
        var s = Script()
        s.user("add a task for input limits")
        s.user("add a task for input limits")
        s.user("add a task for input limits")
        #expect(RepeatLoops.find(s.items).isEmpty)
    }

    @Test func theSameSkillInFrontIsNotTheSameAsk() {
        var s = Script()
        let skill = "<skill name=\"task-creator\" location=\"/s/SKILL.md\">" + String(repeating: "Create a task file in docs/tasks with a goal and steps. ", count: 20) + "</skill>"
        s.user(skill + " token usage tracking"); s.edit("/p/24.md"); s.answer("Created docs/tasks/24-token-usage.md")
        s.user(skill + " language flag on the card"); s.edit("/p/25.md"); s.answer("Created docs/tasks/25-language-flag.md")
        s.user(skill + " diacritics in translation"); s.edit("/p/26.md"); s.answer("Created docs/tasks/26-diacritics.md")
        #expect(RepeatLoops.find(s.items).isEmpty)
    }

    @Test func aLoopEndsWhenTheUserMovesOn() {
        var s = Script()
        s.user("the build fails: error TS5055 cannot write file dist/index.d.ts"); s.edit("/p/tsconfig.json"); s.answer("Set outDir.")
        s.user("опять error TS5055 cannot write file"); s.edit("/p/tsconfig.json"); s.answer("Set rootDir.")
        s.user("still TS5055"); s.edit("/p/tsconfig.json"); s.answer("Excluded dist.")
        s.user("ok, now write the README"); s.edit("/p/README.md"); s.answer("Wrote the README.")
        let loops = RepeatLoops.find(s.items)
        #expect(loops.count == 1)
        #expect(loops.first?.asks == 3)
        #expect(RepeatLoops.ongoing(s.items) == nil)
    }

    @Test func claudeCommandsSetModelAndEffortAndAreNotAsks() {
        var s = Script()
        s.event("Command", "/model sonnet")
        s.event("Command", "/effort low")
        s.user("the test testLogin fails with a nil token"); s.edit("/p/Auth.swift"); s.answer("Fixed the nil token in Auth.swift.")
        s.user("still fails"); s.edit("/p/Auth.swift"); s.answer("Fixed the nil token in Auth.swift by a default.")
        s.user("/compact")
        s.user("still fails, same error"); s.edit("/p/Auth.swift"); s.answer("Fixed the nil token in Auth.swift with a guard.")
        let loop = RepeatLoops.find(s.items, fallbackModel: "claude-opus-5-5").first
        #expect(loop?.asks == 3)
        #expect(loop?.model == "sonnet")
        #expect(loop?.thinking == "low")
    }

    @Test func fallbackModelWhenTheLogHasNone() {
        var s = Script()
        s.user(error); s.answer("Added IF NOT EXISTS. Try again.")
        s.user(error); s.answer("Added IF NOT EXISTS again. Try again.")
        s.user(error); s.answer("Added IF NOT EXISTS once more. Try again.")
        let loop = RepeatLoops.find(s.items, fallbackModel: "claude-opus-5-5").first
        #expect(loop?.model == "claude-opus-5-5")
        #expect(loop?.thinking == nil)
    }

    @Test func similarity() {
        #expect(RepeatLoops.similarity("Fix the bug", "fix the BUG") == 1)
        #expect(RepeatLoops.similarity("Fix the bug", "Write the docs") < 0.3)
        #expect(RepeatLoops.similarity("", "anything") == 0)
    }

    @Test func retryPhrases() {
        #expect(RepeatLoops.isRetry("Still doesn't work"))
        #expect(RepeatLoops.isRetry("всё ещё та же ошибка"))
        #expect(RepeatLoops.isRetry("pořád nefunguje"))
        #expect(!RepeatLoops.isRetry("Add a static image to the page header"))
    }
}
