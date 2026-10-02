import Foundation
import Testing
import AKitFoundation
@testable import AKitErrorAnalysis
@testable import AKitLab

/// Judges inside a batch: "Invalid output is an error, not a skip."
extension BatchTests {
    @Test func aJudgeErrorFailsTheSessionUntilARetry() async throws {
        // The judge's answers come from a wrapper; every other call goes to the batch's fake.
        try fm.moveItem(at: home.appending(path: "bin/claude"), to: home.appending(path: "bin/claude-base"))
        try write("bin/claude", #"""
            #!/bin/sh
            case "$*" in
              *"You judge one recorded"*)
                cat > /dev/null
                echo judge >> "$HOME/calls.txt"
                if [ -f "$HOME/judge-fixed" ]; then
                  echo '{"type":"result","is_error":false,"result":"","structured_output":{"present":true,"steps":[0],"toughCall":false,"severe":false,"reason":"r"},"usage":{"input_tokens":10,"output_tokens":5}}'
                else
                  echo '{"type":"result","is_error":false,"result":"no json"}'
                fi ;;
              *) exec "$HOME/bin/claude-base" "$@" ;;
            esac

            """#, executable: true)
        for index in 1...2 { try session(index, text: "Do the task \(index)") }
        try await importSessions()
        let mode = try await ModeStore(env: env).confirm("large-file-read-whole")
        try ValidationStore(env: env).setJudge(agent, for: mode.id)

        let first = try await Batches.new(filter: Sampling.Filter(project: "/work/app"), size: 10, notesAgent: agent, environment: .background,
                                          akit: URL(filePath: "/usr/bin/true"), seed: 5, env: env)
        #expect(await run(first) == 0)
        var batch = try #require(BatchStore(env: env).load(first.id))
        #expect(batch.sessions.count == 2)
        #expect(batch.sessions.allSatisfy { $0.status == .error && $0.message == "The judge's answer isn't the JSON asked for." })
        #expect(CheckStore(env: env).load(Judges.resultsID(mode.id))?.verdicts.isEmpty != false)

        // Retry errors judges again; notes, verifier and matching are reused by their done keys.
        try write("judge-fixed", "")
        let notes = calls.filter { $0 == "notes" }.count
        let retry = try await Batches.resume(first.id, retryErrors: true, environment: .background, akit: URL(filePath: "/usr/bin/true"), env: env)
        #expect(await run(retry) == 0)
        batch = try #require(BatchStore(env: env).load(first.id))
        #expect(batch.sessions.allSatisfy { $0.status == .done })
        #expect(CheckStore(env: env).load(Judges.resultsID(mode.id))?.verdicts.count == 2)
        #expect(calls.filter { $0 == "notes" }.count == notes)
    }
}
