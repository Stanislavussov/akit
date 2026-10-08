import Foundation
import Testing
import AKitErrorAnalysis
import AKitFoundation
@testable import AKitLab
@testable import AKitCommandLine

/// `akit analysis control compare --eval ID`: a layer eval's verdict from the command line.
/// Cells are queued with --no-start and finished by hand; no agent runs.
extension AKitCLITests {
    /// Every queued control cell finished: `passed` decides its oracle's verdict.
    func finishControlCells(_ passed: (RunSpec) -> Bool) throws {
        for run in LabStore.list(env: env) where run.spec.kind == .control && run.status == .queued {
            try LabStore.save(RunState(status: .finished), of: run.id, env: env)
            let layer = run.spec.controlSetup?.layer != nil
            try LabStore.save(RunResult(control: ControlOutcome(key: run.id, passed: passed(run.spec), oracle: "x", overlay: layer ? [] : nil,
                                                                harnessVersion: "2.1.290")), of: run.id, env: env)
        }
    }

    @Test func layerEvalVerdictFromTheCommandLine() async throws {
        _ = try await repository()
        var ids: [String] = []
        for index in 0..<5 {
            let made = await akit("analysis", "control", "task", "new", "--repo", ".", "--base", "HEAD", "--prompt", "Task \(index)", "--tests", "true")
            ids.append(try #require(made.out.split(separator: " ").dropFirst(3).first.map { String($0.dropLast()) }, "\(made)"))
        }
        let brain = home.appending(path: "brain")
        try write("brain/layers/base/layer.yaml", "files:\n  - template: base.md\n    to: AGENTS.md\n")
        try write("brain/layers/base/templates/base.md", "- BASE\n")
        try write("brain/layers/swiftui/layer.yaml", "requires: [base]\nfiles:\n  - template: s.md\n    to: AGENTS.md\n")
        try write("brain/layers/swiftui/templates/s.md", "- LAYER\n")
        for args in [["init", "-q", "-b", "main"], ["add", "-A"], ["commit", "-q", "-m", "Brain"]] {
            _ = await ProcessRunner.run(URL(filePath: "/usr/bin/git"), arguments: ["-C", brain.path] + args, environment: env.gitVariables, timeout: 60)
        }
        try recordControlCost(0.5, model: "sonnet")
        let queued = await akit("analysis", "control", "run", ids.joined(separator: ","), "--layer", "swiftui", "--brain", brain.path,
                                "--model", "sonnet", "--read-only-setup", "--env", "background", "--no-start", "--yes", "--max-cost", "100")
        #expect(queued.code == 0 && queued.out.contains("Queued 33 cells of eval swiftui-"), "\(queued)")
        let eval = try #require(LayerEvalStore.evals(of: "swiftui", env: env).first?.id)
        let verdictFile = home.appending(path: ".akit/lab/evals/verdicts/swiftui.json")

        // Open cells: the comparison waits, and nothing is saved.
        let waiting = await akit("analysis", "control", "compare", "--eval", eval)
        #expect(waiting.code == 0 && waiting.out.hasSuffix("The verdict waits for 33 cells still queued or running."), "\(waiting)")
        #expect(!FileManager.default.fileExists(atPath: verdictFile.path))
        #expect(await akit("analysis", "control", "compare", ids[0], "--eval", eval).err.contains("leave out the task list"))
        #expect(await akit("analysis", "control", "compare", "--eval", "nope").err.contains("No eval nope"))

        // The layer passes every cell, its required layers alone 1 of 3, the read-only cells none.
        try finishControlCells { spec in
            guard let layer = spec.controlSetup?.layer, spec.controlSetup?.readOnly == false else { return false }
            return layer.role == .layer || spec.repeatIndex == 1
        }
        let done = await akit("analysis", "control", "compare", "--eval", eval)
        #expect(done.code == 0, "\(done)")
        #expect(done.out.contains("layer swiftui vs without swiftui: +67 points per task over 5 tasks; 100% of the bootstrap mass on improvement: helps (offline)."))
        #expect(done.out.contains("swiftui · Claude Code · sonnet · ") && done.out.contains(" · 5 tasks × 3 · eval "))
        #expect(done.out.contains("success: 33% → 100%, helps (offline) (100% of the bootstrap mass on improvement, 0% on worse; needs 95%)"))
        #expect(done.out.contains("read-only sanity: 0 of 3 passed · Claude Code 2.1.290"))
        #expect(done.out.contains("Saved as the last verdict of swiftui for Claude Code · sonnet"), "\(done)")
        let stored = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: verdictFile)) as? [String: Any])
        let verdicts = try #require(stored["verdicts"] as? [[String: Any]])
        #expect(stored["schema"] as? Int == 1 && verdicts.count == 1 && verdicts[0]["verdict"] as? String == "helps-offline")
        #expect(verdicts[0]["evalID"] as? String == eval && verdicts[0]["model"] as? String == "sonnet")

        let json = await akit("analysis", "control", "compare", "--eval", eval, "--json")
        let report = try #require(try JSONSerialization.jsonObject(with: Data(json.out.utf8)) as? [String: Any], "\(json)")
        #expect(report["eval"] as? String == eval && report["open"] as? Int == 0 && report["saved"] as? Bool == false)
        #expect((report["verdict"] as? [String: Any])?["verdict"] as? String == "helps-offline")

        // A patch fix on the same tasks with the same passes still has no conclusion (D4).
        let patch = await akit("analysis", "control", "run", ids.joined(separator: ","), "--patch-file", "CLAUDE.md", "--patch-text", "x",
                               "--model", "sonnet", "--env", "background", "--no-start", "--yes", "--max-cost", "100")
        #expect(patch.code == 0 && patch.out.contains("Queued 30 cells"), "\(patch)")
        try finishControlCells { spec in spec.controlSetup?.patch != nil || spec.repeatIndex == 1 }
        let both = await akit("analysis", "control", "compare", ids.joined(separator: ","))
        let lines = both.out.split(separator: "\n").map(String.init)
        let fixLine = try #require(lines.first { $0.hasPrefix("variant vs baseline:") }, "\(both)")
        #expect(fixLine.hasSuffix("100% of the bootstrap mass on improvement: no conclusion."))
        #expect(lines.contains { $0.hasPrefix("layer swiftui vs without swiftui:") && $0.hasSuffix("helps (offline).") })
    }
}
