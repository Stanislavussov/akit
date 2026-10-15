import Foundation
import Testing
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
}
