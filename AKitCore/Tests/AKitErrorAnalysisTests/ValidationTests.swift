import Foundation
import Testing
import AKitFoundation
@testable import AKitErrorAnalysis
@testable import AKitLab

@Suite(.serialized)
struct ValidationTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-validation-\(UUID().uuidString)")
        try fm.createDirectory(at: home.appending(path: "bin"), withIntermediateDirectories: true)
    }

    var env: HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home, variables: ["HOME": home.path],
                           executableSearchPaths: [home.appending(path: "bin"), URL(filePath: "/usr/bin"), URL(filePath: "/bin")])
    }

    func label(_ key: String, _ positive: Bool) -> ModeLabel { ModeLabel(sessionKey: key, positive: positive, source: .bootstrap) }

    @Test func splitsAreStickyAndAboutTenThirtySixty() {
        let labels = (0..<1000).map { label("s\($0)", $0 % 2 == 0) }
        let split = Validation.split(labels, modeID: "m", existing: nil)
        #expect(split.train.count + split.dev.count + split.test.count == 1000)
        #expect((60...140).contains(split.train.count) && (240...360).contains(split.dev.count) && (530...670).contains(split.test.count))
        // A session keeps its set when labels are added later.
        var moved = split
        moved.test.removeFirst()
        moved.train.append(split.test[0])
        let again = Validation.split(labels + [label("new", true)], modeID: "m", existing: moved)
        #expect(again.train.contains(split.test[0]) && !again.test.contains(split.test[0]))
        #expect((again.train + again.dev + again.test).contains("new"))
    }

    @Test func evaluateLeavesUndecidedToughCallsOut() {
        let labels = [label("a", true), label("b", true), label("c", false), label("d", false), label("e", true)]
        let verdicts = ["a": CheckVerdict(positive: true, version: 1), "b": CheckVerdict(positive: false, version: 1),
                        "c": CheckVerdict(positive: false, version: 1), "d": CheckVerdict(positive: true, toughCall: true, version: 1)]
        let result = Validation.evaluate(modeID: "m", modeVersion: 2, checker: "code|1", set: .test, labels: labels,
                                         sessions: ["a", "b", "c", "d", "e"], verdicts: verdicts, decided: [:])
        #expect(result.tpr == 0.5 && result.tnr == 1)
        #expect(result.toughLeftOut == 1 && result.unchecked == 1)
        let decided = Validation.evaluate(modeID: "m", modeVersion: 2, checker: "code|1", set: .test, labels: labels,
                                          sessions: ["a", "b", "c", "d"], verdicts: verdicts, decided: ["d": false])
        #expect(decided.tnr == 0.5 && decided.toughLeftOut == 0)
    }

    func result(positives: Int, truePositives: Int, negatives: Int, trueNegatives: Int, version: Int = 1, checker: String = "code|1") -> ValidationResult {
        let labels = Stats.CheckLabels(onPositives: (0..<positives).map { $0 < truePositives },
                                       onNegatives: (0..<negatives).map { $0 >= trueNegatives })
        return ValidationResult(modeID: "m", modeVersion: version, checker: checker, set: .test, labels: labels,
                                tprLow: Stats.wilson(truePositives, positives).low, tnrLow: Stats.wilson(trueNegatives, negatives).low,
                                toughLeftOut: 0, unchecked: 0, at: .now)
    }

    @Test func trustNeedsVolumeAndTheLowerBound() {
        let validated = result(positives: 30, truePositives: 30, negatives: 30, trueNegatives: 30)
        #expect(Validation.trust(modeID: "m", modeVersion: 1, checker: "code|1", results: [validated]).level == .validated)
        // 18/20 is about [70%, 97%]: not enough, and too few labels: provisional.
        let provisional = result(positives: 20, truePositives: 18, negatives: 20, trueNegatives: 20)
        #expect(Validation.trust(modeID: "m", modeVersion: 1, checker: "code|1", results: [provisional]).level == .provisional)
        let weak = result(positives: 40, truePositives: 30, negatives: 40, trueNegatives: 40)
        #expect(Validation.trust(modeID: "m", modeVersion: 1, checker: "code|1", results: [weak]).level == .provisional)
        #expect(Validation.trust(modeID: "m", modeVersion: 1, checker: "code|1", results: [result(positives: 5, truePositives: 5, negatives: 5, trueNegatives: 5)]).level == .none)
        // A new mode version or another checker invalidates the result.
        #expect(Validation.trust(modeID: "m", modeVersion: 2, checker: "code|1", results: [validated]).level == .none)
        #expect(Validation.trust(modeID: "m", modeVersion: 1, checker: "judge|claude-code|opus|1", results: [validated]).level == .none)
        // A mechanical code check is exact.
        #expect(Validation.trust(modeID: "large-file-read-whole", modeVersion: 1, checker: "code|1", results: []).level == .exact)
    }

    @Test func judgesJudgeAndTestRunsOnce() async throws {
        try Data(#"""
            #!/bin/sh
            if [ "$1 $2" = "auth status" ]; then echo '{"loggedIn":true,"email":"me@example.com","orgName":"Me"}'; exit 0; fi
            in=$(mktemp); cat > "$in"
            if grep -q "BIG" "$in"; then p=true; else p=false; fi
            echo '{"type":"result","is_error":false,"result":"","structured_output":{"present":'$p',"steps":[0],"toughCall":false,"severe":false,"reason":"r"},"usage":{"input_tokens":1,"output_tokens":1}}'
            """#.utf8).write(to: home.appending(path: "bin/claude"))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.appending(path: "bin/claude").path)
        let folder = home.appending(path: ".claude/projects/-w")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var entries: [BootstrapReservations.Entry] = []
        var labels: [Bootstrap.Label] = []
        for index in 0..<12 {
            let id = String(format: "%08x-0000-4000-8000-%012x", index, index)
            let file = folder.appending(path: "\(id).jsonl")
            let text = index % 2 == 0 ? "Read the BIG file" : "Small task"
            try Data((#"{"type":"user","cwd":"/w","message":{"role":"user","content":"\#(text)"}}"# + "\n").utf8).write(to: file)
            entries.append(.init(sessionKey: "claude:\(id)", transcript: file.path, labeledAt: .now))
            var h1 = Note(id: "h1", source: .human, description: "big read", step: 0, quote: "BIG")
            h1.id = "h1"
            labels.append(Bootstrap.Label(sessionKey: "claude:\(id)", transcript: file.path, notes: index % 2 == 0 ? [h1] : [], outcome: .no,
                                          labeledAt: .now))
        }
        try BootstrapReservations(env: env).update { $0 += entries }
        for label in labels { try Bootstrap.LabelStore(env: env).save(label) }
        var book = LabelBook()
        for label in labels where !label.notes.isEmpty { book.mapping["\(label.sessionKey)#h1"] = "large-file-read-whole" }
        _ = try LabelBookStore(env: env).update { $0 = book }

        let store = ModeStore(env: env)
        let modes = try await store.list()
        let mode = try #require(modes.first { $0.id == "large-file-read-whole" })
        let agent = LabAgent(harness: .claudeCode, model: "opus", effort: "low", mode: .call)
        try ValidationStore(env: env).setJudge(agent, for: mode.id)
        let gate = try await SendGate.open(agent: agent, env: env)
        let test = try await Validation.run(mode: mode, set: .test, modes: modes, gate: gate, workFolder: home.appending(path: "w"), env: env)
        #expect(test.tpr == 1 && test.tnr == 1)
        #expect(test.checker.hasPrefix("judge|claude-code|opus"))
        #expect(CheckStore(env: env).load(Judges.resultsID(mode.id))?.verdicts.isEmpty == false)
        // The cost before a pool run counts only what would be judged: not the sessions judged
        // on unchanged files, all of them for another judge, and a session whose file changed.
        let all = entries.map { (key: $0.sessionKey, file: $0.transcript) }
        let judged = Set(try #require(CheckStore(env: env).load(Judges.resultsID(mode.id))).verdicts.keys)
        #expect(Set(Judges.pending(mode: mode, sessions: all, agent: agent, env: env)) == Set(all.map(\.key)).subtracting(judged))
        var other = agent
        other.model = "sonnet"
        #expect(Judges.pending(mode: mode, sessions: all, agent: other, env: env).count == all.count)
        let changed = try #require(all.first { judged.contains($0.key) })
        let handle = try FileHandle(forWritingTo: URL(filePath: changed.file))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n".utf8))
        try handle.close()
        #expect(Judges.pending(mode: mode, sessions: all, agent: agent, env: env).contains(changed.key))
        await #expect(throws: Judges.Failure.self) {
            _ = try await Validation.run(mode: mode, set: .test, modes: modes, gate: gate, workFolder: home.appending(path: "w"), env: env)
        }
        // Too few labels for "validated" with 12 sessions.
        #expect(Validation.trustMap(modes: modes, env: env)[mode.id]?.level == CheckTrust.Level.none)
        #expect(Validation.verdicts(modeID: mode.id, env: env)?.modeID == mode.id)
        // Exemplars never come from the test set.
        let testKey = try #require(ValidationStore(env: env).splits()[mode.id]?.test.first)
        await #expect(throws: (any Error).self) {
            _ = try await store.addExemplar(Exemplar(modeID: mode.id, sessionKey: testKey, step: 0, quote: "BIG"),
                                            testSessions: ValidationStore(env: env).testSessions())
        }
    }

    @Test func eligibleModesForJudges() {
        func mode(_ id: String, fix: Mode.FixStatus?) -> Mode {
            var mode = Mode(id: id, name: id, definition: "d")
            mode.status = .active
            mode.fix = fix
            return mode
        }
        let modes = [mode("a", fix: .draft), mode("b", fix: nil), mode("c", fix: .applied), mode("d", fix: .draft),
                     mode("e", fix: .draft), mode("f", fix: .applied)]
        let seen = ["a": 10, "b": 9, "c": 8, "d": 1]
        #expect(Judges.eligible(modes, seen: seen).map(\.id) == ["a", "c"])
        // Or in the top 3 by cost: by tokens (d) or by steps (e); f has no recorded cost.
        let cost: [String: (tokens: Int, steps: Int)] = ["d": (50_000, 0), "e": (0, 12), "b": (90_000, 30)]
        #expect(Judges.eligible(modes, seen: seen, cost: cost).map(\.id) == ["a", "c", "d", "e"])
    }

    @Test func costSumsTheNotesSeenInAMode() {
        func note(_ id: String, tokens: Int?, steps: Int?) -> Note {
            Note(id: id, source: .model, description: id, step: 1, quote: "q", costTokens: tokens, costSteps: steps,
                 verdict: Verdict(accepted: true, reason: "", by: .model))
        }
        var notes = SessionNotes(sessionKey: "claude:a", transcript: "/t", title: nil, project: nil, requirements: [], outcome: .no,
                                 notes: [note("n1", tokens: 1000, steps: 2), note("n2", tokens: nil, steps: 5), note("n3", tokens: 7, steps: 7)],
                                 deviation: Deviation(), paragraph: "", advice: [],
                                 notesConfig: StepConfig(step: "notes", harness: "claude-code", model: "opus", promptVersion: 1),
                                 verifierConfig: nil, doneKeys: [:], runID: nil)
        notes.routes = [Route(noteID: "n1", modeID: "m", confidence: 0.9, by: .matching),
                        Route(noteID: "n2", modeID: "m", confidence: 0.9, by: .matching),
                        // Waits for the user: not seen yet, so not counted.
                        Route(noteID: "n3", modeID: "m", confidence: 0.3, by: .matching)]
        let cost = Judges.cost([notes], modes: [Mode(id: "m", name: "m", definition: "d")])
        #expect(cost["m"]?.tokens == 1000 && cost["m"]?.steps == 7)
    }

    /// A judge failure in a batch must fail the session (thrown); elsewhere the run goes on.
    /// Results judged under another scrub version start over.
    @Test func judgeErrorsAndTheScrubVersion() async throws {
        try Data(#"""
            #!/bin/sh
            if [ "$1 $2" = "auth status" ]; then echo '{"loggedIn":true,"email":"me@example.com","orgName":"Me"}'; exit 0; fi
            in=$(mktemp); cat > "$in"
            if grep -q "BROKEN" "$in"; then echo '{"type":"result","is_error":false,"result":"no json"}'; exit 0; fi
            echo '{"type":"result","is_error":false,"result":"","structured_output":{"present":true,"steps":[0],"toughCall":false,"severe":true,"reason":"new"},"usage":{"input_tokens":1,"output_tokens":1}}'
            """#.utf8).write(to: home.appending(path: "bin/claude"))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.appending(path: "bin/claude").path)
        let folder = home.appending(path: ".claude/projects/-w")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        func session(_ index: Int, _ text: String) throws -> (key: String, file: String) {
            let id = String(format: "%08x-0000-4000-8000-%012x", index, index)
            let file = folder.appending(path: "\(id).jsonl")
            try Data((#"{"type":"user","cwd":"/w","message":{"role":"user","content":"\#(text)"}}"# + "\n").utf8).write(to: file)
            return ("claude:\(id)", file.path)
        }
        let good = try session(1, "Fine task"), broken = try session(2, "BROKEN task")
        let mode = try #require(try await ModeStore(env: env).mode("large-file-read-whole"))
        let agent = LabAgent(harness: .claudeCode, model: "opus", effort: "low", mode: .call)
        let gate = try await SendGate.open(agent: agent, env: env)
        let work = home.appending(path: "w")

        // A verdict judged before the scrub version was part of the judge's key.
        let info = JSONLines.fileInfo(URL(filePath: good.file))
        try CheckStore(env: env).update(Judges.resultsID(mode.id)) { results in
            results.modeVersion = mode.version
            results.judge = "claude-code|opus|\(Judges.promptVersion)"
            results.verdicts[good.key] = CheckVerdict(positive: false, detail: "old", by: .judge, version: 1, fileSize: info.size,
                                                      fileModified: info.modified.timeIntervalSince1970)
        }
        let results = try await Judges.run(mode: mode, sessions: [good, broken], agent: agent, gate: gate, runID: nil, workFolder: work, env: env)
        #expect(results.verdicts[good.key]?.detail == "new" && results.verdicts[good.key]?.severe == true)
        #expect(results.judge?.hasSuffix("|scrub \(Scrubber.version)") == true && results.verdicts[broken.key] == nil)
        await #expect(throws: Judges.Failure.self) {
            _ = try await Judges.run(mode: mode, sessions: [broken], agent: agent, gate: gate, runID: nil, workFolder: work, env: env,
                                     stopOnError: true)
        }
    }

    /// Like the notes, a session whose user turns alone pass the judge's budget is refused
    /// with a clear error, and nothing is sent.
    @Test func aDigestOverTheBudgetIsNotJudged() async throws {
        let sent = home.appending(path: "sent")
        try Data(#"""
            #!/bin/sh
            if [ "$1 $2" = "auth status" ]; then echo '{"loggedIn":true,"email":"me@example.com","orgName":"Me"}'; exit 0; fi
            touch "\#(sent.path)"
            echo '{"type":"result","is_error":false,"result":"","structured_output":{"present":true,"steps":[0],"toughCall":false,"severe":false,"reason":"r"},"usage":{"input_tokens":1,"output_tokens":1}}'
            """#.utf8).write(to: home.appending(path: "bin/claude"))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.appending(path: "bin/claude").path)
        let folder = home.appending(path: ".claude/projects/-w")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = "00000001-0000-4000-8000-000000000001"
        let file = folder.appending(path: "\(id).jsonl")
        // 130 user turns of 3000 characters: ~390K, over the default budget and never cut.
        let turn = #"{"type":"user","cwd":"/w","message":{"role":"user","content":""# + String(repeating: "u", count: 3000) + #""}}"#
        try Data((Array(repeating: turn, count: 130).joined(separator: "\n") + "\n").utf8).write(to: file)
        let mode = try #require(try await ModeStore(env: env).mode("large-file-read-whole"))
        let agent = LabAgent(harness: .claudeCode, model: "opus", effort: "low", mode: .call)
        let gate = try await SendGate.open(agent: agent, env: env)
        await #expect {
            _ = try await Judges.judge(mode: mode, exemplars: [], session: "claude:\(id)", file: file, agent: agent, gate: gate,
                                       runID: nil, workFolder: home.appending(path: "w"), env: env)
        } throws: { error in
            (error as? Judges.Failure)?.message.contains("too long for one judge call") == true
        }
        #expect(!fm.fileExists(atPath: sent.path))
    }
}
