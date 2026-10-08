import AKitBrain
import AKitErrorAnalysis
import AKitFoundation
import AKitHarnesses
import AKitInsights
import AKitLab
import AKitSessions
import AKitSkills
import Foundation

/// `akit analysis control …`: controlled evals (docs/design/error-analysis.md, "Controlled evals").
extension AKitCLI {
    static let analysisControlUsage = """
        Controlled evals: did a fix help on fixed tasks? Tasks in ~/.akit/lab/evals; cells are Lab runs:
          akit analysis control task new --session SESSION [--mode MODE] (--tests CMD | --assert MODE)
                              [--reference SHA]
                                          A task from an exemplar session: its first user turn, at HEAD
                                          of its start (recorded by the capture hook), in the repository
                                          it ran in. SESSION: a session key (claude:ID, pi:ID), a
                                          transcript path or a Claude Code or Pi session id. The oracle: the
                                          project's test command (exit 0 passes), or a mode's code check
                                          on the cell's transcript (passes when the mode doesn't show;
                                          for a success mode, when it does)
          akit analysis control task new --repo DIR --base SHA --prompt TEXT [--mode MODE]
                              (--tests CMD | --assert MODE) [--reference SHA]
                                          A minimal reproduction: the simplest request that triggers the mode
          akit analysis control tasks [--json]
                                          Control tasks, oldest first
          akit analysis control task check ID
                                          The sanity check: the test command must pass on the task's
                                          --reference commit (in an isolated clone)
          akit analysis control task remove ID
                                          Move a task's file to the Trash (its cells stay Lab runs)
          akit analysis control run TASK[,TASK…] [--setups baseline,variant] [--patch-file FILE]
                              [--patch-text TEXT|@FILE | --fix MODE] [--harness claude-code|pi] [--model M] [--effort E]
                              [--repeats N] [--read-only-setup] [--env orca|herdr|background] [--keep]
                              [--no-start] [--yes]
                                          Queue N (3) cells of each task and setup, interleaved, each in an
                                          isolated clone of the task's base. baseline runs as is; every
                                          other setup appends --patch-text to --patch-file (CLAUDE.md,
                                          AGENTS.md, .claude/skills/NAME/SKILL.md) in its clone only.
                                          --read-only-setup adds a sanity setup with read-only tools that
                                          must fail. Cells already done (same task, setup, base, repeat)
                                          are skipped. The agent defaults to Claude Code with your model.
                                          The number of cells and the ≈ cost first; --yes queues them
          akit analysis control run [TASK[,TASK…]] --layer LAYER [--answer FIELD=VALUE]… [--eval ID]
                              [--brain DIR] [--model M] [--effort E] [--repeats N] [--read-only-setup]
                              [--env orca|herdr|background] [--keep] [--no-start] [--yes]
                                          A layer eval (Claude Code only): the brain layer is rendered
                                          once from a clean brain commit, and each cell gets either its
                                          required layers alone ("without LAYER") or them and LAYER
                                          ("layer LAYER") in its clone. Field answers: --answer, then
                                          the project's saved answers, then the layer's defaults (bool
                                          true|false, a list a,b). Tasks whose clone can't take the
                                          layer are listed and left out. --read-only-setup adds 1 read-
                                          only cell on each of the first 3 tasks. A new eval queues new
                                          cells; --eval ID continues one (its tasks, setups and repeats;
                                          no task list needed) while the layer renders the same files.
                                          Pairs only within one eval
          akit analysis control compare TASK[,TASK…] [--json]
                                          pass@1 and pass^k per setup with 95% intervals, and for each
                                          variant the paired bootstrap over tasks: "helped" when at least
                                          95% of its mass is on improvement (3+ repeats, 15+ cells a side)
                                          and the applied fix is not worse in production; without
                                          production data, no conclusion. Cells with dropped or changed
                                          tests, or that read the exemplar, count as failed. A layer
                                          pairs only with its eval's required layers; no conclusion yet
        """

    static func analysisControl(_ args: inout Arguments, options: AnalysisOptions, env: HarnessEnvironment, cwd: URL, projectsRoot: URL,
                                out: (String) -> Void, trash: (URL) throws -> URL?) async throws -> Int32 {
        let json = options.json
        let command = args.positional()
        // Only cells run an agent; the other commands take none of its flags.
        if let command, command != "run" { try options.refuseModelFlags("control \(command)") }
        switch command {
        case "task":
            switch args.positional() {
            case "new": return try await newControlTask(&args, env: env, cwd: cwd, out: out)
            case "remove":
                guard let id = args.positional() else { throw Failure(message: "Which task? akit analysis control task remove ID.") }
                try args.finish()
                do {
                    try ControlTasks.remove(id, env: env, trash: trash)
                } catch {
                    throw Failure(message: error.localizedDescription)
                }
                out("Moved control task \(id) to the Trash.")
                return 0
            case "check":
                guard let id = args.positional() else { throw Failure(message: "Which task? akit analysis control task check ID.") }
                try args.finish()
                guard let task = ControlTasks.load(id, env: env) else { throw Failure(message: "No control task \(id).") }
                do {
                    let checked = try await ControlTasks.checkReference(task, env: env, out: { LinePrinter.shared.print($0) })
                    out(checked.referenceGreen == true ? "The tests pass on the reference commit: the oracle can tell a fix."
                        : "The tests fail on the reference commit: fix the test command or the reference before running cells.")
                } catch {
                    throw Failure(message: error.localizedDescription)
                }
                return 0
            default:
                throw Failure(message: "akit analysis control task new|check|remove ….")
            }
        case "tasks":
            try args.finish()
            let tasks = ControlTasks.list(env: env)
            if json { out(try labJSON(tasks)); return 0 }
            out(tasks.isEmpty ? "No control tasks." : tasks.map(controlTaskLine).joined(separator: "\n"))
            return 0
        case "run":
            return try await runControl(&args, options: options, env: env, cwd: cwd, projectsRoot: projectsRoot, out: out)
        case "compare":
            guard let list = args.positional() else { throw Failure(message: "Which tasks? akit analysis control compare TASK[,TASK…].") }
            try args.finish()
            let tasks = try controlTasks(list, env: env)
            let ids = Set(tasks.map(\.id))
            let runs = LabStore.list(env: env).filter { $0.spec.kind == .control && $0.spec.controlTask.map(ids.contains) == true }
            let comparison = ControlComparison.compare(ControlComparison.Cell.of(runs),
                                                       production: try await ControlComparison.production(for: tasks, env: env))
            if json { out(try labJSON(comparison)); return 0 }
            let open = runs.filter { $0.status == .queued || $0.status == .running }.count
            out(comparisonText(comparison, tasks: tasks, open: open))
            return 0
        case let other:
            throw Failure(message: "Unknown “akit analysis control \(other ?? "")”. Run akit analysis --help.")
        }
    }

    private static func newControlTask(_ args: inout Arguments, env: HarnessEnvironment, cwd: URL, out: (String) -> Void) async throws -> Int32 {
        let session = args.value("--session")
        let repo = args.value("--repo")
        let base = args.value("--base")
        let prompt = args.value("--prompt")
        let mode = args.value("--mode")
        let tests = args.value("--tests")
        let assert = args.value("--assert")
        let reference = args.value("--reference")
        try args.finish()
        let oracle: ControlTask.Oracle
        switch (tests, assert) {
        case (let command?, nil): oracle = .tests(command: command)
        case (nil, let modeID?): oracle = .assertion(modeID: modeID)
        default: throw Failure(message: "Give the oracle: --tests CMD or --assert MODE (one of them).")
        }
        // A success mode's assertion passes when the strategy shows; the mode's kind says which.
        var success = false
        if let assert { success = try await ModeStore(env: env).mode(assert)?.kind == .success }
        let modeID = mode ?? assert
        let task: ControlTask
        do {
            if let session {
                guard repo == nil, base == nil, prompt == nil else {
                    throw Failure(message: "--session takes the repository, base and prompt from the session; leave out --repo, --base and --prompt.")
                }
                task = try await ControlTasks.fromSession(try controlSession(session, cwd: cwd, env: env), modeID: modeID, oracle: oracle,
                                                          successMode: success, reference: reference, env: env)
            } else {
                guard let base, let prompt else {
                    throw Failure(message: "Give --session SESSION, or --repo DIR --base SHA --prompt TEXT for a reproduction.")
                }
                task = try await ControlTasks.reproduction(repo: repo.map { resolve($0, cwd: cwd, env: env) } ?? cwd, base: base,
                                                           prompt: prompt, modeID: modeID, oracle: oracle, successMode: success,
                                                           reference: reference, env: env)
            }
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure(message: error.localizedDescription)
        }
        try ControlTasks.save(task, env: env)
        out("Saved control task \(task.id): \(task.title)")
        out("  \(task.repo) at \(String(task.base.prefix(7))) · \(task.oracle.label)")
        return 0
    }

    /// `--harness`, `--model`, `--effort` and `--yes` were taken out of `args` by `akit analysis`.
    private static func runControl(_ args: inout Arguments, options: AnalysisOptions, env: HarnessEnvironment, cwd: URL, projectsRoot: URL,
                                   out: (String) -> Void) async throws -> Int32 {
        let layer = args.value("--layer")
        let answerTexts = args.values("--answer")
        let evalID = args.value("--eval")
        let brainText = args.value("--brain")
        let setupsText = args.value("--setups")
        var patchFile = args.value("--patch-file")
        var patchText = args.value("--patch-text")
        let fixMode = args.value("--fix")
        let harnessText = options.harness
        let model = options.model
        let effort = options.effort
        let repeatsText = args.value("--repeats")
        let environmentText = args.value("--env")
        let readOnly = args.flag("--read-only-setup")
        let keep = args.flag("--keep")
        let noStart = args.flag("--no-start")
        let list = args.positional()
        try args.finish()
        // Continue of a layer eval: its own tasks and repeats, never others.
        var continued: LayerEvalManifest?
        if let evalID {
            guard layer != nil else { throw Failure(message: "--answer, --eval and --brain go with --layer.") }
            guard let manifest = LayerEvalStore.manifest(evalID, env: env) else {
                throw Failure(message: LayerEvalStore.problem(evalID, env: env) ?? "No eval \(evalID).")
            }
            continued = manifest
        }
        let tasks: [ControlTask]
        if let continued {
            if let list, Set(try controlTasks(list, env: env).map(\.id)) != Set(continued.tasks) {
                throw Failure(message: "The eval \(continued.id) runs its own tasks (\(continued.tasks.joined(separator: ", "))); "
                                  + "leave out the task list, or give exactly those.")
            }
            tasks = continued.tasks.compactMap { ControlTasks.load($0, env: env) }
        } else {
            guard let list else { throw Failure(message: "Which tasks? akit analysis control run TASK[,TASK…].") }
            tasks = try controlTasks(list, env: env)
        }
        let environment = try labEnvironment(environmentText, env: env)
        guard let harness = LabHarness(rawValue: harnessText ?? "claude-code") else { throw Failure(message: "--harness is claude-code or pi.") }
        var agent = LabRuns.defaultAgent(harness, env: env)
        if let model { agent.model = model }
        if let effort { agent.effort = effort }
        guard harness.efforts.contains(agent.effort) else {
            throw Failure(message: "--effort for \(harness.title) is one of \(harness.efforts.joined(separator: ", ")).")
        }
        guard harness == .pi || !agent.model.isEmpty else { throw Failure(message: "Which model? --model.") }
        let repeats: Int
        if let continued {
            if let given = try positiveNumber(repeatsText, "--repeats"), given != continued.repeats {
                throw Failure(message: "The eval \(continued.id) runs \(continued.repeats) repeats; leave out --repeats, "
                                  + "or give --repeats \(continued.repeats).")
            }
            repeats = continued.repeats
        } else {
            repeats = try positiveNumber(repeatsText, "--repeats") ?? 3
        }

        if let layer {
            guard setupsText == nil, patchFile == nil, patchText == nil, fixMode == nil else {
                throw Failure(message: "--layer makes its own setups (without \(layer), layer \(layer)); leave out --setups, --patch-file, --patch-text and --fix.")
            }
            guard harness == .claudeCode else { throw Failure(message: "Layer evals run Claude Code only for now; leave out --harness pi.") }
            let brainRoot = brainText.map { resolve($0, cwd: cwd, env: env) } ?? Brain.defaultRoot(home: env.homeDirectory)
            return try await runLayerControl(layer, tasks: tasks, answerTexts: answerTexts, evalID: evalID, brainRoot: brainRoot, agent: agent,
                                             repeats: repeats, sanity: readOnly, environment: environment, keep: keep, noStart: noStart,
                                             options: options, env: env, projectsRoot: projectsRoot, out: out)
        }
        guard answerTexts.isEmpty, evalID == nil, brainText == nil else {
            throw Failure(message: "--answer, --eval and --brain go with --layer.")
        }

        if let fixMode {
            // The fix draft's text, in the file its layer names: the variant's one difference.
            guard patchFile == nil, patchText == nil else { throw Failure(message: "--fix takes the patch from the draft; leave out --patch-file and --patch-text.") }
            guard let draft = FixStore(env: env).load(fixMode), let fromDraft = draft.patch else {
                throw Failure(message: "No fix draft for \(fixMode) whose layer is a file (CLAUDE.md, AGENTS.md or a skill).")
            }
            patchFile = fromDraft.file
            patchText = fromDraft.text
        }
        let patch: ControlPatch?
        switch (patchFile, patchText) {
        case (nil, nil): patch = nil
        case (let file?, let text?):
            var content = text
            if text.hasPrefix("@") {
                let url = resolve(String(text.dropFirst()), cwd: cwd, env: env)
                guard let read = try? String(contentsOf: url, encoding: .utf8) else { throw Failure(message: "Can't read \(url.path).") }
                content = read
            }
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure(message: "The patch text is empty.") }
            patch = ControlPatch(file: file, text: content)
        default:
            throw Failure(message: "Give both --patch-file and --patch-text: the one difference from the baseline.")
        }
        let names = (setupsText ?? (patch == nil ? "baseline" : "baseline,variant")).split(separator: ",").map(String.init)
        var setups = try names.map { name in
            if name == "baseline" { return ControlSetup(name: name, agent: agent) }
            guard let patch else {
                throw Failure(message: "The setup \(name) needs --patch-file and --patch-text: its one difference from the baseline.")
            }
            return ControlSetup(name: name, agent: agent, patch: patch)
        }
        if readOnly { setups.append(ControlSetup(name: "read-only", agent: agent, readOnly: true)) }

        try printEstimate(cells: repeats * tasks.count * setups.count, agent: agent, env: env, out: out)
        guard options.yes else {
            out("Run it again with --yes to queue them.")
            return 0
        }
        let queued: (runs: [LabRun], skipped: Int)
        do {
            queued = try await ControlRuns.newControlRuns(tasks: tasks, setups: setups, repeats: repeats, environment: environment, keep: keep,
                                                         akit: ownExecutable, env: env)
        } catch {
            throw Failure(message: error.localizedDescription)
        }
        let skipped = queued.skipped > 0 ? " Skipped \(queued.skipped) cells already done or queued." : ""
        guard let first = queued.runs.first else {
            out("Nothing to queue.\(skipped)")
            return 0
        }
        out("Queued \(queued.runs.count) cells: \(repeats) × \(tasks.count) tasks × \(setups.map(\.label).joined(separator: ", "))"
            + " (\(first.spec.environment.title)).\(skipped)")
        if !noStart { try await startNext(env: env, out: out) }
        return 0
    }

    /// Agent runs cost money (Copilot bills per token): an estimate from the recorded cost of
    /// earlier control cells of the same harness and model, before anything is queued.
    private static func printEstimate(cells: Int, agent: LabAgent, env: HarnessEnvironment, out: (String) -> Void) throws {
        let earlier = SendLog.records(env: env).filter { $0.purpose == "control" && $0.harness == agent.harness && $0.model == agent.model }
        let costs = earlier.compactMap(\.usage.cost)
        if !costs.isEmpty {
            let estimate = costs.reduce(0, +) / Double(costs.count) * Double(cells)
            out(String(format: "Up to %d cells, ≈ $%.2f at the recorded cost of %d earlier cells.", cells, estimate, costs.count))
            do {
                try SendLog.checkLimit(estimate: estimate, settings: LabSettings.loadForSending(env: env), env: env)
            } catch {
                throw Failure(message: error.localizedDescription)
            }
        } else {
            out("Up to \(cells) cells; no estimate yet (no recorded cost of control cells with \(agent.harness.title) · \(agent.model)).")
        }
    }

    /// `akit analysis control run … --layer LAYER`: the eval's setups from the brain, what can't
    /// run and why, the estimate; with --yes the eval folder first, then the cells.
    private static func runLayerControl(_ layer: String, tasks: [ControlTask], answerTexts: [String], evalID: String?, brainRoot: URL,
                                        agent: LabAgent, repeats: Int, sanity: Bool, environment: LabEnvironment?, keep: Bool,
                                        noStart: Bool, options: AnalysisOptions, env: HarnessEnvironment, projectsRoot: URL,
                                        out: (String) -> Void) async throws -> Int32 {
        guard let brain = Brain.load(from: brainRoot) else {
            throw Failure(message: "No brain repo at \(brainRoot.path). Create it in AKit (Brain → Create Brain Repo) or pass --brain.")
        }
        let answers = try layerAnswers(answerTexts, layer: layer, brain: brain)
        let prepared: LayerSetups.Prepared
        do {
            prepared = try await LayerSetups.prepare(layer: layer, tasks: tasks, answers: answers, agent: agent, sanity: sanity,
                                                     continuing: evalID, homeSkills: claudeHomeSkills(env: env), brain: brainRoot,
                                                     store: ProjectStore.current(brain: brainRoot, home: env.homeDirectory),
                                                     projectsRoot: projectsRoot, env: env)
        } catch {
            throw Failure(message: error.localizedDescription)
        }
        out("Eval \(prepared.evalID)\(prepared.continuing ? " (continued)" : "") · brain \(prepared.brainCommit.prefix(7))")
        for setup in prepared.setups {
            out("  \(setup.label) · overlay \(setup.layer?.overlayHash.map { String($0.prefix(12)) } ?? "none (nothing written)")")
        }
        if let sanity = prepared.sanitySetup {
            out("  \(sanity.label) · 1 cell on each of \(prepared.sanityTasks.count) tasks (must fail)")
        }
        out(prepared.overlap.isEmpty ? "Home overlap: none." : "Home overlap:")
        prepared.overlap.forEach { out("  \($0)") }
        for (id, reason) in prepared.blocked.sorted(by: { $0.key < $1.key }) { out("Blocked \(id): \(reason)") }
        for (id, notes) in prepared.notes.sorted(by: { $0.key < $1.key }) { notes.forEach { out("Note \(id): \($0)") } }
        prepared.warnings.forEach { out("Warning: \($0)") }
        guard !prepared.runnable.isEmpty else { throw Failure(message: "No task can take the layer; see the blocked tasks above.") }

        let cells = repeats * prepared.runnable.count * prepared.setups.count + prepared.sanityTasks.count
        try printEstimate(cells: cells, agent: prepared.setups.first?.agent ?? agent, env: env, out: out)
        guard options.yes else {
            out("Run it again with --yes to queue them.")
            return 0
        }
        let queued: (runs: [LabRun], skipped: Int)
        do {
            // The eval folder first: a queued cell must find its overlay.
            try LayerEvalStore.create(prepared, repeats: repeats, env: env)
            queued = try await ControlRuns.newControlRuns(tasks: prepared.runnable, setups: prepared.setups, repeats: repeats,
                                                         sanity: prepared.sanitySetup.map { ($0, prepared.sanityTasks, 1) },
                                                         environment: environment, keep: keep, akit: ownExecutable, env: env)
        } catch {
            throw Failure(message: error.localizedDescription)
        }
        let skipped = queued.skipped > 0 ? " Skipped \(queued.skipped) cells already done or queued." : ""
        guard let first = queued.runs.first else {
            out("Nothing to queue.\(skipped)")
            return 0
        }
        out("Queued \(queued.runs.count) cells of eval \(prepared.evalID): \(repeats) × \(prepared.runnable.count) tasks × "
            + "\(prepared.setups.count) setups" + (prepared.sanityTasks.isEmpty ? "" : " + \(prepared.sanityTasks.count) read-only")
            + " (\(first.spec.environment.title)).\(skipped)")
        if !noStart { try await startNext(env: env, out: out) }
        return 0
    }

    /// `FIELD=VALUE` typed by the field's kind in the layer or the layers it requires: bool
    /// `true|false`, a list `a,b`, else text. An empty value is dropped (the default stays).
    static func layerAnswers(_ texts: [String], layer: String, brain: Brain) throws -> [String: FieldValue] {
        let byName = Dictionary(brain.layers.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        guard byName[layer] != nil else { throw Failure(message: "The brain has no layer \(layer).") }
        let fields = Brain.requiredClosure(of: layer, in: byName).sorted().flatMap { byName[$0]?.fields ?? [] }
        var answers: [String: FieldValue] = [:]
        for text in texts {
            guard let equals = text.firstIndex(of: "=") else { throw Failure(message: "--answer takes FIELD=VALUE, not \(text).") }
            let id = String(text[..<equals]).trimmingCharacters(in: .whitespaces)
            let value = String(text[text.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            guard let field = fields.first(where: { $0.id == id }) else {
                throw Failure(message: "\(layer) and the layers it requires have no field \(id)"
                                  + (fields.isEmpty ? "." : " (fields: \(fields.map(\.id).joined(separator: ", ")))."))
            }
            guard !value.isEmpty else { continue }
            switch field.kind {
            case .bool:
                guard ["true", "false"].contains(value.lowercased()) else { throw Failure(message: "\(id) is true or false.") }
                answers[id] = .bool(value.lowercased() == "true")
            case .multi:
                answers[id] = .list(value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
            case .text, .choice:
                answers[id] = .text(value)
            }
        }
        return answers
    }

    /// Skill names Claude Code has outside any project: the home folder's, synced and plugin
    /// skills. A layer skill with one of these names overlaps.
    static func claudeHomeSkills(env: HarnessEnvironment) -> Set<String> {
        let skills = SkillScanner.scan(installations: HarnessCatalog.detectAll(in: env), in: env)
        return Set(skills.filter { skill in
            guard skill.visibleTo.contains(.claudeCode) else { return false }
            if case .project = skill.scope { return false }
            return true
        }.map(\.name))
    }

    /// Tasks by id or a unique id prefix, comma-separated.
    private static func controlTasks(_ list: String, env: HarnessEnvironment) throws -> [ControlTask] {
        let all = ControlTasks.list(env: env)
        return try list.split(separator: ",").map { part in
            let id = String(part)
            if let task = all.first(where: { $0.id == id }) { return task }
            let matches = all.filter { $0.id.hasPrefix(id) }
            guard matches.count == 1 else {
                throw Failure(message: matches.isEmpty ? "No control task \(id) (akit analysis control tasks)." : "\(id) matches several tasks.")
            }
            return matches[0]
        }
    }

    /// A session key from the index, or a transcript file or session id (Claude Code or Pi).
    private static func controlSession(_ text: String, cwd: URL, env: HarnessEnvironment) throws -> SessionSummary {
        if SessionKey(parsing: text) != nil {
            guard let database = try AnalysisIndex.open(env: env),
                  let session = try AnalysisIndex.sessions(database).first(where: { $0.key == text }) else {
                throw Failure(message: "No session \(text) in the index. Run akit sessions import first.")
            }
            guard let summary = IndexedSessions.summary(session) else { throw Failure(message: "The file of \(text) is gone.") }
            return summary
        }
        let file = try transcript(text, cwd: cwd, env: env)
        let info = JSONLines.fileInfo(file)
        return SessionSummary(harness: LabPaths.harness(ofTranscript: file), file: file,
                              title: file.deletingPathExtension().lastPathComponent, project: LabPaths.folder(ofTranscript: file),
                              started: nil, modified: info.modified, size: info.size)
    }

    private static func controlTaskLine(_ task: ControlTask) -> String {
        let source = switch task.source {
        case .session(let key): "from \(key)"
        case .reproduction: "reproduction"
        }
        return "\(task.id)  \(String(task.base.prefix(7)))  \(task.oracle.label)  \(source)  \(task.title)"
    }

    static func comparisonText(_ comparison: ControlComparison, tasks: [ControlTask], open: Int) -> String {
        func percent(_ value: Double?) -> String { value.map { String(format: "%.0f%%", 100 * $0) } ?? "–" }
        func interval(_ value: Stats.Interval) -> String { String(format: "95%% %.0f–%.0f%%", 100 * value.low, 100 * value.high) }
        guard !comparison.rows.isEmpty else {
            return "No finished cells of \(tasks.map(\.id).joined(separator: ", ")) yet." + (open > 0 ? " \(open) queued or running." : "")
        }
        var lines: [String] = []
        for row in comparison.rows {
            lines.append(row.setup.label)
            let allPassed = row.tasks.filter { $0.passed == $0.total }.count
            lines.append("  pass@1 \(percent(row.passAt1)) (\(interval(row.passAt1Interval))) · pass^\(row.k) \(allPassed)/\(row.tasks.count) tasks"
                         + " (\(interval(row.passHatKInterval))) · \(row.cells) cells" + (row.flagged > 0 ? ", \(row.flagged) flagged (counted as failed)" : ""))
            for rate in row.tasks { lines.append("    \(rate.task)  \(rate.passed)/\(rate.total)") }
        }
        for pair in comparison.paired {
            let change = pair.meanChange.map { String(format: "%+.0f points", 100 * $0) } ?? "–"
            lines.append("")
            lines.append("\(pair.variant.name) vs \(pair.baseline.name): \(change) per task over \(pair.tasks) tasks; "
                         + "\(percent(pair.improvementShare)) of the bootstrap mass on improvement: \(pair.verdict.title).")
            lines.append("  \(pair.reason)")
            if pair.harnessVersions.count > 1 { lines.append("  The cells mix Claude Code versions: \(pair.harnessVersions.joined(separator: ", ")).") }
        }
        if comparison.leftOut > 0 {
            lines.append("\(comparison.leftOut) cells run by an older akit, left out: it ignored the layer. Install the app and akit together.")
        }
        if open > 0 { lines.append("\(open) cells still queued or running.") }
        return lines.joined(separator: "\n")
    }
}
