import Foundation
import Testing
import AKitBrain
import AKitFoundation
@testable import AKitCommandLine

/// `--local-only`, `akit worktrees` and `akit doctor`, run in-process against a temporary
/// fake home whose project is a git repository.
struct LocalOnlyCLITests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-cli-local-\(UUID().uuidString)")
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
    var exclude: String { (try? String(contentsOf: project.appending(path: ".git/info/exclude"), encoding: .utf8)) ?? "" }

    func write(_ path: String, _ text: String = "") throws {
        let url = home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// Runs `akit` with these arguments from `cwd` (default: the project); returns (exit code, stdout, stderr).
    func akit(_ arguments: String..., cwd: URL? = nil) async -> (code: Int32, out: String, err: String) {
        var out: [String] = [], err: [String] = []
        let code = await AKitCLI.run(arguments, env: env, cwd: cwd ?? project, projectsRoot: home.appending(path: "Projects"),
                                     hostName: "TestMac.local", installedTargets: ["claude"], out: { out.append($0) }, err: { err.append($0) },
                                     trash: { url in
                                         let target = home.appending(path: "Trash/\(UUID().uuidString)")
                                         try fm.createDirectory(at: target, withIntermediateDirectories: true)
                                         try fm.moveItem(at: url, to: target.appending(path: url.lastPathComponent))
                                         return target
                                     }, hardwareHash: { "test-hardware" })
        return (code, out.joined(separator: "\n"), err.joined(separator: "\n"))
    }

    @discardableResult
    func git(_ args: String..., in folder: URL? = nil) async throws -> String {
        let result = try #require(await ProcessRunner.run(URL(filePath: "/usr/bin/git"), arguments: args, directory: folder ?? project,
                                                           environment: env.variables, timeout: 20))
        #expect(result.succeeded, "git \(args.joined(separator: " ")): \(result.output)")
        return result.output
    }

    func setUp() async throws {
        try await BrainSetup.create(at: Brain.defaultRoot(home: home), env: env)
        try write(".akit/registry/skills/tdd/SKILL.md", "---\nname: tdd\ndescription: Tests first\n---\n")
        try write(".akit/registry/layers/task/layer.yaml", "skills: [tdd]\nfiles:\n  - template: agents.md\n    to: AGENTS.md\n")
        try write(".akit/registry/layers/task/templates/agents.md", "# Task\n")
        try write("Projects/task/README.md", "readme\n")
        try await git("init", "-q", "-b", "main")
        try await git("add", "-A")
        try await git("commit", "-qm", "Start")
    }

    @Test func localOnlyIsAnAnswer() async throws {
        try await setUp()
        let plan = await akit("plan", "--layers", "task", "--local-only", "yes")
        #expect(plan.code == 0, "\(plan.err)")
        #expect(plan.out.contains("note: Local only: AKit's block in .git/info/exclude keeps these out of git: /.agents/skills/tdd, /.claude/skills, /AGENTS.md, /CLAUDE.md."),
                "\(plan.out)")
        #expect(await akit("apply", "--layers", "task", "--local-only", "yes").code == 0)
        #expect(exclude.contains("/.agents/skills/tdd\n"))
        #expect(await akit("answers").out.contains("\"localOnly\" : true"))

        // auto: the Mac's role decides (a personal Mac commits), and the answer is dropped.
        #expect(await akit("apply", "--local-only", "auto").code == 0)
        #expect(!exclude.contains("akit"))
        #expect(!(await akit("answers").out.contains("localOnly")))

        let bad = await akit("plan", "--local-only", "maybe")
        #expect(bad.code == 2 && bad.err.contains("--local-only takes yes, no or auto"))
        #expect(await akit("plan", "--home", "--local-only", "yes").code == 2)
    }

    @Test func worktreesShowWhatEachLacksAndSyncFromInsideAWorktree() async throws {
        try await setUp()
        #expect(await akit("apply", "--layers", "task", "--local-only", "yes").code == 0)
        let tree = home.appending(path: "trees/x")
        try await git("worktree", "add", "-q", "-b", "x", tree.path)

        let status = await akit("worktrees")
        #expect(status.code == 0, "\(status.err)")
        #expect(status.out.contains("AKit's files (local only): .agents/skills/tdd, .claude/skills, AGENTS.md, CLAUDE.md"), "\(status.out)")
        #expect(status.out.contains("(x): lacks .agents/skills/tdd, .claude/skills, AGENTS.md, CLAUDE.md"))
        #expect(status.out.contains("Run akit worktrees sync"))

        // From the new worktree, as a tool's hook runs it.
        let sync = await akit("worktrees", "sync", cwd: tree)
        #expect(sync.code == 0, "\(sync.err)")
        #expect(sync.out.hasPrefix("Linked: "))
        #expect(fm.fileExists(atPath: tree.appending(path: ".agents/skills/tdd/SKILL.md").path))
        #expect(await akit("worktrees", "sync", project.path).out == "Nothing to do: every worktree has its links.")
        #expect(await akit("worktrees", cwd: tree).out.contains("(x): 4 linked"))

        let outside = await akit("worktrees", home.path)
        #expect(outside.code == 2 && outside.err.contains("is not in a git repository"))
    }

    @Test func doctorReportsAndAlwaysExitsZero() async throws {
        try await setUp()
        try write(".pi/agent/auth.json", #"{"anthropic": {"access": "sk-ant-oat01-clidoctorsecret987"}}"#)
        let doctor = await akit("doctor")
        #expect(doctor.code == 0, "\(doctor.err)")
        #expect(doctor.out.hasPrefix("AKit doctor"))
        #expect(doctor.out.contains("! app: ~/Applications/AKit.app is missing"))
        #expect(!doctor.out.contains("clidoctorsecret"))
        #expect(await akit("doctor", "extra").code == 2)
        #expect(AKitCLI.usage.contains("akit doctor") && AKitCLI.usage.contains("akit worktrees sync [PROJECT]"))
    }
}
