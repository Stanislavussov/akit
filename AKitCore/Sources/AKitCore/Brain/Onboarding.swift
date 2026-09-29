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
        /// Relative repo paths are read from here.
        public var cwd: URL?

        public init(brainRepo: String? = nil, skipHome: Bool = false, cwd: URL? = nil) {
            self.brainRepo = brainRepo
            self.skipHome = skipHome
            self.cwd = cwd
        }
    }

    public static func run(_ options: Options, root: URL, env: HarnessEnvironment, io: IO, preferences: Preferences,
                           hostName: String, installedTargets: [String],
                           trash: (URL) throws -> URL? = Trash.move) async throws(Failure) {
        try await brain(options, root: root, env: env, io: io)
        projectsFolder(io: io, preferences: preferences)
        if options.skipHome {
            io.say("Home folder: skipped. Later: akit apply --home")
        } else {
            try await home(root: root, env: env, io: io, hostName: hostName, installedTargets: installedTargets, trash: trash)
        }
        io.say("""

            Done. Open a project and ask your agent: /akit set up this project
            (or in AKit: Brain → Set Up Project…). akit setup is safe to run again.
            """)
    }

    // MARK: - Steps

    /// Uses the brain that is there (bringing in other Macs' changes), clones one, or creates one.
    static func brain(_ options: Options, root: URL, env: HarnessEnvironment, io: IO) async throws(Failure) {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(atPath: root.path))?.filter { $0 != ".DS_Store" }
        if let contents, !contents.isEmpty {
            guard Brain.load(from: root) != nil, fm.fileExists(atPath: root.appending(path: "layers").path) else {
                throw Failure(message: "\(root.path) exists but isn't a brain (no layers/). Move it away, then run akit setup again.")
            }
            io.say("Brain: \(root.path)")
            if let status = await BrainSync.status(of: root, env: env, fetch: false), status.hasRemote {
                io.say("  syncing with its remote…")
                do {
                    let outcome = try await BrainSync.sync(root, env: env)
                    io.say(outcome.pulled + outcome.pushed > 0 ? "  synced: \(outcome.pulled) in, \(outcome.pushed) out" : "  up to date")
                } catch {
                    io.say("  not synced: \(error.message)")
                }
            } else {
                await offerGitHubRepo(root: root, env: env, io: io)
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
                try await clone(repo, to: root, env: env, cwd: options.cwd)
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
        let later = """
              To use it on other Macs, push it to a private repo:
                git -C \(root.path) remote add origin <url> && git -C \(root.path) push -u origin HEAD
            """
        guard let ask = io.ask else { return io.say(later) }
        guard let gh = env.findExecutable("gh"), await run(gh, ["auth", "status"], in: root, env: env) != nil else {
            return io.say(later + "\n  Or sign in to the GitHub CLI (gh auth login) and run akit setup again: it can do it for you.")
        }
        guard yes(ask("Keep it in a private GitHub repo to use it on your other Macs? [Y/n]"), default: true) else { return io.say(later) }
        let name = nonEmpty(ask("Repo name [brain]:")) ?? "brain"
        guard await run(gh, ["repo", "create", name, "--private", "--source", root.path, "--remote", "origin"], in: root, env: env) != nil else {
            return io.say("  Couldn't create the repo \(name) (does it exist already?).\n" + later)
        }
        // gh's own credentials, for an HTTPS remote (without changing the user's git config).
        let push = ["-c", "credential.helper=", "-c", "credential.helper=!\(gh.path) auth git-credential", "push", "--quiet", "-u", "origin", "HEAD"]
        guard let git = env.findExecutable("git"), await run(git, push, in: root, env: env, timeout: 60) != nil else {
            return io.say("  Created \(name), but the push failed. Run: git -C \(root.path) push -u origin HEAD")
        }
        io.say("  Private repo \(name) created. On another Mac, answer \(name) when akit setup asks (with your GitHub name: you/\(name)).")
    }

    static func projectsFolder(io: IO, preferences: Preferences) {
        if let saved = preferences.projectsRoot() {
            return io.say("Projects folder: \(saved)")
        }
        var folder = io.ask.flatMap { nonEmpty($0("Where do you keep your projects? [\(ProjectFinder.defaultRoots[0])]")) }
            ?? ProjectFinder.defaultRoots[0]
        if !folder.hasPrefix("/") && !folder.hasPrefix("~") { folder = "~/" + folder }  // "Code" means ~/Code
        while folder.count > 2, folder.hasSuffix("/") { folder.removeLast() }
        preferences.setProjectsRoot(folder)
        io.say("Projects folder: \(folder)")
    }

    /// The core layer into ~. Skills that are already there and differ are replaced only
    /// after a yes (backed up first). Something in the way is explained, never fatal.
    static func home(root: URL, env: HarnessEnvironment, io: IO, hostName: String, installedTargets: [String],
                     trash: (URL) throws -> URL?) async throws(Failure) {
        guard let brain = Brain.load(from: root), brain.layers.contains(where: { $0.name == "core" }) else {
            return io.say("Home folder: the brain has no core layer; nothing to put there.")
        }
        // A work Mac keeps its home record locally (see ProjectStore), under its machine name.
        let store = ProjectStore.current(brain: root, home: env.homeDirectory)
        let id = ProjectRecords.homeID(hostName: hostName, machineName: MachineProfile.load(home: env.homeDirectory).homeName)
        var answers = ProjectRecords.savedAnswers(id: id, in: store) ?? ProjectAnswers()
        answers.layers = ["core"]
        // Harnesses installed since the last setup join in.
        answers.targets += installedTargets.filter { !answers.targets.contains($0) }
        if answers.targets.isEmpty { answers.targets = ["claude"] }
        var plan = ProjectSetup.plan(project: env.homeDirectory, id: id, answers: answers, brain: brain, store: store, forHome: true)

        // Claude's own skills folder has to become a link to ~/.agents/skills.
        let claudeSkills = env.homeDirectory.appending(path: ".claude/skills")
        if !plan.blockers.isEmpty, isRealFolder(claudeSkills) {
            let items = ((try? FileManager.default.contentsOfDirectory(atPath: claudeSkills.path)) ?? []).filter { $0 != ".DS_Store" }
            io.say("Your Claude skills are in ~/.claude/skills (\(items.count)); every harness reads ~/.agents/skills instead.")
            // Asked only: without a terminal they stay where they are.
            if let ask = io.ask, yes(ask("Move them to ~/.agents/skills and link ~/.claude/skills there? A backup is kept. [Y/n]"), default: true) {
                try moveClaudeSkills(claudeSkills, home: env.homeDirectory, io: io)
                plan = ProjectSetup.plan(project: env.homeDirectory, id: id, answers: answers, brain: brain, store: store, forHome: true)
            }
        }
        guard plan.canApply else {
            io.say("Home folder: skipped, because:\n" + (plan.render.errors + plan.blockers).map { "  \($0)" }.joined(separator: "\n"))
            return io.say("  Fix that, then run akit setup (or akit apply --home) again.")
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
        let keptNote = "  Kept your own versions of \(Set(skipped.map { skillName($0) ?? $0 }).count); replace them later with akit setup."
        let changing = plan.changes.filter { $0.kind != .same && !skipped.contains($0.path) }
        guard !changing.isEmpty else {
            io.say("Home folder: nothing new from the core layer (\(answers.targets.joined(separator: ", "))).")
            if !skipped.isEmpty { io.say(keptNote) }
            return
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
        if !skipped.isEmpty { io.say(keptNote) }
    }

    /// Moves each skill in `~/.claude/skills` into `~/.agents/skills` (a skill already there
    /// wins; the Claude copy stays in the backup), then removes the emptied folder so the
    /// render can put the link in its place.
    static func moveClaudeSkills(_ folder: URL, home: URL, io: IO) throws(Failure) {
        let fm = FileManager.default
        let agents = home.appending(path: ".agents/skills")
        do {
            let backup = try Backup.newFolder(home: home)
            try Backup.copy(folder, into: backup, home: home)
            try fm.createDirectory(at: agents, withIntermediateDirectories: true)
            var kept: [String] = []
            for name in try fm.contentsOfDirectory(atPath: folder.path) where name != ".DS_Store" {
                let target = agents.appending(path: name)
                if fm.fileExists(atPath: target.path) || (try? fm.destinationOfSymbolicLink(atPath: target.path)) != nil {
                    kept.append(name)
                    try fm.removeItem(at: folder.appending(path: name))
                } else {
                    try fm.moveItem(at: folder.appending(path: name), to: target)
                }
            }
            try fm.removeItem(at: folder)
            io.say("  Moved to ~/.agents/skills (backup: \(backup.path))."
                   + (kept.isEmpty ? "" : " Already there, so only in the backup: \(kept.sorted().joined(separator: ", "))."))
        } catch {
            throw Failure(message: "Couldn't move ~/.claude/skills: \(error.localizedDescription). A copy is in ~/.akit/backups.")
        }
    }

    static func isRealFolder(_ url: URL) -> Bool {
        var isFolder: ObjCBool = false
        return (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil
            && FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) && isFolder.boolValue
    }

    // MARK: - Helpers

    /// Clones a brain: a git URL or path as is; owner/repo (or a github.com URL) with gh when
    /// it is signed in (private repos), else over HTTPS, else SSH. Never waits for a password.
    static func clone(_ repo: String, to root: URL, env: HarnessEnvironment, cwd: URL? = nil) async throws(Failure) {
        var repo = repo
        for prefix in ["https://github.com/", "http://github.com/", "github.com/"] where repo.hasPrefix(prefix) {
            repo = String(repo.dropFirst(prefix.count))
            if repo.hasSuffix(".git") { repo = String(repo.dropLast(4)) }
            while repo.hasSuffix("/") { repo.removeLast() }
        }
        let isPath = repo.hasPrefix("/") || repo.hasPrefix(".") || repo.hasPrefix("~")
        let isURL = repo.contains(":") || isPath
        guard isURL || repo.split(separator: "/", omittingEmptySubsequences: false).count == 2 else {
            throw Failure(message: "“\(repo)” is not owner/repo or a git URL.")
        }
        let parent = root.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        var attempts: [(URL, [String])] = []
        if isURL, let git = env.findExecutable("git") {
            let source = repo.hasPrefix("~") ? env.expand(repo).path
                : repo.hasPrefix(".") ? URL(filePath: repo, relativeTo: cwd).standardizedFileURL.path : repo
            attempts.append((git, ["clone", "--quiet", source, root.path]))
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
        if environment["GIT_SSH_COMMAND"] == nil, environment["GIT_SSH"] == nil {
            // First contact with github.com on a new Mac: accept its host key instead of failing.
            environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
        }
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
