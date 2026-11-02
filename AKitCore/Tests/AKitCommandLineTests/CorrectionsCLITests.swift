import Foundation
import Testing
import AKitFoundation
@testable import AKitCorrections
@testable import AKitCommandLine

/// `akit corrections` over a made-up home: the count, the plan of Find Pattern…, and a rule
/// applied to a project's file, judged and removed again. No model is called.
struct CorrectionsCLITests {
    let home: URL
    let fm = FileManager.default
    var project: URL { home.appending(path: "Projects/app") }

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-corrections-\(UUID().uuidString)")
        try fm.createDirectory(at: home.appending(path: "Projects/app/.git"), withIntermediateDirectories: true)
        try Data("[core]\n".utf8).write(to: home.appending(path: "Projects/app/.git/config"))
        try Data("ref: refs/heads/main\n".utf8).write(to: home.appending(path: "Projects/app/.git/HEAD"))
    }

    var env: HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home, variables: ["HOME": home.path],
                           executableSearchPaths: [URL(filePath: "/usr/bin"), URL(filePath: "/bin")])
    }

    func akit(_ arguments: String...) async -> (code: Int32, out: String, err: String) {
        var out: [String] = [], err: [String] = []
        let code = await AKitCLI.run(arguments, env: env, cwd: project, projectsRoot: home.appending(path: "Projects"),
                                     hostName: "TestMac.local", installedTargets: ["claude"], out: { out.append($0) },
                                     err: { err.append($0) }, input: { Data() }, hardwareHash: { "test-hardware" })
        return (code, out.joined(separator: "\n"), err.joined(separator: "\n"))
    }

    /// A Claude Code session in the project: a task, an edit, then the user's correction.
    func writeSession(_ id: String, correction: String, minutesAgo: Double) throws {
        let start = Date().addingTimeInterval(-minutesAgo * 60)
        func time(_ second: Int) -> String { start.addingTimeInterval(Double(second)).formatted(.iso8601) }
        let lines: [[String: Any]] = [
            ["type": "user", "cwd": project.path, "sessionId": id, "uuid": "u0", "timestamp": time(0),
             "message": ["role": "user", "content": "Add a settings screen"]],
            ["type": "assistant", "sessionId": id, "uuid": "a0", "timestamp": time(1),
             "message": ["id": "m0", "model": "claude-opus-5-5", "role": "assistant",
                         "content": [["type": "text", "text": "Done, the screen is added."]], "usage": ["input_tokens": 10, "output_tokens": 5]]],
            ["type": "user", "cwd": project.path, "sessionId": id, "uuid": "u1", "timestamp": time(2),
             "message": ["role": "user", "content": correction]],
        ]
        let url = home.appending(path: ".claude/projects/-app/\(id).jsonl")
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = try lines.map { String(decoding: try JSONSerialization.data(withJSONObject: $0, options: .sortedKeys), as: UTF8.self) }
        try Data((text.joined(separator: "\n") + "\n").utf8).write(to: url)
    }

    @Test func countsPlansAppliesJudgesAndRemoves() async throws {
        try writeSession("c1", correction: "no, run the tests before you say done", minutesAgo: 90)
        try writeSession("c2", correction: "you forgot the tests again", minutesAgo: 30)
        try writeSession("c3", correction: "now add a menu item", minutesAgo: 10)

        let count = await akit("corrections")
        #expect(count.code == 0, "\(count)")
        #expect(count.out.contains("Corrections, last 14 days: 2 of 3 scanned sessions (67%)"), "\(count.out)")
        #expect(count.out.contains("claude: 2 of 3"), "\(count.out)")
        let json = await akit("corrections", "--json")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.out.utf8)) as? [String: Any], "\(json)")
        #expect(object["version"] as? Int == 1 && object["sessionsCorrected"] as? Int == 2)

        let plan = await akit("corrections", "find")
        #expect(plan.code == 0 && plan.out.contains("would send 2 corrections from 2 sessions"), "\(plan)")
        let planJSON = await akit("corrections", "find", "--json")
        let planObject = try #require(try JSONSerialization.jsonObject(with: Data(planJSON.out.utf8)) as? [String: Any], "\(planJSON)")
        #expect(planObject["corrections"] as? Int == 2 && planObject["sessions"] as? Int == 2)
        let shown = await akit("corrections", "find", "--show")
        #expect(shown.out.contains("user: \"no, run the tests before you say done\""), "\(shown.out)")
        #expect(shown.out.contains("[agent] Done, the screen is added."), "\(shown.out)")

        // The model's answer, as Find Pattern… would check and keep it.
        let report = try Corrections.report(env: env)
        let pick = CorrectionExcerpts.pick(report, env: env)
        let ids = pick.excerpts.map(\.id)
        let answer = #"{"patterns":[{"title":"Says done before running the tests","reactionIds":["\#(ids[0])","\#(ids[1])"],"rule":["Before you say a change is done, run the tests.","Name the command you ran."]}]}"#
        let patterns = try Corrections.checked(answer: answer, pick: pick, now: Date())
        let pattern = try #require(patterns.first)
        try CorrectionsState(patterns: patterns).save(env: env)

        let preview = await akit("corrections", "apply", pattern.id, "--to", project.path)
        #expect(preview.code == 0, "\(preview.err)")
        #expect(preview.out.contains("+ ## Rules from corrections") && preview.out.contains("+ - Before you say a change is done, run the tests."), "\(preview.out)")
        #expect(preview.out.contains("Run again with --yes"))
        #expect(!fm.fileExists(atPath: project.appending(path: "CLAUDE.md").path))

        let applied = await akit("corrections", "apply", pattern.id, "--to", project.path, "--yes")
        #expect(applied.code == 0, "\(applied)")
        let file = try String(contentsOf: project.appending(path: "CLAUDE.md"), encoding: .utf8)
        #expect(file == "## Rules from corrections\n\n- Before you say a change is done, run the tests.\n  Name the command you ran.\n")
        let spool = try fm.contentsOfDirectory(atPath: home.appending(path: ".akit/index/spool").path)
        #expect(!spool.isEmpty)

        let twice = await akit("corrections", "apply", pattern.id, "--to", project.path)
        #expect(twice.code != 0 && twice.err.contains("already"), "\(twice)")

        let rules = await akit("corrections", "rules")
        #expect(rules.code == 0 && rules.out.contains("\(pattern.id)  waiting  Says done before running the tests"), "\(rules)")
        #expect(rules.out.contains("No session in the rule's scope since it was applied."), "\(rules.out)")
        // Applied: it isn't shown again.
        #expect(try CorrectionsState.load(env: env).shown.isEmpty)

        let removed = await akit("corrections", "remove", pattern.id, "--yes")
        #expect(removed.code == 0, "\(removed)")
        #expect(try String(contentsOf: project.appending(path: "CLAUDE.md"), encoding: .utf8).isEmpty)
        let after = await akit("corrections", "rules", "--json")
        #expect(after.out.contains("\"status\" : \"removed\""), "\(after.out)")
    }

    @Test func refusesWrongFlagsAndUnknownIds() async throws {
        #expect(await akit("corrections", "rules", "--days", "3").code != 0)
        #expect(await akit("corrections", "find", "--show", "--yes").code != 0)
        #expect(await akit("corrections", "apply").code != 0)
        let unknown = await akit("corrections", "apply", "p-nothing")
        #expect(unknown.code != 0 && unknown.err.contains("No pattern p-nothing"), "\(unknown)")
        let empty = await akit("corrections", "find")
        #expect(empty.code == 0 && empty.out.contains("there is nothing to send"), "\(empty)")
        // Global without a brain.
        try CorrectionsState(patterns: [CorrectionPattern(id: "p-1", title: "t", rule: ["r"], reactions: [], scope: nil, found: Date())]).save(env: env)
        let global = await akit("corrections", "apply", "p-1", "--to", "global")
        #expect(global.code != 0 && global.err.contains("No brain"), "\(global)")
    }
}
