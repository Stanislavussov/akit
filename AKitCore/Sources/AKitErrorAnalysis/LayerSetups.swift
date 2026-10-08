import AKitBrain
import AKitFoundation
import AKitLab
import AKitRender
import Foundation

/// A brain layer as the setups of an eval (`docs/design/layer-evals.md`): the layer rendered
/// once from a clean brain commit into two overlays, "required layers + X" and "required
/// layers alone", checked against every task's base commit before anything is queued.
/// Reads the brain and the task repository; writes nothing.
public enum LayerSetups {
    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
        public init(message: String) { self.message = message }
    }

    /// What an eval would queue, before anything is written.
    public struct Prepared: Sendable {
        public var evalID: String
        public var layer: String
        /// `[requiredOnly, layer]`.
        public var setups: [ControlSetup]
        /// The read-only sanity setup (the required layers alone, read-only tools), or nil.
        public var sanitySetup: ControlSetup?
        public var sanityTasks: [ControlTask]
        /// The overlays to store, by hash.
        public var overlays: [String: ControlOverlay]
        /// Tasks whose placement works for both setups.
        public var runnable: [ControlTask]
        /// Task id → why the layer can't be placed in its clone.
        public var blocked: [String: String]
        /// Task id → what the layer's placement noted (appended to the project's own CLAUDE.md, …).
        public var notes: [String: [String]]
        /// Task id → the project's own file the layer's AGENTS.md text is appended to
        /// (`CLAUDE.md`, `.claude/CLAUDE.md`, or `AGENTS.md` when CLAUDE.md brings it in).
        public var ownFiles: [String: String]
        /// Skills of the layer the agent already has elsewhere.
        public var overlap: [String]
        public var warnings: [String]
        public var brainCommit: String
        /// The field answers the render used (explicit, then the project's), before defaults.
        public var values: [String: FieldValue]
        /// Continues an eval: its folder exists, its finished cells are reused.
        public var continuing: Bool
        /// Shell commands the agent may not run in any cell of the eval (`ControlSetup.denied`).
        public var denied: [String]
        /// What each setup's cells must and must not show the agent (`LayerChecks`).
        public var checks: LayerChecks
    }

    /// Read-only sanity cells: one repeat on the first tasks.
    public static let sanityTaskCount = 3

    /// `answers`: explicit field answers, which win over the project's saved answers (when the
    /// task repository was set up through AKit), which win over the defaults of `layer.yaml`.
    /// `homeSkills`: Claude Code skill names of the home folder and plugins, for the overlap
    /// warning. `continuing`: an eval id; its setups and tasks are reused when the layer still
    /// renders the same overlays. `denied`: shell commands no cell may run (both setups and the
    /// sanity cells); nil takes `ControlSetup.defaultDenied(repo:)`. A continued eval keeps
    /// its own.
    public static func prepare(layer: String, tasks: [ControlTask], answers: [String: FieldValue], agent: LabAgent, sanity: Bool,
                               continuing: String? = nil, denied: [String]? = nil, homeSkills: Set<String>, brain brainRoot: URL, store: ProjectStore,
                               projectsRoot: URL, now: Date = .now, env: HarnessEnvironment) async throws -> Prepared {
        let explicit = denied.map { $0.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        if let explicit, let problem = ControlSetup.deniedProblem(explicit) { throw Failure(message: problem) }
        guard agent.harness == .claudeCode else {
            throw Failure(message: "Layer evals run Claude Code only for now; pick Claude Code as the agent.")
        }
        guard layer != "core" else {
            throw Failure(message: "The core layer is the home folder's layer: every cell already has it, so it can't be evaluated.")
        }
        guard let brain = Brain.load(from: brainRoot) else { throw Failure(message: "No brain repo at \(brainRoot.path).") }
        let byName = Dictionary(brain.layers.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        guard let target = byName[layer] else { throw Failure(message: "The brain has no layer \(layer).") }

        var warnings: [String] = []
        var manifest: LayerEvalManifest?
        var chosen = tasks
        if let continuing {
            guard let found = LayerEvalStore.manifest(continuing, env: env) else { throw Failure(message: "No eval \(continuing).") }
            guard found.layer == layer else { throw Failure(message: "The eval \(continuing) is of \(found.layer), not \(layer).") }
            manifest = found
            // Only the eval's starting tasks: its task population never changes.
            chosen = found.tasks.compactMap { ControlTasks.load($0, env: env) }
            let missing = found.tasks.count - chosen.count
            if missing > 0 { warnings.append("\(missing) of the eval's tasks are gone from ~/.akit/lab/evals/tasks and are left out.") }
        }
        guard !chosen.isEmpty else { throw Failure(message: "Pick at least one task.") }
        // A task whose repository is gone from this Mac is blocked by itself, not counted as
        // another repository.
        let gone = chosen.filter { !$0.repositoryExists }
        chosen.removeAll { !$0.repositoryExists }
        guard !chosen.isEmpty else {
            throw Failure(message: "The repositories of these tasks are gone from this Mac: "
                              + Set(gone.map(\.mainFolder.path)).sorted().joined(separator: ", ") + ".")
        }
        // Worktrees of one repository count as one (also after a worktree is removed); its main
        // folder names the project.
        let repositories = Set(chosen.map(\.mainFolder))
        guard repositories.count == 1, let repo = repositories.first else {
            throw Failure(message: "One eval takes the tasks of one repository for now; these come from "
                              + repositories.map(\.lastPathComponent).sorted().joined(separator: ", ") + ".")
        }

        // The brain must be committed where the layer comes from, so the eval names its commit.
        let closure = Brain.requiredClosure(of: layer, in: byName).sorted()
        let skills = Set(closure.flatMap { byName[$0]?.skills.map(\.name) ?? [] }).sorted()
        let paths = closure.map { "layers/\($0)" } + skills.map { "skills/\($0)" }
        guard let status = await git(["status", "--porcelain", "--"] + paths, in: brainRoot, env: env),
              let commit = await git(["rev-parse", "HEAD"], in: brainRoot, env: env) else {
            throw Failure(message: "\(brainRoot.path) is not a git repository with a commit.")
        }
        guard status.isEmpty else {
            // "XY path" lines; the output is trimmed, so the first may have lost a leading space.
            let changed = status.split(separator: "\n")
                .map { String($0.split(separator: " ", maxSplits: 1).last ?? $0) }.prefix(5).joined(separator: ", ")
            throw Failure(message: "The brain has uncommitted changes in \(changed): commit or discard them first, so the eval names the commit it was rendered from.")
        }

        // Answers: explicit (an empty one keeps the default), then the project's, then defaults.
        let projectID = await ProjectRecords.projectID(for: repo, projectsRoot: projectsRoot, env: env)
        var values = ProjectRecords.savedAnswers(id: projectID, in: store)?.values ?? [:]
        for (field, value) in answers {
            if case .text(let text) = value, text.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            values[field] = value
        }

        let projectName = repo.lastPathComponent
        let full = try render(layers: [layer], role: .layer, of: layer, values: values, brain: brain, projectName: projectName)
        let required = target.requires.isEmpty ? nil
            : try render(layers: target.requires, role: .requiredOnly, of: layer, values: values, brain: brain, projectName: projectName)
        let layerOverlay = full.overlay
        let baseOverlay = required.flatMap { $0.overlay.entries.isEmpty ? nil : $0.overlay }
        if layerOverlay.hash == (baseOverlay ?? ControlOverlay()).hash {
            warnings.append("\(layer) renders nothing beyond its required layers here; both setups get the same files.")
        }
        let checks = LayerChecks.make(layer: layer, full: full, required: required, layerOverlay: layerOverlay, baseOverlay: baseOverlay,
                                      declared: Set(closure.flatMap { byName[$0]?.skills.map(\.name) ?? [] }))
        // Shared by every cell, so every cell of that setup would fail before its agent.
        warnings += checks.outsideProblems(layer: layer, home: env.homeDirectory).map { $0 + "; its cells won't start while it is there." }

        if let manifest {
            let hashes = (layer: manifest.setups.first { $0.layer?.role == .layer }?.layer?.overlayHash,
                          base: manifest.setups.first { $0.layer?.role == .requiredOnly }?.layer?.overlayHash)
            guard hashes.layer == layerOverlay.hash, hashes.base == baseOverlay?.hash else {
                throw Failure(message: "The layer changed since the eval \(manifest.id) (its rendered files differ); start a new eval.")
            }
            // Explicitly none in AKit's own repository: its agent may build or start AKit.
            if !ControlSetup.defaultDenied(repo: repo).isEmpty, manifest.setups.first?.denied == [] {
                warnings.append("The eval \(manifest.id) denies no commands in AKit's own repository: its agent may run make snapshot or "
                                + "make run against the real ~/.akit. Start a new eval to get the default denied commands.")
            }
            if let first = manifest.setups.first, first.agent != agent {
                warnings.append("The eval continues with its own agent: \(first.agent.harness.title) · \(first.agent.model) · \(first.agent.effort).")
            }
        }

        // Each base commit's tracked files, read from git: no clone, no tokens.
        var trees: [String: CloneFiles] = [:]
        var runnable: [ControlTask] = []
        var blocked: [String: String] = [:]
        for task in gone { blocked[task.id] = "Its repository is gone from this Mac (\(task.mainFolder.path))." }
        var notes: [String: [String]] = [:]
        var ownFiles: [String: String] = [:]
        var projectSkills: [String: [String]] = [:]
        let ownSkills = full.skills
        for task in chosen {
            let tree: CloneFiles
            if let known = trees[task.base] {
                tree = known
            } else {
                do {
                    tree = try await CloneFiles.fromTree(repo: repo, base: task.base, env: env)
                } catch {
                    blocked[task.id] = error.localizedDescription
                    continue
                }
                trees[task.base] = tree
            }
            for name in ownSkills where tree.has(skill: name) { projectSkills[name, default: []].append(String(task.base.prefix(7))) }
            var reason: String?
            for overlay in [baseOverlay, layerOverlay].compactMap({ $0 }) {
                if case .blocked(let why) = ControlOverlay.place(overlay, in: tree) {
                    reason = why
                    break
                }
            }
            if let reason {
                blocked[task.id] = reason
                continue
            }
            if case .writes(let writes, let placed) = ControlOverlay.place(layerOverlay, in: tree) {
                if !placed.isEmpty { notes[task.id] = placed }
                ownFiles[task.id] = writes.first { $0.kind == .agentsSection && $0.action == .append }?.path
            }
            runnable.append(task)
        }

        var overlap: [String] = []
        for name in ownSkills where homeSkills.contains(name) {
            overlap.append("\(name) is already installed in the home folder: the difference will look smaller than it is.")
        }
        for name in ownSkills {
            guard let bases = projectSkills[name] else { continue }
            let unique = bases.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            overlap.append("\(name) is already in the project (at \(unique.joined(separator: ", "))): the layer's copy is skipped there, so the difference will look smaller than it is.")
        }

        let evalID = manifest?.id ?? newID(layer: layer, at: now)
        let brainCommit = manifest?.brainCommit ?? commit
        var overlays: [String: ControlOverlay] = [layerOverlay.hash: layerOverlay]
        if let baseOverlay { overlays[baseOverlay.hash] = baseOverlay }
        let setups: [ControlSetup]
        let sanitySetup: ControlSetup?
        var sanityTasks: [ControlTask]
        if let manifest {
            setups = manifest.setups
            sanitySetup = manifest.sanity
            let ids = Set(runnable.map(\.id))
            sanityTasks = manifest.sanityTasks.compactMap { id in runnable.first { $0.id == id } }
            if sanityTasks.count < manifest.sanityTasks.count {
                warnings.append("\(manifest.sanityTasks.filter { !ids.contains($0) }.count) sanity tasks can't run now and are left out.")
            }
        } else {
            let baseline = LayerVariant(layer: layer, role: .requiredOnly, overlayHash: baseOverlay?.hash, evalID: evalID, brainCommit: brainCommit)
            let variant = LayerVariant(layer: layer, role: .layer, overlayHash: layerOverlay.hash, evalID: evalID, brainCommit: brainCommit)
            // The same denied commands on every setup, so the comparison stays fair.
            // Stored even when empty: an explicit "none" is not filled with the default later.
            let deny = explicit ?? ControlSetup.defaultDenied(repo: repo)
            setups = [ControlSetup(name: "without \(layer)", agent: agent, layer: baseline, denied: deny),
                      ControlSetup(name: "layer \(layer)", agent: agent, layer: variant, denied: deny)]
            sanitySetup = sanity ? ControlSetup(name: "read-only", agent: agent, readOnly: true, layer: baseline, denied: deny) : nil
            sanityTasks = sanity ? Array(runnable.prefix(sanityTaskCount)) : []
        }
        if sanitySetup == nil { sanityTasks = [] }
        return Prepared(evalID: evalID, layer: layer, setups: setups, sanitySetup: sanitySetup, sanityTasks: sanityTasks, overlays: overlays,
                        runnable: runnable, blocked: blocked, notes: notes, ownFiles: ownFiles, overlap: overlap, warnings: warnings + full.warnings,
                        brainCommit: brainCommit, values: values, continuing: manifest != nil,
                        // An older eval's setups name none: its cells get the default when queued.
                        denied: setups.first?.denied ?? ControlSetup.defaultDenied(repo: repo), checks: checks)
    }

    /// `<layer>-<yyyyMMdd-HHmm>-<4 hex>`.
    static func newID(layer: String, at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return "\(layer)-\(formatter.string(from: date))-\(UUID().uuidString.prefix(4).lowercased())"
    }

    /// One render for Claude Code into an overlay. Refuses a render with errors, and a layer
    /// that merges keys into a JSON file (v1: merging into the clone's file needs JSONMerge).
    static func render(layers: [String], role: LayerVariant.Role, of layer: String, values: [String: FieldValue], brain: Brain,
                       projectName: String) throws -> Rendered {
        let bundle = ProjectBundle.resolve(ProjectAnswers(layers: layers, values: values, targets: ["claude"]), brain: brain,
                                           projectName: projectName)
        let result = Render.render(bundle, forHome: false)
        guard result.errors.isEmpty else {
            let what = role == .layer ? layer : "the layers \(layer) requires"
            let hint = result.errors.contains { $0.contains(" is required by ") }
                ? " Set it in the layer's set (Error Analysis → Evals, or akit analysis control layer-set \(layer) answer FIELD=VALUE), "
                    + "with --answer, or answer it for the project in Brain → Set Up Project…." : ""
            throw Failure(message: "\(what.prefix(1).uppercased() + what.dropFirst()) can't be rendered: "
                              + result.errors.joined(separator: " ") + hint)
        }
        if let merged = result.outputs.first(where: \.mergesJSON) {
            throw Failure(message: "\(merged.layers.joined(separator: ", ")) merges keys into \(merged.path) (MCP servers or Claude Code settings); "
                              + "layer evals can't merge JSON into a clone yet, so this layer can't be evaluated.")
        }
        var overlay = ControlOverlay(layer: layer, role: role.rawValue, layers: result.layers)
        let skillsPrefix = ProjectBundle.skillsFolder + "/"
        for output in result.outputs {
            switch output.content {
            case .link(let target):
                guard output.path == ".claude/skills" else {
                    throw Failure(message: "The render links \(output.path), which layer evals don't know how to place.")
                }
                overlay.addLink(output.path, to: target)
            case .data(let data):
                let lower = output.path.lowercased()
                if lower == "claude.md", output.layers.isEmpty { continue }  // the shim; the overlay decides about CLAUDE.md
                if lower == "agents.md" {
                    overlay.add(output.path, kind: .agentsSection, data: data)
                } else if output.path.hasPrefix(skillsPrefix) {
                    let name = output.path.dropFirst(skillsPrefix.count).split(separator: "/").first.map(String.init)
                    // A skill's script keeps its executable bit.
                    let source = name.flatMap { name in brain.skills.first { $0.name == name } }.map { skill in
                        skill.folder.appending(path: String(output.path.dropFirst(skillsPrefix.count + (name?.count ?? 0) + 1)))
                    }
                    let executable = source.map { FileManager.default.isExecutableFile(atPath: $0.path) } ?? false
                    overlay.add(output.path, kind: .skillFile, skill: name, data: data, executable: executable)
                } else if lower.hasSuffix(".md") {
                    overlay.add(output.path, kind: .markdown, data: data)
                } else {
                    overlay.add(output.path, kind: .file, data: data)
                }
            }
        }
        let own = result.skills.filter { $0.source == layer }.map(\.name)
        return Rendered(overlay: overlay, skills: role == .layer ? own : [], warnings: result.warnings,
                        rendered: result.skills.map { SetupCheck.Skill(name: $0.name, manual: $0.mode == .manual) },
                        files: role == .layer ? bundle.files.filter { $0.layer == layer } : [])
    }

    /// One render as an overlay, with what the setup check needs.
    struct Rendered {
        var overlay: ControlOverlay
        /// The layer's own skills (role `layer` only), for the overlap warning.
        var skills: [String]
        var warnings: [String]
        /// Every skill the render brings, with its mode.
        var rendered: [SetupCheck.Skill]
        /// The template outputs of the evaluated layer itself (role `layer` only), fields filled.
        var files: [ProjectBundle.File]
    }

    private static func git(_ arguments: [String], in folder: URL, env: HarnessEnvironment) async -> String? {
        guard let result = await ProcessRunner.run(env.findExecutable("git") ?? URL(filePath: "/usr/bin/git"),
                                                   arguments: ["-C", folder.path] + arguments, environment: env.gitVariables,
                                                   timeout: 60),
              result.succeeded else { return nil }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
