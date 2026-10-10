import Foundation
import Testing
import AKitBrain
import AKitFoundation
@testable import AKitCommandLine

/// `akit move skill`, run in-process against a temporary fake home with Claude Code and Pi
/// folders, a brain and a git project.
struct MoveCLITests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-cli-move-\(UUID().uuidString)")
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
    let skill = "---\nname: deploy\ndescription: Deploys the app\n---\n"

    func write(_ path: String, _ text: String = "") throws {
        let url = home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func akit(_ arguments: String...) async -> (code: Int32, out: String, err: String) {
        var out: [String] = [], err: [String] = []
        let code = await AKitCLI.run(arguments, env: env, cwd: project, projectsRoot: home.appending(path: "Projects"),
                                     hostName: "TestMac.local", installedTargets: ["claude", "pi"], out: { out.append($0) },
                                     err: { err.append($0) },
                                     trash: { url in
                                         let target = home.appending(path: "Trash/\(UUID().uuidString)")
                                         try fm.createDirectory(at: target, withIntermediateDirectories: true)
                                         try fm.moveItem(at: url, to: target.appending(path: url.lastPathComponent))
                                         return target
                                     }, hardwareHash: { "test-hardware" })
        return (code, out.joined(separator: "\n"), err.joined(separator: "\n"))
    }

    @discardableResult
    func git(_ args: String...) async throws -> String {
        let result = try #require(await ProcessRunner.run(URL(filePath: "/usr/bin/git"), arguments: args, directory: project,
                                                           environment: env.variables, timeout: 20))
        #expect(result.succeeded, "git \(args.joined(separator: " ")): \(result.output)")
        return result.output
    }

    func setUp() async throws {
        try await BrainSetup.create(at: Brain.defaultRoot(home: home), env: env)
        try fm.createDirectory(at: home.appending(path: ".pi/agent"), withIntermediateDirectories: true)
        try write(".agents/skills/deploy/SKILL.md", skill)
        try write("Projects/task/README.md", "readme\n")
        try await git("init", "-q", "-b", "main")
        try await git("add", "-A")
        try await git("commit", "-qm", "Start")
    }

    @Test func showsThePlanThenMovesWithYes() async throws {
        try await setUp()
        let plan = await akit("move", "skill", "deploy", "--to", ".")
        #expect(plan.code == 0, "\(plan.err)")
        #expect(plan.out.contains("Move deploy (mode auto, from its calls and current mode) into 1 project; then out of the core layer"), "\(plan.out)")
        #expect(plan.out.contains("Brain: copy ~/.agents/skills/deploy into skills/deploy (in no layer), committed."), "\(plan.out)")
        #expect(plan.out.contains("Project local/task (~/Projects/task): first set up, with only this skill; local only (hidden from git), a new project."),
                "\(plan.out)")
        #expect(plan.out.contains("  + .agents/skills/deploy/SKILL.md"))
        #expect(plan.out.contains("Home folder, to the Trash: ~/.agents/skills/deploy."), "\(plan.out)")
        #expect(plan.out.hasSuffix("Run again with --yes to move it."))
        #expect(fm.fileExists(atPath: home.appending(path: ".agents/skills/deploy").path), "the plan only reads")

        let moved = await akit("move", "skill", "deploy", "--to", ".", "--mode", "manual", "--yes")
        #expect(moved.code == 0, "\(moved.err) \(moved.out)")
        #expect(moved.out.contains("Copied deploy into the brain's library.") && moved.out.contains("To the Trash: ~/.agents/skills/deploy."),
                "\(moved.out)")
        #expect(!fm.fileExists(atPath: home.appending(path: ".agents/skills/deploy").path))
        let copy = try String(contentsOf: project.appending(path: ".agents/skills/deploy/SKILL.md"), encoding: .utf8)
        #expect(copy.contains("disable-model-invocation: true"))
        #expect(try await git("status", "--porcelain", "--untracked-files=all").isEmpty)
        #expect(await akit("answers").out.contains("\"name\" : \"deploy\""))
    }

    @Test func refusesWhatItCantMove() async throws {
        try await setUp()
        #expect(await akit("move", "skill", "deploy").code == 2)
        #expect(await akit("move", "skill", "deploy", "--to", ".", "--mode", "off").err.contains("--mode is auto or manual."))
        #expect(await akit("move", "skill", "deploy", "--to", ".", "--local-only", "maybe").err.contains("--local-only is yes, no or auto."))
        #expect(await akit("move", "skill", "deploy", "--to", ".", "--layers", "x").err.contains("--layers doesn't go with akit move."))
        let missing = await akit("move", "skill", "nothing", "--to", ".")
        #expect(missing.code == 1 && missing.out.contains("blocked: nothing is not a global skill on this Mac"), "\(missing.out)")
        let away = await akit("move", "skill", "deploy", "--to", "github.com/me/away")
        #expect(away.code == 1 && away.out.contains("Project github.com/me/away: skipped: not on this Mac"), "\(away.out)")
    }
}
