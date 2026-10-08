import Foundation
import Testing
import AKitBrain
@testable import AKitFoundation
@testable import AKitCommandLine
@testable import AKitInsights

/// `akit setup` on a new Mac, in a temporary fake home, with scripted answers.
struct OnboardingTests {
    let home: URL
    let fm = FileManager.default
    let commands = FakeCommands()

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-setup-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        // An installed akit (make install-cli) for the hourly import; never run.
        let akit = home.appending(path: ".local/bin/akit")
        try fm.createDirectory(at: akit.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: akit)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: akit.path)
        commands.gitEnvironment = env.variables
    }

    /// Stands in for `launchctl` (and a `claude` that isn't there): records every call; the agent
    /// is loaded once bootstrapped. Nothing runs for real except git.
    final class FakeCommands: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [String] = []
        private var loaded = false
        var gitEnvironment: [String: String] = [:]

        var all: [String] { lock.withLock { calls } }

        var runner: CommandRunner {
            { executable, arguments, directory, timeout in
                if executable.lastPathComponent == "git" {
                    return await ProcessRunner.run(executable, arguments: arguments, directory: directory,
                                                   environment: self.gitEnvironment, timeout: timeout)
                }
                let missing: Bool = self.lock.withLock {
                    self.calls.append(([executable.lastPathComponent] + arguments).joined(separator: " "))
                    if arguments.first == "bootstrap" { self.loaded = true }
                    return arguments.first == "print" && !self.loaded
                }
                return ProcessRunner.Result(exitedNormally: true, status: missing ? 113 : 0, timedOut: false, output: "")
            }
        }
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
                                     trash: trash,
                                     ask: answers == nil ? nil : { question in
                                         session.questions.append(question)
                                         return session.answers.isEmpty ? "" : session.answers.removeFirst()
                                     },
                                     preferences: .init(projectsRoot: { session.projectsRoot }, setProjectsRoot: { session.projectsRoot = $0 }),
                                     runner: commands.runner)
        return (code, out.joined(separator: "\n"), session)
    }

    /// Runs another akit command, without a terminal.
    func akit(_ arguments: String...) async -> (code: Int32, out: String) {
        var out: [String] = []
        let code = await AKitCLI.run(arguments, env: env, cwd: home, out: { out.append($0) }, err: { out.append($0) },
                                     trash: trash, runner: commands.runner)
        return (code, out.joined(separator: "\n"))
    }

    /// The fake Trash: a folder inside the fake home.
    func trash(_ url: URL) throws -> URL? {
        let target = home.appending(path: "Trash/\(UUID().uuidString)")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try fm.moveItem(at: url, to: target.appending(path: url.lastPathComponent))
        return target
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
        #expect(fm.fileExists(atPath: plist.path) && result.out.contains("Session capture: on (hourly import)."), "\(result.out)")

        // Again: nothing to do, nothing asked.
        let again = await setup(answers: [], session: result.session)
        #expect(again.code == 0 && again.session.questions.isEmpty, "\(again.session.questions) \(again.out)")
        #expect(again.out.contains("nothing new") && again.out.contains("Session capture: on."))
    }

    @Test func onAWorkMacTheHomeRecordStaysOffTheBrain() async throws {
        try MachineProfile(kind: .work).save(home: home)
        let result = await setup()
        #expect(result.code == 0, "\(result.out)")
        #expect(read(".agents/skills/akit/SKILL.md") != nil)
        #expect(ProjectRecords.savedAnswers(id: "home/work", in: .local(home: home))?.layers == ["core"])
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
        #expect(result.session.questions.count == 3)  // repo, projects folder, session capture
        #expect(result.session.projectsRoot == "~/Code")
        #expect(await BrainSync.status(of: brain, env: env, fetch: false)?.hasRemote == true)
        #expect(read(".agents/skills/akit/SKILL.md") != nil)
    }

    @Test func aBadRepoIsAskedAgainOrFailsWithoutATerminal() async throws {
        let failed = await setup(["--repo", home.appending(path: "missing.git").path])
        #expect(failed.code == 2 && !fm.fileExists(atPath: brain.path))

        let retried = await setup(answers: [home.appending(path: "missing.git").path, ""])
        #expect(retried.code == 0, "\(retried.out)")
        #expect(retried.session.questions.count == 4)  // repo, another repo, projects folder, session capture
        #expect(Brain.load(from: brain) != nil)
    }

    @Test func theirOwnSkillsAreReplacedOnlyAfterAYes() async throws {
        let mine = ".agents/skills/akit/SKILL.md"
        try fm.createDirectory(at: home.appending(path: ".agents/skills/akit"), withIntermediateDirectories: true)
        try Data("my own\n".utf8).write(to: home.appending(path: mine))

        let kept = await setup(answers: ["", "", "n"])
        #expect(kept.code == 0, "\(kept.out)")
        #expect(kept.session.questions.contains { $0.contains("Replace them") })
        #expect(read(mine) == "my own\n")

        let replaced = await setup(answers: ["y"], session: kept.session)
        #expect(replaced.code == 0 && replaced.out.contains("backup"), "\(replaced.session.questions) \(replaced.out)")
        #expect(read(mine)?.contains("# AKit") == true)
    }

    @Test func theInstructionsBlockIsNamedAndAskedForOrLeftAloneWithoutATerminal() async throws {
        let first = await setup()
        #expect(first.code == 0, "\(first.out)")
        try write(".akit/registry/layers/core/layer.yaml", "name: core\nskills:\n  - name: akit\n    mode: manual\nfiles:\n  - template: AGENTS.md\n    to: AGENTS.md\n")
        try write(".akit/registry/layers/core/templates/AGENTS.md", "Be brief.\n")
        try write(".claude/CLAUDE.md", "# Mine\n")

        let quiet = await setup(session: first.session)
        #expect(quiet.code == 0, "\(quiet.out)")
        #expect(quiet.out.contains("Home folder: left alone without a terminal: ~/.claude/CLAUDE.md (AKit's instructions block)."), "\(quiet.out)")
        #expect(read(".claude/CLAUDE.md") == "# Mine\n")

        let asked = await setup(answers: [], session: first.session)
        #expect(asked.code == 0, "\(asked.out)")
        #expect(asked.session.questions.contains("Add AKit's block (the core layer's AGENTS.md) to ~/.claude/CLAUDE.md? The text around it stays; a backup is kept. [Y/n]"),
                "\(asked.session.questions)")
        #expect(asked.out.contains("AKit's instructions block: ~/.claude/CLAUDE.md."), "\(asked.out)")
        #expect(read(".claude/CLAUDE.md") == "# Mine\n\n<!-- akit:core:start -->\nBe brief.\n<!-- akit:core:end -->\n")
    }

    @Test func skipHomeLeavesTheHomeFolderAlone() async throws {
        try fm.createDirectory(at: home.appending(path: ".pi/agent"), withIntermediateDirectories: true)
        let result = await setup(["--skip-home", "--yes"], answers: ["should not be asked"])
        #expect(result.code == 0 && result.session.questions.isEmpty)
        #expect(!fm.fileExists(atPath: home.appending(path: ".agents").path))
        // Session capture writes into ~ too: skipped as well.
        #expect(!fm.fileExists(atPath: plist.path) && read(piExtension) == nil)
        #expect(!commands.all.contains { $0.hasPrefix("launchctl bootstrap") })
        #expect(result.out.contains("Session capture: skipped. Later: akit insights install --yes"), "\(result.out)")
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

    // MARK: Session capture

    var plist: URL { home.appending(path: "Library/LaunchAgents/dev.ussov.akit.sessions-import.plist") }
    let piExtension = ".pi/agent/extensions/akit-record.ts"
    let captureQuestion = "Record sessions as they start"

    @Test func captureIsOfferedOnceAndInstalled() async throws {
        try fm.createDirectory(at: home.appending(path: ".pi/agent"), withIntermediateDirectories: true)
        let result = await setup(answers: [])
        #expect(result.code == 0, "\(result.out)")
        #expect(result.session.questions.last == "\(captureQuestion) (Pi extension, hourly import)? [Y/n]")
        #expect(read(piExtension) == CaptureInstaller.piExtensionText)
        #expect(fm.fileExists(atPath: plist.path))
        #expect(commands.all.contains("launchctl bootstrap gui/\(getuid()) \(plist.path)"), "\(commands.all)")
        #expect(result.out.contains("Session capture: on (Pi extension, hourly import)."), "\(result.out)")

        let again = await setup(answers: [], session: result.session)
        #expect(!again.session.questions.contains { $0.hasPrefix(captureQuestion) })
        #expect(again.out.contains("Session capture: on.") && !again.out.contains("updated"), "\(again.out)")
    }

    @Test func captureDeclinedWritesNothing() async throws {
        try fm.createDirectory(at: home.appending(path: ".pi/agent"), withIntermediateDirectories: true)
        let result = await setup(answers: ["", "", "n"])  // brain, projects folder, capture
        #expect(result.code == 0, "\(result.out)")
        #expect(result.session.questions.last?.hasPrefix(captureQuestion) == true)
        #expect(read(piExtension) == nil && !fm.fileExists(atPath: plist.path))
        #expect(!commands.all.contains { $0.hasPrefix("launchctl bootstrap") })
        #expect(result.out.contains("Session capture: off."))

        // The no is remembered: not asked again, nothing installed, even with every default taken.
        let rerun = await setup(["--yes"], session: result.session)
        #expect(rerun.code == 0, "\(rerun.out)")
        #expect(rerun.out.contains("Session capture: off (your choice). Later: akit insights install --yes"), "\(rerun.out)")
        #expect(read(piExtension) == nil && !fm.fileExists(atPath: plist.path))
        let asked = await setup(answers: [], session: result.session)
        #expect(!asked.session.questions.contains { $0.hasPrefix(captureQuestion) || $0.hasPrefix(addQuestion) })

        // Installing by hand undoes the no.
        let installed = await akit("insights", "install", "--yes")
        #expect(installed.code == 0, "\(installed.out)")
        #expect(read(piExtension) == CaptureInstaller.piExtensionText && fm.fileExists(atPath: plist.path))
        #expect(InsightsPaths(env: env).readSettings()["capture"] == nil)
        let after = await setup(answers: [], session: result.session)
        #expect(after.out.contains("Session capture: on."), "\(after.out)")

        // Uninstalling is a no: the next setup doesn't put capture back.
        let removed = await akit("insights", "uninstall", "--yes")
        #expect(removed.code == 0, "\(removed.out)")
        #expect(read(piExtension) == nil)
        #expect(InsightsPaths(env: env).readSettings()["capture"] as? Bool == false)
        let kept = await setup(["--yes"], session: result.session)
        #expect(kept.out.contains("Session capture: off (your choice)."), "\(kept.out)")
        #expect(read(piExtension) == nil && !fm.fileExists(atPath: plist.path))
    }

    let addQuestion = "Also record sessions with"

    @Test func outdatedCaptureIsUpdatedWithoutAQuestion() async throws {
        try write(piExtension, "// \(CaptureInstaller.marker)\n// an older one\n")
        let result = await setup(answers: ["", "", "n"])  // brain, projects folder, adding the hourly import
        #expect(result.code == 0, "\(result.out)")
        #expect(!result.session.questions.contains { $0.hasPrefix(captureQuestion) }, "\(result.session.questions)")
        #expect(read(piExtension) == CaptureInstaller.piExtensionText)
        // A part that isn't there is asked for, never added silently.
        #expect(result.session.questions.last == "\(addQuestion) the hourly import? [Y/n]", "\(result.session.questions)")
        #expect(!fm.fileExists(atPath: plist.path) && !commands.all.contains { $0.hasPrefix("launchctl bootstrap") })
        #expect(result.out.contains("Session capture: updated (Pi extension)."), "\(result.out)")

        // That no is remembered too; the Pi extension is still kept current.
        let again = await setup(answers: [], session: result.session)
        #expect(!again.session.questions.contains { $0.hasPrefix(addQuestion) }, "\(again.session.questions)")
        #expect(!fm.fileExists(atPath: plist.path) && again.out.contains("Session capture: on."), "\(again.out)")
    }

    @Test func aPartInstalledByHandIsKeptAndTheOthersAreAskedFor() async throws {
        try fm.createDirectory(at: home.appending(path: ".pi/agent"), withIntermediateDirectories: true)
        let pi = await akit("insights", "install", "--only", "pi", "--yes")
        #expect(pi.code == 0 && read(piExtension) == CaptureInstaller.piExtensionText, "\(pi.out)")

        let result = await setup(answers: [])
        #expect(result.code == 0, "\(result.out)")
        #expect(!result.session.questions.contains { $0.hasPrefix(captureQuestion) }, "\(result.session.questions)")
        #expect(result.session.questions.last == "\(addQuestion) the hourly import? [Y/n]", "\(result.session.questions)")
        #expect(fm.fileExists(atPath: plist.path))
        #expect(result.out.contains("Session capture: updated (hourly import)."), "\(result.out)")
    }

    @Test func aForeignPiExtensionIsLeftAlone() async throws {
        try write(piExtension, "// my own\n")
        let result = await setup(answers: [])
        #expect(result.code == 0, "\(result.out)")
        #expect(result.session.questions.last == "\(captureQuestion) (hourly import)? [Y/n]")
        #expect(read(piExtension) == "// my own\n")
        #expect(!fm.fileExists(atPath: home.appending(path: ".akit/backups").path))
        #expect(fm.fileExists(atPath: plist.path))
        #expect(result.out.contains("not set up: \(home.appending(path: piExtension).path) was not written by AKit; left alone"), "\(result.out)")
    }
}
