import Foundation
import Testing
import AKitFoundation
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

    /// A task is named neutrally by id, whether it is still in the list or not.
    @Test func aTaskIDIsNamedNeutrallyEvenWhenTheTaskIsGone() {
        let task = ControlTask(id: ControlTasks.newID("Make the export button work on iPad"), title: "t", repo: "/r", base: "b", prompt: "p",
                               source: .reproduction, oracle: .tests(command: "make test"))
        #expect(ControlTask.neutralName(of: task.id, in: [task]) == task.neutralName)
        let gone = ControlTask.neutralName(of: task.id, in: [])
        #expect(gone.hasPrefix("a removed control task #") && !gone.contains("export"))
        #expect(gone == ControlTask.neutralName(of: task.id, in: []))
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
        let clean = context.redacting([], ids: ids)
        #expect(clean.summary == "Oracle: \(AskContext.redacted): present")
        #expect(clean.element?.title == "Control task \(AskContext.redacted)")
        // Seed and commit ids stay.
        #expect(clean.element?.facts == "Mode: \(seed.id)\nTask: \(commit.id)")
    }

    /// Short ids count too, as exact tokens; a plain word that equals part of one doesn't.
    @Test func shortIDsAreCaughtAsExactTokens() {
        let task = ControlTasks.newID("Export")
        let mode = Clustering.slug("Over-reading", taken: [])
        #expect(task.hasPrefix("export-") && mode == "over-reading")
        let context = AskContext(screen: "analysis", screenTitle: "Error Analysis", summary: "Export… button\nTask \(task) ok\nMode \(mode): present",
                                 element: .init(title: "Over reading and EXPORT", facts: "Path: x/\(task)/y\nNot \(task)-2 nor pre\(mode)"))
        let clean = context.redacting([], ids: [task, mode])
        #expect(clean.summary == "Export… button\nTask \(AskContext.redacted) ok\nMode \(AskContext.redacted): present")
        #expect(clean.element?.title == "Over reading and EXPORT")
        // Bounded by "/" it is a token; inside a longer id or word it isn't.
        #expect(clean.element?.facts == "Path: x/\(AskContext.redacted)/y\nNot \(task)-2 nor pre\(mode)")
    }

    /// An emergent mode's name counts whatever its length, as a whole word sequence.
    @Test func shortModeNamesAreCaughtAsWordSequences() {
        let context = AskContext(screen: "analysis", screenTitle: "Error Analysis", summary: "Mode: Scope creep (12 notes)\nScope: all projects",
                                 element: .init(title: "scope-creep", facts: "Scoped creeping"))
        let clean = context.redacting([], names: ["Scope creep"])
        #expect(clean.summary == "Mode: \(AskContext.redacted) (12 notes)\nScope: all projects")
        #expect(clean.element?.title == AskContext.redacted)
        #expect(clean.element?.facts == "Scoped creeping")
    }

    /// The backstop reads the saved modes and tasks without setting anything up, and says when
    /// a file is there but can't be read.
    @Test func storedModesAndTasksAreReadOnlyAndStrict() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "akit-stored-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = HarnessEnvironment(homeDirectory: home, variables: ["HOME": home.path], executableSearchPaths: [])
        #expect(try ModeStore(env: env).storedModes().isEmpty)
        #expect(try ControlTasks.storedTasks(env: env).isEmpty)
        // Nothing was created: no repository, no seeds.
        #expect(!FileManager.default.fileExists(atPath: AnalysisPaths(env: env).folder.path))
        let modes = AnalysisPaths(env: env).modesFile
        try FileManager.default.createDirectory(at: modes.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: modes)
        #expect(throws: ModeStore.Failure.self) { try ModeStore(env: env).storedModes() }
        let tasks = EvalPaths(env: env).tasks
        try FileManager.default.createDirectory(at: tasks, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: tasks.appending(path: "broken.json"))
        #expect(throws: ControlTasks.Failure.self) { try ControlTasks.storedTasks(env: env) }
    }
}
