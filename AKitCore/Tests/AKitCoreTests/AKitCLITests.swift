import Foundation
import Testing
@testable import AKitCore

/// The `akit` command, run in-process against a temporary fake home.
struct AKitCLITests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-cli-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var env: HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home, variables: [
            "HOME": home.path, "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
            "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
        ], executableSearchPaths: [URL(filePath: "/usr/bin")])
    }

    var project: URL { home.appending(path: "Projects/task") }

    func write(_ path: String, _ text: String = "") throws {
        let url = home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func read(_ path: String) -> String? { try? String(contentsOf: project.appending(path: path), encoding: .utf8) }

    /// Runs `akit` with these arguments from the project folder; returns (exit code, stdout, stderr).
    func akit(_ arguments: String...) async -> (code: Int32, out: String, err: String) {
        var out: [String] = [], err: [String] = []
        let code = await AKitCLI.run(arguments, env: env, cwd: project, projectsRoot: home.appending(path: "Projects"),
                                     installedTargets: ["claude"], out: { out.append($0) }, err: { err.append($0) },
                                     trash: { url in
                                         let target = home.appending(path: "Trash/\(UUID().uuidString)")
                                         try fm.createDirectory(at: target, withIntermediateDirectories: true)
                                         try fm.moveItem(at: url, to: target.appending(path: url.lastPathComponent))
                                         return target
                                     })
        return (code, out.joined(separator: "\n"), err.joined(separator: "\n"))
    }

    func setUp() async throws {
        try await BrainSetup.create(at: Brain.defaultRoot(home: home), env: env)
        try write(".akit/registry/skills/tdd/SKILL.md", "---\nname: tdd\ndescription: Tests first\n---\n")
        try write(".akit/registry/layers/task/layer.yaml", """
            fields:
              - id: company
                required: true
              - id: stack
                type: choice
                options: [node, swift]
              - id: review
                type: bool
            skills: [tdd]
            files:
              - template: agents.md
                to: AGENTS.md
            """)
        try write(".akit/registry/layers/task/templates/agents.md", "# {{company}} in {{stack}}\n")
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
    }

    @Test func checkAndLayers() async throws {
        try await setUp()
        let ok = await akit("check")
        #expect(ok.code == 0 && ok.out.contains("No problems."), "\(ok)")
        try write(".akit/registry/layers/bad/layer.yaml", "skills: [ghost]\n")
        let bad = await akit("check")
        #expect(bad.code == 1 && bad.out.contains("- layers/bad: Skill “ghost” is not in skills/."))

        let layers = await akit("layers", "--json")
        let json = try JSONSerialization.jsonObject(with: Data(layers.out.utf8)) as? [[String: Any]]
        #expect(json?.map { $0["name"] as? String } == ["bad", "core", "task"])
        #expect(await akit("--brain", home.appending(path: "nope").path, "check").code == 2)
    }

    @Test func planThenApplyFromFlags() async throws {
        try await setUp()
        let missing = await akit("plan", "--layers", "task")
        #expect(missing.code == 1 && missing.out.contains("ERROR: “company” (company) is required by task."))
        #expect(await akit("plan", "--layers", "task", "--set", "stack=rust").err.contains("“rust” is not an option of stack"))
        #expect(await akit("plan", "--set", "nope=1").code == 2)

        let plan = await akit("plan", ".", "--layers", "task", "--set", "company=Acme", "--set", "stack=swift")
        #expect(plan.code == 0, "\(plan)")
        #expect(plan.out.contains("NEW AGENTS.md") && plan.out.contains("+ # Acme in swift"))
        #expect(read("AGENTS.md") == nil)  // plan never writes

        let apply = await akit("apply", "--layers", "task", "--set", "company=Acme", "--set", "stack=swift", "--targets", "claude,pi")
        #expect(apply.code == 0, "\(apply)")
        #expect(read("AGENTS.md") == "# Acme in swift\n")
        #expect(read("CLAUDE.md") == "@AGENTS.md\n")

        // Saved answers are the starting point next time.
        let answers = await akit("answers")
        #expect(answers.out.contains("\"company\" : \"Acme\""))
        let again = await akit("plan", "--set", "company=Beta")
        #expect(again.out.contains("CHANGED AGENTS.md") && again.out.contains("+ # Beta in swift"))
    }

    @Test func applySkipsForeignFilesUnlessIncluded() async throws {
        try await setUp()
        try write("Projects/task/CLAUDE.md", "my rules\n")
        let skipped = await akit("apply", "--layers", "task", "--set", "company=A")
        #expect(skipped.code == 0 && skipped.out.contains("Skipped: CLAUDE.md"))
        #expect(read("CLAUDE.md") == "my rules\n")

        let included = await akit("apply", "--include", "CLAUDE.md")
        #expect(included.code == 0, "\(included)")
        #expect(read("CLAUDE.md") == "@AGENTS.md\n")
        #expect(included.out.contains("Backup: "))
    }
}
