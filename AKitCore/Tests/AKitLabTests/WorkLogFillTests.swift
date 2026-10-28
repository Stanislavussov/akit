import Foundation
import Testing
import AKitFoundation
import AKitKnowledge
@testable import AKitLab

/// Auto-Fill of the work log (docs/design/worklog.md, W8): slots, branches, tickets, the answer.
struct WorkLogFillTests {
    func moment(_ time: String, _ text: String, project: String = "akit", branch: String? = "feature/COL-12-retry") -> WorkLogFill.Moment {
        .init(time: time, harness: "claude-code", project: project, branch: branch, text: text)
    }

    @Test func promptsGoIntoSlotsWithTheirProjectBranchAndTicket() {
        let moments = [moment("09:05", "fix the retry"), moment("09:20", "run tests"), moment("09:40", "look at OPS-7", branch: "main"),
                       moment("11:02", "write notes", project: "docs", branch: nil)]
        let half = WorkLogFill.slots(moments, minutes: 30)
        #expect(half.map(\.time) == ["09:00", "09:30", "11:00"])
        #expect(half[0].places == ["akit · feature/COL-12-retry · COL-12"])
        #expect(half[1].places == ["akit · main · OPS-7"])
        #expect(half[2].places == ["docs"])
        #expect(WorkLogFill.slots(moments, minutes: 15).map(\.time) == ["09:00", "09:15", "09:30", "11:00"])
        let input = WorkLogFill.input(day: "2026-10-28", slots: half, minutes: 30, existing: [.init(time: "08:00", kind: "reply", text: "x")])
        #expect(input.contains("## 09:00 (30 min) — akit · feature/COL-12-retry · COL-12\n- 09:05 claude-code: fix the retry"))
        #expect(input.contains("- 08:00 #reply x"))
    }

    @Test func aLongDayKeepsEverySlot() {
        let moments = (0..<600).map { moment(String(format: "%02d:%02d", 8 + $0 / 60, $0 % 60), String(repeating: "x", count: 200)) }
        let input = WorkLogFill.input(day: "2026-10-28", slots: WorkLogFill.slots(moments, minutes: 15), minutes: 15, existing: [])
        #expect(input.count < WorkLogFill.maxCharacters + 1000)
        #expect(input.contains("## 17:45 (15 min)"))
        // A day of a prompt a minute in 15-minute slots: still under the cap, morning and evening kept.
        let busy = (0..<900).map { moment(String(format: "%02d:%02d", 6 + $0 / 60, $0 % 60), String(repeating: "y", count: 240)) }
        let full = WorkLogFill.input(day: "2026-10-28", slots: WorkLogFill.slots(busy, minutes: 15), minutes: 15, existing: [])
        #expect(full.count < WorkLogFill.maxCharacters + 1000)
        #expect(full.contains("## 06:00") && full.contains("## 20:"))
    }

    @Test func theAnswerIsCheckedAndSorted() throws {
        let answer = #"Here: {"entries": [{"time": "10:00", "kind": "Bug", "text": "COL-12 outbox\nduplicates"},"# +
            #"{"time": "9:00", "kind": "a b", "text": "notes"}, {"time": "25:00", "kind": "task", "text": "x"}]}"#
        let entries = try WorkLogFill.entries(fromAnswer: answer)
        #expect(entries == [.init(time: "09:00", kind: nil, text: "notes"), .init(time: "10:00", kind: "bug", text: "COL-12 outbox duplicates")])
        #expect(throws: WorkLogFill.Failure.self) { try WorkLogFill.entries(fromAnswer: "no json") }
    }

    @Test func theBranchAtAMomentComesFromTheReflog() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "akit-branch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let env = ["HOME": folder.path, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "PATH": "/usr/bin:/bin",
                   "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"]
        func git(_ args: String..., at seconds: Int? = nil) {
            var env = env
            if let seconds { env["GIT_COMMITTER_DATE"] = "\(seconds) +0000" }
            _ = ProcessRunner.runAndWait(URL(filePath: "/usr/bin/git"), arguments: ["-C", folder.path] + args, environment: env, timeout: 10)
        }
        git("init", "-q", "-b", "main")
        git("commit", "-q", "--allow-empty", "-m", "a", at: 1_700_001_000)
        git("checkout", "-q", "-b", "COL-1-x", at: 1_700_002_000)
        git("checkout", "-q", "main", at: 1_700_003_000)
        let history = GitBranchHistory()
        #expect(history.branch(in: folder, at: Date(timeIntervalSince1970: 1_700_001_500)) == "main")
        #expect(history.branch(in: folder, at: Date(timeIntervalSince1970: 1_700_002_500)) == "COL-1-x")
        #expect(history.branch(in: folder, at: Date(timeIntervalSince1970: 1_700_003_500)) == "main")
    }
}

extension WorkLogFillTests {
    @Test func theEntriesAreInCzechUnlessAnotherLanguageIsChosen() {
        #expect(WorkLogFill.system(.czech).contains("in Czech"))
        #expect(WorkLogFill.system(.english).contains("in English"))
    }
}

extension WorkLogFillTests {
    @Test func eachProposalCarriesItsSummary() throws {
        let answer = #"{"entries": [{"time": "09:00", "kind": "bug", "text": "COL-12 outbox", "summary": "Hledal duplicitní události.\nOpravil klíč."}]}"#
        let entries = try WorkLogFill.entries(fromAnswer: answer)
        #expect(entries.first?.summary == "Hledal duplicitní události. Opravil klíč.")
        #expect(WorkLogFill.schema.contains(#""summary""#) && WorkLogFill.system.contains("2 to 3 sentences"))
    }
}
