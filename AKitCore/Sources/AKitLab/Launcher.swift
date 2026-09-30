import AKitFoundation
import Darwin
import Foundation

/// Runs `<akit> lab run <id>` in a folder with a title, in Orca, herdr or the background,
/// and brings its tab forward later. Knows nothing about what the run does.
public enum Launcher {
    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// The environment for a folder: Orca and herdr worktree paths, then the folders Orca
    /// and herdr list, else the background.
    public static func suggested(for folder: URL, env: HarnessEnvironment) async -> LabEnvironment {
        let path = folder.standardizedFileURL.path
        let home = env.homeDirectory.path
        if env.findExecutable("orca") != nil, path.hasPrefix(home + "/orca/workspaces/") { return .orca }
        if env.findExecutable("herdr") != nil, path.hasPrefix(home + "/.herdr/worktrees/") { return .herdr }
        if env.findExecutable("orca") != nil,
           await orcaWorktree(for: folder, known: await orcaWorktrees(env: env), env: env) != nil { return .orca }
        if await herdrWorkspace(for: path, env: env) != nil { return .herdr }
        return .background
    }

    /// Environments whose command is installed on this Mac.
    public static func available(env: HarnessEnvironment) -> [LabEnvironment] {
        LabEnvironment.allCases.filter { environment in
            switch environment {
            case .orca: env.findExecutable("orca") != nil
            case .herdr: env.findExecutable("herdr") != nil
            case .background: true
            }
        }
    }

    /// The shell line a tab runs.
    static func command(for spec: RunSpec) -> String {
        "\(quoted(spec.akit)) lab run \(spec.id)"
    }

    static func quoted(_ text: String) -> String {
        text.allSatisfy { $0.isLetter || $0.isNumber || "/._-~".contains($0) } ? text
            : "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Starts the run's worker; returns what `show` needs.
    public static func launch(_ spec: RunSpec, env: HarnessEnvironment) async throws -> LaunchInfo {
        let title = "Lab: \(spec.title)"
        switch spec.environment {
        case .orca: return try await launchOrca(spec, title: title, env: env)
        case .herdr: return try await launchHerdr(spec, title: title, env: env)
        case .background: return try launchBackground(spec, env: env)
        }
    }

    /// Brings the run's tab forward.
    public static func show(_ launch: LaunchInfo, env: HarnessEnvironment) async throws {
        switch launch.environment {
        case .orca:
            guard let terminal = launch.orcaTerminal else { return }
            _ = try await json("orca", ["terminal", "switch", "--terminal", terminal, "--json"], env: env)
        case .herdr:
            if let workspace = launch.herdrWorkspace { _ = try await json("herdr", ["workspace", "focus", workspace], env: env) }
            if let tab = launch.herdrTab { _ = try await json("herdr", ["tab", "focus", tab], env: env) }
        case .background:
            break
        }
    }

    // MARK: Orca

    private static func launchOrca(_ spec: RunSpec, title: String, env: HarnessEnvironment) async throws -> LaunchInfo {
        let known = await orcaWorktrees(env: env)
        guard let worktree = await orcaWorktree(for: URL(filePath: spec.folder), known: known, env: env) else {
            throw Failure(message: "\(spec.folder) is not in an Orca worktree. Add the repository to Orca, or pick herdr or Background.")
        }
        let object = try await json("orca", ["terminal", "create", "--worktree", "path:\(worktree)", "--title", title,
                                             "--command", command(for: spec), "--json"], env: env)
        guard let terminal = ((object["result"] as? [String: Any])?["terminal"] as? [String: Any])?["handle"] as? String else {
            throw Failure(message: "Orca didn't return a terminal: \(orcaError(object))")
        }
        return LaunchInfo(environment: .orca, orcaTerminal: terminal)
    }

    /// The Orca worktree holding the folder; else the repository's main worktree when Orca
    /// knows it (a worktree created outside Orca, a subfolder of the repository).
    static func orcaWorktree(for folder: URL, known: [String], env: HarnessEnvironment) async -> String? {
        let path = folder.standardizedFileURL.path
        if let worktree = known.filter({ path == $0 || path.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count }) {
            return worktree
        }
        guard let common = await LabGit.output(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: folder, env: env)
        else { return nil }
        let root = URL(filePath: common).deletingLastPathComponent().standardizedFileURL.path
        return known.contains(root) ? root : nil
    }

    static func orcaWorktrees(env: HarnessEnvironment) async -> [String] {
        guard let object = try? await json("orca", ["worktree", "list", "--json"], env: env),
              let worktrees = (object["result"] as? [String: Any])?["worktrees"] as? [[String: Any]] else { return [] }
        return worktrees.compactMap { $0["path"] as? String }.map { URL(filePath: $0).standardizedFileURL.path }
    }

    private static func orcaError(_ object: [String: Any]) -> String {
        let error = object["error"] as? [String: Any]
        return (error?["message"] as? String) ?? "unknown error"
    }

    // MARK: herdr

    private static func launchHerdr(_ spec: RunSpec, title: String, env: HarnessEnvironment) async throws -> LaunchInfo {
        let folder = URL(filePath: spec.folder).standardizedFileURL.path
        var workspace = await herdrWorkspace(for: folder, env: env)
        if workspace == nil {
            let created = try await json("herdr", ["workspace", "create", "--cwd", folder, "--label", title, "--no-focus"], env: env)
            let result = created["result"] as? [String: Any]
            workspace = ((result?["workspace"] as? [String: Any])?["workspace_id"] as? String)
                ?? ((result?["root_pane"] as? [String: Any])?["workspace_id"] as? String)
        }
        guard let workspace else { throw Failure(message: "herdr didn't create a workspace for \(folder).") }
        let object = try await json("herdr", ["tab", "create", "--workspace", workspace, "--cwd", folder,
                                              "--label", title, "--no-focus"], env: env)
        let result = object["result"] as? [String: Any]
        guard let pane = (result?["root_pane"] as? [String: Any])?["pane_id"] as? String,
              let tab = (result?["tab"] as? [String: Any])?["tab_id"] as? String else {
            throw Failure(message: "herdr didn't create a tab.")
        }
        _ = try await run("herdr", ["pane", "run", pane, command(for: spec)], env: env)
        return LaunchInfo(environment: .herdr, herdrWorkspace: workspace, herdrTab: tab, herdrPane: pane)
    }

    /// The herdr workspace whose worktree is `path` (or holds it).
    static func herdrWorkspace(for path: String, env: HarnessEnvironment) async -> String? {
        guard let object = try? await json("herdr", ["workspace", "list"], env: env),
              let list = (object["result"] as? [String: Any])?["workspaces"] as? [[String: Any]] else { return nil }
        let matches = list.compactMap { workspace -> (String, String)? in
            guard let id = workspace["workspace_id"] as? String,
                  let checkout = (workspace["worktree"] as? [String: Any])?["checkout_path"] as? String else { return nil }
            let root = URL(filePath: checkout).standardizedFileURL.path
            return path == root || path.hasPrefix(root + "/") ? (id, root) : nil
        }
        return matches.max { $0.1.count < $1.1.count }?.0
    }

    // MARK: Background

    /// A detached child (its own session), output in `console.log`; it outlives AKit.
    private static func launchBackground(_ spec: RunSpec, env: HarnessEnvironment) throws -> LaunchInfo {
        let log = LabPaths(env: env).run(spec.id).appending(path: "console.log")
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, log.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        posix_spawn_file_actions_addchdir_np(&actions, spec.folder)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT
                                                     | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        let arguments = [spec.akit, "lab", "run", spec.id]
        let variables = env.variables.merging(["PATH": env.pathForChildProcesses]) { $1 }
        let argv = arguments.map { strdup($0) } + [nil]
        let envp = variables.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, spec.akit, &actions, &attributes, argv, envp)
        guard status == 0 else { throw Failure(message: "Couldn't start \(spec.akit): \(String(cString: strerror(status))).") }
        // Reap it when it ends, so it never lingers as a zombie of AKit.
        let child = pid
        Thread.detachNewThread {
            var raw: Int32 = 0
            while waitpid(child, &raw, 0) == -1 && errno == EINTR {}
        }
        return LaunchInfo(environment: .background, pid: child)
    }

    // MARK: Commands

    private static func run(_ tool: String, _ arguments: [String], env: HarnessEnvironment) async throws -> String {
        guard let executable = env.findExecutable(tool) else { throw Failure(message: "\(tool) is not installed.") }
        guard let result = await ProcessRunner.run(executable, arguments: arguments,
                                                   environment: env.variables.merging(["PATH": env.pathForChildProcesses]) { $1 },
                                                   timeout: 30) else {
            throw Failure(message: "Couldn't start \(tool).")
        }
        guard result.succeeded else { throw Failure(message: "\(tool) \(arguments.prefix(2).joined(separator: " ")): \(result.failureText)") }
        return result.output
    }

    /// The command's JSON output (the last line that parses as an object: CLIs may print warnings first).
    private static func json(_ tool: String, _ arguments: [String], env: HarnessEnvironment) async throws -> [String: Any] {
        let output = try await run(tool, arguments, env: env)
        if let object = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any] { return object }
        if let start = output.firstIndex(of: "{"),
           let object = try? JSONSerialization.jsonObject(with: Data(output[start...].utf8)) as? [String: Any] { return object }
        throw Failure(message: "\(tool) printed no JSON: \(output.prefix(200))")
    }
}

/// One run at a time: the next queued run starts when nothing else is running.
public enum LabQueue {
    /// A launched run whose worker hasn't written `state.json` after this long never started.
    static let startGrace: TimeInterval = 120

    /// Starts the oldest queued run if no run is active. Returns it, or nil.
    @discardableResult
    public static func startNext(env: HarnessEnvironment) async throws -> LabRun? {
        let lock = LabPaths(env: env).folder.appending(path: "queue.lock")
        try FileManager.default.createDirectory(at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(lock.path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        // Two starters (the app and a finishing worker) must not both launch.
        guard flock(descriptor, LOCK_EX) == 0 else { return nil }
        defer { flock(descriptor, LOCK_UN) }

        var runs = LabStore.list(env: env)
        let stale = runs.filter { run in
            run.status == .queued && run.launch.map { Date.now.timeIntervalSince($0.launchedAt) >= startGrace } == true
        }
        for run in stale {
            try? LabStore.save(RunState(status: .error, message: "The run never started in its \(run.spec.environment.title) tab."),
                               of: run.id, env: env)
        }
        if !stale.isEmpty { runs = LabStore.list(env: env) }
        let busy = runs.contains { run in
            run.status == .running
                || (run.status == .queued && run.launch.map { Date.now.timeIntervalSince($0.launchedAt) < startGrace } == true)
        }
        guard !busy, let next = runs.filter({ $0.status == .queued && $0.launch == nil }).min(by: { $0.spec.createdAt < $1.spec.createdAt })
        else { return nil }
        do {
            let launch = try await Launcher.launch(next.spec, env: env)
            try LabStore.save(launch, of: next.id, env: env)
        } catch {
            try? LabStore.save(RunState(status: .error, message: error.localizedDescription), of: next.id, env: env)
            throw error
        }
        return LabStore.load(next.id, env: env)
    }
}
