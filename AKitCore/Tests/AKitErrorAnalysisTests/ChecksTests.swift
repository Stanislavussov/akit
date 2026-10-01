import Foundation
import Testing
import AKitFoundation
import AKitInsights
import AKitSessions
@testable import AKitErrorAnalysis

/// Statistics, cheap signals and code checks.
struct StatsTests {
    @Test func wilsonMatchesTheDesignsNumbers() {
        let interval = Stats.wilson(18, 20)
        #expect(abs(interval.low - 0.699) < 0.005 && abs(interval.high - 0.972) < 0.005)
        // Passing the 80% bound needs about 29/30 or 46/50.
        #expect(Stats.wilson(29, 30).low >= 0.8)
        #expect(Stats.wilson(28, 30).low < 0.8)
        #expect(Stats.wilson(46, 50).low >= 0.8)
        #expect(Stats.wilson(0, 0) == Stats.Interval(low: 0, high: 1))
        #expect(Stats.wilson(0, 10).low == 0)
    }

    @Test func fisherMatchesTheDesign() {
        // 21/30 against 25/30: p ≈ 0.36, compatible with noise.
        #expect(abs(Stats.fisherExact(21, 30, 25, 30) - 0.36) < 0.01)
        #expect(Stats.fisherExact(5, 10, 5, 10) == 1)
        #expect(Stats.fisherExact(0, 20, 20, 20) < 1e-6)
    }

    @Test func betaPosteriorProbability() {
        // Same rate: about a coin flip.
        #expect(abs(Stats.probabilityLower(after: 10, of: 30, before: 10, of: 30) - 0.5) < 0.02)
        // 50% → 15% with 30 sessions each is a large effect: clearly lower.
        #expect(Stats.probabilityLower(after: 5, of: 30, before: 15, of: 30) > 0.99)
        #expect(Stats.probabilityLower(after: 15, of: 30, before: 5, of: 30) < 0.01)
        #expect(abs(Stats.regularizedIncompleteBeta(0.5, 2, 2) - 0.5) < 1e-9)
    }
}

@Suite(.serialized)
struct ChecksTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-checks-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var env: HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home, variables: ["HOME": home.path],
                           executableSearchPaths: [URL(filePath: "/usr/bin"), URL(filePath: "/bin")])
    }

    func item(_ id: Int, _ kind: TranscriptItem.Kind, _ text: String) -> TranscriptItem {
        TranscriptItem(id: id, kind: kind, text: text, timestamp: nil)
    }

    func json(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    var big: String { String(repeating: "line of code\n", count: 2000) }

    @Test func largeFileReadWholeIsMechanical() {
        let check = CodeChecks.check(for: "large-file-read-whole")!
        #expect(check.kind == .mechanical)
        let whole = [item(0, .user, "Look at it"), item(1, .toolCall(name: "Read"), json(["file_path": "/p/Big.swift"])),
                     item(2, .toolResult(name: "Read", isError: false), big)]
        #expect(check.check(SessionTranscript(items: whole)).positive)
        #expect(check.check(SessionTranscript(items: whole)).steps == [1])
        // A range, a small file, or a file rewritten whole afterwards don't count.
        let ranged = [item(1, .toolCall(name: "Read"), json(["file_path": "/p/Big.swift", "offset": 1, "limit": 100])),
                      item(2, .toolResult(name: "Read", isError: false), big)]
        #expect(!check.check(SessionTranscript(items: ranged)).positive)
        let small = [item(1, .toolCall(name: "Read"), json(["file_path": "/p/a.swift"])), item(2, .toolResult(name: "Read", isError: false), "x")]
        #expect(!check.check(SessionTranscript(items: small)).positive)
        let rewritten = whole + [item(3, .toolCall(name: "Write"), json(["file_path": "/p/Big.swift", "content": "new"]))]
        #expect(!check.check(SessionTranscript(items: rewritten)).positive)
        // cat of one file counts; cat piped into head doesn't.
        let cat = [item(1, .toolCall(name: "Bash"), json(["command": "cat Sources/Big.swift"])), item(2, .toolResult(name: "Bash", isError: false), big)]
        #expect(check.check(SessionTranscript(items: cat)).positive)
        let head = [item(1, .toolCall(name: "Bash"), json(["command": "cat Sources/Big.swift | head -50"])), item(2, .toolResult(name: "Bash", isError: false), big)]
        #expect(!check.check(SessionTranscript(items: head)).positive)
        // Pi's read.
        let pi = [item(1, .toolCall(name: "read"), json(["path": "/p/Big.swift"])), item(2, .toolResult(name: "read", isError: false), big)]
        #expect(check.check(SessionTranscript(items: pi)).positive)
    }

    @Test func repeatedStepsNeedTheSameResultThreeTimes() {
        let check = CodeChecks.check(for: "repeated-steps")!
        func calls(_ results: [String], command: String = "swift build") -> [TranscriptItem] {
            results.enumerated().flatMap { index, result in
                [item(index * 2, .toolCall(name: "Bash"), json(["command": command])),
                 item(index * 2 + 1, .toolResult(name: "Bash", isError: true), result)]
            }
        }
        #expect(check.check(SessionTranscript(items: calls(["e", "e", "e"]))).positive)
        #expect(!check.check(SessionTranscript(items: calls(["e1", "e2", "e3"]))).positive)
        #expect(!check.check(SessionTranscript(items: calls(["e", "e", "e"], command: "sleep 30 && gh run view"))).positive)
    }

    @Test func overclaimingAndUnverifiedDone() {
        let check = CodeChecks.check(for: "overclaiming-completion")!
        let unverified = [item(0, .user, "Fix it"), item(1, .toolCall(name: "Edit"), json(["file_path": "/p/a.swift", "old_string": "a", "new_string": "b"])),
                          item(2, .toolResult(name: "Edit", isError: false), "ok"), item(3, .assistant, "Done, it is fixed.")]
        #expect(check.check(SessionTranscript(items: unverified)).positive)
        #expect(SignalScanner.signals(of: unverified).unverifiedDone)
        let verified = Array(unverified.prefix(3)) + [item(3, .toolCall(name: "Bash"), json(["command": "swift test"])),
                                                       item(4, .toolResult(name: "Bash", isError: false), "passed"), item(5, .assistant, "Done.")]
        #expect(!check.check(SessionTranscript(items: verified)).positive)
        let afterError = [item(0, .user, "Run it"), item(1, .toolCall(name: "Bash"), json(["command": "swift test"])),
                          item(2, .toolResult(name: "Bash", isError: true), "Exit code 1"), item(3, .assistant, "All tests pass.")]
        #expect(check.check(SessionTranscript(items: afterError)).steps == [2, 3])
    }

    @Test func weakeningTestsAndLongSessions() {
        let weak = CodeChecks.check(for: "weakening-tests")!
        let removed = [item(1, .toolCall(name: "Edit"), json(["file_path": "/p/Tests/FooTests.swift",
                                                              "old_string": "@Test func a() { #expect(x) }", "new_string": ""]))]
        #expect(weak.check(SessionTranscript(items: removed)).positive)
        let skipped = [item(1, .toolCall(name: "Edit"), json(["file_path": "/p/src/foo.test.ts", "old_string": "it('a'", "new_string": "it.skip('a'"]))]
        #expect(weak.check(SessionTranscript(items: skipped)).positive)
        let added = [item(1, .toolCall(name: "Edit"), json(["file_path": "/p/Tests/FooTests.swift", "old_string": "", "new_string": "@Test func b() {}"]))]
        #expect(!weak.check(SessionTranscript(items: added)).positive)

        let long = CodeChecks.check(for: "long-session-not-reset")!
        var items = [item(0, .user, "Build A"), item(1, .toolCall(name: "Bash"), json(["command": "git commit -m A"])),
                     item(2, .toolResult(name: "Bash", isError: false), "[main abc] A"), item(3, .user, "Now build B")]
        for i in 0..<5 { items.append(item(4 + i, .toolCall(name: "Read"), json(["file_path": "/p/\(i)"]))) }
        var usage = SessionUsage()
        usage.peakContext = 150_000
        #expect(long.check(SessionTranscript(items: items, usage: usage)).positive)
        usage.peakContext = 60_000
        #expect(!long.check(SessionTranscript(items: items, usage: usage)).positive)
    }

    @Test func pushbacksAndRepeatsAreSignals() {
        let items = [item(0, .user, "Add a button"), item(1, .toolCall(name: "Read"), json(["file_path": "/a"])),
                     item(2, .toolResult(name: "Read", isError: true), "missing"), item(3, .toolCall(name: "Read"), json(["file_path": "/a"])),
                     item(4, .user, "No, I asked for a menu item"), item(5, .user, "[Request interrupted by user]"),
                     item(6, .user, "нет, не то"), item(7, .assistant, "OK")]
        let signals = SignalScanner.signals(of: items)
        #expect(signals.pushbacks == 2 && signals.interrupts == 1 && signals.toolErrors == 1 && signals.repeatedCalls == 1)
        #expect(signals.userTurns == 4 && signals.steps == 8 && signals.raised)
        #expect(!SignalScanner.isPushback("Now add the menu item"))
    }

    // MARK: Over the index

    func writeSession(_ id: String, read size: Int) throws {
        let folder = home.appending(path: ".claude/projects/-work")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let output = String(repeating: "x", count: size)
        let lines = [
            ["type": "user", "cwd": "/work", "sessionId": id, "timestamp": "2026-10-01T10:00:00Z",
             "message": ["role": "user", "content": "Read it"]],
            ["type": "assistant", "sessionId": id, "timestamp": "2026-10-01T10:00:02Z",
             "message": ["id": "m-\(id)", "model": "claude-opus-5-5", "role": "assistant",
                         "content": [["type": "tool_use", "id": "t-\(id)", "name": "Read", "input": ["file_path": "/work/Big.swift"]]],
                         "usage": ["input_tokens": 10, "output_tokens": 5]]],
            ["type": "user", "sessionId": id, "timestamp": "2026-10-01T10:00:03Z",
             "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t-\(id)", "content": output]]]],
        ] as [[String: Any]]
        let text = lines.map { String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: folder.appending(path: "\(id).jsonl"))
    }

    @Test func checksAndSignalsRunOverIndexedSessions() async throws {
        let first = "11111111-1111-4111-8111-111111111111"
        let second = "22222222-2222-4222-8222-222222222222"
        try writeSession(first, read: 30_000)
        try writeSession(second, read: 100)
        let database = try IndexSchema.open(InsightsPaths(env: env).database)
        _ = try await SessionImporter.importAndBind(env: env, projectsRoot: home.appending(path: "Projects"), database: database)

        let sessions = try AnalysisIndex.sessions(database)
        #expect(Set(sessions.map(\.key)) == ["claude:\(first)", "claude:\(second)"])
        #expect(sessions.allSatisfy { $0.requests == 1 && $0.model == "claude-opus-5-5" && $0.file != nil })

        let (computed, total) = try SignalScanner.refresh(env: env)
        #expect(computed == 2 && total == 2)
        #expect(try SignalScanner.refresh(env: env).computed == 0)
        #expect(try AnalysisIndex.signals(database)["claude:\(first)"]?.signals.steps == 3)

        let results = try CheckRunner.run([CodeChecks.check(for: "large-file-read-whole")!], env: env)
        let rate = results[0].rate()
        #expect(rate.positive == 1 && rate.total == 2)
        #expect(results[0].verdicts["claude:\(first)"]?.steps == [1])
        #expect(CheckStore(env: env).load("large-file-read-whole")?.verdicts.count == 2)
    }
}
