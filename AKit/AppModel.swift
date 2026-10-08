import AKitBrain
import AKitErrorAnalysis
import AKitFoundation
import AKitHarnesses
import AKitInsights
import AKitLab
import AKitMCP
import AKitModel
import AKitProjectSetup
import AKitSessions
import AKitSkills
import AKitSkillsSh
import AKitUsage
import Foundation
import Observation

/// App state. Screens only read it and call its methods.
@MainActor
@Observable
final class AppModel {
    private(set) var installations: [HarnessInstallation] = []
    private(set) var versions: [HarnessID: String] = [:]
    private(set) var skills: [Skill] = []
    /// Pi packages from Pi's global settings and the known projects' `.pi/settings.json`.
    private(set) var piPackages: [PiPackage] = []
    /// Saved conversations of all installed harnesses, newest first.
    private(set) var sessions: [SessionSummary] = []
    /// The person's ratings of runs (`akit rate`, Pi's ⌥G / ⌥X / ⌥R), by session log path.
    private(set) var ratings: [String: [Ratings.Rating]] = [:]
    /// Session folder (`SessionSummary.project` path) → project id, worktrees under their
    /// repository (from the last scan). Folders without a project are missing.
    private(set) var sessionProjects: [String: String] = [:]
    /// Project folders the harnesses know about plus those found in `projectRoots`.
    private(set) var projects: [URL] = []
    /// MCP servers from the config files of all installed harnesses.
    private(set) var mcpServers: [MCPServer] = []
    /// MCP config files that couldn't be read (file: reason).
    private(set) var mcpProblems: [String] = []
    /// Places a new MCP server can be written to (from the last scan).
    private(set) var mcpWriteTargets: [MCPWriteTarget] = []

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

    /// A Lab run the Lab screen should select when it appears (set by "Show Review").
    var revealLabRun: String?
    /// An error analysis batch the Reports tab should open when it appears (set by "Open Report").
    var revealBatch: String?

    /// A brain skill the Brain screen should select when it appears (set by "Show in Brain").
    var revealBrainSkill: String?
    /// A layer whose set Error Analysis → Evals should show when it appears (set by Brain's
    /// "Show in Error Analysis" and "Edit in Set…").
    var revealLayerSet: String?

    /// Opens Error Analysis → Evals on the layer's set.
    func showLayerSet(_ layer: String) {
        revealLayerSet = layer
        section = .analysis
    }

    /// Opens the Brain screen on this brain skill.
    func showBrainSkill(_ name: String) {
        revealBrainSkill = name
        section = .brain
    }

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

    /// Brain repo folder (`~/.akit/registry` by default). Stored per machine.
    var brainPath: String {
        didSet { UserDefaults.standard.set(brainPath, forKey: Self.brainPathKey) }
    }
    var brainRoot: URL { HarnessEnvironment.current.expand(brainPath) }
    /// The brain repo from the last scan; nil when there is no folder at `brainPath`.
    private(set) var brain: Brain?
    /// Brain project ids → their folders on this Mac (from the last scan).
    private(set) var brainProjectFolders: [String: URL] = [:]
    /// How each of your skills relates to the brain: rendered copy, same name, or not in it.
    private(set) var brainLinks: [Skill.ID: BrainLink] = [:]

    /// This Mac's role, from `~/.akit/machine.json` (shared with the `akit` command); reread on refresh.
    private(set) var machine = MachineProfile.load(home: HarnessEnvironment.current.homeDirectory)

    /// Saves this Mac's role and returns notes for the user; the file, not this copy,
    /// decides where answers go.
    func setMachine(_ profile: MachineProfile) throws -> [String] {
        let notes = try MachineProfile.change(to: profile, brain: brainRoot, home: HarnessEnvironment.current.homeDirectory)
        machine = profile
        return notes
    }

    /// Where project answers and locks are kept on this Mac: the brain, or a local folder on a work Mac.
    /// Apply checks the file again, so a role changed by `akit machine` meanwhile can't slip through.
    var projectStore: ProjectStore {
        ProjectStore.current(brain: brainRoot, home: HarnessEnvironment.current.homeDirectory, machine: machine)
    }

    /// Creates an empty brain repo at `brainPath` (folder layout, `core` layer, first commit).
    func createBrain() async throws {
        try await BrainSetup.create(at: brainRoot, env: .current)
        await refresh()
    }

    /// What importing skills from `source` (default `~/.agents/skills`) into a brain layer would do. Only reads.
    func brainImportPlan(from source: URL? = nil, layer: String = "core", mode: LayerSkill.Mode = .manual) async -> BrainImport.Plan? {
        guard let brain else { return nil }
        let env = HarnessEnvironment.current
        return await Task.detached {
            BrainImport.plan(from: source ?? BrainImport.defaultSource(home: env.homeDirectory), into: brain.root,
                             layer: layer, mode: mode, env: env)
        }.value
    }

    /// Copies the chosen skills into the brain, lists them in core and commits, then rescans.
    func importIntoBrain(_ plan: BrainImport.Plan, names: [String]) async throws {
        defer { Task { await refresh() } }
        try await BrainImport.apply(plan, importing: names, env: .current)
    }

    /// Adds a layer to the brain from the New Layer form and commits it, then rescans.
    func createLayer(_ draft: LayerWriter.Draft) async throws {
        guard let brain else {
            throw NSError(domain: "AKit", code: 4, userInfo: [NSLocalizedDescriptionKey: "The brain is not loaded."])
        }
        defer { Task { await refresh() } }
        try await LayerWriter.create(draft, in: brain, env: .current)
    }

    /// Removes a layer (to the Trash, committed); returns the projects to re-apply.
    func removeLayer(_ name: String) async throws -> [String] {
        guard let brain else { throw Self.noBrain }
        defer { Task { await refresh() } }
        return try await BrainRemove.removeLayer(name, in: brain, env: .current)
    }

    /// Removes a skill from the brain's library (to the Trash, committed).
    func removeSkill(_ name: String) async throws {
        guard let brain else { throw Self.noBrain }
        defer { Task { await refresh() } }
        try await BrainRemove.removeSkill(name, in: brain, env: .current)
    }

    /// Takes a skill out of one layer's skills list (committed).
    func removeSkill(_ skill: String, fromLayer layer: String) async throws {
        defer { Task { await refresh() } }
        try await oneLayerEditAtATime { brain in try await BrainRemove.removeSkill(skill, fromLayer: layer, in: brain, env: .current) }
    }

    /// Lists brain skills in a layer with one mode (committed).
    func addSkills(_ names: [String], mode: LayerSkill.Mode, toLayer layer: String) async throws {
        defer { Task { await refresh() } }
        try await oneLayerEditAtATime { brain in try await LayerEditor.addSkills(names, mode: mode, toLayer: layer, in: brain, env: .current) }
    }

    /// Sets how a layer brings one of its skills (committed).
    func setMode(_ mode: LayerSkill.Mode, ofSkill skill: String, inLayer layer: String) async throws {
        defer { Task { await refresh() } }
        try await oneLayerEditAtATime { brain in try await LayerEditor.setMode(mode, ofSkill: skill, inLayer: layer, in: brain, env: .current) }
    }

    /// Writes a layer's description, requires and AGENTS.md section (committed).
    func updateLayer(_ name: String, to details: LayerEditor.Details) async throws {
        defer { Task { await refresh() } }
        try await oneLayerEditAtATime { brain in try await LayerEditor.update(name, to: details, in: brain, env: .current) }
    }

    private var lastLayerEdit: Task<Void, Never>?

    /// Runs layer edits one after another: two edits of one layer.yaml (or two git commits)
    /// at the same time could lose a change.
    private func oneLayerEditAtATime(_ edit: @escaping @MainActor (Brain) async throws -> Void) async throws {
        let previous = lastLayerEdit
        let task = Task { @MainActor in
            await previous?.value
            guard let brain else { throw Self.noBrain }
            try await edit(brain)
        }
        lastLayerEdit = Task { _ = try? await task.value }
        try await task.value
    }

    /// The brain against its git remote; nil when it isn't a git repo.
    private(set) var brainSync: BrainSync.Status?
    private(set) var isSyncingBrain = false
    /// Bumped by every sync, so a fetch that started earlier can't overwrite its result.
    private var brainSyncGeneration = 0
    private var brainFetch: Task<Void, Never>?

    /// Asks the remote what's new (network), then updates `brainSync`.
    func fetchBrainSync() async {
        guard brain != nil, !isSyncingBrain else { return }
        let root = brainRoot, generation = brainSyncGeneration
        let task = Task {
            let status = await BrainSync.status(of: root, env: .current, fetch: true)
            if !Task.isCancelled, !isSyncingBrain, generation == brainSyncGeneration, root == brainRoot { brainSync = status }
        }
        brainFetch = task
        await task.value
    }

    /// Publishes this Mac's usage summaries, pulls the other Macs' commits and pushes this one's
    /// (`InsightsSync`, as `akit sync`), then rescans.
    func syncBrain() async throws -> InsightsSync.Outcome {
        guard let brain else { throw Self.noBrain }
        guard !isSyncingBrain else {
            throw NSError(domain: "AKit", code: 5, userInfo: [NSLocalizedDescriptionKey: "The brain is already syncing."])
        }
        isSyncingBrain = true
        brainSyncGeneration += 1
        // Let a running fetch finish first: two fetches at once can fail on git's ref locks.
        brainFetch?.cancel()
        await brainFetch?.value
        let root = brainRoot
        defer { Task { await refresh() } }
        do {
            // Off the main thread: the host name can take a network lookup.
            let projectsRoot = projectsRoot
            let outcome = try await Task.detached {
                try await InsightsSync.run(env: .current, brain: brain, projectsRoot: projectsRoot)
            }.value
            brainSync = await BrainSync.status(of: root, env: .current, fetch: false)
            isSyncingBrain = false
            return outcome
        } catch {
            brainSync = await BrainSync.status(of: root, env: .current, fetch: false)
            isSyncingBrain = false
            throw error
        }
    }

    private static let noBrain = NSError(domain: "AKit", code: 4, userInfo: [NSLocalizedDescriptionKey: "The brain is not loaded."])

    // MARK: Project setup

    /// Render targets for the harnesses installed on this Mac (`claude`, `pi`, …).
    var installedTargets: [String] {
        installations.compactMap { ProjectAnswers.target(for: $0.id) }
    }

    /// The brain's id for a project folder (from its git remote).
    func projectID(for project: URL) async -> String {
        await ProjectRecords.projectID(for: project, projectsRoot: projectsRoot, env: .current)
    }

    /// The first projects folder: project ids of folders without a git remote are relative to it
    /// (the `akit` command reads the same setting).
    var projectsRoot: URL {
        let env = HarnessEnvironment.current
        return projectRoots.first.map(env.expand) ?? env.homeDirectory.appending(path: "Projects")
    }

    /// Brain project ids found on this Mac → their folders: the home folder and every known project.
    func projectFolders() async -> [String: URL] {
        let env = HarnessEnvironment.current
        var folders = [ProjectRecords.homeID(machineName: machine.homeName): env.homeDirectory]
        await withTaskGroup(of: (String, URL).self) { group in
            for project in projects {
                group.addTask { (await self.projectID(for: project), project) }
            }
            for await (id, folder) in group where folders[id] == nil { folders[id] = folder }
        }
        return folders
    }

    /// What rendering these answers would change in the project (or the home folder). Only reads.
    func projectPlan(project: URL, id: String, answers: ProjectAnswers, forHome: Bool = false) async -> ProjectSetup.Plan? {
        guard let brain else { return nil }
        let store = projectStore
        return await Task.detached { ProjectSetup.plan(project: project, id: id, answers: answers, brain: brain, store: store, forHome: forHome) }.value
    }

    /// What forgetting a project would trash; nil when nothing is saved for it. Only reads.
    func forgetPreview(id: String, folder: URL?, forHome: Bool) async -> ProjectForget.Preview? {
        guard let brain else { return nil }
        let store = projectStore
        return await Task.detached { ProjectForget.preview(id: id, folder: folder, forHome: forHome, brain: brain, store: store) }.value
    }

    /// Trashes the files AKit wrote in the project (unless `keepFiles`) and its record, then rescans.
    func forget(_ preview: ProjectForget.Preview, keepFiles: Bool) async throws {
        guard let brain else {
            throw NSError(domain: "AKit", code: 4, userInfo: [NSLocalizedDescriptionKey: "The brain is not loaded; open the Brain screen again."])
        }
        defer { Task { await refresh() } }
        let env = HarnessEnvironment.current
        try await ProjectForget.run(preview, keepFiles: keepFiles, brain: brain, home: env.homeDirectory, env: env)
    }

    /// Writes the project files (backup first), saves answers in the plan's store, then rescans.
    func applyProject(_ plan: ProjectSetup.Plan, excluding: Set<String>, accepting: Set<String> = []) async throws -> ProjectSetup.Outcome {
        guard let brain else {
            throw NSError(domain: "AKit", code: 4, userInfo: [NSLocalizedDescriptionKey: "The brain is not loaded; open the Brain screen again."])
        }
        defer { Task { await refresh() } }
        let env = HarnessEnvironment.current
        return try await ProjectSetup.apply(plan, excluding: excluding, accepting: accepting, brain: brain, home: env.homeDirectory, env: env)
    }

    /// Harnesses described by the user in `~/.akit/harnesses.json`.
    private(set) var customHarnesses: [CustomHarness] = []
    /// Set when `~/.akit/harnesses.json` can't be read; AKit then refuses to overwrite it.
    private(set) var customHarnessError: String?

    var checkedAdapters: [String] { HarnessCatalog.adapters.map(\.displayName) + customHarnesses.map(\.name) }
    var builtInNames: [String] { HarnessCatalog.adapters.map(\.displayName) }

    private static let projectRootsKey = "projectRoots"
    private static let brainPathKey = "brainPath"
    static let defaultBrainPath = "~/.akit/registry"
    /// A refresh was requested while a scan was running: scan once more when it ends.
    private var rescanRequested = false

    init() {
        projectRoots = UserDefaults.standard.stringArray(forKey: Self.projectRootsKey) ?? ProjectFinder.defaultRoots
        brainPath = DebugSnapshot.options?.brain ?? UserDefaults.standard.string(forKey: Self.brainPathKey) ?? Self.defaultBrainPath
    }

    /// Re-detect harnesses, their versions and skills. Files are only read.
    func refresh() async {
        guard !isScanning else {
            rescanRequested = true
            return
        }
        isScanning = true
        machine = MachineProfile.load(home: HarnessEnvironment.current.homeDirectory)
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

    // MARK: MCP

    /// Places a new MCP server can be written to, for the installed harnesses and known projects.
    func mcpTargets() -> [MCPWriteTarget] { mcpWriteTargets }

    /// Whether AKit can change this server's file (not a plugin, not TOML, no comments).
    func canEdit(_ server: MCPServer) -> Bool {
        guard !server.isReadOnly, let target = MCPWriter.target(of: server, in: mcpWriteTargets) else { return false }
        return target.blockedReason == nil
    }

    /// Bumped after a secret is saved, so Keychain badges refresh.
    private(set) var keychainVersion = 0

    func isInKeychain(_ account: String) -> Bool {
        _ = keychainVersion
        return KeychainSecretStore().contains(account)
    }

    var envFileSourced: Bool {
        _ = keychainVersion
        return MCPWriter.isEnvFileSourced(home: HarnessEnvironment.current.homeDirectory)
    }

    /// "Set in Keychain": saves the value and exports it from ~/.akit/env.sh. Returns hints.
    /// Runs off the main thread: /usr/bin/security may wait for an unlocked Keychain.
    func storeSecret(_ value: String, for account: String) async throws -> [String] {
        defer { keychainVersion += 1 }
        let home = HarnessEnvironment.current.homeDirectory
        return try await Task.detached {
            try MCPWriter.storeSecret(value, for: account, in: KeychainSecretStore(), home: home)
        }.value
    }

    /// Stores the secrets in the Keychain, writes the server (backup first), then rescans.
    func applyMCP(_ plan: MCPWritePlan) async throws -> MCPWriter.Outcome {
        let outcome = try await MCPWriter.apply(plan, claude: installations.first { $0.id == .claudeCode },
                                                secrets: KeychainSecretStore(), env: HarnessEnvironment.current)
        keychainVersion += 1
        await refresh()
        return outcome
    }

    /// Messages of one session, read in the background.
    func transcript(of session: SessionSummary) async throws -> SessionTranscript {
        try await Self.background { try SessionReader.transcript(of: session) }
    }

    /// Lab runs in `~/.akit/lab`, newest first (reloaded by the Lab screen while it is open).
    var labRuns: [LabRun] = []
    /// Checked replay tasks of those runs, by commit.
    var labTasks: [String: ReplayTask] = [:]
    /// A start failed; the queue waits for Start instead of retrying on its own.
    var labAutoStartPaused = false
    /// The batch files of error analysis runs, by batch id (reloaded with the runs).
    var labBatches: [String: Batch] = [:]
    /// The control tasks of control runs, by task id (reloaded with the runs).
    var labControlTasks: [String: ControlTask] = [:]
    /// When the send log last changed: model calls of the Error Analysis screen and the
    /// `akit` command write it too, not only Lab runs (reloaded with the runs).
    var labSendsChanged: Date?
    /// What each run cost, by run id, from the send log (reloaded when it changes).
    var labRunCosts: [String: RunCost] = [:]
    /// Ended runs with neither sends nor an agent log to price them: not read again.
    @ObservationIgnored var labUnpricedRuns = Set<String>()

    /// Lab metrics of one Claude Code session: transcript, then git for its commits.
    func analysis(of session: SessionSummary) async throws -> SessionMetrics {
        let file = session.file, project = session.project
        return try await Task.detached(priority: .userInitiated) {
            try await LabAnalysis.analyze(file: file, project: project, env: .current)
        }.value
    }

    // MARK: Usage

    /// Token usage recorded by the installed harnesses from `since` on, read in the background.
    func usage(since: Date) async throws -> [UsageRecord] {
        let installations = installations
        return try await Self.background {
            UsageScanner.scan(installations: installations, since: since, in: .current)
        }
    }

    /// Subscription limit use (Codex: ChatGPT plan windows) from `since` on, read in the background.
    func limits(since: Date) async throws -> [LimitSample] {
        let installations = installations
        return try await Self.background {
            UsageScanner.scanLimits(installations: installations, since: since, in: .current)
        }
    }

    // MARK: System prompt

    /// Prompts caught from harnesses in this run of AKit, by harness and project.
    private(set) var capturedPrompts: [String: PromptSnapshot] = [:]

    func promptAccess(_ harness: HarnessID) -> SystemPromptAccess {
        PromptReader.access(for: harness)
    }

    /// The system prompt saved in this session, if the harness saves it.
    func recordedPrompt(in session: SessionSummary) async throws -> PromptSnapshot? {
        try await Self.background { try PromptReader.recorded(in: session) }
    }

    func capturedPrompt(harness: HarnessID, project: URL) -> PromptSnapshot? {
        capturedPrompts[Self.promptKey(harness, project)]
    }

    /// Asks the harness for its current system prompt in `project` (see PiPromptProbe).
    func capturePrompt(harness: HarnessID, project: URL) async throws {
        guard let adapter = adapter(for: harness) else { return }
        guard let prompt = try await PromptReader.capture(harness: harness, in: project, env: .current) else {
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
        let brainRoot = brainRoot
        do {
            customHarnesses = try CustomHarnessStore.load(in: env)
            customHarnessError = nil
        } catch {
            customHarnessError = error.localizedDescription
        }
        let adapters = HarnessCatalog.allAdapters(custom: customHarnesses)
        let (found, skills, projects, sessions, mcp, targets, brain, piPackages) = await Task.detached {
            let found = HarnessCatalog.detectAll(in: env, adapters: adapters)
            let extra = ProjectFinder.projects(inRoots: roots)
            let projects = SkillScanner.projects(installations: found, extraProjects: extra, adapters: adapters, in: env)
            // Read once per refresh: the Overview lists them, the skill scan adds their skills.
            let piPackages = found.contains { $0.id == .pi }
                ? HarnessCatalog.configRoot(of: .pi, in: env).map { PiPackages.list(configRoot: $0, projects: projects, in: env) } ?? []
                : []
            async let skills = SkillScanner.scan(installations: found, extraProjects: extra, adapters: adapters,
                                                 projects: projects, piPackages: piPackages, in: env)
            async let sessions = SessionScanner.scan(installations: found, in: env)
            async let mcp = MCPScanner.scan(installations: found, projects: projects, adapters: adapters, in: env)
            async let targets = MCPWriter.targets(installations: found, projects: projects, adapters: adapters, in: env)
            async let brain = Brain.load(from: brainRoot)
            return (found, await skills, projects, await sessions, await mcp, await targets, await brain, piPackages)
        }.value
        // Before anything is shown: the session list and its projects change together.
        let folders = Array(Set(sessions.compactMap { $0.project?.path }))
        let projectsRoot = projectsRoot
        let (sessionProjects, ratings) = await Task.detached {
            (SessionProjects.projectIDs(ofFolders: folders, env: env, projectsRoot: projectsRoot), Ratings.byTranscript(env: env))
        }.value
        self.brain = brain
        brainSync = brain == nil ? nil : await BrainSync.status(of: brainRoot, env: env, fetch: false)
        installations = found
        self.skills = skills
        self.piPackages = piPackages
        self.projects = projects
        if let brain {
            brainProjectFolders = await projectFolders()
            brainLinks = BrainLinks.links(for: skills, brain: brain, folders: brainProjectFolders, store: projectStore)
        } else {
            brainProjectFolders = [:]
            brainLinks = [:]
        }
        self.sessions = sessions
        self.sessionProjects = sessionProjects
        self.ratings = ratings
        mcpServers = mcp.servers
        mcpProblems = mcp.problems
        mcpWriteTargets = targets
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
