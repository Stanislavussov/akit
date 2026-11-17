import Foundation
import Testing
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
