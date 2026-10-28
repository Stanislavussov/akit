import Foundation
import Testing
import AKitFoundation
@testable import AKitKnowledge

/// The work log (docs/design/worklog.md): one file per day, entries in time order, how long each lasted.
final class KnowledgeWorkLogTests {
    deinit { try? FileManager.default.removeItem(at: home) }

    let home: URL
    init() throws { home = try FakeHome.make("akit-kb-worklog") }
    var env: HarnessEnvironment { FakeHome.env(home) }

    func worklog() async throws -> KnowledgeWorkLog { KnowledgeWorkLog(base: try await TemplateBase.base(home: home)) }

    func date(_ text: String) -> Date {
        var parts = DateComponents()
        let numbers = text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        (parts.year, parts.month, parts.day, parts.hour, parts.minute) = (numbers[0], numbers[1], numbers[2], numbers[3], numbers[4])
        return Calendar.current.date(from: parts)!
    }

    @Test func entriesGetTheirDayAndTimeAndKeepTimeOrder() async throws {
        let log = try await worklog()
        let first = try log.add("Review of COL-1", kind: "Agent", at: date("2026-10-28 09:14"))
        #expect(first.path == "worklog/2026-10-28.md")
        #expect(first.entry == .init(line: 0, time: "09:14", kind: "agent", text: "Review of COL-1"))
        _ = try log.add("#bug Login fails\nin Safari", kind: nil, at: date("2026-10-28 10:05"))
        // An earlier time goes between them.
        _ = try log.add("", kind: "reply", day: "2026-10-28", time: "9:30")
        #expect(try log.text("2026-10-28") == "- 09:14 #agent Review of COL-1\n- 09:30 #reply\n- 10:05 #bug Login fails in Safari\n")
        _ = try log.add("x", kind: nil, at: date("2026-10-29 08:00"))
        #expect(log.days() == ["2026-10-29", "2026-10-28"])
        #expect(throws: KnowledgeBase.Failure.self) { try log.add("  ", kind: nil, at: .now) }
        #expect(throws: KnowledgeBase.Failure.self) { try log.add("x", kind: "a b", at: .now) }
    }

    @Test func anEntryLastsUntilTheNextAndTheLastOfTodayUntilNow() {
        let text = "# Notes kept as they are\n- 09:00 #agent a\n- 09:45 #break\n- 10:00 #bug b\n- 10:30 c\n"
        let past = KnowledgeWorkLog.day("2026-10-27", text: text, now: date("2026-10-28 12:00"))
        #expect(past.minutes == [45, 15, 30, nil])
        #expect(past.totals.map(\.kind) == ["agent", "bug", "break"])
        #expect(past.workMinutes == 75)
        let today = KnowledgeWorkLog.day("2026-10-28", text: text, now: date("2026-10-28 11:00"))
        #expect(today.minutes.last == 30)
        #expect(today.workMinutes == 105)
        #expect(KnowledgeWorkLog.duration(105) == "1 h 45 min")
    }

    @Test func editAndDeleteFindTheirLineAndRefuseAChangedOne() async throws {
        let log = try await worklog()
        let a = try log.add("a", kind: "task", at: date("2026-10-28 09:00")).entry
        let b = try log.add("b", kind: nil, at: date("2026-10-28 10:00")).entry
        // b moves before a.
        _ = try log.replace(b, on: "2026-10-28", with: .init(time: "08:30", kind: "bug", text: "b2"))
        #expect(try log.text("2026-10-28") == "- 08:30 #bug b2\n- 09:00 #task a\n")
        // a is on line 1 now: the old line number is refused.
        #expect(throws: KnowledgeBase.Failure.self) { try log.remove(a, on: "2026-10-28") }
        let day = try log.day("2026-10-28")
        _ = try log.remove(day.entries[1], on: "2026-10-28")
        #expect(try log.text("2026-10-28") == "- 08:30 #bug b2\n")
    }

    @Test func theCommandCommitsAndTheWatcherQueuesOutsideEdits() async throws {
        let log = try await worklog()
        try await log.add("a", kind: "task", at: date("2026-10-28 09:00"), env: env)
        let subject = try await FakeHome.git(["log", "--format=%s", "-1"], in: log.base.root, env: env)
        #expect(subject.trimmingCharacters(in: .whitespacesAndNewlines) == "Work log: 09:00 #task")
        #expect(WatchFilter.classify("worklog/2026-10-28.md") == .worklog("worklog/2026-10-28.md"))
        let batch = WatchFilter.batch(["worklog/2026-10-28.md"], own: [:]) { _ in "x" }
        #expect(batch.worklog && batch.enqueue == ["worklog/2026-10-28.md"] && !batch.reindex)
        #expect(KnowledgeCommitQueue.message(for: ["worklog/2026-10-28.md"]) == "Work log: 2026-10-28")
    }
}

extension KnowledgeWorkLogTests {
    @Test func crlfFilesAndLineBreaksInTextStayReadable() async throws {
        let log = try await worklog()
        try FileManager.default.createDirectory(at: log.folder, withIntermediateDirectories: true)
        try Data("- 09:00 #task a\r\n- 10:00 b\r\n".utf8).write(to: log.file("2026-10-28"))
        #expect(try log.day("2026-10-28").entries.map(\.time) == ["09:00", "10:00"])
        let added = try log.add("x\ry\u{2028}z", kind: nil, at: date("2026-10-28 09:30")).entry
        #expect(added.text == "x y z")
        #expect(try log.text("2026-10-28") == "- 09:00 #task a\n- 09:30 x y z\n- 10:00 b\n")
    }
}
