import AKitBrain
import AKitErrorAnalysis
import AKitFoundation
import AKitInsights
import AKitProjectSetup
import Foundation

/// The `akit` command: the brain and project setup for agents and terminals. Same rules
/// as the app: checks before writing, backups, the Trash for removals, answers in the brain
/// (or, on a work Mac, in a local folder that never reaches the brain).
public enum AKitCLI {
    public static let usage = """
        akit — harness layers from your brain repo (~/.akit/registry)

        Setup (a new Mac; asks a few questions, Enter takes the default):
          akit setup [--repo REPO] [--yes] [--skip-home]
                                          Get your brain (clone REPO, or $AKIT_BRAIN_REPO) or create
                                          one, remember the projects folder, put core into ~,
                                          set up session capture (akit insights install)

        Brain:
          akit init                       Create a brain: core layer with the /akit skill, git repo
          akit check                      Read every layer and skill; list problems (exit 1 if any)
          akit layers [--json]            Layers with their fields, skills and files
          akit skills                     Skills in the brain
          akit sync                       Import sessions, publish this Mac's usage summaries, pull the
                                          other Macs' brain commits, push this one's

        Projects (PROJECT is a folder; default: the current one):
          akit answers [PROJECT]          Saved answers for the project (JSON)
          akit plan [PROJECT] [ANSWERS]   What would change, with diffs (exit 1 if it can't apply)
          akit apply [PROJECT] [ANSWERS] [--include PATH]... [--exclude PATH]... [--include-unmanaged]
                                          Write it: backup first, removals to the Trash, answers
                                          saved in the brain (work Mac: locally). Files AKit didn't write, or edited
                                          by hand since, are skipped unless --include PATH
                                          (--include-unmanaged: every file AKit didn't write).
                                          AGENTS.md, CLAUDE.md and other layer templates follow
                                          the layers until the project edits them; after that a
                                          newer layer version is taken only with --include PATH.
                                          .mcp.json and .claude/settings.json are merged key by
                                          key: the project's keys stay, a key the project removed
                                          isn't added back, env/headers values are shown masked.

        Remove (shows what happens; add --yes to do it; folders go to the Trash, one commit each):
          akit remove layer NAME              refused while other layers require it; dropped from
                                              saved project answers (re-apply those projects)
          akit remove skill NAME              refused while a layer lists it
          akit remove skill NAME --from LAYER only from that layer's skills list
          akit remove project [PROJECT|--home] [--keep-files]
                                              trashes the files AKit wrote there (not hand-edited
                                              ones), takes AKit's keys out of .mcp.json and
                                              .claude/settings.json, then forgets the project in
                                              the brain

        Home (the core layer into ~, for every harness on this Mac):
          akit plan --home  /  akit apply --home [--include-unmanaged]

        Sessions (a local index in ~/.akit/index; never in the brain, works without one):
          akit sessions import [--json] [--quiet]
                                          Read new Claude Code and Pi session lines into the index:
                                          counts, sizes and skill use, never message text; then bind
                                          sessions to projects (hook, folder, git worktrees, siblings)
          akit stats [--project ID|PATH | --all] [--days N] [--top N] [--details] [--bindings LIST] [--json]
                                          Every listed skill: its owner (layer, plugin, hand-installed,
                                          built-in), ≈ tokens and ≈ context space (tokens × requests),
                                          sessions and days listed, calls by the model and the user.
                                          Default: all sessions on this Mac, last 30 days, top 10 (all
                                          with --details). --project: the sessions bound to it at LIST
                                          (default exact,high,medium). Imports new lines first
          akit stats bindings [--days N] [--bindings LIST] [--json]
                                          How sessions are bound to projects: per method and
                                          confidence, the last N (30) days' share bound in LIST (default
                                          exact,high,medium; add low for unconfirmed siblings), a
                                          sample of unbound folders and suggested path templates.
                                          Orca and herdr worktrees are built in; add others to
                                          ~/.akit/insights.json: {"pathTemplates": ["~/.tool/trees/{repo}/*"]}
          akit stats changes [--project ID|PATH | --all] [--json]
                                          First-request context (recorded tokens) 14 days before and
                                          after each akit apply and mark, with the same harness version
                                          and model (5 sessions a side), and the skill listing's change;
                                          calibrates k (characters per token) for the ≈ sizes. A home
                                          apply or a mark counts every session, a project apply the
                                          project's. --project: that project's applies only
          akit stats mark "<note>" [--at DATE]
                                          Note a change made by hand (a plugin disabled, a setting) as a
                                          before/after anchor. DATE: 2026-09-26 or 2026-09-26T14:30 (local)
          akit stats --debug [--session ID] [--json]
                                          Per session (default: the latest 20): skills listed, skill
                                          calls by the model, the user and subagents, largest tool
                                          outputs, first-request context. Imports new lines first
          akit insights install [--only claude|pi|launchd] [--dry-run] [--yes]
                                          Capture sessions as they start: the akit Claude plugin (in
                                          the brain, installed by Claude Code), a Pi extension, and an
                                          hourly import (launchd; needs make install-cli).
                                          Shows every write and command; --yes does it
          akit insights status [--json]   Plugin versions (brain, installed, this akit), Pi extension,
                                          hourly import, last spool line, last import
          akit insights uninstall [--yes] Uninstall the plugin on this Mac, unload the hourly import;
                                          extension and agent to the Trash
          akit insights publish [--dry-run]
                                          Import, then commit this Mac's usage summaries to the brain
                                          (counts per day, last 120 days): insights/machines/<id>.json
                                          and projects/<project>/usage/<id>.json. A work Mac commits only
                                          insights/machines/<pseudonym>.json with brain skills' counts;
                                          its project summaries stay on it. akit sync does this too

        Recommendations (auto skills the model never calls; counts from this Mac and the other Macs' summaries):
          akit recommend [--project ID|PATH | --all] [--details] [--min-sessions N] [--min-days D] [--bindings LIST] [--json]
                                          Skills listed with their description in ≥ N (20) sessions on ≥ D (14)
                                          distinct days and never called by the model anywhere (other Macs,
                                          subagents, Pi), counted from their current description (and, in a
                                          project, from when their layer arrived there); sorted by ≈ context space. A layer skill gets a patch
                                          (mode: manual), anything else advice. A plugin is judged as a whole:
                                          disable it when the model called none of its skills, else at most
                                          one note on its unused ones. Imports new lines first
          akit recommend apply ID [--yes] Show the layer.yaml patch; --yes commits it in the brain. Then run
                                          akit plan/apply in the projects using the layer
          akit recommend dismiss ID [--yes]
                                          Layer skill: keep_auto: true in its layer.yaml (committed). Advice:
                                          hidden until its ≈ context space doubles

        Lab (measure agent sessions; ~/.akit/lab, never in the brain):
          akit lab analyze SESSION        Calls, fresh tokens, context rent, friction and commits of one
                                          Claude Code session. akit lab --help lists the rest
          akit analysis notes [SESSION]   Error analysis: a reviewed session's outcome, verified notes
                                          and advice. akit analysis --help lists the rest

        This Mac (~/.akit/machine.json, never in the brain):
          akit machine                    Show whether this is a personal or a work Mac
          akit machine work [--name NAME] Work Mac: answers and locks of projects stay in
                                          ~/.akit/local/projects, nothing about them reaches the
                                          brain. NAME replaces the host name (default: work)
          akit machine personal           Back to keeping answers in the brain

        ANSWERS (start from the saved answers, or empty):
          --layers a,b          Layers to use (replaces the list)
          --set field=value     A field value; bool: true/false, multi: a,b (repeatable)
          --unset field         Remove a value
          --targets claude,pi   Harnesses (default: saved, else the installed ones)
          --answers FILE        Answers JSON ({"layers":[],"values":{},"targets":[]}) instead

        Options:
          --brain DIR           Brain folder (default: ~/.akit/registry)
          AKIT_PROJECTS_ROOT    Projects folder for ids of projects without a git remote
                                (default: the app's setting, else ~/Projects)
          --help
        """

    struct Failure: Error {
        let message: String
    }

    /// Runs one command. `out`/`err` receive text; returns the exit code.
    public static func run(_ arguments: [String], env: HarnessEnvironment, cwd: URL, projectsRoot: URL? = nil,
                           hostName: String = ProcessInfo.processInfo.hostName,
                           installedTargets: [String] = [], out: (String) -> Void, err: (String) -> Void,
                           trash: (URL) throws -> URL? = Trash.move,
                           ask: ((String) -> String?)? = nil, preferences: Onboarding.Preferences? = nil,
                           input: () -> Data = { Data() }, runner: CommandRunner? = nil,
                           hardwareHash: () -> String? = MachineProfile.currentHardwareHash) async -> Int32 {
        // Hidden; the akit binary runs it before everything else (main.swift). Silent, exit 0.
        if arguments.first == "record-session" {
            RecordSession.run(harness: RecordSession.harness(in: arguments), stdin: input(), env: env)
            return 0
        }
        // Run by the Pi extension; the akit binary also runs it first (main.swift).
        if arguments.first == "rate" {
            do {
                try RateRun.run(arguments: Array(arguments.dropFirst()), stdin: input(), env: env)
                return 0
            } catch {
                err("akit rate: \(error.message)")
                return 1
            }
        }
        let projectsRoot = projectsRoot ?? env.homeDirectory.appending(path: "Projects")
        do {
            // Lab has its own options (--repo, --json, …); none of the brain's apply.
            if arguments.first == "lab" {
                return try await lab(Array(arguments.dropFirst()), env: env, cwd: cwd, out: out, err: err, trash: trash)
            }
            if arguments.first == "analysis" {
                return try await analysis(Array(arguments.dropFirst()), env: env, cwd: cwd, projectsRoot: projectsRoot, out: out, err: err,
                                          trash: trash)

            }
            var args = Arguments(arguments)
            if args.flag("--help") || args.flag("-h") || args.isEmpty {
                out(usage)
                return 0
            }
            // Options first, so their values are never taken for the command or the project.
            let options = Options(brain: args.value("--brain"), json: args.flag("--json"), answersFile: args.value("--answers"),
                                  layers: args.value("--layers"), targets: args.value("--targets"),
                                  set: args.values("--set"), unset: args.values("--unset"),
                                  include: args.values("--include"), exclude: args.values("--exclude"),
                                  home: args.flag("--home"), includeUnmanaged: args.flag("--include-unmanaged"),
                                  yes: args.flag("--yes"), keepFiles: args.flag("--keep-files"), from: args.value("--from"),
                                  repo: args.value("--repo"), skipHome: args.flag("--skip-home"), name: args.value("--name"))
            let command = args.positional()
            if command == "sessions" {
                try refuseProjectOptions(options, command: "sessions")
                return try await sessions(&args, options: options, env: env, projectsRoot: projectsRoot, out: out)
            }
            if command == "stats" {
                try refuseProjectOptions(options, command: "stats")
                return try await stats(&args, options: options, env: env, cwd: cwd,
                                       projectsRoot: projectsRoot, hostName: hostName, hardwareHash: hardwareHash,
                                       runner: runner, out: out, err: err)
            }
            if command == "insights" {
                try refuseProjectOptions(options, command: "insights")
                return try await insights(&args, options: options, env: env, cwd: cwd,
                                          projectsRoot: projectsRoot, hostName: hostName,
                                          hardwareHash: hardwareHash, out: out, err: err, trash: trash, runner: runner)
            }
            if command == "recommend" {
                try refuseProjectOptions(options, command: "recommend")
                return try await recommend(&args, options: options, env: env, cwd: cwd,
                                           projectsRoot: projectsRoot, hostName: hostName, hardwareHash: hardwareHash,
                                           runner: runner, out: out, err: err)
            }
            if command == "remove" {
                let kind = args.positional(), name = args.positional()
                try args.finish()
                return try await remove(kind: kind, name: name, options: options, env: env, cwd: cwd, projectsRoot: projectsRoot,
                                        hostName: hostName, installedTargets: installedTargets, out: out, trash: trash)
            }
            let projectArgument = args.positional()
            try args.finish()
            let brainRoot = brainRoot(options, cwd: cwd, env: env)
            if options.name != nil, command != "machine" { throw Failure(message: "--name only goes with akit machine.") }
            if command != "machine", let problem = MachineProfile.load(home: env.homeDirectory).problem { err("akit: \(problem)") }
            if command == "machine" {
                return try machine(projectArgument, options: options, brainRoot: brainRoot, env: env, hostName: hostName,
                                   hardware: hardwareHash(), out: out)
            }
            if command == "setup" {
                if projectArgument != nil { throw Failure(message: "akit setup takes no folder; use --brain DIR.") }
                let prefs = preferences ?? Onboarding.Preferences(projectsRoot: { nil }, setProjectsRoot: { _ in })
                let repo = options.repo ?? env.variables["AKIT_BRAIN_REPO"].flatMap { $0.isEmpty ? nil : $0 }
                let failure: String? = await withoutActuallyEscaping(out) { (say) async -> String? in
                    do {
                        try await Onboarding.run(.init(brainRepo: repo, skipHome: options.skipHome, cwd: cwd), root: brainRoot, env: env,
                                                 io: .init(ask: options.yes ? nil : ask, say: say), preferences: prefs,
                                                 hostName: hostName, installedTargets: installedTargets, trash: trash, runner: runner)
                        return nil
                    } catch {
                        return error.localizedDescription
                    }
                }
                if let failure { throw Failure(message: failure) }
                return 0
            }
            if command == "init" {
                if projectArgument != nil { throw Failure(message: "akit init takes no folder; use --brain DIR.") }
                do {
                    try await BrainSetup.create(at: brainRoot, env: env)
                } catch {
                    throw Failure(message: error.message)
                }
                out("""
                    Created a brain in \(brainRoot.path): the core layer with the /akit skill, committed.
                    Put core into this Mac's home folder: akit apply --home
                    To share it between Macs, push it to a private repo:
                      git -C \(brainRoot.path) remote add origin <url> && git -C \(brainRoot.path) push -u origin main
                    """)
                return 0
            }
            guard let brain = Brain.load(from: brainRoot) else {
                throw Failure(message: "No brain repo at \(brainRoot.path). Create it in AKit (Brain → Create Brain Repo) or pass --brain.")
            }

            switch command {
            case "check":
                return check(brain, out: out)
            case "layers":
                out(options.json ? try layersJSON(brain) : layersText(brain))
                return 0
            case "skills":
                out(brain.skills.map { "\($0.name)\t\($0.description)" }.joined(separator: "\n"))
                return 0
            case "sync":
                if projectArgument != nil { throw Failure(message: "akit sync takes no folder; use --brain DIR.") }
                // Import, publish this Mac's summaries, then pull and push (`InsightsSync`, as the app's Sync).
                // A publish that fails or is refused (work Mac) is only a warning: the pull and push still run.
                let published = await InsightsSync.publish(env: env, brain: brain, projectsRoot: projectsRoot, hostName: hostName,
                                                           hardware: hardwareHash())
                if let problem = published.problem { err("akit: usage summaries not published: \(problem)") }
                if let outcome = published.outcome, !outcome.committed.isEmpty || !outcome.notes.isEmpty { out(publishText(outcome)) }
                let outcome: BrainSync.Outcome
                do {
                    outcome = try await BrainSync.sync(brain.root, env: env)
                } catch {
                    throw Failure(message: error.message)
                }
                let changed = await BrainSync.status(of: brain.root, env: env, fetch: false)?.changed ?? []
                out(syncText(outcome, changed: changed, brain: Brain.load(from: brain.root)))
                return 0
            case "answers", "plan", "apply":
                if options.home, projectArgument != nil { throw Failure(message: "--home and a project folder don't go together.") }
                let project = options.home ? env.homeDirectory : resolve(projectArgument ?? ".", cwd: cwd, env: env)
                guard FileManager.default.fileExists(atPath: project.path) else { throw Failure(message: "No folder at \(project.path).") }
                let store = ProjectStore.current(brain: brain.root, home: env.homeDirectory)
                let id = options.home ? homeID(hostName: hostName, env: env)
                    : await ProjectRecords.projectID(for: project, projectsRoot: projectsRoot, env: env)
                if command == "answers" {
                    let saved = ProjectRecords.savedAnswers(id: id, in: store)
                    out(saved.map(encode) ?? "No saved answers for \(id).")
                    return saved == nil ? 1 : 0
                }
                if options.home, options.layers != nil || options.answersFile != nil {
                    throw Failure(message: "The home folder always gets the core layer; --layers and --answers don't apply.")
                }
                var answers = try readAnswers(options, id: id, brain: brain, store: store, cwd: cwd, env: env,
                                              installedTargets: installedTargets)
                if options.home {
                    guard brain.layers.contains(where: { $0.name == "core" }) else { throw Failure(message: "The brain has no core layer.") }
                    answers.layers = ["core"]
                }
                let include = Set(options.include), exclude = Set(options.exclude)
                let plan = ProjectSetup.plan(project: project, id: id, answers: answers, brain: brain, store: store, forHome: options.home)
                out(planText(plan))
                guard plan.canApply else { return 1 }
                guard command == "apply" else { return 0 }
                let skipped = Set(plan.changes.filter { change in
                    change.kind == .update && (change.editedSinceRender || (change.replacesUnmanaged && !options.includeUnmanaged))
                }.map(\.path)).subtracting(include).union(exclude)
                // The project's own files take the layers' version only when asked by path.
                let suggested = Set(plan.changes.filter { $0.kind == .suggest }.map(\.path))
                let own = Set(plan.changes.filter { $0.kind == .own }.map(\.path))
                let taken = suggested.union(own).intersection(include).subtracting(exclude)
                let outcome: ProjectSetup.Outcome
                do {
                    outcome = try await ProjectSetup.apply(plan, excluding: skipped, accepting: taken, brain: brain, home: env.homeDirectory, env: env, trash: trash)
                } catch {
                    throw Failure(message: error.message)
                }
                out(outcomeText(outcome, skipped: skipped.intersection(plan.changes.filter { $0.kind != .same && $0.kind != .own }.map(\.path))
                    .union(suggested.subtracting(taken)), plan: plan))
                return 0
            default:
                throw Failure(message: "Unknown command “\(command ?? "")”. Run akit --help.")
            }
        } catch let failure as Failure {
            err("akit: \(failure.message)")
            return 2
        } catch {
            err("akit: \(error.localizedDescription)")
            return 2
        }
    }

    // MARK: - Machine

    /// This Mac's home id: the machine name when set, else the host name.
    private static func homeID(hostName: String, env: HarnessEnvironment) -> String {
        ProjectRecords.homeID(hostName: hostName, machineName: MachineProfile.load(home: env.homeDirectory).homeName)
    }

    private static func machine(_ kind: String?, options: Options, brainRoot: URL, env: HarnessEnvironment, hostName: String,
                                hardware: String?, out: (String) -> Void) throws -> Int32 {
        let home = env.homeDirectory
        var profile = MachineProfile.load(home: home)
        guard let kind else {
            let store = ProjectStore.current(brain: brainRoot, home: home)
            let named = profile.name.map { " “\($0)”" } ?? ""
            var lines = [profile.isWork
                ? "Work Mac\(named). Answers and locks of projects stay in \(store.root.path); nothing about them goes into the brain."
                : "Personal Mac\(named). Answers and locks of projects are saved and committed in the brain under projects/."]
            if profile.isWork, let pseudonym = profile.pseudonym {
                lines.append("Its usage summaries go to the brain as \(pseudonym): counts of brain skills only.")
            }
            if let problem = profile.problem { lines.append(problem) }
            out(lines.joined(separator: "\n"))
            return 0
        }
        guard let chosen = MachineProfile.Kind(name: kind) else { throw Failure(message: "Use: akit machine [work [--name NAME] | personal]") }
        // A new name when given; switching kind drops the old one (work defaults to "work").
        let given = options.name.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        let name = given ?? (chosen == profile.kind && profile.problem == nil ? profile.name : nil)
        profile = MachineProfile(kind: chosen, name: chosen == .work ? (name ?? "work") : name)
        do {
            out(try MachineProfile.change(to: profile, brain: brainRoot, home: home, hostName: hostName, hardware: hardware)
                .joined(separator: "\n"))
        } catch {
            throw Failure(message: "Couldn't save \(MachineProfile.file(home: home).path): \(error.localizedDescription)")
        }
        return 0
    }

    // MARK: - Brain

    static func syncText(_ outcome: BrainSync.Outcome, changed: [String], brain: Brain?) -> String {
        func commits(_ n: Int) -> String { "\(n) commit\(n == 1 ? "" : "s")" }
        var lines: [String] = []
        switch (outcome.pulled, outcome.pushed) {
        case (0, 0): lines.append("The brain is in sync with its remote.")
        case (let pulled, 0): lines.append("Pulled \(commits(pulled)).")
        case (0, let pushed): lines.append("Pushed \(commits(pushed)).")
        case (let pulled, let pushed): lines.append("Pulled \(commits(pulled)), pushed \(commits(pushed)).")
        }
        if outcome.changesCore(in: brain) { lines.append("The core layer changed: run akit apply --home to update this Mac's home folder.") }
        if !changed.isEmpty { lines.append("Not committed, so not synced: \(changed.joined(separator: ", "))") }
        return lines.joined(separator: "\n")
    }

    private static func check(_ brain: Brain, out: (String) -> Void) -> Int32 {
        var lines = ["Brain \(brain.root.path): \(brain.layers.count) layers, \(brain.skills.count) skills"]
        if brain.problems.isEmpty {
            lines.append("No problems.")
        } else {
            for problem in brain.problems {
                lines.append("- \(problem.layer.map { "layers/\($0): " } ?? "")\(problem.message)")
            }
        }
        out(lines.joined(separator: "\n"))
        return brain.problems.isEmpty ? 0 : 1
    }

    private static func layersText(_ brain: Brain) -> String {
        brain.layers.map { layer in
            var lines = ["\(layer.name)\(layer.description.isEmpty ? "" : " — \(layer.description)")"]
            if !layer.requires.isEmpty { lines.append("  requires: \(layer.requires.joined(separator: ", "))") }
            if !layer.conflicts.isEmpty { lines.append("  conflicts: \(layer.conflicts.joined(separator: ", "))") }
            for field in layer.fields {
                var line = "  field \(field.id) (\(field.kind.rawValue)\(field.required ? ", required" : "")): \(field.prompt)"
                if !field.options.isEmpty { line += " [\(field.options.joined(separator: ", "))]" }
                if let value = field.defaultValue { line += " default \(value.display)" }
                lines.append(line)
            }
            for skill in layer.skills {
                lines.append("  skill \(skill.name) \(skill.mode.rawValue)\(skill.keepAuto ? " (keep auto)" : "")\(skill.when.isEmpty ? "" : " when \(skill.when.map(\.description).joined(separator: " and "))")")
            }
            for file in layer.files {
                lines.append("  file \(file.template) → \(file.to)\(file.when.isEmpty ? "" : " when \(file.when.map(\.description).joined(separator: " and "))")")
            }
            return lines.joined(separator: "\n")
        }
        .joined(separator: "\n\n")
    }

    private struct LayerInfo: Encodable {
        struct Field: Encodable { let id, prompt, type: String; let required: Bool; let options: [String]; let `default`: FieldValue? }
        struct Skill: Encodable { let name, mode: String; let when: [String]; let keepAuto: Bool }
        struct File: Encodable { let template, to: String; let when: [String] }
        let name, description: String
        let requires, conflicts: [String]
        let fields: [Field]
        let skills: [Skill]
        let files: [File]
        let folder: String
        let problems: [String]
    }

    private static func layersJSON(_ brain: Brain) throws -> String {
        let infos = brain.layers.map { layer in
            LayerInfo(name: layer.name, description: layer.description, requires: layer.requires, conflicts: layer.conflicts,
                      fields: layer.fields.map { .init(id: $0.id, prompt: $0.prompt, type: $0.kind.rawValue, required: $0.required,
                                                       options: $0.options, default: $0.defaultValue) },
                      skills: layer.skills.map { .init(name: $0.name, mode: $0.mode.rawValue, when: $0.when.map(\.description),
                                                       keepAuto: $0.keepAuto) },
                      files: layer.files.map { .init(template: $0.template, to: $0.to, when: $0.when.map(\.description)) },
                      folder: layer.folder.path, problems: brain.problems(of: layer.name).map(\.message))
        }
        return encode(infos)
    }

    // MARK: - Session insights

    /// Options read before the command that only mean something for brain and project commands.
    private static func refuseProjectOptions(_ options: Options, command: String) throws {
        try refuse([
            (options.home, "--home"), (options.layers != nil, "--layers"), (options.from != nil, "--from"),
            (options.answersFile != nil, "--answers"), (options.targets != nil, "--targets"), (!options.set.isEmpty, "--set"),
            (!options.unset.isEmpty, "--unset"), (!options.include.isEmpty, "--include"), (!options.exclude.isEmpty, "--exclude"),
            (options.includeUnmanaged, "--include-unmanaged"), (options.keepFiles, "--keep-files"), (options.repo != nil, "--repo"),
            (options.skipHome, "--skip-home"), (options.name != nil, "--name"),
        ], command: command)
    }

    /// The first of the given flags fails `akit <command>`.
    private static func refuse(_ given: [(set: Bool, flag: String)], command: String) throws {
        if let flag = given.first(where: \.set)?.flag { throw Failure(message: "\(flag) doesn't go with akit \(command).") }
    }

    /// `akit sessions import`: one importer at a time; a second one exits quietly.
    private static func sessions(_ args: inout Arguments, options: Options, env: HarnessEnvironment, projectsRoot: URL,
                                 out: (String) -> Void) async throws -> Int32 {
        let quiet = args.flag("--quiet")
        let subcommand = args.positional()
        try args.finish()
        guard subcommand == "import" else { throw Failure(message: "Use: akit sessions import [--json] [--quiet]") }
        let paths = InsightsPaths(env: env)
        guard let lock = try ImportLock.acquire(paths.lock) else {
            if !quiet { out("Import already running.") }
            return 0
        }
        defer { withExtendedLifetime(lock) {} }
        let report = try await SessionImporter.importAndBind(env: env, projectsRoot: projectsRoot,
                                                             database: try IndexSchema.open(paths.database))
        // Signals and the code checks of active modes follow every import, still under the lock.
        let upkeep = await AnalysisUpkeep.afterImport(env: env)
        if options.json {
            out(encode(report))
        } else if !quiet {
            out(importText(report))
            if let upkeep { out(upkeep) }
        }
        return 0
    }

    static func importText(_ report: ImportReport) -> String {
        var lines: [String] = []
        if report.sources == 0 {
            lines.append("Nothing new in the session logs (\(report.ms) ms).")
        } else {
            let bytes = ByteCountFormatter.string(fromByteCount: Int64(report.newBytes), countStyle: .file)
            lines.append("Read \(count(report.sources, "file")) (\(bytes)) in \(report.ms) ms. Added \(count(report.sessions, "session")), "
                         + "\(count(report.requests, "request")), \(count(report.toolCalls, "tool call")), \(count(report.skillCalls, "skill call")).")
        }
        if report.spoolLines > 0 { lines.append("Read \(count(report.spoolLines, "spool line")) (session starts, applies, marks, ratings).") }
        if report.pending > 0 { lines.append("\(count(report.pending, "file")) left for the next run.") }
        if report.bindings > 0 { lines.append("Bound \(count(report.bindings, "session")) to projects (new or changed).") }
        if report.bindingsPending > 0 { lines.append("\(count(report.bindingsPending, "session")) left to bind in the next run.") }
        lines += report.skipped.map { "Skipped \($0.path): \($0.reason)" }
        return lines.joined(separator: "\n")
    }

    /// `akit stats`: owners, ≈ context space and calls of every listed skill.
    /// `akit stats --debug`: what the index recorded per session, to check the parsers.
    /// `akit stats bindings`: how sessions are bound to projects.
    private static func stats(_ args: inout Arguments, options: Options, env: HarnessEnvironment, cwd: URL, projectsRoot: URL,
                              hostName: String, hardwareHash: () -> String?, runner: CommandRunner?, out: (String) -> Void,
                              err: (String) -> Void) async throws -> Int32 {
        // Value flags before the subcommand word, so a value (`--project bindings`) is never taken for it.
        let session = args.value("--session")
        let bindingList = args.value("--bindings")
        let projectArgument = args.value("--project")
        let daysText = args.value("--days")
        let topText = args.value("--top")
        let debug = args.flag("--debug")
        let all = args.flag("--all")
        let details = args.flag("--details")
        let atText = args.value("--at")
        let subcommand = args.positional()
        let note = subcommand == "mark" ? args.positional() : nil
        try args.finish()
        if let subcommand, !["bindings", "changes", "mark"].contains(subcommand) {
            throw Failure(message: "Unknown “akit stats \(subcommand)”. Use: akit stats [--project X|--all], akit stats bindings, "
                          + "akit stats changes, akit stats mark \"<note>\" [--at DATE], or akit stats --debug.")
        }
        let days = try positiveNumber(daysText, "--days"), top = try positiveNumber(topText, "--top")
        if projectArgument != nil, all { throw Failure(message: "--project and --all don't go together.") }
        if atText != nil, subcommand != "mark" { throw Failure(message: "--at goes with akit stats mark.") }
        if subcommand == "mark" {
            try refuse([(debug, "--debug"), (session != nil, "--session"), (bindingList != nil, "--bindings"),
                        (projectArgument != nil, "--project"), (all, "--all"), (days != nil, "--days"), (top != nil, "--top"),
                        (details, "--details"), (options.json, "--json")], command: "stats mark")
            return try mark(note, at: atText, env: env, out: out)
        }
        if subcommand == "changes" {
            try refuse([(debug, "--debug"), (session != nil, "--session"), (bindingList != nil, "--bindings"), (days != nil, "--days"),
                        (top != nil, "--top"), (details, "--details")], command: "stats changes")
        } else if subcommand == "bindings" {
            try refuse([(debug, "--debug"), (session != nil, "--session"), (projectArgument != nil, "--project"), (all, "--all"),
                        (top != nil, "--top"), (details, "--details")], command: "stats bindings")
        } else if debug {
            try refuse([(bindingList != nil, "--bindings"), (projectArgument != nil, "--project"), (all, "--all"),
                        (days != nil, "--days"), (top != nil, "--top"), (details, "--details")], command: "stats --debug")
        } else if session != nil {
            throw Failure(message: "--session goes with akit stats --debug.")
        }
        let bindingSet = try BindingSet.parse(bindingList)
        if let problem = MachineProfile.load(home: env.homeDirectory).problem { err("akit: \(problem)") }
        let database = try IndexSchema.open(InsightsPaths(env: env).database)
        let imported = try await QuickImport.run(env: env, projectsRoot: projectsRoot, database: database)
        if subcommand == "bindings" {
            let report = try IndexQueries.bindingStats(database, set: bindingSet, notes: imported.notes, days: days ?? InsightsStats.defaultDays,
                                                     home: env.homeDirectory.path, templates: ProjectBinder.pathTemplates(env: env))
            out(options.json ? encode(report) : bindingStatsText(report))
            return 0
        }
        if debug {
            let sessions = try IndexQueries.debugStats(database, session: session)
            if let session, sessions.isEmpty { throw Failure(message: "No session “\(session)” in the index.") }
            let report = DebugStats(sessions: sessions, notes: imported.notes + (try IndexQueries.debugNotes(database, sessions: sessions)))
            out(options.json ? encode(report) : debugStatsText(report))
            return 0
        }
        var project: String?
        if let projectArgument { project = await projectID(argument: projectArgument, cwd: cwd, projectsRoot: projectsRoot, env: env) }
        let brainRoot = brainRoot(options, cwd: cwd, env: env)
        var inputs = try await InsightsStats.inputs(env: env, database: database, brain: Brain.load(from: brainRoot),
                                                    projectsRoot: projectsRoot, hostName: hostName, hardware: hardwareHash(),
                                                    run: runner)
        if subcommand == "changes" {
            let report = try BeforeAfter.report(database, env: env, descriptions: inputs.descriptions, project: project,
                                                notes: imported.notes)
            if options.json {
                out(encode(report))
                for note in report.notes { err("note: \(note)") }
            } else {
                out(changesText(report, project: project))
            }
            return 0
        }
        inputs.importNotes = imported.notes
        inputs.importRunning = imported.running
        let report = try InsightsStats.report(database, options: .init(days: days ?? InsightsStats.defaultDays, project: project,
                                                                       bindings: bindingSet,
                                                                       top: top ?? (details ? nil : InsightsStats.defaultTop)),
                                              inputs: inputs)
        out(options.json ? encode(report) : statsText(report, details: details))
        return 0
    }

    /// `akit stats mark "<note>" [--at DATE]`: a spool line the next import turns into a before/after anchor.
    private static func mark(_ note: String?, at atText: String?, env: HarnessEnvironment, now: Date = Date(),
                             out: (String) -> Void) throws -> Int32 {
        let text = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { throw Failure(message: "Use: akit stats mark \"<note>\" [--at DATE], e.g. akit stats mark \"Disabled the marketing plugin\".") }
        guard text.count <= Spool.maxNoteLength else { throw Failure(message: "The note is longer than \(Spool.maxNoteLength) characters.") }
        var date = now
        if let atText {
            guard let parsed = BeforeAfter.date(from: atText) else {
                throw Failure(message: "--at needs a date like 2026-09-26 or 2026-09-26T14:30 (local time).")
            }
            guard parsed <= now else { throw Failure(message: "--at is in the future.") }
            date = parsed
        }
        do {
            try Spool.mark(text, at: date, home: env.homeDirectory, now: now)
        } catch {
            throw Failure(message: error.message)
        }
        out("Marked \(localMinute(date)): \(text). akit stats changes compares first-request context "
            + "before and after it.")
        return 0
    }

    static func changesText(_ report: ChangesReport, project: String?) -> String {
        let short = ContextSize.short
        func signed(_ n: Int) -> String { n > 0 ? "+" + short(n) : short(n) }
        var lines = ["First-request context (recorded tokens) of sessions within \(Int(BeforeAfter.window / 86_400)) days before and "
                     + "after each change, with the same harness version and model"
                     + (project.map { ", applies of \($0) and marks" } ?? "") + ":"]
        if report.changes.isEmpty {
            lines.append("No changes yet: akit apply records one, akit stats mark \"<note>\" [--at DATE] one made by hand.")
        }
        for change in report.changes {
            let what = change.anchor == "mark" ? "mark “\(change.note ?? "")”" : "apply \(change.project ?? "")"
            let scope = change.scope.project.map { "sessions of \($0)" } ?? "all sessions on this Mac"
            lines.append("\(localMinute(change.date))  \(what) (\(scope))")
            guard change.isMeasured, let group = change.group, let before = change.before, let after = change.after else {
                lines.append("  not enough data: \(change.reason ?? "")")
                continue
            }
            lines.append("  \(group.harness) \(group.harnessVersion ?? "?"), \(group.model ?? "unknown model"): before "
                         + "\(count(before.sessions, "session")), median \(short(before.median)); after \(count(after.sessions, "session")), "
                         + "median \(short(after.median)); change \(signed(change.deltaTokens ?? 0)) tokens")
            let left = change.left ?? [], joined = change.joined ?? []
            if left.isEmpty, joined.isEmpty {
                lines.append("  skill listing unchanged")
            } else {
                var parts: [String] = []
                if !left.isEmpty { parts.append("\(count(left.count, "skill")) left") }
                if !joined.isEmpty { parts.append("\(count(joined.count, "skill")) joined") }
                lines.append("  skill listing: \(parts.joined(separator: ", ")), \(signed(change.deltaChars ?? 0)) description characters"
                             + (change.k.map { "; k ≈ \(String(format: "%.1f", $0)) characters per token (\(change.script ?? "latin"))" } ?? ""))
            }
        }
        let calibration = report.calibration
        lines.append("")
        func k(_ value: Double, _ script: String, _ pairs: Int) -> String {
            let source = pairs >= ContextSize.minimumPairs ? "calibrated from \(count(pairs, "pair"))"
                : "default; \(count(pairs, "accepted pair")), \(ContextSize.minimumPairs) needed"
            return "\(String(format: "%.1f", value)) \(script) (\(source))"
        }
        lines.append("≈ sizes use k " + k(calibration.latin, "Latin", calibration.latinPairs) + ", "
                     + k(calibration.cyrillic, "Cyrillic", calibration.cyrillicPairs) + ".")
        lines += report.notes.map { "note: \($0)" }
        return lines.joined(separator: "\n")
    }

    static func statsText(_ report: StatsReport, details: Bool) -> String {
        let short = ContextSize.short
        let summary = report.summary
        let scope = report.scope.project.map { "project \($0) (sessions bound at \(report.scope.bindings.joined(separator: ", ")))" }
            ?? "all sessions on this Mac"
        var lines = ["Last \(report.window.days) days, \(scope): \(count(summary.sessions, "session")), \(count(summary.requests, "request"))."]
        if summary.sessions > 0 {
            lines.append("First-request context (recorded): median \(short(summary.firstRequestContext.median)) tokens, "
                         + "p90 \(short(summary.firstRequestContext.p90)).")
            lines.append("Skill listing: ≈ \(short(summary.approxListingTokensPerRequest)) tokens per request.")
        }
        let owners = summary.byOwner.filter { $0.skills > 0 }
        if !owners.isEmpty {
            lines.append("")
            lines.append("By owner (skills, ≈ tokens per request when listed):")
            lines += owners.map { "  \(ownerLabel($0.owner)): \(count($0.skills, "skill")), ≈ \(short($0.approxTokens))" }
        }
        lines.append("")
        if report.skills.isEmpty {
            lines.append("No skill listings in this window.")
        } else {
            lines.append("\(details && report.omitted.skills == 0 ? "Skills" : "Top \(report.skills.count)") by ≈ context space (tokens × requests):")
            for skill in report.skills {
                let owner = [ownerLabel(skill.owner.kind), skill.owner.name].compactMap { $0 }.joined(separator: " ")
                var line = "  \(skill.name) (\(owner)): ≈ \(short(skill.approxContextSpace)) context space, "
                    + "≈ \(short(skill.approxTokens)) tokens per request; "
                    + "listed with its description in \(count(skill.listedSessions, "session")) on \(count(skill.listedDays, "day")); "
                    + "model calls \(skill.modelCalls) (\(Int((skill.callRate * 100).rounded()))% of those sessions), user calls \(skill.userCalls)"
                if skill.piModelCalls > 0 { line += ", in Pi \(skill.piModelCalls)" }
                lines.append(line)
                if details {
                    let versions = skill.descriptionVersions > 1 ? ", \(skill.descriptionVersions) description texts seen" : ""
                    lines.append("    counted since its description window start \(skill.windowStart)\(versions)")
                }
            }
            if report.omitted.skills > 0 { lines.append("\(count(report.omitted.skills, "more skill")): --top N, or --details for all.") }
            lines.append("Model calls count in every session that listed the skill, by name only too (they protect it); "
                         + "the % counts only the sessions with its description.")
        }
        if let dropped = report.droppedDescriptions.text {
            lines.append("")
            lines.append(dropped)
        }
        lines += report.notes.map { "note: \($0)" }
        return lines.joined(separator: "\n")
    }

    struct DebugStats: Encodable {
        let sessions: [IndexQueries.SessionDebug]
        let notes: [String]
    }

    static func debugStatsText(_ report: DebugStats) -> String {
        func size(_ bytes: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
        var lines: [String] = []
        if report.sessions.isEmpty { lines.append("No sessions in the index yet.") }
        for session in report.sessions {
            let version = session.harnessVersion.map { " (\(session.harness) \($0))" } ?? ""
            lines.append("\(session.key)  \(session.started ?? "no date")\(version)")
            lines.append("  \(session.requests) requests; first request context: \(session.firstRequestContext.map { "\($0) tokens" } ?? "none")")
            lines.append("  listed: \(session.listings) skills, ≈ \(session.listedChars) description chars")
            lines.append("  skill calls: \(session.modelCalls) by the model, \(session.userCalls) by the user, "
                         + "\(session.subagentCalls) in \(session.subagentRuns) subagent runs; "
                         + "\(session.userCommands) built-in commands (/model, /clear …)")
            if !session.largestToolOutputs.isEmpty {
                lines.append("  largest tool outputs: " + session.largestToolOutputs.map { "\($0.name) \(size($0.bytes))" }.joined(separator: ", "))
            }
        }
        lines += report.notes.map { "note: \($0)" }
        return lines.joined(separator: "\n")
    }

    static func bindingStatsText(_ report: IndexQueries.BindingStats) -> String {
        func counts(_ names: [String], _ values: [String: Int]) -> String {
            names.map { "\($0) \(values[$0] ?? 0)" }.joined(separator: ", ")
        }
        let total = report.byMethod.values.reduce(report.undecided, +)
        var lines = ["Project bindings of \(total) sessions\(report.undecided > 0 ? " (\(report.undecided) not decided yet)" : ""):",
                     "  by method: " + counts(BindingMethod.allCases.map(\.rawValue), report.byMethod),
                     "  by confidence: " + counts(Confidence.allCases.map(\.rawValue) + ["none"], report.byConfidence)]
        let recent = report.recent
        let share = recent.share.map { " (\(Int(($0 * 100).rounded()))%)" } ?? ""
        lines.append("Last \(recent.days) days: \(recent.bound) of \(recent.sessions) main sessions bound at "
                     + report.bindingSet.joined(separator: ", ") + share + ".")
        if !report.unboundFolders.isEmpty {
            lines.append("Unbound folders (latest first):")
            lines += report.unboundFolders.map { "  \($0)" }
        }
        if !report.suggestedTemplates.isEmpty {
            lines.append("Path templates that would bind more sessions (add to \"pathTemplates\" in ~/.akit/insights.json):")
            lines += report.suggestedTemplates.map { "  \($0.template)  \($0.sessions) sessions (\($0.repositories.joined(separator: ", ")))" }
        }
        lines += report.notes.map { "note: \($0)" }
        return lines.joined(separator: "\n")
    }

    /// `akit insights install|status|uninstall|publish`. Without a brain only the Pi and launchd parts and status work.
    private static func insights(_ args: inout Arguments, options: Options, env: HarnessEnvironment, cwd: URL, projectsRoot: URL,
                                 hostName: String, hardwareHash: () -> String?, out: (String) -> Void, err: (String) -> Void,
                                 trash: (URL) throws -> URL?, runner: CommandRunner?) async throws -> Int32 {
        let onlyName = args.value("--only")
        let dryRun = args.flag("--dry-run")
        let subcommand = args.positional()
        try args.finish()
        let usage = "Use: akit insights install [--only claude|pi|launchd] [--dry-run] [--yes] | status [--json] | uninstall [--yes] | publish [--dry-run]"
        var only: CaptureInstaller.Part?
        if let onlyName {
            guard let part = CaptureInstaller.Part(rawValue: onlyName), subcommand == "install" else { throw Failure(message: usage) }
            only = part
        }
        if dryRun, subcommand == "status" { throw Failure(message: usage) }
        let brainRoot = brainRoot(options, cwd: cwd, env: env)
        let brain = Brain.load(from: brainRoot)
        if subcommand == "publish" {
            guard let brain else { throw Failure(message: "No brain repo at \(brainRoot.path); usage summaries are published there.") }
            if let problem = MachineProfile.load(home: env.homeDirectory).problem { err("akit: \(problem)") }
            let database = try IndexSchema.open(InsightsPaths(env: env).database)
            let imported = try await QuickImport.run(env: env, projectsRoot: projectsRoot, database: database)
            let outcome = try await SummaryPublisher.publish(env: env, brain: brain, database: database, hostName: hostName,
                                                             hardware: hardwareHash(), dryRun: dryRun)
            out(([publishText(outcome)] + imported.notes.map { "note: \($0)" }).joined(separator: "\n"))
            return 0
        }
        let installer = CaptureInstaller(env: env, brainRoot: brain?.root, run: runner)
        let plan: CaptureInstaller.Plan
        switch subcommand {
        case "status":
            let status = await installer.status()
            out(options.json ? encode(status) : insightsStatusText(status))
            return 0
        case "install":
            if brain == nil, only == nil || only == .claude {
                throw Failure(message: "No brain repo at \(brainRoot.path); the Claude plugin lives there. Use --only pi|launchd, or create a brain first (akit init).")
            }
            plan = await installer.installPlan(only: only)
        case "uninstall":
            plan = await installer.uninstallPlan()
        default:
            throw Failure(message: usage)
        }
        out(plan.text)
        if subcommand != "status", options.yes, !dryRun {
            // Installing by hand undoes a no given in akit setup, for what it installs;
            // uninstalling is a no, so the next akit setup doesn't put capture back.
            do {
                if subcommand == "install" {
                    try installer.saveInstalled(only.map { [$0] } ?? CaptureInstaller.Part.allCases)
                } else {
                    try installer.save(.init(declined: true))
                }
            } catch {
                err("akit: couldn't update \(InsightsPaths(env: env).settings.path): \(error.localizedDescription)")
            }
        }
        let refused: Int32 = plan.refused.isEmpty ? 0 : 1
        guard !plan.isEmpty else { return refused }
        guard options.yes, !dryRun else {
            out("Run again with --yes to do it.")
            return refused
        }
        let failures = try await installer.execute(plan, trash: trash)
        out((failures.isEmpty ? ["Done."] : failures).joined(separator: "\n"))
        return failures.isEmpty ? refused : 1
    }

    /// `akit recommend`, `akit recommend apply ID`, `akit recommend dismiss ID`.
    private static func recommend(_ args: inout Arguments, options: Options, env: HarnessEnvironment, cwd: URL, projectsRoot: URL,
                                  hostName: String, hardwareHash: () -> String?, runner: CommandRunner?, out: (String) -> Void,
                                  err: (String) -> Void) async throws -> Int32 {
        // Value flags before the subcommand word, so a value (`--project apply`) is never taken for it.
        let bindingList = args.value("--bindings")
        let projectArgument = args.value("--project")
        let minSessionsText = args.value("--min-sessions")
        let minDaysText = args.value("--min-days")
        let all = args.flag("--all")
        let details = args.flag("--details")
        let subcommand = args.positional()
        let id = subcommand == "apply" || subcommand == "dismiss" ? args.positional() : nil
        try args.finish()
        let usage = "Use: akit recommend [--project X|--all] [--details] [--json] [--min-sessions N] [--min-days D] [--bindings LIST], "
            + "akit recommend apply ID [--yes], or akit recommend dismiss ID [--yes]"
        if let subcommand, (subcommand != "apply" && subcommand != "dismiss") || id == nil { throw Failure(message: usage) }
        if projectArgument != nil, all { throw Failure(message: "--project and --all don't go together.") }
        if subcommand == nil, options.yes { throw Failure(message: "--yes goes with akit recommend apply or dismiss.") }
        if subcommand != nil, options.json || details { throw Failure(message: "\(options.json ? "--json" : "--details") doesn't go with akit recommend \(subcommand ?? "").") }
        var recommendOptions = Recommender.Options(bindings: try BindingSet.parse(bindingList),
                                                   top: details || subcommand != nil ? nil : Recommender.defaultTop)
        if let minSessions = try positiveNumber(minSessionsText, "--min-sessions") { recommendOptions.minSessions = minSessions }
        if let minDays = try positiveNumber(minDaysText, "--min-days") { recommendOptions.minDays = minDays }
        let machine = MachineProfile.load(home: env.homeDirectory)
        if let problem = machine.problem { err("akit: \(problem)") }
        if let projectArgument {
            recommendOptions.project = await projectID(argument: projectArgument, cwd: cwd, projectsRoot: projectsRoot, env: env)
        }
        let brainRoot = brainRoot(options, cwd: cwd, env: env)
        let brain = Brain.load(from: brainRoot)
        let (database, inputs) = try await Recommender.prepare(env: env, brain: brain, project: recommendOptions.project,
                                                               projectsRoot: projectsRoot, hostName: hostName,
                                                               hardware: hardwareHash(), run: runner)
        guard let subcommand, let id else {
            let report = try Recommender.recommend(database, options: recommendOptions, inputs: inputs)
            if options.json {
                out(encode(report))
                for note in report.notes { err("note: \(note)") }
            } else {
                out(recommendText(report, details: details))
            }
            return 0
        }

        // The id names its scope: the one given, else the global one, then every project known here.
        var found = try Recommender.recommend(database, options: recommendOptions, inputs: inputs).recommendations.first { $0.id == id }
        if found == nil, projectArgument == nil {
            for project in try Recommender.knownProjects(database, brain: brain, home: env.homeDirectory, bindings: recommendOptions.bindings) {
                var scoped = recommendOptions
                scoped.project = project
                let projectInputs = try await Recommender.scoped(inputs, to: project, env: env, database: database, run: runner)
                found = try Recommender.recommend(database, options: scoped, inputs: projectInputs).recommendations.first { $0.id == id }
                if found != nil { break }
            }
        }
        guard let recommendation = found else {
            throw Failure(message: "No recommendation \(id) now. Run akit recommend to see the current ones (with the same --project, --min-sessions and --min-days).")
        }
        let confirm = "Run again with --yes to do it."
        if recommendation.stale {
            out("Other Macs' summaries are old (\(recommendation.staleMachines.joined(separator: ", "))): run akit sync first, they may have called \(recommendation.subject) since.")
        }
        if subcommand == "apply" {
            guard let patch = recommendation.patch, let layer = recommendation.action.layer, let brain else {
                throw Failure(message: "\(id) is advice, not a layer patch; nothing to apply. \(recommendation.action.text ?? "") "
                              + "To hide it: akit recommend dismiss \(id).")
            }
            out((["Set \(recommendation.skill) to manual in \(LayerPatch.path(layer: layer)):"]
                 + TextDiff.unified(TextDiff.lines(from: patch.before, to: patch.after))).joined(separator: "\n"))
            guard options.yes else { out(confirm); return 0 }
            try await LayerPatch.commit(skill: recommendation.skill, layer: layer, change: .manual, before: patch.before, after: patch.after,
                                        brain: brain.root, machine: machine, env: env)
            var lines = ["Committed “\(LayerPatch.Change.manual.message(skill: recommendation.skill, layer: layer))”."]
            let projects = Recommender.projectsUsing(layer, brain: brain, home: env.homeDirectory)
                .map { $0.hasPrefix("home/") ? "\($0) (akit apply --home)" : $0 }
            if !projects.isEmpty { lines.append("Run akit plan/apply in: \(projects.joined(separator: ", ")).") }
            if let note = recommendation.action.text { lines.append(note) }
            out(lines.joined(separator: "\n"))
            return 0
        }

        // Dismiss: a layer skill is pinned in its layer.yaml; advice is remembered with its evidence.
        if let patch = recommendation.patch, let layer = recommendation.action.layer, let brain {
            let after = try LayerPatch.edit(patch.before, skill: recommendation.skill, layer: layer, change: .keepAuto)
            out((["Keep \(recommendation.skill) auto in \(LayerPatch.path(layer: layer)):"]
                 + TextDiff.unified(TextDiff.lines(from: patch.before, to: after))).joined(separator: "\n"))
            guard options.yes else { out(confirm); return 0 }
            try await LayerPatch.commit(skill: recommendation.skill, layer: layer, change: .keepAuto, before: patch.before, after: after,
                                        brain: brain.root, machine: machine, env: env)
            out("Committed “\(LayerPatch.Change.keepAuto.message(skill: recommendation.skill, layer: layer))”.")
            return 0
        }
        let space = recommendation.evidence.approxContextSpace
        out("Dismiss \(id) (\(recommendation.subject)): hidden until its ≈ context space reaches ≈ \(Dismissals.showsAgainAt(space)) "
            + "(twice now's ≈ \(space)).")
        guard options.yes else { out(confirm); return 0 }
        let entry = Dismissals.Entry(id: id, at: Date().formatted(.iso8601), approxContextSpace: space)
        let url = try await Dismissals.dismiss(entry, project: recommendation.scope.project, brain: brain?.root, home: env.homeDirectory,
                                               machine: machine, env: env)
        out("Saved in \(url.path).")
        return 0
    }

    static func recommendText(_ report: RecommendReport, details: Bool) -> String {
        let short = ContextSize.short
        let rule = report.rule
        let scope = report.project.map { "project \($0), sessions bound at \(rule.bindings.joined(separator: ", "))" } ?? "all sessions"
        var lines = ["Auto skills the model never called: listed with their description in ≥ \(count(rule.minSessions, "session")) on ≥ \(count(rule.minDistinctDays, "day")), "
                     + "summed over this Mac and the other Macs' summaries (\(scope))."]
        let owners = report.summary.approxContextPerRequestByOwner.filter { $0.skills > 0 }
        if !owners.isEmpty {
            lines.append("≈ Context per request by owner: "
                         + owners.map { "\(ownerLabel($0.owner)) ≈ \(short($0.approxTokens)) (\(count($0.skills, "skill")))" }.joined(separator: ", ") + ".")
        }
        lines.append("≈ tokens = description characters / k (\(report.calibration.describe)).")
        lines.append("")
        if report.recommendations.isEmpty { lines.append("Nothing to recommend.") }
        for item in report.recommendations {
            let owner = [ownerLabel(item.owner.kind), item.owner.name].compactMap { $0 }.joined(separator: " ")
            let evidence = item.evidence
            let subject = item.skill == Recommender.wholePlugin ? owner : "\(item.skill) (\(owner))"
            lines.append("\(item.stale ? "[stale] " : "")\(item.id)  \(subject): \(item.type)")
            let period = evidence.from.map { from in " (\(from) … \(evidence.to ?? from))" } ?? ""
            let macs = evidence.machines.count > 1 ? " on \(evidence.machines.count) Macs" : ""
            lines.append("  ≈ \(short(evidence.approxContextSpace)) context space; listed with its description in \(count(evidence.sessions, "session")) on "
                         + "\(count(evidence.distinctDays, "day"))\(period)\(macs); model calls 0 (rate < \(Int((evidence.callRateUpperBound95 * 100).rounded(.up)))% "
                         + "at 95%), user calls \(evidence.userCalls)")
            if let skills = evidence.skills {
                let shown = details || skills.count <= 5 ? skills : Array(skills.prefix(5)) + ["… \(skills.count - 5) more"]
                lines.append("  skills: \(shown.joined(separator: ", "))")
            }
            if item.stale { lines.append("  other Macs' summaries are old (\(item.staleMachines.joined(separator: ", "))): run akit sync first") }
            if item.isPatch {
                lines.append("  patch: \(item.action.layer.map(LayerPatch.path) ?? "") mode auto → manual; akit recommend apply \(item.id) "
                             + "(or dismiss to keep it auto)")
                if details, let diff = item.action.diff { lines += diff.split(separator: "\n", omittingEmptySubsequences: false).map { "    \($0)" } }
            }
            if let text = item.action.text { lines.append("  \(item.isPatch ? "then" : "advice"): \(text)") }
            if details {
                lines.append("  machines: " + evidence.machines.map { "\($0.name) (\($0.updated ?? "never")\($0.stale ? ", stale" : ""))" }
                    .joined(separator: ", "))
                if let binding = evidence.binding {
                    lines.append("  bound by \(binding.methods.joined(separator: ", ")) (lowest confidence \(binding.confidence ?? "none"))")
                }
            }
        }
        if report.omitted > 0 { lines.append("\(count(report.omitted, "more recommendation")): --details for all.") }
        if report.hiddenByDismissal > 0 { lines.append("Hidden by dismissal: \(report.hiddenByDismissal) (they return when their ≈ context space doubles).") }
        if !report.noData.isEmpty {
            lines.append("No data (Pi records no skill list): \(report.noData.map(\.skill).joined(separator: ", ")).")
        }
        lines += report.notes.map { "note: \($0)" }
        return lines.joined(separator: "\n")
    }

    static func publishText(_ outcome: SummaryPublisher.Outcome) -> String {
        let who = outcome.isWork ? "this work Mac's pseudonym \(outcome.key)" : "this Mac's id \(outcome.key)"
        var lines: [String] = []
        if outcome.dryRun {
            lines.append(outcome.changed.isEmpty ? "Usage summaries are up to date (\(who)); nothing to commit."
                         : "Would commit “\(outcome.message)”: \(outcome.changed.joined(separator: ", "))")
            if !outcome.local.isEmpty { lines.append("Would write on this Mac only: \(outcome.local.joined(separator: ", "))") }
            return lines.joined(separator: "\n")
        }
        lines.append(outcome.committed.isEmpty ? "Usage summaries are up to date (\(who)); nothing to commit."
                     : "Committed “\(outcome.message)”: \(outcome.committed.joined(separator: ", ")). akit sync pushes it.")
        if !outcome.local.isEmpty { lines.append("Project summaries kept on this Mac only: \(outcome.local.count) files.") }
        lines += outcome.notes.map { "note: \($0)" }
        return lines.joined(separator: "\n")
    }

    static func insightsStatusText(_ status: CaptureInstaller.Status) -> String {
        let claude = status.claude
        var lines = [
            "Claude plugin: brain \(claude.brainVersion ?? "none"), installed \(claude.installedVersion ?? (claude.claudeFound ? "no" : "no (Claude Code not found)")), this akit \(claude.akitVersion)"
                + (claude.enabled == false ? " (disabled)" : ""),
            "Pi extension: \(status.pi.state) (\(status.pi.path))",
            "Hourly import: " + (status.launchd.present ? "\(status.launchd.loaded ? "loaded" : "not loaded"), runs \(status.launchd.program ?? "?")"
                                 : "not installed"),
            "Last spool line: \(status.lastSpoolLine ?? "none")",
            "Last import: \(status.lastImport ?? "none")",
        ]
        if claude.versionMismatch { lines.append("Versions differ: run akit insights install --yes (and akit sync on the other Macs).") }
        return lines.joined(separator: "\n")
    }

    // MARK: - Remove

    private static func remove(kind: String?, name: String?, options: Options, env: HarnessEnvironment, cwd: URL,
                               projectsRoot: URL, hostName: String, installedTargets: [String],
                               out: (String) -> Void, trash: (URL) throws -> URL?) async throws -> Int32 {
        let brainRoot = brainRoot(options, cwd: cwd, env: env)
        guard let brain = Brain.load(from: brainRoot) else { throw Failure(message: "No brain repo at \(brainRoot.path).") }
        let confirm = "Run again with --yes to do it."
        do {
            switch (kind, name) {
            case ("layer", let name?):
                let impact = BrainRemove.layerImpact(name, in: brain, home: env.homeDirectory)
                if !impact.requiredBy.isEmpty {
                    out("Can't remove \(name): required by \(impact.requiredBy.joined(separator: ", ")).")
                    return 1
                }
                var lines = ["Remove layer \(name): layers/\(name) goes to the Trash."]
                if !impact.projects.isEmpty {
                    lines.append("It is dropped from the answers of: \(impact.projects.joined(separator: ", ")). Re-apply those to take its files out.")
                }
                guard options.yes else { out((lines + [confirm]).joined(separator: "\n")); return 0 }
                try await BrainRemove.removeLayer(name, in: brain, env: env, trash: trash)
                out((lines + ["Done."]).joined(separator: "\n"))
            case ("skill", let name?):
                if let layer = options.from {
                    guard let found = brain.layers.first(where: { $0.name == layer }) else { throw Failure(message: "No layer named \(layer).") }
                    let edit = try BrainRemove.layerWithoutSkill(name, in: found)
                    out((["Remove \(name) from layers/\(layer)/layer.yaml:"] + TextDiff.unified(TextDiff.lines(from: edit.before, to: edit.after))).joined(separator: "\n"))
                    guard options.yes else { out(confirm); return 0 }
                    try await BrainRemove.removeSkill(name, fromLayer: layer, in: brain, env: env)
                    out("Done. Projects using \(layer) lose it on their next apply\(layer == "core" ? "; the home folder on akit apply --home" : "").")
                } else {
                    let users = BrainRemove.skillUsers(name, in: brain)
                    if !users.isEmpty {
                        out("Can't remove \(name): listed in \(users.joined(separator: ", ")). First: \(users.map { "akit remove skill \(name) --from \($0)" }.joined(separator: "; ")).")
                        return 1
                    }
                    guard options.yes else { out("Remove skill \(name): skills/\(name) goes to the Trash. \(confirm)"); return 0 }
                    try await BrainRemove.removeSkill(name, in: brain, env: env, trash: trash)
                    out("Done.")
                }
            case ("project", _):
                if options.home, name != nil { throw Failure(message: "--home and a project folder don't go together.") }
                let project = options.home ? env.homeDirectory : resolve(name ?? ".", cwd: cwd, env: env)
                let id = options.home ? homeID(hostName: hostName, env: env)
                    : await ProjectRecords.projectID(for: project, projectsRoot: projectsRoot, env: env)
                let store = ProjectStore.current(brain: brain.root, home: env.homeDirectory)
                guard let preview = ProjectForget.preview(id: id, folder: project, forHome: options.home, brain: brain, store: store) else {
                    out("Nothing is saved for \(id).")
                    return 1
                }
                var lines = [preview.ownRecord ? "Forget \(id) (\(store.describe(id: id)) goes to the Trash)." : "Forget \(id) on this Mac."]
                if !options.keepFiles {
                    if !preview.removals.isEmpty || preview.keysTakenOut.isEmpty {
                        lines.append(preview.removals.isEmpty ? "No files AKit wrote are left there."
                                     : "Files AKit wrote go to the Trash: \(preview.removals.joined(separator: ", ")).")
                    }
                    if !preview.keysTakenOut.isEmpty {
                        lines.append("The keys AKit added come out of: \(preview.keysTakenOut.joined(separator: ", ")) (the project's own keys stay).")
                    }
                    if !preview.keysLeft.isEmpty {
                        lines.append("AKit's keys stay in \(preview.keysLeft.joined(separator: ", ")): AKit can't read it as JSON, so take them out by hand.")
                    }
                    if !preview.kept.isEmpty { lines.append("Kept (edited by hand): \(preview.kept.joined(separator: ", ")).") }
                }
                guard options.yes else { out((lines + [confirm]).joined(separator: "\n")); return 0 }
                try await ProjectForget.run(preview, keepFiles: options.keepFiles, brain: brain, home: env.homeDirectory, env: env, trash: trash)
                if preview.brainCopyLeft {
                    lines.append("The brain still has projects/\(id) from before this became a work Mac; remove it by hand: git -C \(brain.root.path) rm -r projects/\(id), then commit.")
                }
                out((lines + ["Done."]).joined(separator: "\n"))
            default:
                throw Failure(message: "Use: akit remove layer NAME | skill NAME [--from LAYER] | project [PROJECT|--home] [--keep-files]")
            }
        } catch let failure as BrainRemove.Failure {
            throw Failure(message: failure.message)
        } catch let failure as ProjectSetup.Failure {
            throw Failure(message: failure.message)
        }
        return 0
    }

    // MARK: - Answers

    struct Options {
        var brain: String?
        var json: Bool
        var answersFile: String?
        var layers: String?
        var targets: String?
        var set: [String]
        var unset: [String]
        var include: [String]
        var exclude: [String]
        var home: Bool
        var includeUnmanaged: Bool
        var yes: Bool
        var keepFiles: Bool
        var from: String?
        var repo: String?
        var skipHome: Bool
        var name: String?
    }

    private static func readAnswers(_ options: Options, id: String, brain: Brain, store: ProjectStore, cwd: URL,
                                    env: HarnessEnvironment, installedTargets: [String]) throws -> ProjectAnswers {
        if let file = options.answersFile {
            let url = resolve(file, cwd: cwd, env: env)
            do {
                return try JSONDecoder().decode(ProjectAnswers.self, from: Data(contentsOf: url))
            } catch {
                throw Failure(message: "Can't read answers from \(url.path): \(error.localizedDescription)")
            }
        }
        var answers = ProjectRecords.savedAnswers(id: id, in: store)
            ?? ProjectAnswers(layers: [], values: [:], targets: installedTargets)
        if let layers = options.layers { answers.layers = list(layers) }
        if let targets = options.targets {
            answers.targets = list(targets)
            for target in answers.targets where !ProjectAnswers.knownTargets.contains(target) {
                throw Failure(message: "Unknown target “\(target)” (\(ProjectAnswers.knownTargets.joined(separator: ", "))).")
            }
        }
        let fields = Dictionary(brain.layers.flatMap(\.fields).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for pair in options.set {
            guard let equals = pair.firstIndex(of: "=") else { throw Failure(message: "--set wants field=value, got “\(pair)”.") }
            let key = String(pair[..<equals]), raw = String(pair[pair.index(after: equals)...])
            guard let field = fields[key] else { throw Failure(message: "No layer has a field “\(key)”.") }
            switch field.kind {
            case .bool:
                guard let flag = ["true": true, "yes": true, "false": false, "no": false][raw.lowercased()] else {
                    throw Failure(message: "\(key) is a bool: use true or false.")
                }
                answers.values[key] = .bool(flag)
            case .multi:
                let items = list(raw)
                if let bad = items.first(where: { !field.options.contains($0) }) {
                    throw Failure(message: "“\(bad)” is not an option of \(key) (\(field.options.joined(separator: ", "))).")
                }
                answers.values[key] = .list(items)
            case .choice:
                guard field.options.contains(raw) else {
                    throw Failure(message: "“\(raw)” is not an option of \(key) (\(field.options.joined(separator: ", "))).")
                }
                answers.values[key] = .text(raw)
            case .text:
                answers.values[key] = .text(raw)
            }
        }
        for key in options.unset { answers.values[key] = nil }
        return answers
    }

    // MARK: - Output

    static func planText(_ plan: ProjectSetup.Plan) -> String {
        var lines = ["Project \(plan.project.path) (\(plan.store.isLocal ? "saved locally" : "brain"): \(plan.store.describe(id: plan.id)))",
                     "Layers: \(plan.render.layers.isEmpty ? "none" : plan.render.layers.joined(separator: ", ")) · targets: \(plan.answers.targets.joined(separator: ", "))"]
        for error in plan.render.errors { lines.append("ERROR: \(error)") }
        for blocker in plan.blockers { lines.append("BLOCKED: \(blocker)") }
        for warning in plan.render.warnings { lines.append("warning: \(warning)") }
        let changed = plan.changes.filter { $0.kind != .same && $0.kind != .own }
        if changed.isEmpty { lines.append("No changes.") }
        for change in changed {
            var note = ""
            if change.kind == .update && change.replacesUnmanaged { note = "  (AKit didn't write it: skipped unless --include)" }
            if change.kind == .update && change.editedSinceRender { note = "  (edited by hand since the last render: skipped unless --include)" }
            if change.mergesJSON && [.create, .update].contains(change.kind) { note = "  (keys merged; the project's own keys stay; env and headers values masked)" }
            lines.append("")
            lines.append("\(label(change.kind)) \(change.path)\(note)")
            let new = change.kind == .remove || change.kind == .keepEdited ? "" : change.newText ?? ""
            if change.oldText != nil || change.newText != nil {
                lines += TextDiff.unified(TextDiff.lines(from: change.oldText ?? "", to: new))
            }
        }
        let own = plan.changes.filter { $0.kind == .own }.map(\.path)
        if !own.isEmpty {
            lines.append("\nThe project's own version (take the layers' with --include PATH): \(own.joined(separator: ", "))")
        }
        let same = plan.changes.count - changed.count - own.count
        if same > 0 { lines.append("\n\(same) file\(same == 1 ? "" : "s") unchanged.") }
        return lines.joined(separator: "\n")
    }

    private static func label(_ kind: ProjectSetup.Change.Kind) -> String {
        switch kind {
        case .create: "NEW"
        case .update: "CHANGED"
        case .same: "SAME"
        case .remove: "REMOVE (to the Trash)"
        case .keepEdited: "KEEP (no longer rendered, but edited by hand)"
        case .suggest: "LAYERS CHANGED (the project's own file: kept unless --include)"
        case .own: "OWN"
        }
    }

    private static func outcomeText(_ outcome: ProjectSetup.Outcome, skipped: Set<String>, plan: ProjectSetup.Plan) -> String {
        var lines = ["", "Applied: \(outcome.written.count) written, \(outcome.removed.count) moved to the Trash."]
        if !skipped.isEmpty { lines.append("Skipped: \(skipped.sorted().joined(separator: ", "))") }
        if let backup = outcome.backup { lines.append("Backup: \(backup.path)") }
        lines += outcome.notes.map { "Note: \($0)" }
        let place = plan.store.isLocal ? "on this Mac only, in \(plan.store.describe(id: plan.id))" : "in the brain under \(plan.store.describe(id: plan.id))"
        lines.append(plan.id.hasPrefix("home/") ? "Saved \(place). Reload skills in your harness (e.g. /reload-skills)."
                     : "Answers saved \(place). Commit the harness files in the project.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    /// `2026-09-28 13:09` in local time, the same on every Mac whatever its locale.
    static func localMinute(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    private static func list(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func resolve(_ path: String, cwd: URL, env: HarnessEnvironment) -> URL {
        if path.hasPrefix("~") || path.hasPrefix("/") { return env.expand(path).standardizedFileURL }
        return cwd.appending(path: path).standardizedFileURL
    }

    /// `--brain DIR`, else `~/.akit/registry`.
    private static func brainRoot(_ options: Options, cwd: URL, env: HarnessEnvironment) -> URL {
        options.brain.map { resolve($0, cwd: cwd, env: env) } ?? Brain.defaultRoot(home: env.homeDirectory)
    }

    /// `--project`: a folder gives its project id (as akit plan does); anything else is taken as an id.
    private static func projectID(argument: String, cwd: URL, projectsRoot: URL, env: HarnessEnvironment) async -> String {
        let folder = resolve(argument, cwd: cwd, env: env)
        return FileWalk.isDirectory(folder) ? await ProjectRecords.projectID(for: folder, projectsRoot: projectsRoot, env: env) : argument
    }

    /// `--days`, `--top`, `--min-sessions`, `--min-days`: nil when not given.
    static func positiveNumber(_ text: String?, _ flag: String) throws -> Int? {
        guard let text else { return nil }
        guard let value = Int(text), value > 0 else { throw Failure(message: "\(flag) needs a whole number above 0.") }
        return value
    }

    /// `3 sessions`, `1 day`.
    private static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    /// An owner kind as the text output says it.
    private static func ownerLabel(_ kind: String) -> String {
        switch kind {
        case SkillOwner.Kind.handInstalled.rawValue: "hand-installed"
        case SkillOwner.Kind.builtIn.rawValue: "built-in"
        default: kind
        }
    }

    /// Minimal argument reader: flags and `--key value` anywhere, positionals in order.
    struct Arguments {
        private var items: [String]
        init(_ items: [String]) { self.items = items }
        var isEmpty: Bool { items.isEmpty }

        mutating func flag(_ name: String) -> Bool {
            guard let index = items.firstIndex(of: name) else { return false }
            items.remove(at: index)
            return true
        }

        mutating func value(_ name: String) -> String? { values(name).last }

        /// A value never starts with `--`: `--session --debug` leaves `--session` for `finish` to refuse.
        mutating func values(_ name: String) -> [String] {
            var found: [String] = []
            while let index = items.firstIndex(of: name), index + 1 < items.count, !items[index + 1].hasPrefix("--") {
                found.append(items[index + 1])
                items.removeSubrange(index...index + 1)
            }
            return found
        }

        /// The next positional word, without taking it.
        var peek: String? { items.first { !$0.hasPrefix("--") } }

        mutating func positional() -> String? {
            guard let index = items.firstIndex(where: { !$0.hasPrefix("--") }) else { return nil }
            return items.remove(at: index)
        }

        func finish() throws {
            if let extra = items.first { throw Failure(message: "Unexpected “\(extra)”. Run akit --help.") }
        }
    }
}
