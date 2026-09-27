import Foundation

/// Runs an external program (`claude`, `launchctl`, `git`) and returns its result, nil when it
/// couldn't start. Injectable, so tests never run those programs against the real Mac.
public typealias CommandRunner = @Sendable (_ executable: URL, _ arguments: [String], _ directory: URL?,
                                            _ timeout: TimeInterval) async -> ProcessRunner.Result?

/// `akit insights install|status|uninstall`: the pieces that capture sessions before their
/// folders or logs disappear. A plan lists every write and command first; nothing happens
/// until it is executed (`--yes`).
/// - Claude: an `akit` plugin in a local marketplace inside the brain (`plugins/`), committed;
///   Claude itself installs it (`claude plugin marketplace add` + `claude plugin install`).
/// - Pi: an AKit-owned extension file in `~/.pi/agent/extensions/`.
/// - launchd: an agent that runs `akit sessions import --quiet` hourly (it never commits).
struct CaptureInstaller {
    enum Part: String, CaseIterable {
        case claude, pi, launchd
    }

    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Version of the plugin files this akit writes; `insights status` compares it with the
    /// brain's and the installed one.
    static let pluginVersion = "1.0.0"
    static let marketplace = "akit-brain"
    static let pluginID = "akit@akit-brain"
    /// First line of every file AKit owns here; a file without it is someone else's.
    static let marker = "akit-record: written by AKit"

    static let agentLabel = "dev.ussov.akit.sessions-import"
    static let launchctl = URL(filePath: "/bin/launchctl")

    let env: HarnessEnvironment
    /// nil without a brain: only the Pi and launchd parts (and status) work then.
    let brainRoot: URL?
    var run: CommandRunner
    /// The akit binary running now; the agent's program when ~/.local/bin/akit is missing.
    var akitExecutable: URL?

    init(env: HarnessEnvironment, brainRoot: URL?, run: CommandRunner? = nil,
         akitExecutable: URL? = Bundle.main.executableURL?.resolvingSymlinksInPath()) {
        self.env = env
        self.brainRoot = brainRoot
        self.run = run ?? Self.liveRunner(env)
        self.akitExecutable = akitExecutable
    }

    static func liveRunner(_ env: HarnessEnvironment) -> CommandRunner {
        let environment = env.variables.merging(["PATH": env.pathForChildProcesses]) { $1 }
        return { executable, arguments, directory, timeout in
            await ProcessRunner.run(executable, arguments: arguments, directory: directory, environment: environment, timeout: timeout)
        }
    }

    // MARK: - Plan

    struct Plan {
        struct Write {
            let url: URL
            let text: String
            let executable: Bool
            /// What is there now; nil for a new file.
            let old: String?
            /// Not written by AKit: copied into ~/.akit/backups first.
            let backup: Bool
        }

        struct Command {
            let executable: URL
            let arguments: [String]
            var display: String { ([executable.lastPathComponent] + arguments).joined(separator: " ") }
        }

        /// Created before the writes.
        var folders: [URL] = []
        var writes: [Write] = []
        /// Brain paths committed after the writes, with this message.
        var commitPaths: [String] = []
        var commitMessage = ""
        var commands: [Command] = []
        /// Moved to the Trash (uninstall).
        var trash: [URL] = []
        var notes: [String] = []
        /// Parts that can't be set up as things are (nothing of them is in the plan).
        var refused: [String] = []

        var isEmpty: Bool { writes.isEmpty && commitPaths.isEmpty && commands.isEmpty && trash.isEmpty }
    }

    // MARK: - Files

    var piExtension: URL { PiAdapter().configRoot(in: env).appending(path: "extensions/akit-record.ts") }

    /// The plugin, by path inside the brain; `true` = executable.
    static let pluginFiles: [(path: String, text: String, executable: Bool)] = [
        ("plugins/.claude-plugin/marketplace.json", """
            {
              "name": "\(marketplace)",
              "owner": { "name": "AKit" },
              "description": "AKit's own Claude Code plugins, from the brain repo.",
              "plugins": [
                {
                  "name": "akit",
                  "source": "./akit",
                  "description": "Records session starts for akit stats in a local spool on this Mac.",
                  "version": "\(pluginVersion)"
                }
              ]
            }

            """, false),
        ("plugins/akit/.claude-plugin/plugin.json", """
            {
              "name": "akit",
              "version": "\(pluginVersion)",
              "description": "Records session starts for akit stats in a local spool on this Mac. Prints nothing.",
              "author": { "name": "AKit" }
            }

            """, false),
        ("plugins/akit/hooks/hooks.json", """
            {
              "description": "akit: one spool line per session start (akit record-session); no output",
              "hooks": {
                "SessionStart": [
                  {
                    "hooks": [
                      { "type": "command", "command": "\\"${CLAUDE_PLUGIN_ROOT}/hooks/record-session.sh\\"", "timeout": 10 }
                    ]
                  }
                ]
              }
            }

            """, false),
        ("plugins/akit/hooks/record-session.sh", """
            #!/bin/sh
            # \(marker) (akit insights install). Claude Code SessionStart hook: hands the
            # hook input to `akit record-session`, which appends one line to ~/.akit/index/spool.
            # Prints nothing (hook output would reach the agent) and never fails the session.
            if command -v akit >/dev/null 2>&1; then
              AKIT=akit
            elif [ -x "$HOME/.local/bin/akit" ]; then
              AKIT="$HOME/.local/bin/akit"
            else
              exit 0
            fi
            exec "$AKIT" record-session --harness claude >/dev/null 2>&1

            """, true),
    ]

    /// Pi extension: on every session start, `akit record-session --harness pi` detached, with
    /// the session id, folder and log path on stdin. Errors are swallowed; Pi never waits.
    static let piExtensionText = """
        // \(marker) (akit insights install); AKit replaces or removes this file.
        // On session start, hands the session id, folder and log path to `akit record-session`,
        // which appends one line to ~/.akit/index/spool. Never blocks or fails Pi.
        import { spawn } from "node:child_process";
        import { existsSync } from "node:fs";
        import { homedir } from "node:os";
        import { delimiter, join } from "node:path";

        function findAkit(): string | undefined {
          for (const folder of (process.env.PATH ?? "").split(delimiter)) {
            if (folder && existsSync(join(folder, "akit"))) return join(folder, "akit");
          }
          const local = join(homedir(), ".local", "bin", "akit");
          return existsSync(local) ? local : undefined;
        }

        export default function (pi: any) {
          pi.on("session_start", (event: any, ctx: any) => {
            try {
              const akit = findAkit();
              if (!akit) return;
              const sessions = ctx?.sessionManager;
              const input = JSON.stringify({
                session_id: sessions?.getSessionId?.(),
                cwd: sessions?.getCwd?.() ?? ctx?.cwd ?? process.cwd(),
                transcript_path: sessions?.getSessionFile?.(),
                source: event?.reason,
              });
              const child = spawn(akit, ["record-session", "--harness", "pi"], { detached: true, stdio: ["pipe", "ignore", "ignore"] });
              child.on("error", () => {});
              child.stdin?.on("error", () => {});
              child.stdin?.end(input);
              child.unref();
            } catch {
              // Capture is best effort; the session goes on.
            }
          });
        }

        """
}

// MARK: - Install

extension CaptureInstaller {
    /// Every write and command `install` would do, for all parts or one.
    func installPlan(only: Part? = nil) async -> Plan {
        var plan = Plan()
        if only == nil || only == .claude { await planClaude(into: &plan) }
        if only == nil || only == .pi { planPi(into: &plan) }
        if only == nil || only == .launchd { await planLaunchd(into: &plan) }
        return plan
    }

    private func planClaude(into plan: inout Plan) async {
        guard let brain = brainRoot else {
            plan.notes.append("No brain: the Claude plugin lives in the brain (akit init or akit setup first).")
            return
        }
        var changed = false
        for file in Self.pluginFiles {
            let url = brain.appending(path: file.path)
            let old = try? String(contentsOf: url, encoding: .utf8)
            let modeOK = !file.executable || FileManager.default.isExecutableFile(atPath: url.path)
            guard old != file.text || !modeOK else { continue }
            plan.writes.append(.init(url: url, text: file.text, executable: file.executable, old: old, backup: false))
            plan.commitPaths.append(file.path)
            changed = true
        }
        let existed = FileManager.default.fileExists(atPath: brain.appending(path: "plugins/akit").path)
        plan.commitMessage = existed ? "Update the akit Claude plugin" : "Add the akit Claude plugin"
        if !FileManager.default.fileExists(atPath: brain.appending(path: ".git").path) { plan.commitPaths = [] }

        let manual = "claude plugin marketplace add \(brain.appending(path: "plugins").path) && claude plugin install \(Self.pluginID)"
        guard let claude = env.findExecutable("claude") else {
            plan.notes.append("Claude Code was not found. After installing it: \(manual)")
            return
        }
        let help = await run(claude, ["plugin", "--help"], nil, 30)?.output ?? ""
        guard help.contains("marketplace"), help.contains("install") else {
            plan.notes.append("This Claude Code has no `claude plugin marketplace` / `install`. Install the plugin by hand: \(manual)")
            return
        }
        let marketplaces = await jsonArray(claude, ["plugin", "marketplace", "list", "--json"])
        if !marketplaces.contains(where: { $0["name"] as? String == Self.marketplace }) {
            plan.commands.append(.init(executable: claude, arguments: ["plugin", "marketplace", "add", brain.appending(path: "plugins").path]))
        } else if changed {
            plan.commands.append(.init(executable: claude, arguments: ["plugin", "marketplace", "update", Self.marketplace]))
        }
        let installed = await installedPlugin(claude)
        if installed == nil {
            plan.commands.append(.init(executable: claude, arguments: ["plugin", "install", Self.pluginID]))
        } else if changed || installed?["version"] as? String != Self.pluginVersion {
            plan.commands.append(.init(executable: claude, arguments: ["plugin", "update", Self.pluginID]))
        } else {
            plan.notes.append("The akit plugin \(Self.pluginVersion) is installed in Claude Code.")
        }
    }

    private func planPi(into plan: inout Plan) {
        let root = PiAdapter().configRoot(in: env)
        guard FileManager.default.fileExists(atPath: root.path) else {
            plan.notes.append("Pi was not found (\(root.path)); no extension written.")
            return
        }
        let old = try? String(contentsOf: piExtension, encoding: .utf8)
        guard old != Self.piExtensionText else {
            plan.notes.append("The Pi extension is current.")
            return
        }
        plan.writes.append(.init(url: piExtension, text: Self.piExtensionText, executable: false, old: old,
                                 backup: old.map { !$0.contains(Self.marker) } ?? false))
    }

    /// The akit entry of `claude plugin list --json`, nil when not installed (or unreadable).
    func installedPlugin(_ claude: URL) async -> [String: Any]? {
        await jsonArray(claude, ["plugin", "list", "--json"]).first { $0["id"] as? String == Self.pluginID }
    }

    /// A command's JSON array output; empty when it fails or prints anything else.
    private func jsonArray(_ executable: URL, _ arguments: [String]) async -> [[String: Any]] {
        guard let result = await run(executable, arguments, nil, 60), result.succeeded,
              let start = result.output.firstIndex(where: { $0 == "[" }) else { return [] }
        let data = Data(result.output[start...].utf8)
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
    }

    /// Writes (backing up files AKit didn't write), commits the brain paths, trashes, then runs
    /// the commands. Returns what failed; an empty list means everything worked.
    func execute(_ plan: Plan, trash: (URL) throws -> URL?) async throws(Failure) -> [String] {
        let fm = FileManager.default
        do {
            for folder in plan.folders { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
            var backup: URL?
            for write in plan.writes where write.backup {
                if backup == nil { backup = try Backup.newFolder(home: env.homeDirectory) }
                try Backup.copy(write.url, into: backup!, home: env.homeDirectory)
            }
            for write in plan.writes {
                try fm.createDirectory(at: write.url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(write.text.utf8).write(to: write.url, options: .atomic)
                try fm.setAttributes([.posixPermissions: write.executable ? 0o755 : 0o644], ofItemAtPath: write.url.path)
            }
            for url in plan.trash { _ = try trash(url) }
        } catch {
            throw Failure(message: "Stopped: \(error.localizedDescription)")
        }
        if let brain = brainRoot, !plan.commitPaths.isEmpty {
            guard let git = env.findExecutable("git") else { throw Failure(message: "Written, but git was not found, so nothing was committed.") }
            for arguments in [["add", "--"] + plan.commitPaths, ["commit", "--quiet", "-m", plan.commitMessage, "--"] + plan.commitPaths] {
                guard let result = await run(git, arguments, brain, 30), result.succeeded else {
                    throw Failure(message: "Written, but git \(arguments[0]) failed in the brain; nothing was installed in Claude Code.")
                }
            }
        }
        var failures: [String] = []
        for command in plan.commands {
            let result = await run(command.executable, command.arguments, nil, 120)
            guard let result, result.succeeded else {
                let output = result?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? "couldn't start"
                failures.append("\(command.display) failed: \(output)")
                continue
            }
        }
        return failures
    }
}

// MARK: - Uninstall and status

extension CaptureInstaller {
    /// Uninstalls the plugin from this Mac's Claude Code and trashes the Pi extension (only
    /// AKit's own). The brain's plugin files stay: other Macs use them.
    func uninstallPlan() async -> Plan {
        var plan = Plan()
        if let claude = env.findExecutable("claude") {
            if await installedPlugin(claude) != nil {
                plan.commands.append(.init(executable: claude, arguments: ["plugin", "uninstall", Self.pluginID]))
            } else {
                plan.notes.append("The akit plugin is not installed in Claude Code.")
            }
        }
        if let text = try? String(contentsOf: piExtension, encoding: .utf8) {
            if text.contains(Self.marker) {
                plan.trash.append(piExtension)
            } else {
                plan.notes.append("\(piExtension.path) was not written by AKit; left alone.")
            }
        }
        await planLaunchdRemoval(into: &plan)
        return plan
    }

    struct Status: Encodable {
        struct Claude: Encodable {
            /// Version in the brain's plugin.json; nil without a brain or plugin files.
            var brainVersion: String?
            /// Version Claude Code on this Mac has installed; nil when not installed.
            var installedVersion: String?
            var enabled: Bool?
            var claudeFound: Bool
            var akitVersion = CaptureInstaller.pluginVersion
            /// Brain, installed and this akit disagree.
            var versionMismatch: Bool
        }

        struct Pi: Encodable {
            let path: String
            /// `missing`, `current`, `outdated` (AKit's, older) or `foreign` (not AKit's).
            let state: String
        }

        struct Launchd: Encodable {
            let plist: String
            let present: Bool
            let loaded: Bool
            /// The akit the agent runs.
            let program: String?
        }

        var claude: Claude
        var pi: Pi
        var launchd: Launchd
        /// Time of the newest spool line.
        var lastSpoolLine: String?
        /// Time of the last import.
        var lastImport: String?
    }

    func status() async -> Status {
        var brainVersion: String?
        if let brain = brainRoot,
           let data = try? Data(contentsOf: brain.appending(path: "plugins/akit/.claude-plugin/plugin.json")),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            brainVersion = json["version"] as? String
        }
        let claude = env.findExecutable("claude")
        var installed: [String: Any]?
        if let claude { installed = await installedPlugin(claude) }
        let installedVersion = installed?["version"] as? String
        let versions = [brainVersion, installedVersion].compactMap { $0 }
        let mismatch = versions.contains { $0 != Self.pluginVersion }
        let claudeStatus = Status.Claude(brainVersion: brainVersion, installedVersion: installedVersion,
                                         enabled: installed?["enabled"] as? Bool, claudeFound: claude != nil,
                                         versionMismatch: mismatch)

        let piText = try? String(contentsOf: piExtension, encoding: .utf8)
        let piState = switch piText {
        case nil: "missing"
        case Self.piExtensionText?: "current"
        case let text? where text.contains(Self.marker): "outdated"
        default: "foreign"
        }
        let launchd = Status.Launchd(plist: agentPlist.path, present: FileManager.default.fileExists(atPath: agentPlist.path),
                                     loaded: await agentLoaded(), program: agentPlistProgram())
        return Status(claude: claudeStatus, pi: .init(path: piExtension.path, state: piState), launchd: launchd,
                      lastSpoolLine: lastSpoolLine().map { $0.formatted(.iso8601) },
                      lastImport: lastImport().map { $0.formatted(.iso8601) })
    }

    /// `ts` of the last line in the newest spool day file.
    private func lastSpoolLine() -> Date? {
        let files = SkillScanner.children(of: InsightsPaths(env: env).spool).filter { $0.pathExtension == "jsonl" }
        guard let newest = files.max(by: { $0.lastPathComponent < $1.lastPathComponent }),
              let ms = (JSONLines.tail(of: newest).last?["ts"] as? NSNumber)?.doubleValue else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    /// Never creates the index: status only reads.
    private func lastImport() -> Date? {
        let url = InsightsPaths(env: env).database
        guard FileManager.default.fileExists(atPath: url.path), let database = try? IndexDatabase(url: url),
              let seconds = try? database.value("SELECT MAX(imported_at) FROM sources")?.double else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}

// MARK: - launchd

extension CaptureInstaller {
    var agentPlist: URL { env.homeDirectory.appending(path: "Library/LaunchAgents/\(Self.agentLabel).plist") }
    private var domain: String { "gui/\(getuid())" }

    /// ~/.local/bin/akit (make install-cli) when it exists, else the running binary. A binary in
    /// a build folder is refused: the next build or clean would pull it from under the agent.
    func agentProgram() throws(Failure) -> URL {
        let installed = env.homeDirectory.appending(path: ".local/bin/akit")
        if FileManager.default.isExecutableFile(atPath: installed.path) { return installed }
        guard let running = akitExecutable else { throw Failure(message: "Can't tell where akit is; run make install-cli first.") }
        guard !running.path.contains("/.build/"), !running.path.contains("DerivedData") else {
            throw Failure(message: "\(running.path) is a build folder binary; run make install-cli first (installs ~/.local/bin/akit).")
        }
        return running
    }

    /// The agent: `akit sessions import --quiet` at load and every hour, at low priority, output
    /// into ~/.akit/index/import.log.
    func agentPlistText(program: URL) -> String {
        let log = InsightsPaths(env: env).log.path
        let plist: [String: Any] = [
            "Label": Self.agentLabel,
            "ProgramArguments": [program.path, "sessions", "import", "--quiet"],
            "StartInterval": 3600,
            "RunAtLoad": true,
            "LowPriorityIO": true,
            "Nice": 10,
            "StandardOutPath": log,
            "StandardErrorPath": log,
        ]
        let data = (try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Whether launchd has the agent loaded (`launchctl print`, read-only).
    func agentLoaded() async -> Bool {
        await run(Self.launchctl, ["print", "\(domain)/\(Self.agentLabel)"], nil, 30)?.succeeded == true
    }

    fileprivate func planLaunchd(into plan: inout Plan) async {
        let program: URL
        do {
            program = try agentProgram()
        } catch {
            plan.refused.append("Hourly import: \(error.message)")
            return
        }
        let text = agentPlistText(program: program)
        let old = try? String(contentsOf: agentPlist, encoding: .utf8)
        let loaded = await agentLoaded()
        if old != text {
            plan.folders.append(InsightsPaths(env: env).folder)
            plan.writes.append(.init(url: agentPlist, text: text, executable: false, old: old, backup: false))
            if loaded { plan.commands.append(.init(executable: Self.launchctl, arguments: ["bootout", "\(domain)/\(Self.agentLabel)"])) }
            plan.commands.append(.init(executable: Self.launchctl, arguments: ["bootstrap", domain, agentPlist.path]))
        } else if !loaded {
            plan.commands.append(.init(executable: Self.launchctl, arguments: ["bootstrap", domain, agentPlist.path]))
        } else {
            plan.notes.append("The hourly import is loaded (\(program.path)).")
        }
    }

    /// Unloads the agent and trashes its plist.
    func planLaunchdRemoval(into plan: inout Plan) async {
        if await agentLoaded() {
            plan.commands.append(.init(executable: Self.launchctl, arguments: ["bootout", "\(domain)/\(Self.agentLabel)"]))
        }
        if FileManager.default.fileExists(atPath: agentPlist.path) { plan.trash.append(agentPlist) }
    }

    /// The program the installed plist runs.
    func agentPlistProgram() -> String? {
        guard let data = try? Data(contentsOf: agentPlist),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return nil }
        return (plist["ProgramArguments"] as? [String])?.first
    }
}
