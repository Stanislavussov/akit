import Foundation
import Testing
import AKitFoundation
@testable import AKitLab

/// Session metrics from made-up Claude Code transcripts in a temporary folder.
struct SessionAnalyzerTests {
    let folder: URL
    let fm = FileManager.default

    init() throws {
        folder = fm.temporaryDirectory.appending(path: "akit-lab-\(UUID().uuidString)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func write(_ name: String, _ lines: [[String: Any]]) throws -> URL {
        let url = folder.appending(path: name)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = try lines.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
            .joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: url)
        return url
    }

    /// One response line; a response with several blocks is several lines with the same id.
    func call(_ id: String, context: Int, output: Int = 10, cacheRead: Int? = nil, at second: Int,
              _ blocks: [[String: Any]], sidechain: Bool = false) -> [String: Any] {
        let read = cacheRead ?? context - 100
        return ["type": "assistant", "isSidechain": sidechain, "timestamp": time(second),
                "message": ["id": id, "model": "claude-opus-5-5", "content": blocks,
                            "usage": ["input_tokens": 50, "cache_creation_input_tokens": context - read - 50,
                                      "cache_read_input_tokens": read, "output_tokens": output]]]
    }

    func tool(_ id: String, _ name: String, _ input: [String: Any]) -> [String: Any] {
        ["type": "tool_use", "id": id, "name": name, "input": input]
    }

    func result(_ id: String, _ text: String, error: Bool = false, at second: Int) -> [String: Any] {
        ["type": "user", "timestamp": time(second),
         "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "is_error": error,
                                                   "content": [["type": "text", "text": text]]]]]]
    }

    func prompt(_ text: String, at second: Int) -> [String: Any] {
        ["type": "user", "timestamp": time(second), "message": ["role": "user", "content": text]]
    }

    func time(_ second: Int) -> String {
        ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_790_000_000 + Double(second)))
    }

    @Test func countsCallsFrictionAndCommits() throws {
        let file = try write("s.jsonl", [
            prompt("Fix the bug", at: 0),
            ["type": "attachment", "attachment": ["type": "hook_success", "content": String(repeating: "x", count: 5000)]],
            call("m1", context: 1000, at: 1, [tool("t1", "Read", ["file_path": "/p/a.swift"])]),
            result("t1", "func a()", at: 2),
            call("m2", context: 1200, at: 3, [tool("t2", "Read", ["file_path": "/p/a.swift"])]),
            result("t2", "func a()", at: 4),
            // Two lines of one response: counted once, the last output wins.
            call("m3", context: 1300, output: 5, at: 5, [["type": "text", "text": "Editing"]]),
            call("m3", context: 1300, output: 40, at: 5, [tool("t3", "Edit", ["file_path": "/p/a.swift", "old_string": "a", "new_string": "b"])]),
            result("t3", "The user doesn't want to proceed with this tool use. The tool use was rejected.", error: true, at: 6),
            call("m4", context: 1400, at: 7, [tool("t4", "Read", ["file_path": "/p/a.swift"]),
                                              ]),
            result("t4", "func a()", at: 8),
            call("m5", context: 1500, at: 9, [tool("t5", "Bash", ["command": "git commit -m 'Fix a'"])]),
            result("t5", "[lab 1a2b3c4] Fix a\n 1 file changed", at: 10),
            call("m6", context: 1600, at: 11, [tool("t6", "Bash", ["command": "swift build"])]),
            result("t6", "error: nope", error: true, at: 12),
            prompt("[Request interrupted by user]", at: 13),
            ["type": "system", "subtype": "turn_duration", "durationMs": 10_000, "timestamp": time(12)],
            call("x1", context: 900, at: 14, [["type": "text", "text": "sub"]], sidechain: true),
        ])
        let metrics = try SessionAnalyzer.analyze(file: file)
        #expect(metrics.calls == 6)
        #expect(metrics.outputTokens == 10 * 5 + 40)
        #expect(metrics.baselineContext == 1000 && metrics.peakContext == 1600)
        #expect(metrics.freshTokens == 6 * 100 + 10 * 5 + 40)
        #expect(metrics.toolCalls == 6)
        // The second read of a.swift repeats the first; the third follows an Edit (even a refused one).
        #expect(metrics.rereads == 1)
        #expect(metrics.rejected == 1 && metrics.toolErrors == 1 && metrics.interrupts == 1)
        #expect(metrics.commits == [LabCommit(sha: "1a2b3c4", subject: "Fix a")])
        #expect(metrics.wallSeconds == 13 && metrics.activeSeconds == 10)
        #expect(metrics.subagentCalls == 1 && metrics.subagentFreshTokens == 110)
        #expect(metrics.models == ["claude-opus-5-5"])
    }

    @Test func contextRentAddsUpToWhatWasSent() throws {
        let big = String(repeating: "c", count: 3000)
        let file = try write("rent.jsonl", [
            prompt("Go", at: 0),
            call("m1", context: 10_000, at: 1, [tool("t1", "Bash", ["command": "cat big.swift | head -50"])]),
            result("t1", big, at: 2),
            // Log-only: never sent.
            ["type": "attachment", "attachment": ["type": "prompt_snapshot", "systemPrompt": big]],
            call("m2", context: 13_000, at: 3, [tool("t2", "Bash", ["command": "swift test > out.txt"])]),
            result("t2", big, at: 4),
            ["type": "attachment", "attachment": ["type": "hook_additional_context", "content": [big]]],
            call("m3", context: 16_000, at: 5, [["type": "text", "text": "done"]]),
            ["type": "system", "subtype": "compact_boundary", "timestamp": time(6)],
            call("m4", context: 4_000, at: 7, [["type": "text", "text": "after"]]),
        ])
        let rent = try SessionAnalyzer.analyze(file: file).contextRent
        #expect(rent.total == 10_000 + 13_000 + 16_000 + 4_000)
        // Baselines: 10k sent by the three calls of the first segment, 4k by the one after compaction.
        #expect(rent.baseline == 10_000 * 3 + 4_000)
        // The cat output is almost all of the 3k growth before m2, sent by m2 and m3.
        #expect(rent.readCode > 5_500 && rent.readCode <= 6_000)
        #expect(rent.injections > 1_000)
        #expect(rent.ownOutput > 0 && rent.other > 0)
        #expect(abs(rent.share(rent.baseline) - 34_000.0 / 43_000.0) < 0.001)
    }

    @Test func subagentFilesCountApart() throws {
        let file = try write("abc.jsonl", [prompt("Go", at: 0), call("m1", context: 500, at: 1, [["type": "text", "text": "ok"]])])
        _ = try write("abc/subagents/agent-1.jsonl", [
            call("s1", context: 300, at: 2, [["type": "text", "text": "a"]]),
            call("s2", context: 400, at: 3, [["type": "text", "text": "b"]]),
        ])
        let metrics = try SessionAnalyzer.analyze(file: file)
        #expect(metrics.calls == 1)
        #expect(metrics.subagentCalls == 2 && metrics.subagentFreshTokens == 220)
    }

    @Test func shellReadsAreOnlyReadingCommands() {
        #expect(ShellCommand.onlyReads("cat a.swift"))
        #expect(ShellCommand.onlyReads("cd /x && sed -n 1,80p a.swift | grep foo"))
        #expect(ShellCommand.onlyReads("git -C /x show HEAD:a.swift"))
        #expect(!ShellCommand.onlyReads("sed -i '' s/a/b/ a.swift"))
        #expect(!ShellCommand.onlyReads("cat > a.swift <<'EOF'\nx\nEOF"))
        #expect(!ShellCommand.onlyReads("swift test"))
        #expect(!ShellCommand.onlyReads("cd /x"))
    }

    @Test func commitLines() {
        let lines = "[main (root-commit) abc1234] First\n[feature/x 1234567890abcdef] Second one\nnot [a line]"
        #expect(SessionAnalyzer.Reader.commits(in: lines).map(\.sha) == ["abc1234", "1234567890abcdef"])
        // `git commit -q … && git log --oneline -3`: only the line whose subject is in the command.
        let log = "11f1b09 Plan the Lab\n6a4a3f6 Merge branch 'x'\n75881d1 Show the app version"
        let quiet = SessionAnalyzer.Reader.commits(in: log, command: "git commit -q -m \"Plan the Lab\" && git log --oneline -3")
        #expect(quiet == [LabCommit(sha: "11f1b09", subject: "Plan the Lab")])
    }

    @Test func mergedCommitsFromGit() async throws {
        let env = HarnessEnvironment(homeDirectory: folder, variables: [
            "HOME": folder.path, "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "T", "GIT_AUTHOR_EMAIL": "t@example.com",
            "GIT_COMMITTER_NAME": "T", "GIT_COMMITTER_EMAIL": "t@example.com",
        ], executableSearchPaths: [URL(filePath: "/usr/bin")])
        let repo = folder.appending(path: "repo")
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        func git(_ args: String...) async -> String? { await LabGit.output(args, in: repo, env: env) }
        _ = await git("init", "-q", "-b", "master")
        _ = await git("commit", "-q", "--allow-empty", "-m", "one")
        let merged = await git("rev-parse", "--short", "HEAD")!
        _ = await git("switch", "-q", "-c", "side")
        _ = await git("commit", "-q", "--allow-empty", "-m", "two")
        let side = await git("rev-parse", "--short", "HEAD")!
        let marked = await LabGit.markMerged([LabCommit(sha: merged, subject: "one"), LabCommit(sha: side, subject: "two"),
                                              LabCommit(sha: "deadbee", subject: "gone")], in: repo, env: env)
        #expect(marked.map(\.onMainBranch) == [true, false, nil])
        let gone = await LabGit.markMerged([LabCommit(sha: merged, subject: "one")], in: folder.appending(path: "nope"), env: env)
        #expect(gone[0].onMainBranch == nil)
    }
}
