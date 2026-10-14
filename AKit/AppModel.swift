import AKitBrain
import AKitDoctor
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
    /// What reading them left out (repeated entries, limits), for the Overview.
    private(set) var piPackageNotes: [String] = []
    /// Per project path: ids of global Pi package skills a session there doesn't load.
    private(set) var piHiddenSkills: [String: Set<String>] = [:]
    /// Each skill's switch per harness (Claude Code's skillOverrides, Pi's skills entries).
    private(set) var skillStates: [Skill.ID: [HarnessID: SkillSwitchReading]] = [:]
    /// A skill switch change shown in its sheet until Apply or Cancel.
    var skillSwitchRequest: SkillSwitchRequest?
    /// Why a skill switch change couldn't be planned (shown in an alert).
    var skillSwitchError: String?
    /// A model invocation change (Auto / Manual) waiting in its sheet, and why one couldn't be planned.
    var skillInvocationRequest: SkillInvocationRequest?
    var skillInvocationError: String?
    /// Every global skill Manual (or Auto) at once, waiting in its sheet.
    var globalInvocationRequest: GlobalInvocationRequest?
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
    /// Each server's switch per harness: off everywhere, the folders it is off in.
    private(set) var mcpStates: [MCPServer.ID: [HarnessID: MCPSwitches.Status]] = [:]
    /// claude.ai connectors all off (`disableClaudeAiConnectors`); nil when the settings can't be read.
    private(set) var connectorsOff: Bool? = false
    /// An MCP switch change shown in its sheet (with a project choice first for Off in Project…).
    var mcpSwitchRequest: MCPSwitchRequest?

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
    /// Brain project ids → the git checkout whose top is their folder (from the last scan);
    /// missing when the folder is not the top of one.
    private(set) var brainProjectCheckouts: [String: GitCheckout] = [:]
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

    /// The brain's own git name and email (its `.git/config`); nil when the brain is not a git repo.
    private(set) var brainIdentity: BrainGit.Identity?

    /// A work Mac whose brain has no name or email of its own: AKit refuses to commit there.
    var brainIdentityMissing: Bool { machine.isWork && brainIdentity?.isComplete == false }

    /// Saves the name and email the brain's commits carry, in the brain's own git settings on this Mac.
    func setBrainIdentity(name: String, email: String) async throws {
        let root = brainRoot
        do {
            brainIdentity = try await BrainGit.setOwnIdentity(name: name, email: email, brain: root, env: .current)
        } catch {
            // The name may be saved and the email not: show what is there now.
            brainIdentity = await BrainGit.ownIdentity(brain: root, env: .current)
            throw error
        }
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
    /// A project's main checkout wins over its git worktrees, which share its id.
    func projectFolders() async -> [String: URL] {
        let env = HarnessEnvironment.current
        var found: [String: [URL]] = [:]
        await withTaskGroup(of: (String, URL).self) { group in
            for project in projects {
                group.addTask { (await self.projectID(for: project), project) }
            }
            for await (id, folder) in group { found[id, default: []].append(folder) }
        }
        var folders = found.compactMapValues { GitCheckout.preferred($0) }
        folders[ProjectRecords.homeID(machineName: machine.homeName)] = env.homeDirectory
        return folders
    }

    /// What rendering these answers would change in the project (or the home folder). Only reads.
    func projectPlan(project: URL, id: String, answers: ProjectAnswers, forHome: Bool = false) async -> ProjectSetup.Plan? {
        guard let brain else { return nil }
        let store = projectStore
        let piSetting = HarnessEnvironment.current.variables["PI_CODING_AGENT_DIR"]
        return await Task.detached {
            ProjectSetup.plan(project: project, id: id, answers: answers, brain: brain, store: store, forHome: forHome, piAgentDirSetting: piSetting,
                              rememberPiAgentDir: true)
        }.value
    }

    /// What forgetting a project would trash; nil when nothing is saved for it. Only reads.
    func forgetPreview(id: String, folder: URL?, forHome: Bool) async -> ProjectForget.Preview? {
        guard let brain else { return nil }
        let store = projectStore
        let piSetting = HarnessEnvironment.current.variables["PI_CODING_AGENT_DIR"]
        return await Task.detached {
            ProjectForget.preview(id: id, folder: folder, forHome: forHome, brain: brain, store: store, piAgentDirSetting: piSetting,
                                  rememberPiAgentDir: true)
        }.value
    }

    /// Trashes the files AKit wrote in the project (unless `keepFiles`) and its record, then rescans.
    func forget(_ preview: ProjectForget.Preview, keepFiles: Bool) async throws {
        guard let brain else {
            throw NSError(domain: "AKit", code: 4, userInfo: [NSLocalizedDescriptionKey: "The brain is not loaded; open the Brain screen again."])
        }
        defer { Task { await refresh() } }
        let env = HarnessEnvironment.current
        try await holdingWorktrees(preview.id) {
            try await ProjectForget.run(preview, keepFiles: keepFiles, brain: brain, home: env.homeDirectory, env: env)
        }
    }

    /// Writes the project files (backup first), saves answers in the plan's store, then rescans.
    func applyProject(_ plan: ProjectSetup.Plan, excluding: Set<String>, accepting: Set<String> = []) async throws -> ProjectSetup.Outcome {
        guard let brain else {
            throw NSError(domain: "AKit", code: 4, userInfo: [NSLocalizedDescriptionKey: "The brain is not loaded; open the Brain screen again."])
        }
        defer { Task { await refresh() } }
        let env = HarnessEnvironment.current
        return try await holdingWorktrees(plan.id) {
            try await ProjectSetup.apply(plan, excluding: excluding, accepting: accepting, brain: brain, home: env.homeDirectory, env: env)
        }
    }

    // MARK: Move to Project

    /// One skill's calls per project over the last 30 days (`akit stats skill`), from the index as
    /// it is: opened read-only, never imported or migrated; nil without one. Only reads.
    func skillCalls(_ name: String) async -> SkillCallsReport? {
        let env = HarnessEnvironment.current, brain = brain
        return await Task.detached {
            guard let database = IndexSchema.openReadOnly(InsightsPaths(env: env).database) else { return nil }
            return try? SkillCalls.report(database, skill: name, brain: brain, env: env, hardware: MachineProfile.currentHardwareHash())
        }.value
    }

    /// What moving the skill into these projects would do (`SkillMove.plan`). Only reads.
    func moveSkillPlan(name: String, targets: [SkillMove.Target], mode: LayerSkill.Mode, keepGlobal: Bool) async -> SkillMove.Plan? {
        guard let brain else { return nil }
        let env = HarnessEnvironment.current
        let context = SkillMove.Context(env: env, store: projectStore, homeID: ProjectRecords.homeID(machineName: machine.homeName),
                                        installed: skills, targets: installedTargets, projectFolders: brainProjectFolders,
                                        piAgentDirSetting: env.variables["PI_CODING_AGENT_DIR"], rememberPiAgentDir: true)
        return await Task.detached {
            SkillMove.plan(name: name, targets: targets, mode: mode, keepGlobal: keepGlobal, brain: brain, context: context)
        }.value
    }

    /// Moves the skill (brain, projects, core, home folder), holding the worktree sync of every
    /// project it writes, then rescans. A `SkillMove.Failure` carries what was done before it stopped.
    func moveSkill(_ plan: SkillMove.Plan) async throws -> SkillMove.Outcome {
        guard let brain else {
            throw NSError(domain: "AKit", code: 4, userInfo: [NSLocalizedDescriptionKey: "The brain is not loaded; open the Brain screen again."])
        }
        defer { Task { await refresh() } }
        let env = HarnessEnvironment.current
        let ids = Set(plan.adding.map(\.id) + (plan.home.map { [$0.id] } ?? []))
        return try await holdingWorktrees(all: ids) {
            try await SkillMove.apply(plan, brain: brain, env: env)
        }
    }

    // MARK: Move to Global

    /// What moving the skill from these projects into the core layer would do
    /// (`SkillMove.planToGlobal`); `from` nil: every project whose answers list it. Only reads.
    func moveToGlobalPlan(name: String, from: [String]?, mode: LayerSkill.Mode?) async -> SkillMove.GlobalPlan? {
        guard let brain else { return nil }
        let env = HarnessEnvironment.current
        let context = SkillMove.Context(env: env, store: projectStore, homeID: ProjectRecords.homeID(machineName: machine.homeName),
                                        installed: skills, targets: installedTargets, projectFolders: brainProjectFolders,
                                        piAgentDirSetting: env.variables["PI_CODING_AGENT_DIR"], rememberPiAgentDir: true)
        return await Task.detached { SkillMove.planToGlobal(name: name, from: from, mode: mode, brain: brain, context: context) }.value
    }

    /// Moves it (brain, core, home folder, then the projects), holding the worktree sync of every
    /// folder it writes, then rescans. A `SkillMove.GlobalFailure` says where the skill is.
    func moveToGlobal(_ plan: SkillMove.GlobalPlan) async throws -> SkillMove.GlobalOutcome {
        guard let brain else {
            throw NSError(domain: "AKit", code: 4, userInfo: [NSLocalizedDescriptionKey: "The brain is not loaded; open the Brain screen again."])
        }
        defer { Task { await refresh() } }
        let env = HarnessEnvironment.current
        return try await holdingWorktrees(all: Set(plan.holds)) {
            try await SkillMove.applyToGlobal(plan, brain: brain, env: env)
        }
    }

    // MARK: Remove Everywhere

    /// Every place the harnesses load the skill from and what removing it does
    /// (`SkillRemoval.plan`); `leaving`: unticked places, nil for the defaults. Only reads.
    func removalPlan(name: String, leaving: Set<String>?) async -> SkillRemoval.Plan {
        let env = HarnessEnvironment.current, brain = brain
        let context = SkillMove.Context(env: env, store: projectStore, homeID: ProjectRecords.homeID(machineName: machine.homeName),
                                        installed: skills, targets: installedTargets, projectFolders: brainProjectFolders,
                                        piAgentDirSetting: env.variables["PI_CODING_AGENT_DIR"], rememberPiAgentDir: true)
        return await Task.detached { SkillRemoval.plan(name: name, brain: brain, context: context, leaving: leaving) }.value
    }

    /// Removes the ticked places, holding the worktree sync of every project it writes, then
    /// rescans (the Insights tables load again). A `SkillRemoval.Failure` says what was done.
    func removeEverywhere(_ plan: SkillRemoval.Plan) async throws -> SkillRemoval.Outcome {
        defer { Task { await refresh() } }
        let env = HarnessEnvironment.current, brain = brain
        return try await holdingWorktrees(all: Set(plan.projects)) {
            try await SkillRemoval.apply(plan, brain: brain, env: env)
        }
    }

    /// Disable Plugin…: what turning the plugin off changes, and which skills go with it. Only reads.
    func pluginPlan(_ plugin: String) throws -> PluginSwitch.Plan {
        let servers = mcpServers.filter { if case .plugin(let name) = $0.scope { name == plugin } else { false } }.map(\.name)
        return try PluginSwitch.plan(plugin: plugin, installed: skills, servers: servers, projects: Array(brainProjectFolders.values),
                                     in: .current)
    }

    /// Turns the plugin off in Claude Code's settings (backup first), then rescans.
    func disablePlugin(_ plan: PluginSwitch.Plan) async throws {
        let home = HarnessEnvironment.current.homeDirectory
        _ = try await Task.detached { try PluginSwitch.apply(plan, home: home) }.value
        await refresh()
    }

    // MARK: Worktrees

    /// What a worktree sync of a local-only project did, and when.
    struct WorktreeSync {
        let outcome: ProjectWorktrees.Outcome
        let date: Date
    }

    /// The last worktree sync of each local-only project that changed something or found
    /// something new, by project id: on refresh, about a second after a worktree is added or
    /// removed, or from Sync Worktrees.
    private(set) var worktreeSyncs: [String: WorktreeSync] = [:]
    /// Projects whose worktrees are being synced now, or that an Apply or Forget is changing.
    private(set) var worktreesSyncing: Set<String> = []
    /// A sync was asked for while one ran: run once more when it ends.
    @ObservationIgnored private var worktreesSyncAgain: Set<String> = []
    /// Set-up local-only projects on this Mac (main checkouts), by id, from the last scan.
    @ObservationIgnored private var localOnlyFolders: [String: URL] = [:]
    @ObservationIgnored private var worktreeWatcher: WorktreeWatcher?

    /// The project's worktrees and what each lacks; nil when the folder is not the top of a main
    /// checkout or AKit's block is broken. Only reads.
    func worktreeStatus(of folder: URL) async -> ProjectWorktrees.Status? {
        await Task.detached { ProjectWorktrees.status(of: folder, env: .current) }.value
    }

    /// Links AKit's files into the project's worktrees and removes its stale links (layers.md:
    /// these writes need no preview). The outcome lands in `worktreeSyncs`.
    func syncWorktrees(id: String, folder: URL) async {
        guard !worktreesSyncing.contains(id) else {
            worktreesSyncAgain.insert(id)
            return
        }
        worktreesSyncing.insert(id)
        defer { worktreesSyncing.remove(id) }
        repeat {
            worktreesSyncAgain.remove(id)
            let outcome = await Task.detached { ProjectWorktrees.sync(folder, env: .current) }.value
            await syncMCPWorktrees(only: folder)
            // The same result again changes nothing on screen, so the page doesn't reload.
            if let last = worktreeSyncs[id]?.outcome, !outcome.changed, outcome.problems == last.problems,
               outcome.conflicts == last.conflicts, outcome.worktrees == last.worktrees { continue }
            worktreeSyncs[id] = WorktreeSync(outcome: outcome, date: .now)
        } while worktreesSyncAgain.contains(id)
    }

    /// Runs an Apply or Forget, which sync the project's worktrees themselves, with the project
    /// held in the same gate as `syncWorktrees`: a running sync ends first, and syncs asked for
    /// meanwhile wait and run once after.
    private func holdingWorktrees<T>(_ id: String, _ work: () async throws -> T) async throws -> T {
        try await holdingWorktrees(all: [id], work)
    }

    /// The same for several projects at once (Move to Project applies to each of them).
    private func holdingWorktrees<T>(all ids: Set<String>, _ work: () async throws -> T) async throws -> T {
        while !worktreesSyncing.isDisjoint(with: ids) { try? await Task.sleep(for: .milliseconds(100)) }
        worktreesSyncing.formUnion(ids)
        defer {
            worktreesSyncing.subtract(ids)
            for id in ids where worktreesSyncAgain.remove(id) != nil { worktreesChanged(id) }
        }
        return try await work()
    }

    /// After a scan: watch the worktrees of every set-up local-only project on this Mac and sync
    /// them, quietly. Snapshots change no files, so they skip it.
    private func followLocalOnlyWorktrees() {
        guard DebugSnapshot.options == nil else { return }
        let store = projectStore
        var folders: [String: URL] = [:], commonDirs: [String: URL] = [:]
        for project in brain?.projects ?? [] where !project.isHome && project.answers.isLocalOnly(store: store) {
            guard let folder = brainProjectFolders[project.id], let checkout = brainProjectCheckouts[project.id], !checkout.isLinkedWorktree else { continue }
            folders[project.id] = folder
            commonDirs[project.id] = checkout.commonDir
        }
        localOnlyFolders = folders
        if worktreeWatcher == nil, !commonDirs.isEmpty {
            worktreeWatcher = WorktreeWatcher { [weak self] id in self?.worktreesChanged(id) }
        }
        worktreeWatcher?.watch(commonDirs)
        Task {
            for (id, folder) in folders { await syncWorktrees(id: id, folder: folder) }
        }
    }

    /// A worktree of the project came or went: sync only that project, not a full refresh.
    private func worktreesChanged(_ id: String) {
        guard let folder = localOnlyFolders[id] else { return }
        Task { await syncWorktrees(id: id, folder: folder) }
    }

    // MARK: Diagnostics

    /// Collecting diagnostics, or they were just copied (Help → Copy Diagnostics).
    private(set) var diagnosticsNotice: String?

    /// `akit doctor`'s report with this app's settings and its view of the projects. Only reads.
    func diagnostics() async -> String {
        diagnosticsNotice = "Collecting diagnostics…"
        let env = HarnessEnvironment.current
        let brainRoot = brainRoot, roots = projectRoots.map(env.expand), app = Bundle.main.bundleURL
        let folders = brainProjectFolders.isEmpty ? nil : brainProjectFolders
        return await Task.detached {
            await Doctor.report(Doctor.Input(env: env, brainRoot: brainRoot, projectRoots: roots, appBundle: app,
                                             projectFolders: folders))
        }.value
    }

    /// Shows a short note for a few seconds (after the report is on the pasteboard).
    func showDiagnosticsNotice(_ text: String) {
        diagnosticsNotice = text
        Task {
            try? await Task.sleep(for: .seconds(3))
            if diagnosticsNotice == text { diagnosticsNotice = nil }
        }
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
        // Demo screenshots run in a made-up home: this Mac's saved folders don't belong in them.
        projectRoots = DebugSnapshot.options?.demo == true ? ProjectFinder.defaultRoots
            : UserDefaults.standard.stringArray(forKey: Self.projectRootsKey) ?? ProjectFinder.defaultRoots
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

    /// Plans a skill switch change and opens its sheet (or the alert, when it can't be done).
    func requestSkillSwitch(_ skill: Skill, harness: HarnessID, to state: SkillSwitchState) {
        do {
            let plan = try SkillSwitches.plan(skill, harness: harness, to: state, in: .current)
            guard !plan.changesNothing else { return }
            skillSwitchRequest = SkillSwitchRequest(plan: plan)
        } catch {
            skillSwitchError = error.message
        }
    }

    /// Writes a planned switch change (backup first; refused if the file changed), then rescans.
    func applySkillSwitch(_ plan: SkillSwitches.Plan) async throws -> URL? {
        let home = HarnessEnvironment.current.homeDirectory
        let backup = try await Task.detached { try SkillSwitches.apply(plan, home: home) }.value
        await refresh()
        return backup
    }

    /// Plans making the skill Manual or Auto (`SkillInvocation.plan`, only reads) and opens its
    /// sheet, or the alert when it can't be done.
    func requestSkillInvocation(_ skill: Skill, manual: Bool) {
        let env = HarnessEnvironment.current, brain = brain, link = brainLinks[skill.id]
        let context = SkillMove.Context(env: env, store: projectStore, homeID: ProjectRecords.homeID(machineName: machine.homeName),
                                        installed: skills, targets: installedTargets, projectFolders: brainProjectFolders,
                                        piAgentDirSetting: env.variables["PI_CODING_AGENT_DIR"], rememberPiAgentDir: true)
        Task {
            let result = await Task.detached {
                Result { try SkillInvocation.plan(skill, link: link, manual: manual, brain: brain, context: context) }
            }.value
            switch result {
            case .success(let plan):
                if plan.changesNothing {
                    skillInvocationError = "\(plan.skill) is already \(manual ? "Manual" : "Auto"); there is nothing to change."
                } else {
                    skillInvocationRequest = SkillInvocationRequest(plan: plan)
                }
            case .failure(let error): skillInvocationError = error.localizedDescription
            }
        }
    }

    /// Plans making every global skill Manual or Auto (`SkillInvocation.planAll`, only reads) and
    /// opens its sheet, or the alert when nothing would change.
    func requestGlobalInvocation(manual: Bool) {
        let env = HarnessEnvironment.current, brain = brain, links = brainLinks
        let candidates = SkillInvocation.globalCandidates(skills, manual: manual)
        guard !candidates.isEmpty else {
            skillInvocationError = "Every global skill is already \(SkillInvocationText.title(manual: manual)); there is nothing to change."
            return
        }
        let context = SkillMove.Context(env: env, store: projectStore, homeID: ProjectRecords.homeID(machineName: machine.homeName),
                                        installed: skills, targets: installedTargets, projectFolders: brainProjectFolders,
                                        piAgentDirSetting: env.variables["PI_CODING_AGENT_DIR"], rememberPiAgentDir: true)
        Task {
            let plan = await Task.detached {
                SkillInvocation.planAll(candidates, links: links, manual: manual, brain: brain, context: context)
            }.value
            globalInvocationRequest = GlobalInvocationRequest(plan: plan)
        }
    }

    /// Carries out the planned change of many skills, then rescans. With rendered copies: in line
    /// with the Brain screen's layer edits, holding the home folder's worktree sync.
    func applyGlobalInvocation(_ plan: SkillInvocation.BulkPlan) async throws {
        defer { Task { await refresh() } }
        let env = HarnessEnvironment.current
        guard !plan.holds.isEmpty || !plan.layers.isEmpty else {
            _ = try await SkillInvocation.applyAll(plan, brain: brain, env: env)
            return
        }
        try await oneLayerEditAtATime { [self] brain in
            _ = try await holdingWorktrees(all: Set(plan.holds)) {
                try await SkillInvocation.applyAll(plan, brain: brain, env: env)
            }
        }
    }

    /// Carries out a planned model invocation change (backup first; refused if a file changed),
    /// then rescans. A rendered copy: one layer edit at a time, holding the home folder's worktree sync.
    func applySkillInvocation(_ plan: SkillInvocation.Plan) async throws {
        defer { Task { await refresh() } }
        let env = HarnessEnvironment.current
        guard plan.layer != nil else {
            _ = try await SkillInvocation.apply(plan, brain: brain, env: env)
            return
        }
        // A layer's mode changes: in line with the Brain screen's layer edits.
        try await oneLayerEditAtATime { [self] brain in
            _ = try await holdingWorktrees(all: Set(plan.holds)) {
                try await SkillInvocation.apply(plan, brain: brain, env: env)
            }
        }
    }

    /// The installed skill a name from session records stands for: Claude Code's command name
    /// (the folder, `anthropic-skills:<folder>` for claude.ai skills), Insights' `plugin:name` for a
    /// plugin skill, else the SKILL.md name (Pi). The personal one first, then a project's.
    func installedSkill(named name: String) -> Skill? {
        func names(_ skill: Skill) -> [String] {
            if case .plugin(let plugin) = skill.scope { return ["\(plugin):\(skill.name)"] }
            return [SkillSwitches.claudeName(of: skill), skill.name].compactMap { $0 }
        }
        let sorted = skills.sorted { $0.scope.sortRank < $1.scope.sortRank }
        return sorted.first { names($0).first == name } ?? sorted.first { names($0).contains(name) }
    }

    /// The installed MCP server a name from session records stands for (the name as written, or
    /// its tool-name spelling): the user-level one first.
    func installedMCPServer(named name: String) -> MCPServer? {
        let matches = mcpServers.filter { $0.name == name || MCPSwitches.denyRule($0.name) == "mcp__" + name }
        return matches.first { $0.scope == .global } ?? matches.first
    }

    /// Writes a planned MCP switch change (exclude lines first), then rescans.
    func applyMCPSwitch(_ plan: MCPSwitches.Plan) async throws {
        let home = HarnessEnvironment.current.homeDirectory
        _ = try await Task.detached { try MCPProjectSwitch.apply(plan, home: home) }.value
        await refresh()
    }

    /// Gives worktrees of projects with a Pi server turned off there the entry they lack
    /// (`~/.akit/mcp-off.json`). `only`: one project's main checkout, else all remembered ones.
    /// One sync at a time; one asked for meanwhile runs once after (for all projects).
    func syncMCPWorktrees(only: URL? = nil) async {
        guard DebugSnapshot.options == nil else { return }
        guard !mcpSyncRunning else {
            mcpSyncAgain = true
            return
        }
        mcpSyncRunning = true
        defer { mcpSyncRunning = false }
        var scope = only
        repeat {
            mcpSyncAgain = false
            let env = HarnessEnvironment.current
            let result = await Task.detached { [scope] in MCPProjectSwitch.syncWorktrees(only: scope, env: env) }.value
            if !result.added.isEmpty {
                mcpStates = await Task.detached { [mcpServers, projects] in MCPSwitches.statuses(of: mcpServers, projects: projects, in: env) }.value
            }
            if !result.added.isEmpty || !result.problems.isEmpty || mcpSyncNotice?.problems != result.problems {
                mcpSyncNotice = result.added.isEmpty && result.problems.isEmpty ? nil : MCPSyncNotice(added: result.added, problems: result.problems, date: .now)
            }
            scope = nil
        } while mcpSyncAgain
    }

    /// What the last worktree sync of MCP switches added and couldn't write (MCP Servers screen).
    private(set) var mcpSyncNotice: MCPSyncNotice?
    private var mcpSyncRunning = false
    private var mcpSyncAgain = false

    struct MCPSyncNotice: Equatable {
        let added: [String]
        let problems: [String]
        let date: Date
    }

    func dismissMCPSyncNotice() { mcpSyncNotice = nil }

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
        let (found, scanned, projects, sessions, mcp, targets, brain, pi) = await Task.detached {
            let found = HarnessCatalog.detectAll(in: env, adapters: adapters)
            let extra = ProjectFinder.projects(inRoots: roots)
            let projects = SkillScanner.projects(installations: found, extraProjects: extra, adapters: adapters, in: env)
            async let sessions = SessionScanner.scan(installations: found, in: env)
            async let mcp = MCPScanner.scan(installations: found, projects: projects, adapters: adapters, in: env)
            async let targets = MCPWriter.targets(installations: found, projects: projects, adapters: adapters, in: env)
            async let brain = Brain.load(from: brainRoot)
            // Read once per refresh: the Overview lists them, the skill scan adds their skills.
            let listing = found.contains { $0.id == .pi }
                ? HarnessCatalog.configRoot(of: .pi, in: env).map { PiPackages.list(configRoot: $0, projects: projects, in: env) }
                : nil
            let pi = (listing: listing ?? PiPackages.Listing(),
                      hidden: PiPackages.skillsHidden(projects: projects, packages: listing?.packages ?? []))
            let skills = SkillScanner.scan(installations: found, extraProjects: extra, adapters: adapters, projects: projects,
                                           piPackages: pi.listing.packages, piHidden: pi.hidden, in: env)
            let states = SkillSwitches.states(of: skills, in: env)
            let mcpResult = await mcp
            let switches = (MCPSwitches.statuses(of: mcpResult.servers, projects: projects, in: env), MCPSwitches.connectorsOff(in: env))
            return (found, (skills, states, switches), projects, await sessions, mcpResult, await targets, await brain, pi)
        }.value
        let (skills, states, switches) = scanned
        // Before anything is shown: the session list and its projects change together.
        let folders = Array(Set(sessions.compactMap { $0.project?.path }))
        let projectsRoot = projectsRoot
        let (sessionProjects, ratings) = await Task.detached {
            (SessionProjects.projectIDs(ofFolders: folders, env: env, projectsRoot: projectsRoot), Ratings.byTranscript(env: env))
        }.value
        // A work Mac keeps its project records outside the brain; list them too.
        self.brain = brain?.addingProjects(from: projectStore)
        brainSync = brain == nil ? nil : await BrainSync.status(of: brainRoot, env: env, fetch: false)
        brainIdentity = brain == nil ? nil : await BrainGit.ownIdentity(brain: brainRoot, env: env)
        installations = found
        self.skills = skills
        skillStates = states
        piPackages = pi.listing.packages
        piPackageNotes = pi.listing.notes
        piHiddenSkills = pi.hidden
        self.projects = projects
        if let brain {
            brainProjectFolders = await projectFolders()
            let folders = brainProjectFolders
            brainProjectCheckouts = await Task.detached { folders.compactMapValues { GitCheckout.at($0) } }.value
            brainLinks = BrainLinks.links(for: skills, brain: brain, folders: brainProjectFolders, store: projectStore)
        } else {
            brainProjectFolders = [:]
            brainProjectCheckouts = [:]
            brainLinks = [:]
        }
        followLocalOnlyWorktrees()
        self.sessions = sessions
        self.sessionProjects = sessionProjects
        self.ratings = ratings
        mcpServers = mcp.servers
        mcpProblems = mcp.problems
        mcpWriteTargets = targets
        mcpStates = switches.0
        connectorsOff = switches.1
        lastScan = .now
        Task { await syncMCPWorktrees() }

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
