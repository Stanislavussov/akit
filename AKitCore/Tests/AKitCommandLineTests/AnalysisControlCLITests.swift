import Foundation
import Testing
import AKitErrorAnalysis
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

    @Test func layerEvalFromTheCommandLine() async throws {
        _ = try await repository()
        let made = await akit("analysis", "control", "task", "new", "--repo", ".", "--base", "HEAD", "--prompt", "Make value 2",
                              "--tests", #"test "$(cat value.txt)" = 2"#)
        let id = try #require(made.out.split(separator: " ").dropFirst(3).first.map { String($0.dropLast()) }, "\(made)")
        // A brain with base and swiftui (requires base), committed.
        let brain = home.appending(path: "brain")
        try write("brain/layers/base/layer.yaml", "files:\n  - template: base.md\n    to: AGENTS.md\n")
        try write("brain/layers/base/templates/base.md", "- BASE\n")
        try write("brain/layers/swiftui/layer.yaml", "requires: [base]\nfields:\n  - id: ui_check\n    default: make snapshot\n  - id: strict\n    type: bool\nfiles:\n  - template: s.md\n    to: AGENTS.md\n")
        try write("brain/layers/swiftui/templates/s.md", "- LAYER {{ui_check}}\n")
        for args in [["init", "-q", "-b", "main"], ["add", "-A"], ["commit", "-q", "-m", "Brain"]] {
            _ = await ProcessRunner.run(URL(filePath: "/usr/bin/git"), arguments: ["-C", brain.path] + args, environment: env.gitVariables, timeout: 60)
        }

        let asked = await akit("analysis", "control", "run", id, "--layer", "swiftui", "--brain", brain.path, "--model", "sonnet",
                               "--env", "background", "--no-start")
        #expect(asked.code == 0, "\(asked)")
        #expect(asked.out.hasPrefix("Eval swiftui-") && asked.out.contains("without swiftui@") && asked.out.contains("layer swiftui@"))
        #expect(asked.out.contains("· overlay ") && asked.out.contains("Home overlap: none."))
        #expect(asked.out.contains("Up to 6 cells; no estimate yet") && asked.out.hasSuffix("Run it again with --yes to queue them."), "\(asked)")
        #expect((try JSONSerialization.jsonObject(with: Data(await akit("lab", "list", "--json").out.utf8)) as? [Any])?.isEmpty == true)
        #expect(!FileManager.default.fileExists(atPath: home.appending(path: ".akit/lab/evals/layer-evals").path))

        // Refusals.
        let base = ["analysis", "control", "run", id, "--layer", "swiftui", "--brain", brain.path, "--model", "sonnet", "--no-start"]
        func run(_ extra: [String]) async -> (code: Int32, out: String, err: String) {
            var out: [String] = []
            var err: [String] = []
            let code = await AKitCLI.run(base + extra, env: env, cwd: project, projectsRoot: home.appending(path: "Projects"),
                                         out: { out.append($0) }, err: { err.append($0) })
            return (code, out.joined(separator: "\n"), err.joined(separator: "\n"))
        }
        #expect(await run(["--harness", "pi"]).err.contains("Claude Code only"))
        #expect(await run(["--setups", "baseline"]).err.contains("leave out --setups"))
        #expect(await run(["--answer", "nope=1"]).err.contains("no field nope (fields: ui_check, strict)"))
        #expect(await run(["--answer", "strict=maybe"]).err.contains("strict is true or false"))
        #expect(await akit("analysis", "control", "run", id, "--eval", "x", "--model", "sonnet").err.contains("go with --layer"))

        // The project's saved answers (found under the projects root) reach the render; an empty --answer keeps them.
        try write("brain/projects/local/task/answers.json", #"{"layers":["swiftui"],"values":{"ui_check":"make check"},"targets":["claude"]}"#)
        let queued = await run(["--answer", "ui_check=", "--answer", "strict=true", "--read-only-setup", "--env", "background", "--yes"])
        #expect(queued.code == 0 && queued.out.contains("Queued 7 cells of eval swiftui-") && queued.out.contains("+ 1 read-only"), "\(queued)")
        let evals = FileWalk.children(of: home.appending(path: ".akit/lab/evals/layer-evals")).filter { !$0.lastPathComponent.hasPrefix(".") }
        let folder = try #require(evals.first)
        #expect(evals.count == 1 && FileManager.default.fileExists(atPath: folder.appending(path: "manifest.json").path))
        let sections = FileWalk.children(of: folder.appending(path: "overlays")).compactMap {
            try? String(contentsOf: $0.appending(path: "files/AGENTS.md"), encoding: .utf8)
        }
        #expect(sections.sorted() == ["- BASE\n", "- BASE\n\n- LAYER make check\n"], "\(sections)")

        // Continue the eval: its cells are all queued already.
        let again = await run(["--eval", folder.lastPathComponent, "--read-only-setup", "--env", "background", "--yes"])
        #expect(again.out.contains("(continued)") && again.out.hasSuffix("Nothing to queue. Skipped 7 cells already done or queued."), "\(again)")

        // Without a task list it takes the eval's tasks and repeats; another count or list is refused.
        func cont(_ extra: [String]) async -> (code: Int32, out: String, err: String) {
            var out: [String] = []
            var err: [String] = []
            let code = await AKitCLI.run(["analysis", "control", "run", "--layer", "swiftui", "--brain", brain.path, "--model", "sonnet",
                                          "--no-start", "--eval", folder.lastPathComponent, "--env", "background"] + extra,
                                         env: env, cwd: project, projectsRoot: home.appending(path: "Projects"),
                                         out: { out.append($0) }, err: { err.append($0) })
            return (code, out.joined(separator: "\n"), err.joined(separator: "\n"))
        }
        let own = await cont(["--read-only-setup", "--yes"])
        #expect(own.code == 0 && own.out.hasSuffix("Nothing to queue. Skipped 7 cells already done or queued."), "\(own)")
        #expect(await cont(["--repeats", "3"]).code == 0)
        #expect(await cont(["--repeats", "5"]).err.contains("runs 3 repeats; leave out --repeats, or give --repeats 3."))
        _ = await akit("analysis", "control", "task", "new", "--repo", ".", "--base", "HEAD", "--prompt", "Other", "--tests", "true")
        let other = try #require(ControlTasks.list(env: env).first { $0.id != id }?.id)
        #expect(await cont([other]).err.contains("runs its own tasks (\(id))"))
        #expect(await cont([id]).code == 0)
    }

    @Test func commitTasksAndLayerSetsFromTheCommandLine() async throws {
        let head = try await repository()
        let root = try #require(await ProcessRunner.run(URL(filePath: "/usr/bin/git"), arguments: ["-C", project.path, "rev-parse", "--show-toplevel"],
                                                        environment: env.gitVariables, timeout: 60)?.output.trimmingCharacters(in: .whitespacesAndNewlines))
        // The commit's replay task is cached: nothing is built.
        let base = String(repeating: "b", count: 40)
        try write(".akit/lab/tasks/\(head).json", """
            {"schema": 1, "repo": "\(root)", "commit": "\(head)", "base": "\(base)", "subject": "Make value 2",
             "prompt": "Make value 2\\n\\nImplement this.", "package": "", "testFiles": ["Tests/ValueTests.swift"],
             "failToPass": [{"suite": "ValueTests", "name": "two"}], "passToPass": [],
             "validatedAt": "2026-10-08T10:00:00Z", "notes": []}
            """)
        let made = await akit("analysis", "control", "task", "new", "--commit", head, "--layer-set", "swiftui")
        #expect(made.code == 0 && made.out.contains("Saved control task make-value-2-") && made.out.contains("hidden tests of \(head.prefix(7))")
                && made.out.hasSuffix("Added to the swiftui set (1 task)."), "\(made)")
        let id = try #require(ControlTasks.list(env: env).first?.id)
        #expect(await akit("analysis", "control", "tasks").out.contains("from commit \(head.prefix(7))"))
        // The same commit again is the same task.
        let again = await akit("analysis", "control", "task", "new", "--commit", head)
        #expect(again.out.hasPrefix("The commit is already control task \(id)") && ControlTasks.list(env: env).count == 1, "\(again)")
        #expect(await akit("analysis", "control", "task", "new", "--commit", head, "--tests", "true").err.contains("--commit takes"))

        // A reproduction joins the set from task new; another repository's task can't.
        let repro = await akit("analysis", "control", "task", "new", "--repo", ".", "--base", "HEAD", "--prompt", "Other", "--tests", "true",
                               "--layer-set", "swiftui")
        #expect(repro.out.hasSuffix("Added to the swiftui set (2 tasks)."), "\(repro)")
        let other = home.appending(path: "Projects/other")
        try write("Projects/other/a.txt", "a\n")
        for args in [["init", "-q", "-b", "master"], ["add", "-A"], ["commit", "-q", "-m", "Start"]] {
            _ = await ProcessRunner.run(URL(filePath: "/usr/bin/git"), arguments: ["-C", other.path] + args, environment: env.gitVariables, timeout: 60)
        }
        let foreign = await akit("analysis", "control", "task", "new", "--repo", other.path, "--base", "HEAD", "--prompt", "Foreign",
                                 "--tests", "true", "--layer-set", "swiftui")
        #expect(foreign.code != 0 && foreign.err.contains("can't join the swiftui set") && foreign.err.contains("one repository"), "\(foreign)")

        // Show, remove, add back, answers typed by the layer's fields.
        let brain = home.appending(path: "brain")
        try write("brain/layers/swiftui/layer.yaml", "fields:\n  - id: ui_check\n    default: make snapshot\n  - id: strict\n    type: bool\nfiles:\n  - template: s.md\n    to: AGENTS.md\n")
        try write("brain/layers/swiftui/templates/s.md", "- LAYER {{ui_check}}\n")
        for args in [["init", "-q", "-b", "main"], ["add", "-A"], ["commit", "-q", "-m", "Brain"]] {
            _ = await ProcessRunner.run(URL(filePath: "/usr/bin/git"), arguments: ["-C", brain.path] + args, environment: env.gitVariables, timeout: 60)
        }
        let answered = await akit("analysis", "control", "layer-set", "swiftui", "answer", "ui_check=make check", "strict=true", "--brain", brain.path)
        #expect(answered.code == 0 && answered.out == "ui_check = make check\nstrict = true", "\(answered)")
        #expect(await akit("analysis", "control", "layer-set", "swiftui", "answer", "strict=maybe", "--brain", brain.path).err.contains("true or false"))
        #expect(await akit("analysis", "control", "layer-set", "swiftui", "answer", "strict=", "--brain", brain.path).out.contains("no answer in the set"))
        let shown = await akit("analysis", "control", "layer-set", "swiftui")
        #expect(shown.out.hasPrefix("swiftui: 2 tasks · repository task") && shown.out.contains("\(id)  \(base.prefix(7))  hidden tests of")
                && shown.out.hasSuffix("Answers:\n  ui_check = make check"), "\(shown)")
        #expect(await akit("analysis", "control", "layer-sets").out == "swiftui  2 tasks  1 answer")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(await akit("analysis", "control", "layer-set", "swiftui", "--json").out.utf8))
                                as? [String: Any])
        #expect(json["schema"] as? Int == 1 && (json["answers"] as? [String: Any])?["ui_check"] as? String == "make check")
        #expect(await akit("analysis", "control", "layer-set", "swiftui", "remove", String(id.prefix(12))).out == "The swiftui set has 1 task.")
        #expect(await akit("analysis", "control", "layer-set", "swiftui", "add", id).out == "The swiftui set has 2 tasks.")
        #expect(await akit("analysis", "control", "layer-set", "swiftui", "remove", "nope").err.contains("Not in the swiftui set: nope."))
        #expect(await akit("analysis", "control", "layer-set", "swiftui", "add", id, "--model", "x").err.contains("leave out --model"))
        #expect(await akit("analysis", "control", "layer-set", "core", "add", id).err.contains("core layer"))

        // A layer eval renders with the set's answers.
        let reproID = try #require(ControlTasks.list(env: env).first { $0.title == "Other" }?.id)
        let eval = await akit("analysis", "control", "run", reproID, "--layer", "swiftui", "--brain", brain.path, "--model", "sonnet",
                              "--env", "background", "--no-start", "--yes")
        #expect(eval.code == 0, "\(eval)")
        let folder = try #require(FileWalk.children(of: home.appending(path: ".akit/lab/evals/layer-evals")).first { !$0.lastPathComponent.hasPrefix(".") })
        let sections = FileWalk.children(of: folder.appending(path: "overlays")).compactMap {
            try? String(contentsOf: $0.appending(path: "files/AGENTS.md"), encoding: .utf8)
        }
        #expect(sections == ["- LAYER make check\n"], "\(sections)")

        #expect(await akit("analysis", "control", "layer-set", "swiftui", "delete").out == "Moved the swiftui set to the Trash. Its tasks stay.")
        #expect(await akit("analysis", "control", "layer-sets").out.hasPrefix("No layer sets."))
        #expect(ControlTasks.list(env: env).count == 3)
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
