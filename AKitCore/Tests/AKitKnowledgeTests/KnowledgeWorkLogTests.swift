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

extension KnowledgeWorkLogTests {
    @Test func aSummaryStaysWithItsEntryThroughAddEditAndDelete() async throws {
        let log = try await worklog()
        _ = try log.add("COL-1 outbox", kind: "bug", day: "2026-10-28", time: "09:00", summary: "Found the retry.\nFixed the key.")
        _ = try log.add("notes", kind: nil, day: "2026-10-28", time: "09:30")
        // An earlier-or-equal time goes after the summary, not between entry and summary.
        _ = try log.add("same minute", kind: nil, day: "2026-10-28", time: "09:00")
        #expect(try log.text("2026-10-28") == "- 09:00 #bug COL-1 outbox\n  > Found the retry.\n  > Fixed the key.\n- 09:00 same minute\n- 09:30 notes\n")
        let first = try log.day("2026-10-28").entries[0]
        #expect(first.summary == "Found the retry.\nFixed the key.")
        // Edit moves the entry with its summary.
        _ = try log.replace(first, on: "2026-10-28", with: .init(time: "10:00", kind: "bug", text: "COL-1 outbox", summary: "Done."))
        #expect(try log.text("2026-10-28") == "- 09:00 same minute\n- 09:30 notes\n- 10:00 #bug COL-1 outbox\n  > Done.\n")
        let moved = try log.day("2026-10-28").entries[2]
        _ = try log.remove(moved, on: "2026-10-28")
        #expect(try log.text("2026-10-28") == "- 09:00 same minute\n- 09:30 notes\n")
    }
}

extension KnowledgeWorkLogTests {
    @Test func aSummaryTypedInParagraphsKeepsThemThroughAnEdit() async throws {
        let log = try await worklog()
        try FileManager.default.createDirectory(at: log.folder, withIntermediateDirectories: true)
        try Data("- 09:00 #task a\n  > one\n  >\n  > two\n- 10:00 b\n".utf8).write(to: log.file("2026-10-28"))
        let entry = try log.day("2026-10-28").entries[0]
        #expect(entry.summary == "one\n\ntwo")
        var moved = entry
        moved.time = "09:15"
        _ = try log.replace(entry, on: "2026-10-28", with: moved)
        #expect(try log.text("2026-10-28") == "- 09:15 #task a\n  > one\n  >\n  > two\n- 10:00 b\n")
    }

    // MARK: - Calendar blocks, norm and report (W11–W13)

    @Test func aBlockKeepsItsOwnTimeAndPlainEntriesGetTheRest() {
        let text = "norm: 8 h\n- 09:00 #task a\n- 09:30-10:00 #meeting Standup\n- 10:15 #bug COL-7 b\n- 12:00–12:30 #break Lunch\n- 13:00 c\n- 15:00-16:00 #meeting Demo\n"
        let day = KnowledgeWorkLog.day("2026-11-05", text: text, now: date("2026-11-06 12:00"))
        #expect(day.entries.map(\.end) == [nil, "10:00", nil, "12:30", nil, "16:00"])
        // a: 09:00–10:15 without the standup; b: 10:15–13:00 without lunch; c: until the demo (last plain one of a past day).
        #expect(day.minutes == [45, 30, 135, 30, 120, 60])
        #expect(day.ends == [615, 600, 780, 750, 900, 960])
        #expect(day.norm == 480)
        #expect(day.workMinutes == 390)
        #expect(day.isCovered(9 * 60 + 45) && !day.isCovered(10 * 60))
        #expect(day.entries[1].markdown == "- 09:30-10:00 #meeting Standup")
        // A block that doesn't end after its start is a plain entry.
        #expect(KnowledgeWorkLog.entries(in: "- 10:00-09:00 x\n").first?.end == nil)
    }

    @Test func blocksAreAddedEditedAndChecked() async throws {
        let log = try await worklog()
        let block = try log.add("Planning", kind: "meeting", day: "2026-11-05", time: "14:00", end: "15:30").entry
        _ = try log.add("x", kind: nil, day: "2026-11-05", time: "13:00")
        #expect(try log.text("2026-11-05") == "- 13:00 x\n- 14:00-15:30 #meeting Planning\n")
        #expect(throws: KnowledgeBase.Failure.self) { try log.add("y", kind: nil, day: "2026-11-05", time: "10:00", end: "09:00") }
        var moved = block
        moved.line = 1
        _ = try log.replace(moved, on: "2026-11-05", with: .init(time: "08:00", end: "24:00", kind: "meeting", text: "All day"))
        #expect(try log.text("2026-11-05") == "- 08:00-24:00 #meeting All day\n- 13:00 x\n")
    }

    @Test func theNormComesFromTheDayTheBaseOrTheWeekday() async throws {
        let log = try await worklog()
        #expect(log.hours() == 7.5)
        _ = try log.setHours(8)
        #expect(log.hours() == 8)
        _ = try log.add("a", kind: "task", day: "2026-11-02", time: "09:00")
        _ = try log.setNorm(4, on: "2026-11-02")
        #expect(try log.text("2026-11-02") == "norm: 4 h\n- 09:00 #task a\n")
        #expect(try log.day("2026-11-02").norm == 240)
        _ = try log.setNorm(nil, on: "2026-11-02")
        #expect(try log.text("2026-11-02") == "- 09:00 #task a\n")
        // Saturday has no norm.
        #expect(KnowledgeWorkLog.norm(of: .init(date: "2026-11-07", entries: [], minutes: []), hours: 8) == 0)
        #expect(KnowledgeWorkLog.norm(of: .init(date: "2026-11-06", entries: [], minutes: []), hours: 8) == 480)
    }

    @Test func theReportShowsEveryDayWithWorkMissingKindsAndTickets() async throws {
        let log = try await worklog()
        _ = try log.add("COL-1 fix", kind: "bug", day: "2026-11-02", time: "09:00")
        _ = try log.add("Lunch", kind: "break", day: "2026-11-02", time: "12:00", end: "12:30")
        _ = try log.add("Sync", kind: "meeting", day: "2026-11-02", time: "13:00", end: "14:00")
        let range = KnowledgeWorkLog.range(.week, containing: date("2026-11-05 10:00"))
        #expect(range.from == "2026-11-02" && range.to == "2026-11-08")
        let report = try log.report(from: range.from, to: range.to, now: date("2026-11-06 10:00"))
        #expect(report.rows.count == 7)
        let monday = report.rows[0]
        // The bug runs until lunch (the next block), the meeting has its hour.
        #expect(monday.work == 240 && monday.pause == 30 && monday.norm == 450 && monday.missing == 210)
        #expect(monday.tickets == ["COL-1": 180, "": 60])
        #expect(report.norm == 5 * 450)
        #expect(report.rows[5].norm == 0)
        let csv = report.daysCSV.split(separator: "\n")
        #expect(csv[0] == "date,weekday,norm_h,work_h,missing_h,break_h,kind_bug_h,kind_meeting_h,kind_break_h")
        #expect(csv[1] == "2026-11-02,Mon,7.50,4.00,3.50,0.50,3.00,1.00,0.50")
        #expect(KnowledgeWorkLog.range(.month, containing: date("2026-11-05 10:00")) == ("2026-11-01", "2026-11-30"))
    }
}
