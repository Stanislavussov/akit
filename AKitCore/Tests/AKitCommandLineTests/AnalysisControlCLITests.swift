import Foundation
import Testing
import AKitFoundation

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

        // 3 repeats × (baseline, variant, read-only); the same again is all skipped.
        try write("Projects/task/rule.md", "- Check value.txt before saying done.\n")
        let run = await akit("analysis", "control", "run", String(id.prefix(10)), "--patch-file", "CLAUDE.md", "--patch-text", "@rule.md",
                             "--read-only-setup", "--env", "background", "--no-start")
        #expect(run.code == 0 && run.out.hasPrefix("Queued 9 cells: 3 × 1 tasks × baseline · Claude Code · opus · high"), "\(run)")
        #expect(run.out.contains("variant · Claude Code · opus · high · + CLAUDE.md") && run.out.contains("read-only"))
        let again = await akit("analysis", "control", "run", id, "--patch-file", "CLAUDE.md", "--patch-text", "@rule.md",
                               "--read-only-setup", "--env", "background", "--no-start")
        #expect(again.out == "Nothing to queue. Skipped 9 cells already done or queued.", "\(again)")
        let runs = await akit("lab", "list", "--json")
        let specs = try #require(try JSONSerialization.jsonObject(with: Data(runs.out.utf8)) as? [[String: Any]]).compactMap { $0["spec"] as? [String: Any] }
        #expect(specs.count == 9 && specs.allSatisfy { $0["kind"] as? String == "control" && $0["controlTask"] as? String == id })
        let patched = specs.compactMap { ($0["controlSetup"] as? [String: Any])?["patch"] as? [String: Any] }
        #expect(patched.count == 3 && patched.allSatisfy { $0["text"] as? String == "- Check value.txt before saying done.\n" })

        #expect(await akit("analysis", "control", "compare", id).out.contains("No finished cells of \(id) yet. 9 queued or running."))

        #expect(await akit("analysis", "control", "task", "remove", id).out == "Moved control task \(id) to the Trash.")
        #expect(await akit("analysis", "control", "tasks").out == "No control tasks.")
    }
}
