import AKitBrain
import AKitFoundation
import AKitHarnesses
import AKitInsights
import AKitProjectSetup
import AKitSkills
import Foundation

/// `akit move skill NAME --to PROJECT[,PROJECT…]`: Move to Project (docs/design/layers.md,
/// "Move a skill to a project"). Prints the plan; `--yes` carries it out.
extension AKitCLI {
    static let moveUsage = "Use: akit move skill NAME --to PROJECT[,PROJECT…] [--mode auto|manual] [--local-only yes|no|auto] "
        + "[--keep-global] [--keep-own] [--yes]"

    static func move(_ args: inout Arguments, localOnly localOnlyText: String?, yes: Bool, brainRoot: URL, env: HarnessEnvironment,
                     cwd: URL, projectsRoot: URL, hostName: String, installedTargets: [String], hardware: String?,
                     out: (String) -> Void, err: (String) -> Void, trash: @escaping (URL) throws -> URL?) async throws -> Int32 {
        let to = args.values("--to"), modeText = args.value("--mode")
        let keepGlobal = args.flag("--keep-global"), keepOwn = args.flag("--keep-own")
        let kind = args.positional(), name = args.positional()
        try args.finish()
        guard kind == "skill", let name, !to.isEmpty else { throw Failure(message: moveUsage) }
        var mode: LayerSkill.Mode?
        if let modeText {
            guard let chosen = LayerSkill.Mode(rawValue: modeText), chosen != .off else { throw Failure(message: "--mode is auto or manual.") }
            mode = chosen
        }
        let localOnly: Bool?
        switch localOnlyText {
        case nil, "auto": localOnly = nil
        case "yes": localOnly = true
        case "no": localOnly = false
        default: throw Failure(message: "--local-only is yes, no or auto.")
        }
        guard let brain = Brain.load(from: brainRoot) else {
            throw Failure(message: "No brain repo at \(brainRoot.path). Move to Project goes through the brain; create one with akit init.")
        }
        let home = env.homeDirectory
        let machine = MachineProfile.load(home: home)
        if let problem = machine.problem { err("akit: \(problem)") }
        let context = await skillContext(brainRoot: brain.root, env: env, projectsRoot: projectsRoot, hostName: hostName,
                                         installedTargets: installedTargets)
        let installed = context.installed, folders = context.projectFolders
        let recorded = Set(BrainRemove.savedAnswers(brain: brain, home: home).map(\.id))
        var targets: [SkillMove.Target] = []
        for argument in to.flatMap({ $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }) where !argument.isEmpty {
            let path = resolve(argument, cwd: cwd, env: env)
            guard FileWalk.isDirectory(path) || folders[argument] != nil || recorded.contains(argument) else {
                throw Failure(message: "--to \(argument): no such folder, and no project with that id on this Mac or in the brain.")
            }
            let target: SkillMove.Target = FileWalk.isDirectory(path)
                ? .init(id: await ProjectRecords.projectID(for: path, projectsRoot: projectsRoot, env: env), folder: path,
                        localOnly: localOnly, keepOwn: keepOwn)
                : .init(id: argument, folder: folders[argument], localOnly: localOnly, keepOwn: keepOwn)
            if !targets.contains(where: { $0.id == target.id }) { targets.append(target) }
        }

        // The mode: auto when the model called it (D4), else its mode now.
        var calls: SkillCallsReport?
        // Read-only: the move never imports or migrates the index (akit stats skill imports first).
        if let database = IndexSchema.openReadOnly(InsightsPaths(env: env).database) {
            calls = try? SkillCalls.report(database, skill: name, brain: brain, env: env, hardware: hardware)
        }
        let modelCalls = (calls?.projects.reduce(0) { $0 + $1.modelCalls } ?? 0) + (calls?.otherMacs.modelCalls ?? 0)
        let chosenMode = mode ?? (modelCalls > 0 ? .auto : SkillMove.currentMode(name, brain: brain, installed: installed))

        let plan = SkillMove.plan(name: name, targets: targets, mode: chosenMode, keepGlobal: keepGlobal, brain: brain, context: context)
        out(moveText(plan, calls: calls, modeGiven: mode != nil, home: home))
        guard plan.canApply else { return 1 }
        guard yes else {
            out("Run again with --yes to move it.")
            return 0
        }
        do {
            let outcome = try await SkillMove.apply(plan, brain: brain, env: env, trash: trash)
            out(moveOutcomeText(outcome, plan: plan))
            return 0
        } catch {
            out(moveOutcomeText(error.outcome, plan: plan))
            throw Failure(message: error.message)
        }
    }

    /// What a skill plan reads besides the brain: every skill the installed harnesses see, and the
    /// projects on this Mac by id (every project a harness or the projects folder knows, main
    /// checkouts first).
    static func skillContext(brainRoot: URL, env: HarnessEnvironment, projectsRoot: URL, hostName: String,
                             installedTargets: [String]) async -> SkillMove.Context {
        let home = env.homeDirectory
        let machine = MachineProfile.load(home: home)
        let installations = HarnessCatalog.detectAll(in: env)
        let known = SkillScanner.projects(installations: installations, extraProjects: ProjectFinder.projects(inRoots: [projectsRoot]), in: env)
        let installed = SkillScanner.scan(installations: installations, projects: known, in: env)
        var found: [String: [URL]] = [:]
        for folder in known { found[await ProjectRecords.projectID(for: folder, projectsRoot: projectsRoot, env: env), default: []].append(folder) }
        let detected = installations.compactMap { ProjectAnswers.target(for: $0.id) }
        return SkillMove.Context(env: env, store: ProjectStore.current(brain: brainRoot, home: home, machine: machine),
                                 homeID: ProjectRecords.homeID(hostName: hostName, machineName: machine.homeName), installed: installed,
                                 targets: installedTargets.isEmpty ? detected : installedTargets,
                                 projectFolders: found.compactMapValues { GitCheckout.preferred($0) },
                                 piAgentDirSetting: env.variables["PI_CODING_AGENT_DIR"])
    }

    /// The plan, grouped by place: the brain, each project, the core layer, the home folder.
    static func moveText(_ plan: SkillMove.Plan, calls: SkillCallsReport?, modeGiven: Bool, home: URL) -> String {
        let adding = plan.adding.count
        var lines = ["Move \(plan.name) (mode \(plan.mode.rawValue)\(modeGiven ? "" : ", from its calls and current mode")) into "
                     + "\(adding) project\(adding == 1 ? "" : "s")"
                     + (plan.keepGlobal ? "; core and the home folder keep it (--keep-global)." : "; then out of the core layer and this Mac's home folder.")]
        if let calls {
            let shown = calls.projects.prefix(5).map { "\($0.project ?? "unbound") \($0.calls)" }
            lines.append("Calls in the last \(calls.window.days) days on this Mac: " + (shown.isEmpty ? "none" : shown.joined(separator: ", "))
                         + (calls.otherMacs.calls > 0 ? "; other Macs \(calls.otherMacs.calls)" : "") + " (akit stats skill \(plan.name)).")
        }
        if plan.brainImport != nil, let source = plan.source {
            lines.append("Brain: copy \(SkillMove.shown(source.folder, home: home)) into skills/\(plan.name) (in no layer), committed.")
        } else {
            lines.append("Brain: skills/\(plan.name) is there.")
        }
        for part in plan.parts {
            let place = "Project \(part.id)" + (part.folder.map { " (\(SkillMove.shown($0, home: home)))" } ?? "")
            switch part.state {
            case .answersOnly:
                lines.append("\(place): not on this Mac; \(plan.name) is added to its answers only, and Set Up Project on the Mac that has it renders it.")
            case .blocked(let reason):
                lines.append("\(place): blocked: \(reason)" + (part.ownFolder != nil ? " (--keep-own keeps the project's copy)" : ""))
            case .keepOwn:
                lines.append("\(place): keeps its own \(plan.name); nothing is written there.")
            case .add:
                let why = part.target.localOnly != nil ? "as asked" : part.isNew ? "a new project" : "its choice"
                let files = (part.localOnly ? "local only (hidden from git)" : "committed to git") + ", \(why)"
                lines.append("\(place): \(part.isNew ? "first set up, with only this skill" : "\(plan.name) added to its answers"); \(files).")
                if part.isPresent { lines.append("  already there; only the answers change") }
                for change in part.changes where change.kind != .same {
                    lines.append("  \(change.kind == .create ? "+" : change.kind == .remove ? "-" : "~") \(change.path)")
                }
                if !part.worktrees.isEmpty {
                    lines.append("  links into \(part.worktrees.count) worktree\(part.worktrees.count == 1 ? "" : "s"): "
                                 + part.worktrees.map { SkillMove.shown($0, home: home) }.joined(separator: ", "))
                }
                let waiting = part.plan?.changes.filter { part.excluded.contains($0.path) && $0.kind != .same }.count ?? 0
                if waiting > 0 { lines.append("  \(waiting) other pending change\(waiting == 1 ? "" : "s") wait for akit apply / Set Up Project") }
            }
        }
        if let edit = plan.coreEdit {
            lines.append("Core: \(plan.name) leaves layers/core/layer.yaml (committed after the projects):")
            lines += TextDiff.unified(TextDiff.lines(from: edit.before, to: edit.after)).map { "  " + $0 }
        }
        if !plan.keepGlobal {
            var trash = plan.home.map { _ in plan.homePaths.sorted().map { "~/" + $0 } } ?? []
            trash += plan.trashSource.map { SkillMove.shown($0, home: home) }
            trash += plan.extraCopies.map { SkillMove.shown($0.folder, home: home) }
            if !trash.isEmpty { lines.append("Home folder, to the Trash: \(trash.joined(separator: ", ")).") }
        }
        lines += plan.blockers.map { "blocked: \($0)" }
        lines += plan.warnings.map { "warning: \($0)" }
        lines += plan.notes.map { "note: \($0)" }
        return lines.joined(separator: "\n")
    }

    static func moveOutcomeText(_ outcome: SkillMove.Outcome, plan: SkillMove.Plan) -> String {
        var lines: [String] = []
        if outcome.imported { lines.append("Copied \(plan.name) into the brain's library.") }
        for (id, result) in outcome.projects {
            lines.append("\(id): written \(result.written.count)" + (result.notes.isEmpty ? "." : "; " + result.notes.joined(separator: " ")))
        }
        if !outcome.answersSaved.isEmpty {
            lines.append("Added \(plan.name) to the answers of \(outcome.answersSaved.joined(separator: ", ")) (set them up on their Mac).")
        }
        if outcome.coreChanged { lines.append("Took \(plan.name) out of the core layer.") }
        if let home = outcome.home { lines.append("Home folder: removed \(home.removed.count) file\(home.removed.count == 1 ? "" : "s").") }
        if !outcome.trashed.isEmpty { lines.append("To the Trash: \(outcome.trashed.joined(separator: ", ")).") }
        lines += outcome.notes
        return lines.joined(separator: "\n")
    }
}
