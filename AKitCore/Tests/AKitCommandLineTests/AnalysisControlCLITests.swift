import Foundation
import Testing
import AKitFoundation
@testable import AKitCommandLine

/// `akit analysis control …` against a temporary home and repository. Nothing is started:
/// cells are queued with --no-start.
extension AKitCLITests {
    func repository() async throws -> String {
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        func git(_ args: String...) async -> String? {
            let result = await ProcessRunner.run(URL(filePath: "/usr/bin/git"), arguments: ["-C", project.path] + args,
                                                 environment: env.gitVariables, timeout: 60)
            return result?.succeeded == true ? result?.output.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        }
        _ = await git("init", "-q", "-b", "master")
        try write("Projects/task/value.txt", "1\n")
        _ = await git("add", "-A")
        _ = await git("commit", "-q", "-m", "Start")
        return try #require(await git("rev-parse", "HEAD"))
    }

    @Test func controlTasksRunsAndCompareFromTheCommandLine() async throws {
        let base = try await repository()
        #expect(await akit("analysis", "--help").out.contains("akit analysis control run TASK"))

        let made = await akit("analysis", "control", "task", "new", "--repo", ".", "--base", String(base.prefix(7)),
                              "--prompt", "Make value 2", "--tests", #"test "$(cat value.txt)" = 2"#)
        #expect(made.code == 0 && made.out.hasPrefix("Saved control task make-value-2-"), "\(made)")
        let listed = await akit("analysis", "control", "tasks", "--json")
        let tasks = try #require(try JSONSerialization.jsonObject(with: Data(listed.out.utf8)) as? [[String: Any]])
        let id = try #require(tasks.first?["id"] as? String)
        #expect(tasks.count == 1 && tasks[0]["base"] as? String == base)
        #expect(await akit("analysis", "control", "tasks").out.contains("\(id)  \(base.prefix(7))  tests: "))

        // Refusals with their reasons.
        let pushback = await akit("analysis", "control", "task", "new", "--repo", ".", "--base", base, "--prompt", "x",
                                  "--assert", "intent-misread")
        #expect(pushback.code != 0 && pushback.err.contains("pushback"), "\(pushback)")
        #expect(await akit("analysis", "control", "task", "new", "--session", "claude:nope", "--tests", "true").err.contains("No session"))
        #expect(await akit("analysis", "control", "task", "new", "--repo", ".", "--base", base, "--prompt", "x").err.contains("--tests CMD or --assert MODE"))
        #expect(await akit("analysis", "control", "run", id, "--setups", "baseline,variant", "--no-start").err.contains("needs --patch-file"))
        // The agent's flags where no agent runs are refused, not ignored.
        let tasksWithModel = await akit("analysis", "control", "tasks", "--model", "sonnet", "--yes")
        #expect(tasksWithModel.code != 0 && tasksWithModel.err.contains("leave out --model, --yes"), "\(tasksWithModel)")
        #expect(await akit("analysis", "control", "compare", id, "--harness", "pi").err.contains("leave out --harness"))

        // Cells cost money: the count and estimate first, queued only with --yes.
        try write("Projects/task/rule.md", "- Check value.txt before saying done.\n")
        let asked = await akit("analysis", "control", "run", id, "--patch-file", "CLAUDE.md", "--patch-text", "@rule.md",
                               "--model", "sonnet", "--env", "background", "--no-start")
        #expect(asked.code == 0 && asked.out.contains("Up to 6 cells") && asked.out.hasSuffix("Run it again with --yes to queue them."), "\(asked)")
        let none = await akit("lab", "list", "--json")
        #expect((try JSONSerialization.jsonObject(with: Data(none.out.utf8)) as? [Any])?.isEmpty == true, "\(none)")

        // 3 repeats × (baseline, variant, read-only) with the chosen model and effort; the same again is all skipped.
        let run = await akit("analysis", "control", "run", String(id.prefix(10)), "--patch-file", "CLAUDE.md", "--patch-text", "@rule.md",
                             "--model", "sonnet", "--effort", "medium", "--read-only-setup", "--env", "background", "--no-start", "--yes")
        #expect(run.code == 0 && run.out.contains("Up to 9 cells; no estimate yet") && run.out.contains("Queued 9 cells: 3 × 1 tasks × baseline · Claude Code · sonnet · medium"), "\(run)")
        #expect(run.out.contains("variant · Claude Code · sonnet · medium · + CLAUDE.md") && run.out.contains("read-only"))
        let again = await akit("analysis", "control", "run", id, "--patch-file", "CLAUDE.md", "--patch-text", "@rule.md",
                               "--model", "sonnet", "--effort", "medium", "--read-only-setup", "--env", "background", "--no-start", "--yes")
        #expect(again.out.hasSuffix("Nothing to queue. Skipped 9 cells already done or queued."), "\(again)")
        let runs = await akit("lab", "list", "--json")
        let specs = try #require(try JSONSerialization.jsonObject(with: Data(runs.out.utf8)) as? [[String: Any]]).compactMap { $0["spec"] as? [String: Any] }
        #expect(specs.count == 9 && specs.allSatisfy { $0["kind"] as? String == "control" && $0["controlTask"] as? String == id })
        let agents = specs.compactMap { ($0["controlSetup"] as? [String: Any])?["agent"] as? [String: Any] }
        #expect(agents.count == 9 && agents.allSatisfy { $0["model"] as? String == "sonnet" && $0["effort"] as? String == "medium" }, "\(agents)")
        let patched = specs.compactMap { ($0["controlSetup"] as? [String: Any])?["patch"] as? [String: Any] }
        #expect(patched.count == 3 && patched.allSatisfy { $0["text"] as? String == "- Check value.txt before saying done.\n" })

        #expect(await akit("analysis", "control", "compare", id).out.contains("No finished cells of \(id) yet. 9 queued or running."))

        #expect(await akit("analysis", "control", "task", "remove", id).out == "Moved control task \(id) to the Trash.")
        #expect(await akit("analysis", "control", "tasks").out == "No control tasks.")
    }

    @Test func localAnalysisCommandsRefuseTheModelFlags() async throws {
        for (arguments, flags) in [(["notes", "--yes"], "--yes"), (["signals", "--model", "sonnet"], "--model"),
                                   (["check", "--harness", "pi", "--effort", "high"], "--harness, --effort")] {
            var err: [String] = []
            let code = await AKitCLI.run(["analysis"] + arguments, env: env, cwd: home, out: { _ in }, err: { err.append($0) })
            #expect(code != 0 && err.joined().contains("sends nothing to a model; leave out \(flags)."), "\(arguments): \(err)")
        }
    }

    @Test func codeChecksFromTheCommandLineKeepTheModesVersion() async throws {
        try write(".claude/projects/-work-app/s1.jsonl", """
            {"type":"user","cwd":"/work/app","sessionId":"s1","timestamp":"2026-09-20T10:00:00.000Z","message":{"role":"user","content":"Hi"}}
            {"type":"assistant","sessionId":"s1","timestamp":"2026-09-20T10:00:01.000Z","message":{"id":"m1","model":"claude-opus-5-5","content":[],"usage":{"input_tokens":3,"output_tokens":1}}}

            """)
        #expect(await akit("sessions", "import").code == 0)
        #expect(await akit("analysis", "modes").code == 0) // creates the modes repository with the seeds
        let checked = await akit("analysis", "check", "large-file-read-whole", "--json")
        let results = try #require(try JSONSerialization.jsonObject(with: Data(checked.out.utf8)) as? [[String: Any]], "\(checked)")
        // The import's upkeep and batches pass the version; a run without it would make them start over.
        #expect(results.first?["modeVersion"] as? Int != nil, "\(results)")
    }
}
