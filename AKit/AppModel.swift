import AKitCore
import Foundation
import Observation

/// App state. Screens only read it and call its methods.
@MainActor
@Observable
final class AppModel {
    private(set) var installations: [HarnessInstallation] = []
    private(set) var versions: [HarnessID: String] = [:]
    private(set) var skills: [Skill] = []
    /// Saved conversations of all installed harnesses, newest first.
    private(set) var sessions: [SessionSummary] = []
    /// Project folders the harnesses know about plus those found in `projectRoots`.
    private(set) var projects: [URL] = []
    /// MCP servers from the config files of all installed harnesses.
    private(set) var mcpServers: [MCPServer] = []
    /// MCP config files that couldn't be read (file: reason).
    private(set) var mcpProblems: [String] = []

    /// Sidebar section shown in the window.
    var section: SidebarSection? = DebugSnapshot.options?.section ?? .overview
    /// A skill the Skills screen should select when it appears (set by "Show in Skills").
    var revealSkill: Skill.ID?
    /// Which skills the Skills screen lists: all, only global ones, or what one project sees.
    var skillsFilter: SkillsFilter = .initial
    /// Skills screen: only skills this harness sees (`HarnessID.rawValue`); nil = every harness.
    var skillsHarness: String? = DebugSnapshot.options?.harness
    /// MCP screen filters, same meaning as the Skills ones.
    var mcpFilter: SkillsFilter = .initial
    var mcpHarness: String? = DebugSnapshot.options?.harness

    /// Opens the Skills screen on the skill in this folder.
    func showSkill(inFolder folder: URL) {
        guard let skill = skill(inFolder: folder) else { return }
        if case .project(let url) = skill.scope {
            skillsFilter = .project(url)
        } else if skillsFilter == .global, skill.scope != .global {
            skillsFilter = .all
        }
        revealSkill = skill.id
        section = .skills
    }
    private(set) var isScanning = false
    private(set) var lastScan: Date?

    /// Folders searched for projects (`~/Projects` by default). Stored per machine,
    /// so work and home can differ.
    var projectRoots: [String] {
        didSet { UserDefaults.standard.set(projectRoots, forKey: Self.projectRootsKey) }
    }

    /// Harnesses described by the user in `~/.akit/harnesses.json`.
    private(set) var customHarnesses: [CustomHarness] = []
    /// Set when `~/.akit/harnesses.json` can't be read; AKit then refuses to overwrite it.
    private(set) var customHarnessError: String?

    var checkedAdapters: [String] { HarnessCatalog.adapters.map(\.displayName) + customHarnesses.map(\.name) }
    var builtInNames: [String] { HarnessCatalog.adapters.map(\.displayName) }

    private static let projectRootsKey = "projectRoots"
    /// A refresh was requested while a scan was running: scan once more when it ends.
    private var rescanRequested = false

    init() {
        projectRoots = UserDefaults.standard.stringArray(forKey: Self.projectRootsKey) ?? ProjectFinder.defaultRoots
    }

    /// Re-detect harnesses, their versions and skills. Files are only read.
    func refresh() async {
        guard !isScanning else {
            rescanRequested = true
            return
        }
        isScanning = true
        repeat {
            rescanRequested = false
            await scan()
        } while rescanRequested
        isScanning = false
    }

    /// Moves a skill to the Trash, then rescans.
    func delete(_ skill: Skill) async throws {
        _ = try await Task.detached {
            // Resolve before trashing: afterwards the path no longer exists.
            let folder = skill.realFolder.resolvingSymlinksInPath()
            try SkillRemover.moveToTrash(skill)
            InstalledSkillLock.forget(folder: folder, in: .current)
        }.value
        await refresh()
    }

    /// The scanned skill that lives in this folder, if any.
    func skill(inFolder folder: URL) -> Skill? {
        let real = folder.resolvingSymlinksInPath().path
        return skills.first { $0.realFolder.path == real }
    }

    /// Built-in and custom adapters, for planning installs.
    var adapters: [any HarnessAdapter] { HarnessCatalog.allAdapters(custom: customHarnesses) }

    /// Where a skill would be copied for these harnesses and scope.
    func installTargets(for harnesses: [HarnessID], scope: InstallScope) -> [InstallTarget] {
        SkillInstaller.targets(for: harnesses, scope: scope, adapters: adapters,
                               installed: installations.map(\.id), in: .current)
    }

    /// Installs a skill from skills.sh, then rescans. Returns the new skill folders.
    func install(_ request: InstallRequest, into targets: [InstallTarget], replace: Bool) async throws -> [URL] {
        let folders = try await Task.detached {
            try SkillInstaller.install(request, into: targets, replace: replace, in: .current)
        }.value
        await refresh()
        return folders
    }

    /// Messages of one session, read in the background.
    func transcript(of session: SessionSummary) async throws -> SessionTranscript {
        guard let adapter = adapter(for: session.harness) else { return SessionTranscript() }
        return try await Self.background { try adapter.transcript(of: session) }
    }

    // MARK: System prompt

    /// Prompts caught from harnesses in this run of AKit, by harness and project.
    private(set) var capturedPrompts: [String: PromptSnapshot] = [:]

    func promptAccess(_ harness: HarnessID) -> SystemPromptAccess {
        adapter(for: harness)?.systemPromptAccess ?? .unavailable
    }

    /// The system prompt saved in this session, if the harness saves it.
    func recordedPrompt(in session: SessionSummary) async throws -> PromptSnapshot? {
        guard let adapter = adapter(for: session.harness) else { return nil }
        return try await Self.background { try adapter.recordedPrompt(in: session) }
    }

    func capturedPrompt(harness: HarnessID, project: URL) -> PromptSnapshot? {
        capturedPrompts[Self.promptKey(harness, project)]
    }

    /// Asks the harness for its current system prompt in `project` (see PiPromptProbe).
    func capturePrompt(harness: HarnessID, project: URL) async throws {
        guard let adapter = adapter(for: harness) else { return }
        guard let prompt = try await adapter.capturePrompt(in: project, env: .current) else {
            throw NSError(domain: "AKit", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "\(adapter.displayName) couldn't be started: its command was not found."])
        }
        capturedPrompts[Self.promptKey(harness, project)] = prompt
    }

    private static func promptKey(_ harness: HarnessID, _ project: URL) -> String {
        "\(harness.rawValue)|\(project.standardizedFileURL.path)"
    }

    /// Runs file reading off the main actor. Cancelling the caller (the view's task) cancels
    /// the work too, so moving through large sessions quickly doesn't pile up parsing.
    private static func background<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: .userInitiated) { try work() }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func adapter(for harness: HarnessID) -> (any HarnessAdapter)? {
        adapters.first { $0.id == harness }
    }

    /// Adds or replaces (same id) a custom harness. The file is re-read right before
    /// saving, so hand edits made meanwhile are kept, and a broken file is never overwritten.
    func saveCustomHarness(_ harness: CustomHarness) throws {
        try updateCustomHarnesses { list in
            var list = list
            if let index = list.firstIndex(where: { $0.id == harness.id }) {
                list[index] = harness
            } else {
                list.append(harness)
            }
            return list
        }
    }

    func removeCustomHarness(_ harness: CustomHarness) throws {
        try updateCustomHarnesses { $0.filter { $0.id != harness.id } }
    }

    private func updateCustomHarnesses(_ change: ([CustomHarness]) throws -> [CustomHarness]) throws {
        do {
            customHarnesses = try CustomHarnessStore.update(in: .current, change)
            customHarnessError = nil
        } catch {
            throw NSError(domain: "AKit", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "~/.akit/harnesses.json was not changed: \(error.localizedDescription)"])
        }
        Task { await refresh() }
    }

    private func scan() async {
        let env = HarnessEnvironment.current
        let roots = projectRoots.map(env.expand)
        do {
            customHarnesses = try CustomHarnessStore.load(in: env)
            customHarnessError = nil
        } catch {
            customHarnessError = error.localizedDescription
        }
        let adapters = HarnessCatalog.allAdapters(custom: customHarnesses)
        let (found, skills, projects, sessions, mcp) = await Task.detached {
            let found = HarnessCatalog.detectAll(in: env, adapters: adapters)
            let extra = ProjectFinder.projects(inRoots: roots)
            let projects = SkillScanner.projects(installations: found, extraProjects: extra, adapters: adapters, in: env)
            async let skills = SkillScanner.scan(installations: found, extraProjects: extra, adapters: adapters, in: env)
            async let sessions = SessionScanner.scan(installations: found, adapters: adapters, in: env)
            async let mcp = MCPScanner.scan(installations: found, projects: projects, adapters: adapters, in: env)
            return (found, await skills, projects, await sessions, await mcp)
        }.value
        installations = found
        self.skills = skills
        self.projects = projects
        self.sessions = sessions
        mcpServers = mcp.servers
        mcpProblems = mcp.problems
        lastScan = .now

        var newVersions: [HarnessID: String] = [:]
        await withTaskGroup(of: (HarnessID, String?).self) { group in
            for item in found {
                guard let exe = item.executableURL else { continue }
                group.addTask { (item.id, await VersionProbe.version(of: exe, in: env)) }
            }
            for await (id, version) in group {
                if let version { newVersions[id] = version }
            }
        }
        versions = newVersions
    }
}
