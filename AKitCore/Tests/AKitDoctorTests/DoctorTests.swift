import Foundation
import Testing
import AKitBrain
import AKitFoundation
import AKitProjectSetup
@testable import AKitDoctor

/// `akit doctor`'s report, built in a temporary fake home full of fake secrets.
struct DoctorTests {
    let home: URL
    let fm = FileManager.default
    let secrets = ["sk-ant-oat01-doctorsecret123456", "ghp_doctorMCPenvSECRET0123456789abcdef", "header-secret-value-98765",
                   "local-settings-secret-4321", "envVarSecretValue-555666777"]

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-doctor-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var env: HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home, variables: [
            "HOME": home.path, "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
            "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
            "ANTHROPIC_API_KEY": secrets[4],
        ], executableSearchPaths: [URL(filePath: "/usr/bin")])
    }

    var brainRoot: URL { Brain.defaultRoot(home: home) }
    var project: URL { home.appending(path: "Projects/task") }

    func write(_ path: String, _ text: String = "") throws {
        let url = home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @discardableResult
    func git(_ args: String..., in folder: URL? = nil) async throws -> String {
        let result = try #require(await ProcessRunner.run(URL(filePath: "/usr/bin/git"), arguments: args, directory: folder ?? project,
                                                           environment: env.variables, timeout: 20))
        #expect(result.succeeded, "git \(args.joined(separator: " ")): \(result.output)")
        return result.output
    }

    func trash(_ url: URL) throws -> URL? {
        let target = home.appending(path: "Trash/\(UUID().uuidString)-\(url.lastPathComponent)")
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: url, to: target)
        return target
    }

    /// Harness configs holding secrets, a brain, a local-only project with a worktree lacking its links.
    func setUp() async throws {
        try write(".claude/settings.json", "{}")
        try write(".claude/settings.local.json", #"{"env": {"TOKEN": "\#(secrets[3])"}}"#)
        try write(".claude.json", #"{"mcpServers": {"gh": {"command": "gh-mcp", "env": {"GITHUB_TOKEN": "\#(secrets[1])"}, "headers": {"Authorization": "\#(secrets[2])"}}}}"#)
        try write(".pi/agent/auth.json", #"{"anthropic": {"type": "oauth", "access": "\#(secrets[0])"}}"#)
        try write(".pi/agent/settings.json", "{}")

        try await BrainSetup.create(at: brainRoot, env: env)
        try write(".akit/registry/skills/tdd/SKILL.md", "---\nname: tdd\ndescription: Tests first\n---\n")
        try write(".akit/registry/layers/task/layer.yaml", "skills: [tdd]\nfiles:\n  - template: agents.md\n    to: AGENTS.md\n")
        try write(".akit/registry/layers/task/templates/agents.md", "# Task\n")
        let brain = try #require(Brain.load(from: brainRoot))

        try write("Projects/task/README.md", "readme\n")
        try await git("init", "-q", "-b", "main")
        try await git("add", "-A")
        try await git("commit", "-qm", "Start")
        let store = ProjectStore.brain(brainRoot)
        let plan = ProjectSetup.plan(project: project, id: "local/task", answers: ProjectAnswers(layers: ["task"], targets: ["claude"], localOnly: true),
                                     brain: brain, store: store, env: env)
        _ = try await ProjectSetup.apply(plan, brain: brain, home: home, env: env, trash: trash)
        try await git("worktree", "add", "-q", "-b", "x", home.appending(path: "trees/x").path)
        // Set up on another Mac only.
        try ProjectRecords.save(ProjectRecords.Lock(brainCommit: nil, brainDirty: false, files: [:]),
                                answers: ProjectAnswers(layers: ["task"], targets: ["pi"]), id: "github.com/me/elsewhere", in: store)
    }

    @Test func theReportSaysWhatIsWrongAndNeverShowsASecret() async throws {
        try await setUp()
        let report = await Doctor.report(.init(env: env, brainRoot: brainRoot, projectRoots: [home.appending(path: "Projects")]))
        for secret in secrets { #expect(!report.contains(secret), "leaked \(secret)") }
        for section in ["AKit", "This Mac", "Brain", "Tools", "Project folders", "Projects", "Logs"] {
            #expect(report.contains("\n\(section)\n"), "no section \(section)")
        }
        #expect(report.contains("! app: ~/Applications/AKit.app is missing"))
        #expect(report.contains("! command: ~/.local/bin/akit is missing"))
        #expect(report.contains("  personal Mac"))
        #expect(report.contains("  Claude Code: config ~/.claude"))
        #expect(report.contains("PI_CODING_AGENT_DIR: not set"))
        #expect(report.contains("  local/task: ~/Projects/task · local only · exclude block: 4 lines · 1 worktree"), "\(report)")
        #expect(report.contains("! worktree ~/trees/x lacks .agents/skills/tdd, .claude/skills, AGENTS.md, CLAUDE.md; run akit worktrees sync ~/Projects/task."))
        #expect(report.contains("  github.com/me/elsewhere: not on this Mac"))
        #expect(report.contains("  no AKit crash reports"))
    }

    @Test func aMissingBrainAndAMissingProjectsFolderAreProblems() async throws {
        try write("Projects/task/README.md", "readme\n")
        let report = await Doctor.report(.init(env: env, brainRoot: brainRoot, projectRoots: [home.appending(path: "Nowhere")]))
        #expect(report.contains("! no brain at ~/.akit/registry"))
        #expect(report.contains("! ~/Nowhere doesn't exist"))
    }

    @Test func anOutOfDateBlockIsAProblem() async throws {
        try await setUp()
        let exclude = project.appending(path: ".git/info/exclude")
        let text = try String(contentsOf: exclude, encoding: .utf8).replacingOccurrences(of: "/AGENTS.md\n", with: "")
        try Data(text.utf8).write(to: exclude)
        let report = await Doctor.report(.init(env: env, brainRoot: brainRoot, projectRoots: [home.appending(path: "Projects")]))
        #expect(report.contains("! local/task: AKit's block in .git/info/exclude doesn't match the files AKit wrote; run akit apply ~/Projects/task."))
    }

    @Test func aBrokenBlockIsAProblemToFixByHand() async throws {
        try await setUp()
        let exclude = project.appending(path: ".git/info/exclude")
        let text = try String(contentsOf: exclude, encoding: .utf8) + "# >>> akit (local-only files of this project; managed by AKit)\n"
        try Data(text.utf8).write(to: exclude)
        let report = await Doctor.report(.init(env: env, brainRoot: brainRoot, projectRoots: [home.appending(path: "Projects")]))
        #expect(report.contains("  local/task: ~/Projects/task · local only · exclude block: can't be used"), "\(report)")
        #expect(report.contains("has a broken AKit block (a marker is missing or doubled); AKit left it alone. Delete the lines from"))
        #expect(!report.contains("run akit apply"))
    }

    @Test func aRemoteWithCredentialsShowsOnlyItsID() async throws {
        try await setUp()
        try await git("remote", "add", "origin", "https://me:ghp_remoteTOKEN0123456789abcdefXYZ@github.com/me/brain.git?access_token=querySecret777#frag",
                      in: brainRoot)
        let report = await Doctor.report(.init(env: env, brainRoot: brainRoot, projectRoots: [home.appending(path: "Projects")]))
        #expect(report.contains("  git repo; remote: github.com/me/brain\n"), "\(report)")
        for secret in ["remoteTOKEN", "querySecret777", "access_token", "frag"] { #expect(!report.contains(secret), "leaked \(secret)") }
    }
}
