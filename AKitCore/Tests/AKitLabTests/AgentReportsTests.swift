import Foundation
import Testing
import AKitFoundation
import AKitModel
import AKitSessions
@testable import AKitLab

/// Agent reports (docs/design/agent-reports.md): the sections of final reports, a period, the inputs.
struct AgentReportsTests {
    let sections = AgentReports.defaultSections

    @Test func sectionsUnderTheirOwnLinesWithBullets() {
        let text = """
        Changed `a.ts`; `npm test` passed.

        Agent decisions:
        - Kept the fix in the feature folder.
        - Assumed the API returns UTC
          instants, not local dates.

        Autonomy improvements:
        - none

        Unknown unknowns:
        - none identified

        Anything else?
        """
        let parts = AgentReports.parse(text, sections: sections)
        #expect(parts.map(\.section) == ["Agent decisions", "Autonomy improvements", "Unknown unknowns"])
        #expect(parts[0].items == ["Kept the fix in the feature folder.", "Assumed the API returns UTC instants, not local dates."])
        #expect(parts[1].items.isEmpty && parts[2].items.isEmpty)
    }

    @Test func boldHeadingsInlineAndInOneParagraph() {
        let text = """
        **Agent decisions:** No code findings without reproducible evidence.

        **Autonomy improvements:** - none.

        **Unknown unknowns:** Browser/runtime behavior may still reveal issues.
        """
        let parts = AgentReports.parse(text, sections: sections)
        #expect(parts.map(\.items) == [["No code findings without reproducible evidence."], [], ["Browser/runtime behavior may still reveal issues."]])
        // Russian headings mid-paragraph, another bold label between them.
        let russian = "**Изменённые файлы:** нет. **Решения агента:** использована редакция 6. **Ограничение ревью:** нет второго прохода. "
            + "**Неизвестные факторы:** бэкенд не проверен. **Улучшения автономности:** - none."
        let ru = AgentReports.parse(russian, sections: sections)
        #expect(ru.map(\.section) == ["Agent decisions", "Autonomy improvements", "Unknown unknowns"])
        #expect(ru[0].items == ["использована редакция 6."])
        #expect(ru[1].items.isEmpty)
        #expect(ru[2].items == ["бэкенд не проверен."])
    }

    @Test func aNameInASentenceOrAnInstructionIsNoHeading() {
        #expect(AgentReports.parse("I will list unknown unknowns at the end, and agent decisions too.", sections: sections).isEmpty)
        // A Markdown heading and a bulleted bold label count.
        let parts = AgentReports.parse("## Unknown unknowns\n\n- Hermes timezone data\n\n- **Agent decisions:** kept", sections: sections)
        #expect(parts.first { $0.section == "Unknown unknowns" }?.items == ["Hermes timezone data"])
        #expect(parts.first { $0.section == "Agent decisions" }?.items == ["kept"])
    }

    @Test func noneSpellings() {
        for none in ["none", "- none.", "`- none`", "None identified.", "нет.", "none so far", "отсутствуют", "No additional blind spots identified.", "не выявлены"] { #expect(AgentReports.isNone(none), "\(none)") }
        for real in ["None of the checks ran", "no tests for the parser"] { #expect(!AgentReports.isNone(real), "\(real)") }
    }

    @Test func customSectionsFromText() {
        let parsed = AgentReports.sections(fromText: "Risks | Риски\n\n  Open questions  ")
        #expect(parsed == [.init(name: "Risks", aliases: ["Риски"]), .init(name: "Open questions")])
        #expect(AgentReports.sections(fromText: AgentReports.text(of: sections)) == sections)
    }

    func summary(_ name: String, started: Date, modified: Date) -> SessionSummary {
        SessionSummary(harness: .pi, file: URL(filePath: "/s/\(name).jsonl"), title: "task \(name)", project: URL(filePath: "/p/shop-web"),
                       started: started, modified: modified, size: 1)
    }

    @Test func aPeriodKeepsItsReportsOnceWithTheirTask() {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let report = "Done.\n\nAgent decisions:\n- Kept it local.\n\nAutonomy improvements:\n- none\n\nUnknown unknowns:\n- none"
        let empty = "Agent decisions:\n- none\n\nUnknown unknowns:\n- none"
        let transcripts: [String: SessionTranscript] = [
            "/s/a.jsonl": SessionTranscript(items: [
                TranscriptItem(id: 0, kind: .user, text: "fix the   chart", timestamp: day),
                TranscriptItem(id: 1, kind: .assistant, text: report, timestamp: day.addingTimeInterval(60)),
                TranscriptItem(id: 2, kind: .user, text: "now the labels", timestamp: day.addingTimeInterval(120)),
                TranscriptItem(id: 3, kind: .assistant, text: empty, timestamp: day.addingTimeInterval(180)),
                // After the period's end.
                TranscriptItem(id: 4, kind: .assistant, text: report + " Later.", timestamp: day.addingTimeInterval(7200)),
            ]),
            // A fork: the same report again.
            "/s/b.jsonl": SessionTranscript(items: [TranscriptItem(id: 0, kind: .assistant, text: report, timestamp: day.addingTimeInterval(60))]),
        ]
        let sessions = [summary("a", started: day, modified: day.addingTimeInterval(7200)), summary("b", started: day, modified: day)]
        let to = day.addingTimeInterval(3600)
        #expect(AgentReports.sessions(sessions + [summary("c", started: to.addingTimeInterval(1), modified: to.addingTimeInterval(5))],
                                      from: day, to: to, harnesses: [.pi]).count == 2)
        let collection = AgentReports.collect(sessions, from: day, to: to, sections: sections) { transcripts[$0.file.path] ?? SessionTranscript() }
        #expect(collection.reports.count == 2)
        #expect(collection.reports.map(\.task) == ["fix the chart", "now the labels"])
        #expect(collection.withItems.count == 1)
        #expect(collection.sessionsWithReports == 1)
        #expect(collection.count("Agent decisions") == (reports: 2, withItems: 1, items: 1))
        let markdown = AgentReports.markdown(collection)
        #expect(markdown.contains("## Agent decisions (1 in 1 of 2 reports)"))
        #expect(markdown.contains("- Kept it local. — *"))
        #expect(markdown.contains("## Autonomy improvements (0 in 0 of 1 reports)\n\n- none"))
        let inputs = AgentReports.inputs(collection)
        #expect(inputs.count == 1)
        #expect(inputs[0].contains("### R1 · ") && inputs[0].contains("Task: fix the chart\nAgent decisions:\n- Kept it local."))
        #expect(!inputs[0].contains("now the labels"))
    }

    @Test func aLongPeriodIsSentInPartsThatKeepTheirNumbers() {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let reports = (0..<40).map { index in
            AgentReports.Report(harness: "pi", session: "/s/\(index).jsonl", item: 0, title: "t", project: "p", time: day.addingTimeInterval(Double(index)),
                                task: nil, parts: [.init(section: "Agent decisions", items: [String(repeating: "x", count: 500)])])
        }
        let collection = AgentReports.Collection(from: day, to: day.addingTimeInterval(100), sections: sections, sessionsRead: 40, reports: reports)
        let inputs = AgentReports.inputs(collection, limit: 5_000)
        #expect(inputs.count > 1)
        #expect(inputs.allSatisfy { $0.count <= 5_000 })
        #expect(inputs[0].contains("Part 1 of \(inputs.count)."))
        #expect(inputs.last!.contains("### R40 · "))
        #expect(AgentReports.plan(collection).calls == 1)
    }

    @Test func aFocusIsAskedOnlyWhenGiven() {
        let plain = AgentReports.system(sections: sections, language: .english)
        #expect(plain.contains("- focus: \"\".") && !plain.contains("look first at"))
        let focused = AgentReports.system(sections: sections, language: .english, focus: "  flaky tests\n and CI ")
        #expect(focused.contains("look first at \"flaky tests and CI\""))
        #expect(plain.contains("one of Agent decisions, Autonomy improvements, Unknown unknowns"))
        #expect(AgentReports.mergeSystem(sections: sections, language: .russian, focus: "CI").contains("look first at \"CI\"") )
        #expect(AgentReports.mergeSystem(sections: sections, language: .russian).contains("in Russian"))
    }

    @Test func theAnswerIsCheckedAndSortedBySeverity() throws {
        let answer = ###"Here: {"summary": "Mostly  fine.", "focus": "", "findings": ["###
            + ###"{"severity": "low", "title": "Small thing", "detail": "x", "section": "Agent decisions", "count": 1, "reports": [2], "prompt": "Do a."},"###
            + ###"{"severity": "HIGH", "title": "Never checks\nthe screen", "detail": "y", "section": "Unknown unknowns", "count": 2, "reports": ["R1", 3, 99, 3], "prompt": "Add a rule."},"###
            + ###"{"severity": "urgent", "title": "Odd severity", "detail": "", "section": "", "count": 5, "reports": [], "prompt": ""},"###
            + ###"{"severity": "high", "title": "", "detail": "no title", "section": "", "count": 1, "reports": [], "prompt": ""}]}"}"###
        let analysis = try AgentReports.analysis(fromAnswer: answer, reports: 3)
        #expect(analysis.summary == "Mostly fine.")
        #expect(analysis.findings.map(\.title) == ["Never checks the screen", "Odd severity", "Small thing"])
        #expect(analysis.findings[0].severity == .high && analysis.findings[0].reports == [1, 3] && analysis.findings[0].count == 2)
        #expect(analysis.findings[1].severity == .medium)
        #expect(throws: AgentReports.Failure.self) { try AgentReports.analysis(fromAnswer: "Sorry, no.", reports: 3) }
        let prompts = AgentReports.allPrompts(analysis, period: "p")
        #expect(prompts.contains("1. [High] Never checks the screen\nAdd a rule.") && prompts.contains("2. [Low] Small thing\nDo a."))
    }

    @Test func theSavedReportKeepsItsFindings() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "akit-reports-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let report = AgentReports.Report(harness: "pi", session: "/s/a.jsonl", item: 1, title: "a | b", project: "shop-web", time: day, task: nil,
                                         parts: [.init(section: "Unknown unknowns", items: ["Hermes"])])
        let collection = AgentReports.Collection(from: day, to: day, sections: sections, sessionsRead: 3, reports: [report])
        let analysis = AgentReports.Analysis(summary: "Fine.", focus: "CI was never run.", findings: [
            .init(severity: .high, title: "Never runs CI", detail: "Seen twice.", section: "Unknown unknowns", count: 2, reports: [1], prompt: "Run CI."),
        ])
        let document = AgentReports.document(collection, analysis: analysis, model: "m", focus: "CI\nruns", created: day)
        #expect(document.contains("| R1 | ") && document.contains("| a / b | `/s/a.jsonl` |"))
        #expect(document.contains("### 🔴 High · Never runs CI\n\nSeen twice. (2 reports: R1 · Unknown unknowns)\n\nPrompt:\n\n```text\nRun CI.\n```"))
        #expect(document.contains("**Focus:** CI was never run."))
        let store = AgentReportStore(env: HarnessEnvironment(homeDirectory: home))
        let summary = AgentReports.Summary(markdown: document, analysis: analysis, model: "m", calls: 1)
        let file = try store.save(summary, now: day)
        try store.save(summary, now: day)
        let saved = store.list()
        #expect(saved.count == 2)
        #expect(saved.contains { $0.file == file && $0.model == "m" && $0.reports == 1 && $0.from == AgentReports.stamp(day) && $0.focus == "CI runs" })
        #expect(store.analysis(of: file) == analysis)
    }
}
