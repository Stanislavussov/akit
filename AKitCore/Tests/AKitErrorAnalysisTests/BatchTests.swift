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
