import Foundation
import Testing
import AKitFoundation
@testable import AKitFlows

private let repoRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

/// The Feature-like flow the sample run followed: checks failed → implement.
private let sampleFlow = Flow(name: "feature", steps: [
    FlowStep(id: "plan", agent: "planner", model: "m"),
    FlowStep(id: "implement", agent: "implementer", model: "m"),
    FlowStep(id: "checks", agent: "checker", model: "m", routes: ["failed:*": "implement"]),
])

/// A copy of `fixtures/flow-runs/sample` in a temp project, with one more deviation (a guard
/// block) so the Runs screen has two to show.
func sampleRunCopy() throws -> (project: URL, run: URL) {
    let fm = FileManager.default
    let project = fm.temporaryDirectory.appending(path: "akit-flow-runs-\(UUID().uuidString)/project")
    let run = project.appending(path: ".pi/akit-flow/runs/20261117-1200-0000")
    try fm.createDirectory(at: run.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.copyItem(at: repoRoot.appending(path: "fixtures/flow-runs/sample"), to: run)
    var events = try String(contentsOf: run.appending(path: "events.jsonl"), encoding: .utf8)
    let block = #"{"schema":"akit-flow-event/1","type":"deviation","time":"2026-11-17T12:00:00.000Z","step":"implement","attempt":1,"rule":"tool-not-allowed","tool":"bash","input":"rm -rf build","action":"blocked"}"#
    events = events.replacingOccurrences(of: #"{"schema":"akit-flow-event/1","type":"step-end","time":"2026-11-17T12:00:00.000Z","step":"implement","attempt":1"#,
                                         with: block + "\n" + #"{"schema":"akit-flow-event/1","type":"step-end","time":"2026-11-17T12:00:00.000Z","step":"implement","attempt":1"#)
    try Data(events.utf8).write(to: run.appending(path: "events.jsonl"))
    return (project, run)
}

struct FlowRunSummaryTests {
    @Test func sampleShowsStepsAndTwoDeviations() throws {
        let (_, folder) = try sampleRunCopy()
        let summary = FlowRunSummary(FlowRun.read(folder), flow: sampleFlow)
        #expect(summary.attempts.map { "\($0.step)#\($0.attempt)" } == ["plan#1", "implement#1", "checks#1", "implement#2", "checks#2"])
        #expect(summary.attempts.map(\.state) == [.done, .done, .failed, .done, .done])
        #expect(summary.status == .done && summary.stopReason == "done")
        #expect(summary.deviationCount == 2)
        #expect(summary.attempts(of: "implement").first?.deviations.first.map(FlowRunReport.describe) == "tool-not-allowed: bash rm -rf build")
        #expect(summary.attempts(of: "checks").first?.deviations.first.map(FlowRunReport.describe) == "check-failed: node check.mjs → 1")
        #expect(summary.attempts.allSatisfy { $0.handoff != nil && $0.sessionFile != nil })
        #expect(summary.attempts.last?.evidence == "evidence/03-checks-checks.json")
        #expect(summary.attempts.allSatisfy { $0.forbiddenNext == nil }, "the sample follows its routes")
        #expect(summary.attempts.first?.seconds == 0)
    }

    @Test func aPathTheRoutesForbidIsFlagged() throws {
        let (_, folder) = try sampleRunCopy()
        // Without the failed → implement route, a failed checks step must stop, not go back.
        var flow = sampleFlow
        flow.steps[2].routes = [:]
        let summary = FlowRunSummary(FlowRun.read(folder), flow: flow)
        #expect(summary.attempts.map(\.forbiddenNext) == [nil, nil, "implement", nil, nil])
    }

    @Test func newEventKindsAndHalt() throws {
        let (_, folder) = try sampleRunCopy()
        try Data("""
        {"type":"run-start","flow":"feature","task":"x"}
        {"type":"step-start","step":"plan","attempt":1}
        {"type":"step-end","step":"plan","attempt":1,"outcome":"done"}
        {"type":"gate-edits","before":"implement","commit":"abc"}
        {"type":"halted","reason":"STOP","next":"implement"}

        """.utf8).write(to: folder.appending(path: "events.jsonl"))
        var run = FlowRun.read(folder)
        #expect(run.unknownEvents.isEmpty)
        #expect(run.events.map(\.kind) == [.runStart, .stepStart, .stepEnd, .gateEdits, .halted])
        var summary = FlowRunSummary(run, flow: sampleFlow)
        #expect(summary.status == .halted && summary.stopReason == "STOP")
        let events = try String(contentsOf: folder.appending(path: "events.jsonl"), encoding: .utf8) + #"{"type":"resume","removed":"STOP"}"# + "\n"
        try Data(events.utf8).write(to: folder.appending(path: "events.jsonl"))
        run = FlowRun.read(folder)
        summary = FlowRunSummary(run, flow: sampleFlow)
        #expect(run.events.last?.kind == .resume && summary.status == .running)
    }

    @Test func stopWritesTheStopFile() throws {
        let (project, folder) = try sampleRunCopy()
        let summary = try #require(FlowRunSummary.all(projects: [project], env: HarnessEnvironment(homeDirectory: project)).first)
        #expect(!summary.stopRequested)
        try summary.requestStop()
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "STOP").path))
        #expect(FlowRunSummary(FlowRun.read(folder), flow: nil).stopRequested)
    }
}
