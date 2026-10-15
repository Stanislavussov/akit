import Foundation
import Testing
@testable import AKitHelp
@testable import AKitErrorAnalysis

/// What Ask AKit may send for modes and control tasks: no words from sessions.
struct NeutralNamesTests {
    @Test func aSessionTaskIsNamedWithoutItsPrompt() {
        let prompt = "Fix the flaky checkout test in the payments service"
        let id = ControlTasks.newID(prompt)
        #expect(id.hasPrefix("fix-the-flaky-checkout-test"))
        let task = ControlTask(id: id, title: "t", repo: "/r", base: "abc", prompt: prompt,
                               source: .session(key: SessionKey(harness: "claude-code", nativeID: "s1")), oracle: .tests(command: "swift test"))
        #expect(task.neutralName.hasPrefix("a control task from a session #"))
        #expect(!task.neutralName.contains("flaky") && !task.neutralName.contains(id))
        #expect(task.neutralName == task.neutralName)
        var reproduction = task
        reproduction.source = .reproduction
        #expect(reproduction.neutralName.hasPrefix("a control task from a reproduction #"))
        var commit = task
        commit.source = .commit(sha: "abc1234")
        #expect(commit.neutralName == id)
    }

    @Test func anEmergentModeIsNamedWithoutItsWords() {
        let id = Clustering.slug("Edits files without running the build", taken: [])
        let emergent = Mode(id: id, name: "Edits files without running the build", definition: "d")
        #expect(emergent.neutralName.hasPrefix("an emergent failure mode #"))
        #expect(!emergent.neutralName.contains("edits") && emergent.neutralName.count < 40)
        // Two modes stay apart.
        let other = Mode(id: id + "-2", name: "x", definition: "d")
        #expect(other.neutralName != emergent.neutralName)
        let seed = Mode(id: "no-build-after-swift-edit", name: "No build", definition: "d", origin: .seedPrior)
        #expect(seed.neutralName == "no-build-after-swift-edit")
        #expect(ControlTask.Oracle.assertion(modeID: id).neutralLabel == "assertion: the mode's code check")
        #expect(ControlTask.Oracle.tests(command: "make test").neutralLabel == "tests: make test")
    }

    /// A comparison's reason names the read-only task that passed by its id.
    @Test func aReasonNamesNoSessionTask() {
        let task = ControlTask(id: ControlTasks.newID("Make the export button work on iPad"), title: "t", repo: "/r", base: "b", prompt: "p",
                               source: .reproduction, oracle: .tests(command: "make test"))
        let reason = "A read-only agent passed \(task.id): its oracle can't tell work from no work (40% …)."
        let neutral = ControlTask.neutralizing(reason, tasks: [task])
        #expect(!neutral.contains(task.id) && !neutral.contains("export"))
        #expect(neutral.hasPrefix("A read-only agent passed a control task from a reproduction #"))
    }

    /// The backstop is structural: the ids themselves, as AKit makes them, are caught.
    @Test func theBackstopCatchesRealIDs() {
        let task = ControlTask(id: ControlTasks.newID("Fix the flaky checkout test in payments service"), title: "t", repo: "/r", base: "b",
                               prompt: "p", source: .session(key: SessionKey(harness: "claude-code", nativeID: "s")), oracle: .tests(command: "x"))
        let mode = Mode(id: Clustering.slug("Declares the work done without running the tests again", taken: []), name: "Renamed", definition: "d")
        let seed = Mode(id: "no-build-after-swift-edit", name: "No build", definition: "d", origin: .seedPrior)
        let commit = ControlTask(id: "add-dark-mode-toggle-9f3e", title: "t", repo: "/r", base: "b", prompt: "p", source: .commit(sha: "abc"),
                                 oracle: .hiddenTests(commit: "abc"))
        let ids = ControlTask.sessionDerivedIDs([task, commit]) + Mode.sessionDerivedIDs([mode, seed])
        #expect(ids == [task.id, mode.id])
        let context = AskContext(screen: "analysis", screenTitle: "Error Analysis", summary: "Oracle: \(mode.id): present",
                                 element: .init(title: "Control task \(task.id)", facts: "Mode: \(seed.id)\nTask: \(commit.id)"))
        let clean = context.redacting(ids)
        #expect(clean.summary == "Oracle: \(AskContext.redacted): present")
        #expect(clean.element?.title == "Control task \(AskContext.redacted)")
        // Seed and commit ids stay.
        #expect(clean.element?.facts == "Mode: \(seed.id)\nTask: \(commit.id)")
    }
}
