import Foundation
import Testing
import AKitBrain
import AKitFlows
import AKitFoundation
@testable import AKitCommandLine

/// `akit flow list|show|check|schema` over a made-up home and project.
struct FlowCLITests {
    let home: URL
    let project: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-flow-\(UUID().uuidString)")
        project = home.appending(path: "Projects/app")
        try fm.createDirectory(at: project.appending(path: ".pi/flows"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appending(path: ".pi/agent/flows"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appending(path: ".pi/agent/skills/planning"), withIntermediateDirectories: true)
        try Data("---\nname: planning\ndescription: x\n---\n".utf8).write(to: home.appending(path: ".pi/agent/skills/planning/SKILL.md"))
    }

    var env: HarnessEnvironment { HarnessEnvironment(homeDirectory: home, variables: ["HOME": home.path]) }

    func akit(_ arguments: String...) async -> (code: Int32, out: String, err: String) {
        var out: [String] = [], err: [String] = []
        let code = await AKitCLI.run(arguments, env: env, cwd: project, projectsRoot: home.appending(path: "Projects"),
                                     hostName: "TestMac.local", out: { out.append($0) }, err: { err.append($0) },
                                     hardwareHash: { "test-hardware" })
        return (code, out.joined(separator: "\n"), err.joined(separator: "\n"))
    }

    func write(_ url: URL, _ text: String) throws { try Data(text.utf8).write(to: url) }

    static let good = """
    akit-flow-format: 1
    name: feature
    tools: [read, edit]
    steps:
      - id: implement
        agent: implementer
        model: m/a
        skills: [planning]
        tools: [read, edit]
        checks: [make test]
      - id: review
        agent: reviewer
        model: m/b
        routes:
          "failed:*": implement
          "done:*": end
    """

    @Test func listShowAndCheck() async throws {
        try write(project.appending(path: ".pi/flows/feature.yaml"), Self.good)
        try write(home.appending(path: ".pi/agent/flows/feature.yaml"), "hidden by the project's flow")
        try write(home.appending(path: ".pi/agent/flows/broken.yaml"), "akit-flow-format: 1\nname: broken\n")
        let list = await akit("flow", "list")
        #expect(list.code == 0)
        #expect(list.out.contains("feature (project") && list.out.contains("implement → review"))
        #expect(list.out.contains("broken (home"))
        let show = await akit("flow", "show", "feature", "--json")
        #expect(show.code == 0 && show.out.contains("\"akit-flow-format\" : 1"))
        let check = await akit("flow", "check", "feature")
        #expect(check.code == 0, "\(check.out) \(check.err)")
        #expect(check.out.contains("feature: ok"))
        #expect(check.out.contains("Models not checked"))
    }

    @Test func checkFailsOnAnError() async throws {
        try write(project.appending(path: ".pi/flows/bad.yaml"), Self.good.replacingOccurrences(of: "model: m/b", with: "model: m/a")
            .replacingOccurrences(of: "[make test]", with: "[\"make test && rm -rf /\"]"))
        let check = await akit("flow", "check", "--json")
        #expect(check.code == 1)
        #expect(check.out.contains("reviewer-same-model") && check.out.contains("unsafe-check-command"))
    }

    @Test func runsListsTheProjectsRuns() async throws {
        let empty = await akit("flow", "runs")
        #expect(empty.code == 0 && empty.out.contains("No flow runs"))
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try fm.createDirectory(at: project.appending(path: ".pi/akit-flow/runs"), withIntermediateDirectories: true)
        try fm.copyItem(at: root.appending(path: "fixtures/flow-runs/sample"), to: project.appending(path: ".pi/akit-flow/runs/20261117-1200-0000"))
        let text = await akit("flow", "runs")
        #expect(text.code == 0 && text.out.contains("20261117-1200-0000 feature: done") && text.out.contains("checks #1: failed:checks"))
        #expect(text.out.contains("⚠ check-failed: node check.mjs → 1"))
        let json = await akit("flow", "runs", "--json")
        let value = try JSONSerialization.jsonObject(with: Data(json.out.utf8)) as? [[String: Any]]
        #expect(value?.first?["status"] as? String == "done")
        #expect((value?.first?["attempts"] as? [Any])?.count == 5)
    }

    @Test func schemaPrintsTheJSONSchema() async {
        let schema = await akit("flow", "schema")
        #expect(schema.code == 0 && schema.out.contains("\"$schema\""))
        let unknown = await akit("flow", "show", "nope")
        #expect(unknown.code != 0 && unknown.err.contains("No flow nope"))
    }
}

/// `akit flow export` and the edit commands over a brain made by `akit init` (F23).
struct FlowEditCLITests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-flow-edit-\(UUID().uuidString)")
        try fm.createDirectory(at: home.appending(path: "Projects/app"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appending(path: ".pi/agent/skills/planning"), withIntermediateDirectories: true)
        try Data("---\nname: planning\ndescription: Plans in small steps\n---\nWrite the plan as numbered steps.\n".utf8)
            .write(to: home.appending(path: ".pi/agent/skills/planning/SKILL.md"))
    }

    var env: HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home, variables: [
            "HOME": home.path, "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
            "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
        ], executableSearchPaths: [URL(filePath: "/usr/bin")])
    }
    var file: URL { Brain.defaultRoot(home: home).appending(path: "flows/feature.yaml") }

    func akit(_ arguments: String..., input: String = "") async -> (code: Int32, out: String) {
        var out: [String] = []
        let code = await AKitCLI.run(arguments, env: env, cwd: home.appending(path: "Projects/app"), projectsRoot: home.appending(path: "Projects"),
                                     hostName: "TestMac.local", out: { out.append($0) }, err: { out.append($0) },
                                     input: { Data(input.utf8) }, hardwareHash: { "test-hardware" })
        return (code, out.joined(separator: "\n"))
    }

    func flow() throws -> Flow { try Flow.decode(yaml: String(contentsOf: file, encoding: .utf8)) }

    @Test func editsShowTheDiffAndWriteOnlyWithYes() async throws {
        let made = await akit("init")
        #expect(made.code == 0, "\(made.out)")
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(FlowCLITests.good.utf8).write(to: file)
        let preview = await akit("flow", "set", "feature", "review", "thinking", "high")
        #expect(preview.code == 0 && preview.out.contains("+ ") && preview.out.contains("--yes"), "\(preview)")
        #expect(try flow().step("review")?.thinking == nil)

        #expect(await akit("flow", "set", "feature", "review", "thinking", "high", "--yes").code == 0)
        #expect(try flow().step("review")?.thinking == "high")
        #expect(await akit("flow", "set", "feature", "implement", "prompt", "--file", "-", "--yes", input: "Do it.\nThen hand over.\n").code == 0)
        #expect(try flow().step("implement")?.prompt == "Do it.\nThen hand over.")
        #expect(await akit("flow", "set", "feature", "review", "max-rounds", "5", "--yes").code == 0)
        #expect(await akit("flow", "route", "feature", "review", "blocked:disputed", "implement", "--yes").code == 0)
        let added = await akit("flow", "add-step", "feature", "checker", "--model", "m/a", "--after", "implement", "--yes")
        #expect(added.code == 0, "\(added.out)")
        var edited = try flow()
        #expect(edited.steps.map(\.id) == ["implement", "checks", "review"])
        #expect(edited.step("review")?.maxLoops == 5 && edited.step("review")?.routes["blocked:disputed"] == "implement")

        // A route to a step that isn't there is refused before anything is written.
        let wrong = await akit("flow", "route", "feature", "review", "failed", "nowhere", "--yes")
        #expect(wrong.code != 0 && wrong.out.contains("No step nowhere"))
        // Removing a step drops the routes to it, so it adds no check error.
        #expect(await akit("flow", "remove-step", "feature", "implement", "--yes").code == 0)
        edited = try flow()
        #expect(edited.steps.map(\.id) == ["checks", "review"] && edited.step("review")?.routes["failed:*"] == nil)
        #expect(await akit("flow", "move-step", "feature", "review", "--first", "--yes").code == 0)
        #expect(try flow().steps.map(\.id) == ["review", "checks"])

        let json = await akit("flow", "set", "feature", "review", "gate", "yes", "--json")
        #expect(json.out.contains("\"written\" : false") && json.out.contains("gate"), "\(json)")
    }

    @Test func exportHasEveryStepsContext() async throws {
        let made = await akit("init")
        #expect(made.code == 0, "\(made.out)")
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(FlowCLITests.good.utf8).write(to: file)
        let export = await akit("flow", "export", "feature")
        #expect(export.code == 0)
        for part in ["## What to review", "## Step 1: implement", "## Step 2: review", "### What the agent gets on its first round",
                     "Most recent: the handoff from the step \"implement\" (done)", "Write the plan as numbered steps.", "Used by: implement.",
                     "```yaml", "export const HANDOFF_PARAMETERS", "function prompt(", "export function childArgs", "- failed → implement"] {
            #expect(export.out.contains(part), "missing \(part)")
        }
        let out = home.appending(path: "review.md")
        #expect(await akit("flow", "export", "feature", "--out", out.path).code == 0)
        #expect(fm.fileExists(atPath: out.path))
    }
}
