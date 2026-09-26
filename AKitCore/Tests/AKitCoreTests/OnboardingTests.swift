import Foundation
import Testing
@testable import AKitCore

/// `akit setup` on a new Mac, in a temporary fake home, with scripted answers.
struct OnboardingTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-setup-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var env: HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home, variables: [
            "HOME": home.path, "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
            "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
        ], executableSearchPaths: [URL(filePath: "/usr/bin")])
    }

    var brain: URL { Brain.defaultRoot(home: home) }

    final class Session {
        var answers: [String]
        var questions: [String] = []
        var projectsRoot: String?
        init(_ answers: [String]) { self.answers = answers }
    }

    /// Runs `akit setup`; `answers` = nil runs it without a terminal (every default).
    func setup(_ arguments: [String] = [], answers: [String]? = nil, session: Session? = nil) async -> (code: Int32, out: String, session: Session) {
        let session = session ?? Session([])
        session.answers = answers ?? []
        session.questions = []
        var out: [String] = []
        let code = await AKitCLI.run(["setup"] + arguments, env: env, cwd: home, hostName: "TestMac.local", installedTargets: ["claude"],
                                     out: { out.append($0) }, err: { out.append($0) },
                                     trash: { url in
                                         let target = home.appending(path: "Trash/\(UUID().uuidString)")
                                         try fm.createDirectory(at: target, withIntermediateDirectories: true)
                                         try fm.moveItem(at: url, to: target.appending(path: url.lastPathComponent))
                                         return target
                                     },
                                     ask: answers == nil ? nil : { question in
                                         session.questions.append(question)
                                         return session.answers.isEmpty ? "" : session.answers.removeFirst()
                                     },
                                     preferences: .init(projectsRoot: { session.projectsRoot }, setProjectsRoot: { session.projectsRoot = $0 }))
        return (code, out.joined(separator: "\n"), session)
    }

    func read(_ path: String) -> String? { try? String(contentsOf: home.appending(path: path), encoding: .utf8) }

    func write(_ path: String, _ text: String) throws {
        let url = home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func git(_ directory: URL, _ args: String...) async throws {
        let result = try #require(await ProcessRunner.run(URL(filePath: "/usr/bin/git"), arguments: args, directory: directory,
                                                           environment: env.variables, timeout: 10))
        #expect(result.succeeded, "git \(args.joined(separator: " ")): \(result.output)")
    }

    @Test func withoutATerminalEveryDefaultIsTaken() async throws {
        let result = await setup()
        #expect(result.code == 0, "\(result.out)")
        #expect(Brain.load(from: brain)?.skills.map(\.name) == ["akit"])
        #expect(result.session.projectsRoot == "~/Projects")
        #expect(read(".agents/skills/akit/SKILL.md")?.contains("disable-model-invocation: true") == true)
        #expect(result.out.contains("/akit set up this project"))

        // Again: nothing to do, nothing asked.
        let again = await setup(answers: [], session: result.session)
        #expect(again.code == 0 && again.session.questions.isEmpty, "\(again.session.questions) \(again.out)")
        #expect(again.out.contains("nothing new"))
    }

    @Test func onAWorkMacTheHomeRecordStaysOffTheBrain() async throws {
        try MachineProfile(kind: .work).save(home: home)
        let result = await setup()
        #expect(result.code == 0, "\(result.out)")
        #expect(read(".agents/skills/akit/SKILL.md") != nil)
        #expect(ProjectSetup.savedAnswers(id: "home/work", in: .local(home: home))?.layers == ["core"])
        #expect(!fm.fileExists(atPath: brain.appending(path: "projects/home").path))
        let again = await setup(answers: [], session: result.session)
        #expect(again.code == 0 && again.out.contains("nothing new"), "\(again.out)")
    }

    @Test func clonesTheBrainFromAnotherMacAndAsksForTheProjectsFolder() async throws {
        let other = home.appending(path: "other/registry")
        try await BrainSetup.create(at: other, env: env)
        let remote = home.appending(path: "brain.git")
        try await git(home, "clone", "--quiet", "--bare", other.path, remote.path)

        let result = await setup(answers: [remote.path, "~/Code"])
        #expect(result.code == 0, "\(result.out)")
        #expect(result.session.questions.count == 2)
        #expect(result.session.projectsRoot == "~/Code")
        #expect(await BrainSync.status(of: brain, env: env, fetch: false)?.hasRemote == true)
        #expect(read(".agents/skills/akit/SKILL.md") != nil)
    }

    @Test func aBadRepoIsAskedAgainOrFailsWithoutATerminal() async throws {
        let failed = await setup(["--repo", home.appending(path: "missing.git").path])
        #expect(failed.code == 2 && !fm.fileExists(atPath: brain.path))

        let retried = await setup(answers: [home.appending(path: "missing.git").path, ""])
        #expect(retried.code == 0, "\(retried.out)")
        #expect(retried.session.questions.count == 3)  // repo, another repo, projects folder
        #expect(Brain.load(from: brain) != nil)
    }

    @Test func theirOwnSkillsAreReplacedOnlyAfterAYes() async throws {
        let mine = ".agents/skills/akit/SKILL.md"
        try fm.createDirectory(at: home.appending(path: ".agents/skills/akit"), withIntermediateDirectories: true)
        try Data("my own\n".utf8).write(to: home.appending(path: mine))

        let kept = await setup(answers: ["", "", "n"])
        #expect(kept.code == 0, "\(kept.out)")
        #expect(kept.session.questions.last?.contains("Replace them") == true)
        #expect(read(mine) == "my own\n")

        let replaced = await setup(answers: ["y"], session: kept.session)
        #expect(replaced.code == 0 && replaced.out.contains("backup"), "\(replaced.session.questions) \(replaced.out)")
        #expect(read(mine)?.contains("# AKit") == true)
    }

    @Test func skipHomeLeavesTheHomeFolderAlone() async throws {
        let result = await setup(["--skip-home", "--yes"], answers: ["should not be asked"])
        #expect(result.code == 0 && result.session.questions.isEmpty)
        #expect(!fm.fileExists(atPath: home.appending(path: ".agents").path))
    }

    @Test func claudesOwnSkillsFolderIsMovedOnlyAfterAYes() async throws {
        try write(".claude/skills/mine/SKILL.md", "mine\n")
        try write(".claude/skills/akit/SKILL.md", "old akit\n")

        let quiet = await setup()
        #expect(quiet.code == 0, "\(quiet.out)")
        #expect(quiet.out.contains("Home folder: skipped"))
        #expect(read(".claude/skills/mine/SKILL.md") == "mine\n")

        let moved = await setup(answers: ["y"], session: quiet.session)
        #expect(moved.code == 0, "\(moved.out)")
        #expect(try fm.destinationOfSymbolicLink(atPath: home.appending(path: ".claude/skills").path) == "../.agents/skills")
        #expect(read(".agents/skills/mine/SKILL.md") == "mine\n")
        #expect(read(".agents/skills/akit/SKILL.md") == "old akit\n")  // theirs, not replaced without a yes
        let backups = try fm.contentsOfDirectory(atPath: home.appending(path: ".akit/backups").path)
        #expect(backups.contains { read(".akit/backups/\($0)/.claude/skills/akit/SKILL.md") == "old akit\n" })
    }

    @Test func aFolderThatIsNotABrainStopsSetupAndAnEmptyOneIsFilled() async throws {
        try write(".akit/registry/notes.txt", "mine\n")
        let refused = await setup()
        #expect(refused.code == 2 && refused.out.contains("isn't a brain"))
        #expect(read(".akit/registry/notes.txt") == "mine\n")

        try fm.removeItem(at: brain)
        try fm.createDirectory(at: brain, withIntermediateDirectories: true)
        #expect(await setup().code == 0)
        #expect(Brain.load(from: brain)?.skills.map(\.name) == ["akit"])
    }

    @Test func aBareProjectsFolderNameMeansOneInHome() async throws {
        let result = await setup(["--skip-home"], answers: ["", "Code/"])
        #expect(result.session.projectsRoot == "~/Code")
    }

}
