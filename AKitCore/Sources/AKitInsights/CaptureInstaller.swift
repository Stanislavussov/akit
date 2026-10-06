import AKitBrain
import AKitFoundation
import AKitHarnesses
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
/// On a work Mac the plugin commit carries the brain's own git identity, unsigned (`BrainGit`).
/// - launchd: an agent that runs `akit sessions import --quiet` hourly (it never commits).
public struct CaptureInstaller {
    public enum Part: String, CaseIterable, Encodable, Sendable {
        case claude, pi, launchd
    }

    public struct Failure: Error, LocalizedError {
        let message: String
        public var errorDescription: String? { message }
    }

    static let pluginVersion = CapturePlugin.version
    static let marketplace = CapturePlugin.marketplace
    static let pluginID = "akit@akit-brain"
    static let marker = CapturePlugin.marker

    static let agentLabel = "dev.ussov.akit.sessions-import"
    static let launchctl = URL(filePath: "/bin/launchctl")

    let env: HarnessEnvironment
    /// nil without a brain: only the Pi and launchd parts (and status) work then.
    let brainRoot: URL?
    var run: CommandRunner
    /// The akit binary running now; the agent's program when ~/.local/bin/akit is missing.
    var akitExecutable: URL?

    public init(env: HarnessEnvironment, brainRoot: URL?, run: CommandRunner? = nil,
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

    public struct Plan: Sendable {
        public struct Write: Sendable {
            public let url: URL
            public let text: String
            public let executable: Bool
            /// What is there now; nil for a new file.
            public let old: String?
            /// Not written by AKit: copied into ~/.akit/backups first.
            public let backup: Bool
        }

        public struct Command: Sendable {
            let executable: URL
            let arguments: [String]
            public var display: String { ([executable.lastPathComponent] + arguments).joined(separator: " ") }
        }

        /// Created before the writes.
        public var folders: [URL] = []
        public var writes: [Write] = []
        /// Brain paths committed after the writes, with this message.
        public var commitPaths: [String] = []
        public var commitMessage = ""
        public var commands: [Command] = []
        /// Moved to the Trash (uninstall).
        public var trash: [URL] = []
        public var notes: [String] = []
        /// Parts that can't be set up as things are (nothing of them is in the plan).
        public var refused: [String] = []

        public var isEmpty: Bool { writes.isEmpty && commitPaths.isEmpty && commands.isEmpty && trash.isEmpty }

        /// Every folder, write (with its diff), commit, command and note, one per line, as
        /// `akit insights install` prints it and the app's Install Capture… sheet shows it.
        public var text: String {
            var lines = folders.map { "FOLDER \($0.path)" }
            for write in writes {
                if write.backup { lines.append("BACK UP \(write.url.path) (not written by AKit) into ~/.akit/backups") }
                lines.append("\(write.old == nil ? "NEW" : "CHANGED") \(write.url.path)\(write.executable ? " (executable)" : "")")
                if write.old != nil { lines += TextDiff.unified(TextDiff.lines(from: write.old ?? "", to: write.text)) }
            }
            if !commitPaths.isEmpty { lines.append("COMMIT in the brain: \(commitMessage) (\(commitPaths.joined(separator: ", ")))") }
            lines += trash.map { "TRASH \($0.path)" }
            lines += commands.map { "RUN \($0.display)" }
            lines += notes.map { "note: \($0)" }
            lines += refused.map { "REFUSED: \($0)" }
            if isEmpty { lines.append("Nothing to do.") }
            return lines.joined(separator: "\n")
        }
    }

    // MARK: - Files

    var piExtension: URL { HarnessCatalog.configRoot(of: .pi, in: env)!.appending(path: "extensions/akit-record.ts") }

    /// The plugin, by path inside the brain; `true` = executable.
    static let pluginFiles = CapturePlugin.files

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
    public func installPlan(only: Part? = nil) async -> Plan {
        await installPlan(parts: only.map { [$0] } ?? Part.allCases)
    }

    /// Every write and command `install` would do for these parts.
    public func installPlan(parts: [Part]) async -> Plan {
        var plan = Plan()
        if parts.contains(.claude) { await planClaude(into: &plan) }
        if parts.contains(.pi) { planPi(into: &plan) }
        if parts.contains(.launchd) { await planLaunchd(into: &plan) }
        return plan
    }

    /// One part's plan, for the app's Install Capture… sheet. Each part is executed on its own,
    /// so what runs is exactly what the sheet showed.
    public struct PartPlan: Sendable, Identifiable {
        public let part: Part
        public let plan: Plan
        /// Checked when the sheet opens: every part but those said no to in `akit setup`.
        public let suggested: Bool
        public var id: Part { part }
    }

    /// Every part's plan, in install order.
    public func partPlans() async -> [PartPlan] {
        let skipped = choice.skipped
        var plans: [PartPlan] = []
        for part in Part.allCases {
            plans.append(PartPlan(part: part, plan: await installPlan(only: part), suggested: !skipped.contains(part)))
        }
        return plans
    }

    /// The parts on this Mac now: the plugin installed in Claude Code, AKit's Pi extension
    /// (current or older), the hourly import's plist.
    public static func installedParts(_ status: Status) -> [Part] {
        Part.allCases.filter { part in
            switch part {
            case .claude: status.claude.installedVersion != nil
            case .pi: status.pi.state == "current" || status.pi.state == "outdated"
            case .launchd: status.launchd.present
            }
        }
    }

    /// Pi is on this Mac: its config folder, or `pi` on the PATH (not started yet).
    public var piFound: Bool {
        FileManager.default.fileExists(atPath: HarnessCatalog.configRoot(of: .pi, in: env)!.path) || env.findExecutable("pi") != nil
    }

    /// The parts a plan writes to or runs commands for.
    public func parts(in plan: Plan) -> [Part] {
        let urls = plan.writes.map(\.url)
        let tools = plan.commands.map { $0.executable.lastPathComponent }
        return Part.allCases.filter { part in
            switch part {
            case .claude: tools.contains("claude") || urls.contains { url in brainRoot.map { url.path.hasPrefix($0.path + "/") } ?? false }
            case .pi: urls.contains(piExtension)
            case .launchd: urls.contains(agentPlist) || tools.contains(Self.launchctl.lastPathComponent)
            }
        }
    }

    private func planClaude(into plan: inout Plan) async {
        guard let brain = brainRoot else {
            plan.notes.append("No brain: the Claude plugin lives in the brain (akit init or akit setup first).")
            return
        }
        // A newer akit on another Mac wrote a newer plugin: it stays, and is what Claude installs.
        let brainVersion = pluginVersion(inBrain: brain)
        let newer = brainVersion.map { $0.compare(Self.pluginVersion, options: .numeric) == .orderedDescending } ?? false
        let version = newer ? brainVersion! : Self.pluginVersion
        if newer {
            plan.notes.append("The brain has the akit plugin \(version), newer than this akit's \(Self.pluginVersion); left as is. Update akit on this Mac.")
        }
        var changed = false
        for file in Self.pluginFiles where !newer {
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
        } else if changed || installed?["version"] as? String != version {
            plan.commands.append(.init(executable: claude, arguments: ["plugin", "update", Self.pluginID]))
        } else {
            plan.notes.append("The akit plugin \(version) is installed in Claude Code.")
        }
    }

    private func planPi(into plan: inout Plan) {
        let root = HarnessCatalog.configRoot(of: .pi, in: env)!
        guard piFound else {
            plan.notes.append("Pi was not found (\(root.path), or pi on the PATH); no extension written.")
            return
        }
        let old = try? String(contentsOf: piExtension, encoding: .utf8)
        guard old != Self.piExtensionText else {
            plan.notes.append("The Pi extension is current.")
            return
        }
        let folder = piExtension.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: folder.path) { plan.folders.append(folder) }
        plan.writes.append(.init(url: piExtension, text: Self.piExtensionText, executable: false, old: old,
                                 backup: old.map { !$0.contains(Self.marker) } ?? false))
    }

    /// The version in the brain's plugin.json; nil without one.
    func pluginVersion(inBrain brain: URL) -> String? {
        guard let data = try? Data(contentsOf: brain.appending(path: "plugins/akit/.claude-plugin/plugin.json")),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return json["version"] as? String
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
    public func execute(_ plan: Plan, trash: (URL) throws -> URL?) async throws(Failure) -> [String] {
        let fm = FileManager.default
        var plan = plan
        var failures: [String] = []
        // Claude installs the plugin from the brain's commit: without it the Claude commands are skipped;
        // the other parts (Pi, launchd) still go ahead.
        var skipClaude = false
        // A work Mac commits only with the brain's own identity: without one, the plugin files aren't even written.
        let work = MachineProfile.load(home: env.homeDirectory).isWork
        if work, let brain = brainRoot, !plan.commitPaths.isEmpty {
            do {
                try await BrainGit.requireOwnIdentity(brain: brain, env: env)
            } catch {
                plan.writes.removeAll { $0.url.path.hasPrefix(brain.path + "/") }
                plan.commitPaths = []
                failures.append("The plugin was not added to the brain from this work Mac: \(error.message) "
                                + "Set the brain's own git name and email, then run akit insights install again.")
                skipClaude = true
            }
        }
        do {
            // Private folders: the index folder (launchd writes its log there), Pi's extensions folder.
            for folder in plan.folders {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
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
            if let git = env.findExecutable("git") {
                for arguments in [["add", "--"] + plan.commitPaths, ["commit", "--quiet", "-m", plan.commitMessage, "--"] + plan.commitPaths] {
                    // Work Mac: as BrainSync and WorkFilter commit, without the identity variables and unsigned.
                    let result = work
                        ? await ProcessRunner.run(git, arguments: BrainGit.noSigning + arguments, directory: brain,
                                                  environment: BrainGit.withoutIdentity(env.gitVariables), timeout: 30)
                        : await run(git, arguments, brain, 30)
                    guard let result, result.succeeded else {
                        let output = result.map(\.failureText)
                            ?? "couldn't start git"
                        failures.append("The plugin files are written in the brain, but git \(arguments[0]) failed there (\(output)), so they "
                                        + "are not committed and the plugin was not installed in Claude Code. Fix that, then run akit insights install again.")
                        skipClaude = true
                        break
                    }
                }
            } else {
                failures.append("The plugin files are written in the brain, but git was not found, so they are not committed and the "
                                + "plugin was not installed in Claude Code.")
                skipClaude = true
            }
        }
        for command in plan.commands where !(skipClaude && command.executable.lastPathComponent == "claude") {
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
    public func uninstallPlan() async -> Plan {
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

    public struct Status: Encodable, Sendable {
        public struct Claude: Encodable, Sendable {
            /// Version in the brain's plugin.json; nil without a brain or plugin files.
            public var brainVersion: String?
            /// Version Claude Code on this Mac has installed; nil when not installed.
            public var installedVersion: String?
            public var enabled: Bool?
            public var claudeFound: Bool
            public var akitVersion = CaptureInstaller.pluginVersion
            /// Brain, installed and this akit disagree.
            public var versionMismatch: Bool
        }

        public struct Pi: Encodable, Sendable {
            public let path: String
            /// `missing`, `current`, `outdated` (AKit's, older) or `foreign` (not AKit's).
            public let state: String
            /// Pi is on this Mac (`piFound`).
            public var found: Bool
        }

        public struct Launchd: Encodable, Sendable {
            let plist: String
            public let present: Bool
            public let loaded: Bool
            /// The akit the agent runs.
            public let program: String?
        }

        public var claude: Claude
        public var pi: Pi
        public var launchd: Launchd
        /// Time of the newest spool line.
        public var lastSpoolLine: String?
        /// Time of the last import.
        public var lastImport: String?
        /// The person said no to session capture in `akit setup` (`Choice`).
        public var declined = false
        /// Parts they said no to adding.
        public var skipped: [Part] = []
    }

    public func status() async -> Status {
        let brainVersion = brainRoot.flatMap(pluginVersion(inBrain:))
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
        let choice = choice
        return Status(claude: claudeStatus, pi: .init(path: piExtension.path, state: piState, found: piFound), launchd: launchd,
                      lastSpoolLine: lastSpoolLine().map { $0.formatted(.iso8601) },
                      lastImport: lastImport().map { $0.formatted(.iso8601) },
                      declined: choice.declined, skipped: Part.allCases.filter(choice.skipped.contains))
    }

    /// `ts` of the last line in the newest spool day file.
    private func lastSpoolLine() -> Date? {
        let files = FileWalk.children(of: InsightsPaths(env: env).spool).filter { $0.pathExtension == "jsonl" }
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

// MARK: - The person's choice

extension CaptureInstaller {
    /// What the person answered in `akit setup`, kept in ~/.akit/insights.json so it is asked once:
    /// `"capture": false` = no session capture on this Mac; `"captureSkipped"` = parts they didn't
    /// want added to the ones there. `akit insights install --yes` clears it for what it installs.
    public struct Choice: Equatable {
        public var declined = false
        public var skipped: Set<Part> = []

        public init(declined: Bool = false, skipped: Set<Part> = []) {
            self.declined = declined
            self.skipped = skipped
        }
    }

    public var choice: Choice {
        let settings = InsightsPaths(env: env).readSettings()
        return Choice(declined: settings["capture"] as? Bool == false,
                      skipped: Set((settings["captureSkipped"] as? [String] ?? []).compactMap(Part.init(rawValue:))))
    }

    /// Installing undoes a no given in `akit setup`, for the parts installed. After a no to all
    /// of capture, the parts not installed stay a no; `leftOut` adds parts the person was offered
    /// and didn't check (the app's Install Capture…).
    public func saveInstalled(_ parts: [Part], leftOut: [Part] = []) throws {
        var choice = self.choice
        if choice.declined { choice.skipped.formUnion(Part.allCases) }
        choice.declined = false
        choice.skipped.formUnion(leftOut)
        choice.skipped.subtract(parts)
        try save(choice)
    }

    /// Saves the choice; writes nothing when it is already the saved one.
    public func save(_ choice: Choice) throws {
        guard choice != self.choice else { return }
        try InsightsPaths(env: env).updateSettings { settings in
            settings["capture"] = choice.declined ? false : nil
            settings["captureSkipped"] = choice.skipped.isEmpty ? nil : choice.skipped.map(\.rawValue).sorted()
        }
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
