import Foundation
import Testing
import AKitFoundation
import AKitInsights
@testable import AKitErrorAnalysis
@testable import AKitLab

/// A whole batch with indexed sessions and a fake `claude` that answers every call by its
/// system prompt.
@Suite(.serialized)
struct BatchTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-batch-\(UUID().uuidString)")
        try fm.createDirectory(at: home.appending(path: "bin"), withIntermediateDirectories: true)
        try write("bin/claude", #"""
            #!/bin/sh
            if [ "$1 $2" = "auth status" ]; then
              echo '{"loggedIn":true,"apiProvider":"firstParty","email":"me@example.com","orgName":"Me"}'; exit 0
            fi
            # Two calls run at once: each reads its own copy of the input.
            in=$(mktemp)
            cat > "$in"
            ok() { echo '{"type":"result","is_error":false,"result":"","structured_output":'"$1"',"usage":{"input_tokens":10,"output_tokens":5}}'; }
            case "$*" in
              *"Fill the answer in this order"*)
                echo notes >> "$HOME/calls.txt"
                if grep -q "BROKEN" "$in" && [ ! -f "$HOME/fixed" ]; then echo '{"type":"result","is_error":false,"result":"no json"}'; exit 0; fi
                ok '{"requirements":["Do the task"],"outcome":"partly","notes":[{"id":"n1","description":"Read a file whole","step":0,"quote":"Do the task","severity":"low","faultLayer":"agent"},{"id":"n2","description":"Vague request","step":0,"quote":"the task","severity":"low","faultLayer":"task-spec"}],"paragraph":"It went.","advice":[]}' ;;
              *"You check notes another reviewer"*)
                echo verifier >> "$HOME/calls.txt"
                ok '{"verdicts":[{"id":"n1","supported":true,"reason":"ok"},{"id":"n2","supported":true,"reason":"ok"}]}' ;;
              *"You sort notes"*)
                echo matching >> "$HOME/calls.txt"
                ok '{"routes":[{"note":"n1","mode":"large-file-read-whole","confidence":0.9},{"note":"n2","mode":"none","confidence":0.9}]}' ;;
              *"You group notes"*)
                echo clustering >> "$HOME/calls.txt"
                refs=$(grep -o 'claude:[0-9a-f-]*#n2' "$in" | sed 's/.*/"&"/' | paste -sd, -)
                ok '{"modes":[{"name":"Vague requests","kind":"failure","definition":"The request leaves the goal open.","include":[],"exclude":[],"notes":['"$refs"']}]}' ;;
              *) echo '{"type":"result","is_error":true,"result":"unknown call"}' ;;
            esac

            """#, executable: true)
    }

    var env: HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home, variables: ["HOME": home.path],
                           executableSearchPaths: [home.appending(path: "bin"), URL(filePath: "/usr/bin"), URL(filePath: "/bin")])
    }

    func write(_ path: String, _ text: String, executable: Bool = false) throws {
        let url = home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if executable { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
    }

    /// A Claude Code session with 6 requests.
    func session(_ index: Int, text: String) throws {
        let id = String(format: "%08x-0000-4000-8000-%012x", index, index)
        var lines: [[String: Any]] = [["type": "user", "cwd": "/work/app", "sessionId": id, "timestamp": "2026-10-01T10:00:00Z",
                                       "message": ["role": "user", "content": text]]]
        for request in 0..<6 {
            lines.append(["type": "assistant", "sessionId": id, "timestamp": "2026-10-01T10:0\(request):05Z",
                          "message": ["id": "m\(index)-\(request)", "model": "claude-opus-5-5", "role": "assistant",
                                      "content": [["type": "text", "text": "Working \(request)"]],
                                      "usage": ["input_tokens": 10, "output_tokens": 5]]])
        }
        let body = lines.map { String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n") + "\n"
        try write(".claude/projects/-work-app/\(id).jsonl", body)
    }

    func importSessions() async throws {
        let database = try IndexSchema.open(InsightsPaths(env: env).database)
        _ = try await SessionImporter.importAndBind(env: env, projectsRoot: home.appending(path: "Projects"), database: database)
    }

    var calls: [String] { ((try? String(contentsOf: home.appending(path: "calls.txt"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }

    let agent = LabAgent(harness: .claudeCode, model: "opus", effort: "low", mode: .call)

    func run(_ run: LabRun) async -> Int32 {
        await LabWorker.run(id: run.id, env: env, startNext: false, handleSignals: false, execute: AnalysisRuns.execute, out: { _ in })
    }

    @Test func aBatchReviewsMatchesAndClusters() async throws {
        for index in 1...5 { try session(index, text: "Do the task \(index)") }
        try session(6, text: "Do the task BROKEN")
        // Too short to sample: 1 request.
        try write(".claude/projects/-work-app/short.jsonl", #"{"type":"user","cwd":"/work/app","message":{"role":"user","content":"hi"}}"# + "\n")
        try await importSessions()

        let first = try await Batches.new(filter: Sampling.Filter(project: "/work/app"), size: 10, notesAgent: agent, environment: .background,
                                          akit: URL(filePath: "/usr/bin/true"), seed: 5, env: env)
        #expect(first.spec.kind == .analysis && first.spec.batch == first.id)
        var batch = try #require(BatchStore(env: env).load(first.id))
        #expect(batch.sessions.count == 6)
        #expect(batch.sessions.allSatisfy { $0.pick.inclusion > 0 && $0.status == .pending })

        #expect(await run(first) == 0)
        batch = try #require(BatchStore(env: env).load(first.id))
        let broken = try #require(batch.sessions.first { $0.status == .error })
        #expect(broken.message == "The notes answer isn't the JSON asked for.")
        #expect(batch.coverage.done == 5 && batch.coverage.total == 6)
        #expect(batch.progress(of: "matching") == 5)
        // Clustering waits until every session is done or failed: it ran, once.
        #expect(batch.clustered && batch.candidates == ["vague-requests"])
        #expect(calls.filter { $0 == "clustering" }.count == 1)
        #expect(!batch.spotCheck.isEmpty)
        let result = try #require(LabStore.load(first.id, env: env)?.result?.batch)
        #expect(result.done == 5 && result.failed == 1 && result.total == 6)
        let store = ModeStore(env: env)
        // Clustering makes candidates; the user confirms them (or a later case promotes them).
        #expect(try await store.mode("vague-requests")?.status == .candidate)
        // One batch match: the seed is still inactive.
        #expect(try await store.mode("large-file-read-whole")?.status == .seedInactive)

        // Retry errors: only the failed session runs again.
        try write("fixed", "")
        let before = calls.filter { $0 == "notes" }.count
        let retry = try await Batches.resume(first.id, retryErrors: true, environment: .background, akit: URL(filePath: "/usr/bin/true"), env: env)
        #expect(await run(retry) == 0)
        #expect(calls.filter { $0 == "notes" }.count == before + 1)
        let after = try #require(BatchStore(env: env).load(first.id)).coverage
        #expect(after.done == 6 && after.total == 6)

        // A second, independent batch matching the seed activates it.
        let second = try await Batches.new(filter: Sampling.Filter(project: "/work/app"), size: 3, notesAgent: agent, environment: .background,
                                           akit: URL(filePath: "/usr/bin/true"), seed: 9, env: env)
        #expect(await run(second) == 0)
        #expect(try await store.mode("large-file-read-whole")?.status == .active)
        // Done keys: the second batch reused the notes of sessions it shares with the first.
        #expect(calls.filter { $0 == "notes" }.count == before + 1)
        // Recorded cost per reviewed session is the estimate of the next batch; the limit refuses one that would pass it.
        #expect(Batches.estimate(sessions: 10, agent: agent, env: env) == nil)
        try SendLog.append(SendRecord(purpose: "notes", session: "claude:x", runID: nil, destination: SendDestination(harness: .claudeCode,
                                      provider: "anthropic", account: "me@example.com", org: "Me"), model: "opus", inputCharacters: 100,
                                      usage: SendUsage(cost: 0.5)), env: env)
        #expect(Batches.estimate(sessions: 10, agent: agent, env: env) == 5)
        try LabSettings(monthlyLimit: 1).save(env: env)
        await #expect(throws: (any Error).self) {
            _ = try await Batches.new(filter: Sampling.Filter(project: "/work/app"), size: 3, notesAgent: agent, environment: .background,
                                      akit: URL(filePath: "/usr/bin/true"), seed: 11, env: env)
        }
    }

    @Test func reservedSessionsAreNeverSampled() async throws {
        for index in 1...3 { try session(index, text: "Do the task \(index)") }
        try await importSessions()
        let reserved = String(format: "claude:%08x-0000-4000-8000-%012x", 1, 1)
        try BootstrapReservations(env: env).update { $0 += [.init(sessionKey: reserved, transcript: "/t")] }
        let run = try await Batches.new(filter: Sampling.Filter(), size: 10, notesAgent: agent, environment: .background,
                                        akit: URL(filePath: "/usr/bin/true"), env: env)
        let batch = try #require(BatchStore(env: env).load(run.id))
        #expect(batch.sessions.count == 2 && !batch.sessions.contains { $0.pick.sessionKey == reserved })
    }

    @Test func authorizationErrorsAreRecognized() {
        #expect(BatchRunner.isAuthorizationError("API Error: 401 {\"error\":\"Unauthorized\"}"))
        #expect(BatchRunner.isAuthorizationError("Claude Code is not logged in"))
        #expect(!BatchRunner.isAuthorizationError("The notes answer isn't the JSON asked for."))
    }

    @Test func pauseStopsHandingOutSessions() async throws {
        let picks = (1...3).map { Sampling.Pick(sessionKey: "claude:s\($0)", file: "/f\($0)", inclusion: 1, sampling: "fixed", stratum: "fixed") }
        let batch = Batch(runID: "b1", filter: Sampling.Filter(), size: 3, seed: 0, notesAgent: agent, matchingAgent: agent, language: .english,
                          sessions: picks.map { Batch.Session(pick: $0) })
        let store = BatchStore(env: env)
        try store.save(batch)
        let state = BatchRunner.State(batch: batch, store: store)
        #expect(await state.next()?.pick.sessionKey == "claude:s1")
        try Batches.pause("b1", env: env)
        #expect(await state.next() == nil)
        // A write after the pause keeps it.
        await state.update("claude:s1") { $0.status = .done }
        #expect(store.load("b1")?.paused == true)
        #expect(store.load("b1")?.sessions[0].status == .done)
    }

    @Test func aResumeIsNotWrittenBackToPausedByAWorkerThatSawThePause() async throws {
        let picks = (1...3).map { Sampling.Pick(sessionKey: "claude:s\($0)", file: "/f\($0)", inclusion: 1, sampling: "fixed", stratum: "fixed") }
        let batch = Batch(runID: "b1", filter: Sampling.Filter(), size: 3, seed: 0, notesAgent: agent, matchingAgent: agent, language: .english,
                          sessions: picks.map { Batch.Session(pick: $0) })
        let store = BatchStore(env: env)
        try store.save(batch)
        let state = BatchRunner.State(batch: batch, store: store)
        #expect(await state.next()?.pick.sessionKey == "claude:s1")
        try Batches.pause("b1", env: env)
        // The worker sees the pause, then the user resumes while its session still runs.
        #expect(await state.next() == nil)
        _ = try await Batches.resume("b1", environment: .background, akit: URL(filePath: "/usr/bin/true"), env: env)
        await state.update("claude:s1") { $0.status = .done }
        #expect(store.load("b1")?.paused == false && store.load("b1")?.sessions[0].status == .done)
        #expect(await state.next()?.pick.sessionKey == "claude:s2")
        // A pause the worker sets itself is saved, with its reason.
        await state.finish {
            $0.paused = true
            $0.pauseReason = "The account changed."
        }
        #expect(store.load("b1")?.paused == true && store.load("b1")?.pauseReason == "The account changed.")
    }

    @Test func aRetryQueuedWhileAnOldRunIsAliveIsNotWrittenBackToErrors() async throws {
        let picks = (1...3).map { Sampling.Pick(sessionKey: "claude:s\($0)", file: "/f\($0)", inclusion: 1, sampling: "fixed", stratum: "fixed") }
        var batch = Batch(runID: "b1", filter: Sampling.Filter(), size: 3, seed: 0, notesAgent: agent, matchingAgent: agent, language: .english,
                          sessions: picks.map { Batch.Session(pick: $0) })
        batch.sessions[0].status = .error
        let store = BatchStore(env: env)
        try store.save(batch)
        let state = BatchRunner.State(batch: batch, store: store)
        #expect(await state.next()?.pick.sessionKey == "claude:s2")
        // `akit analysis batch resume --retry-errors` while the old run still works on s2.
        _ = try await Batches.resume("b1", retryErrors: true, environment: .background, akit: URL(filePath: "/usr/bin/true"), env: env)
        await state.update("claude:s2") { $0.status = .done }
        #expect(store.load("b1")?.sessions.map(\.status) == [.pending, .done, .pending])
        // The old run sees the retry and takes the session on itself.
        #expect(await state.next()?.pick.sessionKey == "claude:s1")
        #expect(store.load("b1")?.sessions.map(\.status) == [.running, .done, .pending])
    }

    @Test func aSessionTooLongForADigestIsCountedApartAndNeverRetried() async throws {
        for index in 1...2 { try session(index, text: "Do the task \(index)") }
        // One user turn of 400K characters: over the default budget, and user turns are never cut.
        try session(3, text: String(repeating: "word ", count: 80_000))
        try await importSessions()
        let run = try await Batches.new(filter: Sampling.Filter(project: "/work/app"), size: 10, notesAgent: agent, environment: .background,
                                        akit: URL(filePath: "/usr/bin/true"), seed: 3, env: env)
        #expect(await self.run(run) == 0)
        let batch = try #require(BatchStore(env: env).load(run.id))
        #expect(batch.coverage.done == 2 && batch.tooLong == 1 && !batch.sessions.contains { $0.status == .error })
        #expect(batch.sessions.first { $0.status == .tooLong }?.message?.hasPrefix("The session is too long for one call") == true)
        #expect(calls.filter { $0 == "notes" }.count == 2)
        let result = try #require(LabStore.load(run.id, env: env)?.result?.batch)
        #expect(result.failed == 0 && result.done == 2 && result.total == 3)
        // Nothing for "Retry errors" or Resume to do: no money spent on it again.
        #expect(!batch.hasOpenSessions && !batch.unfinished)
        await #expect(throws: Batches.Failure.self) {
            _ = try await Batches.resume(run.id, retryErrors: true, environment: .background, akit: URL(filePath: "/usr/bin/true"), env: env)
        }
    }

    @Test func anUnreadableSettingsFileRefusesSends() async throws {
        for index in 1...2 { try session(index, text: "Do the task \(index)") }
        try await importSessions()
        try write(".akit/lab/settings.json", "{ not json")
        await #expect {
            _ = try await Batches.new(filter: Sampling.Filter(), size: 2, notesAgent: agent, environment: .background,
                                      akit: URL(filePath: "/usr/bin/true"), env: env)
        } throws: { error in
            error.localizedDescription.contains("settings.json can't be read")
        }
        await #expect(throws: SendAccounts.Failure.self) { _ = try await SendGate.open(agent: agent, env: env) }
        // A limit that doesn't decode would read as no limit at all.
        try write(".akit/lab/settings.json", #"{"monthlyLimit":"ten"}"#)
        #expect(LabSettings.load(env: env).monthlyLimit == nil)
        #expect(throws: SendAccounts.Failure.self) { _ = try LabSettings.loadForSending(env: env) }
        try write(".akit/lab/settings.json", #"{"monthlyLimit":10}"#)
        #expect(try LabSettings.loadForSending(env: env).monthlyLimit == 10)
        _ = try await SendGate.open(agent: agent, env: env)
    }

    @Test func theEstimateCountsTheLatestReviewOfEachSession() throws {
        let claude = SendDestination(harness: .claudeCode, provider: "anthropic", account: "me@example.com", org: "Me")
        func record(_ purpose: String, _ session: String, _ cost: Double, at seconds: Double) throws {
            try SendLog.append(SendRecord(date: Date(timeIntervalSince1970: seconds), purpose: purpose, session: session, runID: nil,
                                          destination: claude, model: "opus", inputCharacters: 100, usage: SendUsage(cost: cost)), env: env)
        }
        // claude:a was reviewed twice: only the second review (0.3 + 0.1) counts.
        try record("notes", "claude:a", 0.5, at: 1000)
        try record("matching", "claude:a", 0.1, at: 1001)
        try record("notes", "claude:a", 0.3, at: 2000)
        try record("verifier", "claude:a", 0.1, at: 2001)
        try record("notes", "claude:b", 0.6, at: 1500)
        let estimate = try #require(Batches.estimate(sessions: 2, agent: agent, env: env))
        #expect(abs(estimate - 1.0) < 1e-9)
    }

    /// A fake Pi signed in to opencode-go, whose default model is qwen.
    func fakePi() throws {
        try write("bin/pi", """
            #!/bin/sh
            case "$*" in
              *"auth check --provider opencode-go"*) echo '{"status":"ready"}' ;;
              *) echo '{"status":"not_ready"}' ;;
            esac

            """, executable: true)
        try write(".pi/agent/settings.json", #"{"defaultProvider":"opencode-go","defaultModel":"qwen3.6-plus"}"#)
        try LabSettings(piAccounts: [PiAccount(provider: "opencode-go", account: "me", org: "me")]).save(env: env)
    }

    @Test func theDefaultReviewerIsAllowedForTheMostSessions() async throws {
        try fakePi()
        let pi = SendOrigin.piSession(providers: ["opencode-go"])
        // Claude sessions: Pi is another family but may not get them; Claude Code is their origin.
        let claudeSessions: [(model: String?, origin: SendOrigin)] = Array(repeating: ("claude-opus-5-5", .claudeSession), count: 3)
        let forClaude = try await Batches.defaultReviewer(sessions: claudeSessions, env: env)
        #expect(forClaude.agent.harness == .claudeCode && forClaude.refused.isEmpty)
        // Pi sessions: Claude Code is another family but not their origin; Pi is.
        let piSessions: [(model: String?, origin: SendOrigin)] = [("qwen3.6-plus", pi), ("qwen3.6-plus", pi)]
        let reviewer = try await Batches.defaultReviewer(sessions: piSessions, env: env)
        #expect(reviewer.agent.harness == .pi && reviewer.agent.model == "opencode-go/qwen3.6-plus" && reviewer.refused.isEmpty)
        // Both kinds: neither may get all of them. The one allowed for more reviews them, and
        // the others are left out instead of failing the batch.
        let mixed = try await Batches.defaultReviewer(sessions: claudeSessions + piSessions, env: env)
        #expect(mixed.agent.harness == .claudeCode && mixed.refused == [pi] && mixed.reason?.contains("didn't produce this data") == true)
        // Nothing is left when no reviewer may get any of them.
        await #expect(throws: Batches.Failure.self) {
            _ = try await Batches.defaultReviewer(sessions: [("qwen3.6-plus", .piSession(providers: ["elsewhere"]))], env: env)
        }
        // On the allowed list, Pi gets Claude sessions too, being of another family.
        var settings = LabSettings.load(env: env)
        settings.allowedDestinations = [SendDestination(harness: .pi, provider: "opencode-go", account: "me", org: "me")]
        try settings.save(env: env)
        #expect(try await Batches.defaultReviewer(sessions: claudeSessions, env: env).agent.harness == .pi)
        let allowed = try await Batches.defaultReviewer(sessions: claudeSessions + piSessions, env: env)
        #expect(allowed.agent.harness == .pi && allowed.refused.isEmpty)
    }

    /// A Pi session of 6 answers in /work/app, from opencode-go.
    func piSession(_ index: Int) throws {
        let id = String(format: "%08x-0000-4000-9000-%012x", index, index)
        var lines: [[String: Any]] = [["type": "session", "version": 3, "id": id, "timestamp": "2026-10-01T10:00:00.000Z", "cwd": "/work/app"],
                                      ["type": "message", "id": "u", "parentId": NSNull(), "timestamp": "2026-10-01T10:00:01.000Z",
                                       "message": ["role": "user", "content": [["type": "text", "text": "Do the Pi task \(index)"]]]]]
        // Entry ids are unique per session: the index dedupes requests by id and time.
        for request in 0..<6 {
            lines.append(["type": "message", "id": "a\(index)-\(request)", "parentId": request == 0 ? "u" : "a\(index)-\(request - 1)",
                          "timestamp": "2026-10-01T10:00:1\(request).000Z",
                          "message": ["role": "assistant", "provider": "opencode-go", "model": "qwen3.6-plus",
                                      "content": [["type": "text", "text": "Working \(request)"]],
                                      "usage": ["input": 10, "output": 5, "cacheRead": 0, "cacheWrite": 0, "totalTokens": 15,
                                                "cost": ["total": 0.01]]]])
        }
        let body = lines.map { String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n") + "\n"
        try write(".pi/agent/sessions/--work-app--/2026-10-01T10-00-0\(index)-000Z_\(id).jsonl", body)
    }

    @Test func aMixedProjectLeavesOutWhatTheAutomaticReviewerMayNotGet() async throws {
        try fakePi()
        for index in 1...3 { try session(index, text: "Do the task \(index)") }
        for index in 1...2 { try piSession(index) }
        try await importSessions()
        let all = Sampling.Filter(project: "/work/app")
        #expect(Batches.sampleSize(filter: all, size: 10, env: env) == 5)

        // Automatic: Claude Code may get the three Claude sessions, Pi only the two Pi ones.
        let sample = try await Batches.draw(filter: all, size: 10, notesAgent: nil, seed: 1, env: env)
        #expect(sample.notesAgent.harness == .claudeCode && sample.picks.count == 3 && sample.leftOut == 2)
        #expect(sample.picks.allSatisfy { $0.sessionKey.hasPrefix("claude:") })
        #expect(sample.warning?.hasPrefix("2 sessions of the filter are left out") == true)
        let run = try await Batches.queue(sample, environment: .background, akit: URL(filePath: "/usr/bin/true"), env: env)
        let batch = try #require(BatchStore(env: env).load(run.id))
        #expect(batch.leftOut == 2 && batch.leftOutReason != nil && batch.sessions.count == 3)

        // The harness filter takes the Pi sessions alone, which Pi reviews whole.
        let pi = try await Batches.draw(filter: Sampling.Filter(project: "/work/app", harness: "pi"), size: 10, notesAgent: nil, env: env)
        #expect(pi.notesAgent.harness == .pi && pi.picks.count == 2 && pi.leftOut == 0 && pi.warning == nil)

        // A reviewer you choose keeps every session; the warning counts the ones it will be refused.
        let chosen = LabAgent(harness: .pi, model: "opencode-go/qwen3.6-plus", effort: "low", mode: .call)
        let manual = try await Batches.draw(filter: all, size: 10, notesAgent: chosen, env: env)
        #expect(manual.picks.count == 5 && manual.leftOut == 0 && manual.refused == 3)
        #expect(manual.warning?.hasPrefix("3 of the 5 sampled sessions may not go to") == true)
    }

    @Test func theAccountRecheckCoversEveryAgentOfTheBatch() async throws {
        let now = SendDestination(harness: .claudeCode, provider: "anthropic", account: "me@example.com", org: "Me")
        let before = SendDestination(harness: .claudeCode, provider: "anthropic", account: "old@example.com", org: "Me")
        let judge = LabAgent(harness: .claudeCode, model: "sonnet", effort: "low", mode: .call)
        func gate(_ destination: SendDestination) -> SendGate { SendGate(destination: destination, isWork: false, settings: LabSettings()) }
        #expect(await BatchRunner.accountProblem([(agent, gate(now)), (judge, gate(now))], env: env) == nil)
        // The notes agent's account is unchanged; the judge's isn't.
        let problem = try #require(await BatchRunner.accountProblem([(agent, gate(now)), (judge, gate(before))], env: env))
        #expect(problem.contains(judge.label) && problem.contains("me@example.com"))
    }

    @Test func onlyCurrentActiveModesRunTheirCodeChecks() {
        var merged = Mode(id: "repeated-steps", name: "Repeated steps", definition: "d", status: .active)
        merged.mergedInto = "large-file-read-whole"
        let modes = [Mode(id: "large-file-read-whole", name: "Large file", definition: "d", status: .active), merged,
                     Mode(id: "weakening-tests", name: "Weakening tests", definition: "d", status: .seedInactive)]
        #expect(AnalysisUpkeep.activeChecks(modes).map(\.mode.id) == ["large-file-read-whole"])
    }

    @Test func aBatchPausedWhileQueuedStaysPaused() async throws {
        for index in 1...3 { try session(index, text: "Do the task \(index)") }
        try await importSessions()
        let run = try await Batches.new(filter: Sampling.Filter(), size: 3, notesAgent: agent, environment: .background,
                                        akit: URL(filePath: "/usr/bin/true"), seed: 1, env: env)
        try Batches.pause(run.id, env: env)
        #expect(await self.run(run) == 0)
        #expect(calls.isEmpty)
        let result = try #require(LabStore.load(run.id, env: env)?.result?.batch)
        #expect(result.paused && result.done == 0)
        #expect(BatchStore(env: env).load(run.id)?.paused == true)
    }
}
