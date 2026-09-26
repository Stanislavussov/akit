import Foundation

/// `akit setup`: the questions a new Mac needs answered, each with a default (Enter), then
/// the work: get or create the brain, optionally give it a private GitHub repo, remember
/// the projects folder, and put the core layer into the home folder. Safe to run again.
public enum Onboarding {
    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Talking to the person. `ask` shows a question and returns the typed line (empty =
    /// the default); nil `ask` = not interactive, every default is taken.
    public struct IO {
        public var ask: ((String) -> String?)?
        public var say: (String) -> Void

        public init(ask: ((String) -> String?)?, say: @escaping (String) -> Void) {
            self.ask = ask
            self.say = say
        }
    }

    /// Where the app keeps the projects folder; `akit` reads the same setting.
    public struct Preferences {
        public var projectsRoot: () -> String?
        public var setProjectsRoot: (String) -> Void

        public init(projectsRoot: @escaping () -> String?, setProjectsRoot: @escaping (String) -> Void) {
            self.projectsRoot = projectsRoot
            self.setProjectsRoot = setProjectsRoot
        }
    }

    public struct Options {
        /// Brain repo to clone when there is none yet (owner/repo, a git URL or a path).
        public var brainRepo: String?
        public var skipHome = false

        public init(brainRepo: String? = nil, skipHome: Bool = false) {
            self.brainRepo = brainRepo
            self.skipHome = skipHome
        }
    }

    public static func run(_ options: Options, root: URL, env: HarnessEnvironment, io: IO, preferences: Preferences,
                           hostName: String, installedTargets: [String],
                           trash: (URL) throws -> URL? = SkillRemover.defaultTrash) async throws(Failure) {
        try await brain(options, root: root, env: env, io: io)
        projectsFolder(io: io, preferences: preferences)
        if options.skipHome {
            io.say("Home folder: skipped. Later: akit apply --home")
        } else {
            try await home(root: root, env: env, io: io, hostName: hostName, installedTargets: installedTargets, trash: trash)
        }
        io.say("""

            Done. Open a project and ask your agent: /akit set up this project
            (or in AKit: Brain → Set Up Project…). Run akit setup again any time.
            """)
    }

    // MARK: - Steps

    /// Uses the brain that is there (bringing in other Macs' changes), clones one, or creates one.
    static func brain(_ options: Options, root: URL, env: HarnessEnvironment, io: IO) async throws(Failure) {
        if FileManager.default.fileExists(atPath: root.path) {
            io.say("Brain: \(root.path)")
            if let status = await BrainSync.status(of: root, env: env, fetch: false), status.hasRemote {
                do {
                    let outcome = try await BrainSync.sync(root, env: env)
                    if outcome.pulled + outcome.pushed > 0 { io.say("  synced: \(outcome.pulled) in, \(outcome.pushed) out") }
                } catch {
                    io.say("  not synced: \(error.message)")
                }
            }
            return
        }

        var repo = options.brainRepo ?? ""
        if repo.isEmpty, let ask = io.ask {
            repo = ask("Do you have a brain repo from another Mac? owner/repo or git URL (Enter: start a new brain):")?
                .trimmingCharacters(in: .whitespaces) ?? ""
        }
        while !repo.isEmpty {
            io.say("Downloading \(repo) into \(root.path)…")
            do {
                try await clone(repo, to: root, env: env)
                io.say("Brain: \(root.path) (from \(repo))")
                return
            } catch {
                io.say("  \(error.message)")
                guard let ask = io.ask else { throw error }
                repo = ask("Try another repo, or Enter to start a new brain:")?.trimmingCharacters(in: .whitespaces) ?? ""
            }
        }

        do {
            try await BrainSetup.create(at: root, env: env)
        } catch {
            throw Failure(message: error.message)
        }
        io.say("Brain: \(root.path) (new: the core layer with the /akit skill)")
        await offerGitHubRepo(root: root, env: env, io: io)
    }

    /// A private GitHub repo for a new brain, when gh is signed in and the person agrees.
    static func offerGitHubRepo(root: URL, env: HarnessEnvironment, io: IO) async {
        let later = "  To use it on other Macs later, push it to a private repo (see the README)."
        guard let ask = io.ask else { return io.say(later) }
        guard let gh = env.findExecutable("gh"), await run(gh, ["auth", "status"], in: root, env: env) != nil else {
            return io.say(later + " With the GitHub CLI signed in (gh auth login), akit setup can do it for you.")
        }
        guard yes(ask("Keep it in a private GitHub repo to use it on your other Macs? [Y/n]"), default: true) else { return io.say(later) }
        let name = nonEmpty(ask("Repo name [brain]:")) ?? "brain"
        guard await run(gh, ["repo", "create", name, "--private", "--source", root.path, "--remote", "origin"], in: root, env: env) != nil else {
            return io.say("  Couldn't create the repo \(name) (does it exist already?).\n" + later)
        }
        guard let git = env.findExecutable("git"), await run(git, ["push", "--quiet", "-u", "origin", "HEAD"], in: root, env: env) != nil else {
            return io.say("  Created \(name), but the push failed. Run: git -C \(root.path) push -u origin HEAD")
        }
        io.say("  Private repo \(name) created. On another Mac, answer \(name) when akit setup asks (with your GitHub name: you/\(name)).")
    }

    static func projectsFolder(io: IO, preferences: Preferences) {
        if let saved = preferences.projectsRoot() {
            return io.say("Projects folder: \(saved)")
        }
        let folder = io.ask.flatMap { nonEmpty($0("Where do you keep your projects? [\(ProjectFinder.defaultRoots[0])]")) }
            ?? ProjectFinder.defaultRoots[0]
        preferences.setProjectsRoot(folder)
        io.say("Projects folder: \(folder)")
    }

    /// The core layer into ~. Skills that are already there and differ are replaced only
    /// after a yes (backed up first).
    static func home(root: URL, env: HarnessEnvironment, io: IO, hostName: String, installedTargets: [String],
                     trash: (URL) throws -> URL?) async throws(Failure) {
        guard let brain = Brain.load(from: root), brain.layers.contains(where: { $0.name == "core" }) else {
            return io.say("Home folder: the brain has no core layer; nothing to put there.")
        }
        let id = ProjectSetup.homeID(hostName: hostName)
        var answers = ProjectSetup.savedAnswers(id: id, brain: root) ?? ProjectAnswers(targets: installedTargets)
        answers.layers = ["core"]
        if answers.targets.isEmpty { answers.targets = ["claude"] }
        let plan = ProjectSetup.plan(project: env.homeDirectory, id: id, answers: answers, brain: brain, forHome: true)
        guard plan.canApply else {
            throw Failure(message: "The core layer can't go into your home folder:\n"
                          + (plan.render.errors + plan.blockers).map { "  \($0)" }.joined(separator: "\n"))
        }
        let theirs = plan.changes.filter { $0.kind == .update && ($0.replacesUnmanaged || $0.editedSinceRender) }
        var skipped = Set(theirs.map(\.path))
        if !theirs.isEmpty {
            let skills = Set(theirs.map { skillName($0.path) ?? $0.path }).sorted()
            io.say("\(skills.count) of the brain's skills are already in your home folder in another version: \(skills.joined(separator: ", ")).")
            if yes(io.ask?("Replace them with the brain's version? The old files are backed up. [y/N]"), default: false) {
                skipped = []
            }
        }
        let changing = plan.changes.filter { $0.kind != .same && !skipped.contains($0.path) }
        guard !changing.isEmpty else {
            return io.say("Home folder: up to date with the core layer (\(answers.targets.joined(separator: ", "))).")
        }
        let outcome: ProjectSetup.Outcome
        do {
            outcome = try await ProjectSetup.apply(plan, excluding: skipped, brain: brain, home: env.homeDirectory, env: env, trash: trash)
        } catch {
            throw Failure(message: error.message)
        }
        let skills = Set(outcome.written.compactMap(skillName)).count
        io.say("Home folder: \(skills) skill\(skills == 1 ? "" : "s") from the core layer for \(answers.targets.joined(separator: ", "))"
               + (outcome.backup.map { " (backup: \($0.path))" } ?? "") + ".")
        if !skipped.isEmpty { io.say("  Kept your own versions; replace them later with: akit apply --home --include-unmanaged") }
    }

    // MARK: - Helpers

    /// Clones a brain: a git URL or path as is; owner/repo with gh when it is signed in
    /// (private repos), else over HTTPS, else SSH. Never waits for a password.
    static func clone(_ repo: String, to root: URL, env: HarnessEnvironment) async throws(Failure) {
        let isURL = repo.contains(":") || repo.hasPrefix("/") || repo.hasPrefix(".") || repo.hasPrefix("~")
        guard isURL || repo.split(separator: "/").count == 2 else {
            throw Failure(message: "“\(repo)” is not owner/repo or a git URL.")
        }
        try? FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        let parent = root.deletingLastPathComponent()
        var attempts: [(URL, [String])] = []
        if let git = env.findExecutable("git") {
            if isURL { attempts.append((git, ["clone", "--quiet", repo.hasPrefix("~") ? env.expand(repo).path : repo, root.path])) }
        }
        if !isURL {
            if let gh = env.findExecutable("gh"), await run(gh, ["auth", "status"], in: parent, env: env) != nil {
                attempts.append((gh, ["repo", "clone", repo, root.path, "--", "--quiet"]))
            }
            if let git = env.findExecutable("git") {
                attempts.append((git, ["clone", "--quiet", "https://github.com/\(repo).git", root.path]))
                attempts.append((git, ["clone", "--quiet", "git@github.com:\(repo).git", root.path]))
            }
        }
        guard !attempts.isEmpty else { throw Failure(message: "git was not found.") }
        for (tool, arguments) in attempts where await run(tool, arguments, in: parent, env: env, timeout: 120) != nil {
            return
        }
        throw Failure(message: "Couldn't download \(repo). Check the name and that you have access (gh auth login, or an SSH key on GitHub).")
    }

    /// Runs a tool without prompts; its output, or nil if it failed.
    static func run(_ tool: URL, _ arguments: [String], in directory: URL, env: HarnessEnvironment,
                    timeout: TimeInterval = 30) async -> String? {
        var environment = env.variables.merging(["PATH": env.pathForChildProcesses, "GIT_TERMINAL_PROMPT": "0", "GH_PROMPT_DISABLED": "1"]) { $1 }
        if environment["GIT_SSH_COMMAND"] == nil, environment["GIT_SSH"] == nil { environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes" }
        guard let result = await ProcessRunner.run(tool, arguments: arguments, directory: directory, environment: environment, timeout: timeout),
              result.succeeded else { return nil }
        return result.output
    }

    /// `.agents/skills/<name>/…` → name.
    static func skillName(_ path: String) -> String? {
        let parts = path.split(separator: "/")
        guard parts.count >= 3, parts[0] == ".agents", parts[1] == "skills" else { return nil }
        return String(parts[2])
    }

    static func yes(_ answer: String?, default value: Bool) -> Bool {
        switch answer?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "y", "yes", "д", "да": true
        case "n", "no", "н", "нет": false
        default: value
        }
    }

    static func nonEmpty(_ answer: String?) -> String? {
        let text = answer?.trimmingCharacters(in: .whitespaces) ?? ""
        return text.isEmpty ? nil : text
    }
}
