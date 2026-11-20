import AKitBrain
import AKitFlows
import AKitFoundation
import AKitRender
import Foundation

/// `akit flow`: read and check the flow files Pi runs (docs/design/flows.md F12), export one for a
/// review, and edit the brain's flows as the Flows screen does (F23). AKit only models a flow; Pi
/// runs it (`/flow` in Pi), so there is no `akit flow run`.
extension AKitCLI {
    static let flowUsage = """
    akit flow: the flows Pi runs with /flow (docs/design/flows.md). Flow files are the project's
    .pi/flows/*.yaml, then ~/.pi/agent/flows/*.yaml; a project flow hides a home flow of the same
    name. AKit writes them (Apply). The edit commands change the brain's flows/NAME.yaml, the file
    the Flows screen saves; Pi gets the change after Apply.

      akit flow list [--project PATH] [--json]
                                        The flows with their scope and steps, or why a file can't
                                        be read. --json: [{name, scope, path, steps, error}]
      akit flow show NAME [--project PATH] [--json]
                                        A flow's steps: agent, model, skills, tools, routes, gate,
                                        max rounds. --json: {name, scope, path, flow}
      akit flow check [NAME] [--project PATH] [--json]
                                        Check one flow or all before Apply: routes exist and are
                                        well formed, failed/blocked routes go back to an earlier
                                        step, step tools are in the flow's tools, no nested flows,
                                        check commands are plain (≤ 10, ≤ 120 chars), skills exist,
                                        reviewer and implementer models differ, this Mac's Pi has
                                        the features. Exit 1 on an error.
                                        --json: [{name, path, issues: [{severity, code, step, message}]}]
      akit flow runs [--project PATH] [--json]
                                        The project's runs (.pi/akit-flow/runs), newest first: status,
                                        steps with state, time, tokens, deviations, and steps the
                                        routes forbid. Read only (Stop is a button on the Runs screen).
                                        --json: [{id, flow, task, project, status, stopReason,
                                        stopRequested, pi, tokens, deviations, attempts: [{step,
                                        attempt, state, reason, seconds, tokens, deviations, evidence,
                                        session, forbiddenNext}], problems}]
      akit flow schema                  Print flow.schema.json, the JSON Schema of a flow file.
      akit flow export NAME [--out FILE] [--project PATH] [--brain PATH]
                                        The review pack (Export for Review on the Flows screen): a
                                        Markdown file for an agent with a fresh context. The flow at
                                        a glance, how the runner works, each step's settings,
                                        routes, child command, instructions, first-round prompt and
                                        skill texts, the flow file and the runner's prompt code.
                                        Secrets are masked. The brain's flow, else the Pi file.

    Edit a brain flow (brain/flows/NAME.yaml). Without --yes: the diff and the check, nothing
    written. --yes: write and commit. A change that adds a check error is refused.
    --json: {name, path, written, diff: [line], issues: [{severity, code, step, message}]}
      akit flow set NAME STEP FIELD VALUE|--file FILE|--file - [--yes] [--json] [--brain PATH]
                                        One step field: agent, model, harness (pi, claude-code),
                                        thinking (default, off … max), prompt (the instructions;
                                        --file reads them, - from stdin), skills, tools, paths,
                                        extensions (comma lists), checks (; list), bash, gate
                                        (yes/no), max-rounds (1-9). none clears a list.
      akit flow set-flow NAME FIELD VALUE [--yes]
                                        The flow's tools (comma list) or minPi.
      akit flow route NAME STEP KEY TARGET [--yes]
                                        KEY: done, failed, blocked, or outcome:reason (failed:tests).
                                        TARGET: a step, end, or stop (removes the route: done goes
                                        on, failed and blocked stop and ask).
      akit flow add-step NAME AGENT --model M [--id ID] [--after STEP] [--yes]
                                        A new step with the agent's template instructions.
      akit flow remove-step NAME STEP [--yes]
                                        Removes it and every route to it.
      akit flow move-step NAME STEP (--after STEP | --first) [--yes]

    --project: the project folder (default: the current folder). --brain: the brain (default
    ~/.akit/registry).
    """

    static func flow(_ arguments: [String], env: HarnessEnvironment, cwd: URL, out: (String) -> Void,
                     input: () -> Data = { Data() }) async throws -> Int32 {
        var args = Arguments(arguments)
        if args.flag("--help") || args.flag("-h") || args.isEmpty {
            out(flowUsage)
            return 0
        }
        let json = args.flag("--json")
        let project = resolve(args.value("--project") ?? ".", cwd: cwd, env: env)
        let brainRoot = args.value("--brain").map { resolve($0, cwd: cwd, env: env) } ?? Brain.defaultRoot(home: env.homeDirectory)
        let command = args.positional()
        let tilde = { (url: URL) in FileWalk.tilde(url, home: env.homeDirectory) }
        switch command {
        case "schema":
            try args.finish()
            out(FlowSchema.text.trimmingCharacters(in: .newlines))
            return 0
        case "runs":
            try args.finish()
            let runs = FlowRunSummary.all(projects: [project], env: env)
            if json {
                out(encode(runs.map(FlowRunReport.init)))
                return 0
            }
            if runs.isEmpty {
                out("No flow runs in \(tilde(project.appending(path: ".pi/akit-flow/runs"))).")
                return 0
            }
            out(runs.map(runText).joined(separator: "\n"))
            return 0
        case "list":
            try args.finish()
            let files = FlowFile.list(project: project, env: env)
            if json {
                struct Item: Encodable { let name: String, scope: String, path: String, steps: [String]?, error: String? }
                out(encode(files.map { Item(name: $0.name, scope: $0.scope.rawValue, path: $0.url.path, steps: $0.flow?.steps.map(\.id),
                                            error: $0.error) }))
                return 0
            }
            if files.isEmpty {
                out("No flows in \(tilde(project.appending(path: ".pi/flows"))) or \(tilde(env.piAgentDirectory.appending(path: "flows"))).")
                return 0
            }
            out(files.map { file in
                let body = file.flow.map { $0.steps.map(\.id).joined(separator: " → ") } ?? "can't read: \(file.error ?? "")"
                return "\(file.name) (\(file.scope.rawValue), \(tilde(file.url))): \(body)"
            }.joined(separator: "\n"))
            return 0
        case "show":
            guard let name = args.positional() else { throw Failure(message: "Use: akit flow show NAME [--project PATH] [--json]") }
            try args.finish()
            let file = try flowFile(name, project: project, env: env)
            guard let flow = file.flow else { throw Failure(message: "\(tilde(file.url)) can't be read: \(file.error ?? "")") }
            if json {
                struct Answer: Encodable { let name: String, scope: String, path: String, flow: Flow }
                out(encode(Answer(name: file.name, scope: file.scope.rawValue, path: file.url.path, flow: flow)))
                return 0
            }
            out(flowText(flow, file: file, tilde: tilde))
            return 0
        case "check":
            let name = args.positional()
            try args.finish()
            let files = try name.map { [try flowFile($0, project: project, env: env)] } ?? FlowFile.list(project: project, env: env)
            let skills = FlowFile.knownSkills(project: project, env: env)
            let pi = FlowFile.capabilities(env: env)
            struct Report: Encodable { let name: String, path: String, issues: [FlowIssue] }
            let reports = files.map { file in
                Report(name: file.name, path: file.url.path, issues: file.flow.map {
                    FlowCheck.check($0, knownModels: nil, knownSkills: skills, pi: pi, claudeSkills: FlowFile.claudeSkills(project: project, env: env))
                } ?? [FlowIssue(.error, .unreadable, file.error ?? "can't read")])
            }
            let failed = reports.contains { $0.issues.contains { $0.severity == .error } }
            if json {
                out(encode(reports))
            } else if reports.isEmpty {
                out("No flows to check.")
            } else {
                out(reports.map { report in
                    let errors = report.issues.filter { $0.severity == .error }.count
                    var lines = ["\(report.name): \(errors == 0 ? "ok" : count(errors, "error"))"]
                    lines += report.issues.map { "  \($0.severity == .error ? "error" : "warning"): \($0.message)" }
                    return lines.joined(separator: "\n")
                }.joined(separator: "\n"))
            }
            return failed ? 1 : 0
        case "export":
            guard let name = args.positional() else { throw Failure(message: "Use: akit flow export NAME [--out FILE] [--project PATH] [--brain PATH]") }
            let file = args.value("--out").map { resolve($0, cwd: cwd, env: env) }
            try args.finish()
            let flow: Flow, source: String
            if let brain = Brain.load(from: brainRoot), BrainFlows.names(in: brain.root).contains(name) {
                flow = try brainFlow(name, brain: brain)
                source = "brain/flows/\(name).yaml"
            } else {
                let found = try flowFile(name, project: project, env: env)
                guard let read = found.flow else { throw Failure(message: "\(tilde(found.url)) can't be read: \(found.error ?? "")") }
                flow = read
                source = tilde(found.url)
            }
            let issues = FlowCheck.check(flow, knownModels: nil, knownSkills: FlowFile.knownSkills(project: project, env: env),
                                         pi: FlowFile.capabilities(env: env), claudeSkills: FlowFile.claudeSkills(project: project, env: env))
            let export = FlowReviewExport.markdown(flow: flow, source: source, project: project, env: env, issues: issues,
                                                   runner: FlowRender.reviewExcerpts.map { .init(title: $0.title, file: $0.file, code: $0.code) })
            guard let file else {
                out(export.text)
                return 0
            }
            do { try Data(export.text.utf8).write(to: file, options: .atomic) } catch {
                throw Failure(message: "Can't write \(tilde(file)): \(error.localizedDescription)")
            }
            out("Wrote \(tilde(file))\(export.masked > 0 ? " (\(count(export.masked, "value")) masked)" : "").")
            return 0
        case "set", "set-flow", "route", "add-step", "remove-step", "move-step":
            return try await flowEdit(command!, args: &args, json: json, brainRoot: brainRoot, project: project, env: env, cwd: cwd,
                                      out: out, input: input)
        default:
            throw Failure(message: "Use: akit flow list|show NAME|check [NAME]|runs|schema|export NAME|set|set-flow|route|add-step|remove-step|move-step. akit flow --help for more.")
        }
    }

    static func runText(_ summary: FlowRunSummary) -> String {
        let report = FlowRunReport(summary)
        var lines = ["\(report.id) \(report.flow ?? "?"): \(report.status.rawValue)\(report.stopReason.map { " (\($0))" } ?? "")"
                     + "\(report.stopRequested ? ", STOP requested" : "")\(report.task.map { " · \($0)" } ?? "")"
                     + " · \(count(report.deviations, "deviation"))"]
        for attempt in report.attempts {
            let tokens = attempt.tokens.map { "\(($0.input ?? 0) + ($0.output ?? 0)) tokens" } ?? "tokens unknown"
            lines.append("  \(attempt.step) #\(attempt.attempt): \(attempt.state.rawValue)\(attempt.reason.flatMap { $0.isEmpty ? nil : ":\($0)" } ?? ""), \(tokens)"
                         + (attempt.forbiddenNext.map { ", then \($0): the routes forbid it" } ?? ""))
            lines += attempt.deviations.map { "    ⚠ \($0)" }
        }
        lines += report.problems.map { "  problem: \($0)" }
        return lines.joined(separator: "\n")
    }

    /// The edit commands: change the brain flow, check it, show the diff; --yes writes and commits.
    private static func flowEdit(_ command: String, args: inout Arguments, json: Bool, brainRoot: URL, project: URL, env: HarnessEnvironment,
                                 cwd: URL, out: (String) -> Void, input: () -> Data) async throws -> Int32 {
        let yes = args.flag("--yes")
        let file = args.value("--file"), after = args.value("--after"), model = args.value("--model"), id = args.value("--id")
        let first = args.flag("--first")
        guard let name = args.positional() else { throw Failure(message: "Use: akit flow \(command) NAME … (akit flow --help)") }
        guard let brain = Brain.load(from: brainRoot) else { throw Failure(message: "No brain at \(brainRoot.path). Create one with akit init.") }
        let old = try brainFlow(name, brain: brain)
        var words: [String] = []
        while let word = args.positional() { words.append(word) }
        try args.finish()
        let use = { (form: String) in Failure(message: "Use: akit flow \(command) NAME \(form) [--yes] [--json]") }
        let new: Flow
        do {
            switch command {
            case "set":
                guard words.count == (file == nil ? 3 : 2) else { throw use("STEP FIELD VALUE|--file FILE") }
                var value = words.count == 3 ? words[2] : ""
                if let file {
                    if file == "-" { value = String(decoding: input(), as: UTF8.self) } else {
                        guard let text = try? String(contentsOf: resolve(file, cwd: cwd, env: env), encoding: .utf8) else {
                            throw Failure(message: "Can't read \(file).")
                        }
                        value = text
                    }
                }
                new = try FlowEdit.set(old, step: words[0], field: words[1], value: value)
            case "set-flow":
                guard words.count == 2 else { throw use("FIELD VALUE") }
                new = try FlowEdit.setFlow(old, field: words[0], value: words[1])
            case "route":
                guard words.count == 3 else { throw use("STEP KEY TARGET") }
                new = try FlowEdit.route(old, step: words[0], key: words[1], target: words[2])
            case "add-step":
                guard words.count == 1, let model else { throw use("AGENT --model M [--id ID] [--after STEP]") }
                new = try FlowEdit.addStep(old, id: id, agent: words[0], model: model, after: after)
            case "remove-step":
                guard words.count == 1 else { throw use("STEP") }
                new = try FlowEdit.removeStep(old, step: words[0])
            default:
                guard words.count == 1, (after != nil) != first else { throw use("STEP (--after STEP | --first)") }
                new = try FlowEdit.moveStep(old, step: words[0], after: after)
            }
        } catch let error as FlowEdit.Failure {
            throw Failure(message: error.message)
        }
        let check = { (flow: Flow) in
            FlowCheck.check(flow, knownModels: nil, knownSkills: FlowFile.knownSkills(project: project, env: env), pi: FlowFile.capabilities(env: env),
                            claudeSkills: FlowFile.claudeSkills(project: project, env: env))
        }
        let issues = check(new)
        let before = Set(check(old).filter { $0.severity == .error }.map(\.message))
        let added = issues.filter { $0.severity == .error && !before.contains($0.message) }
        let oldText = try old.yaml(), newText = try new.yaml()
        let diff = TextDiff.unified(TextDiff.lines(from: oldText, to: newText))
        let path = BrainFlows.url(of: name, in: brain.root).path
        let written = yes && added.isEmpty && !diff.isEmpty
        if written {
            do { try await BrainFlows.save(name, text: newText, in: brain, env: env) } catch { throw Failure(message: error.message) }
        }
        if json {
            struct Answer: Encodable { let name: String, path: String, written: Bool, diff: [String], issues: [FlowIssue] }
            out(encode(Answer(name: name, path: path, written: written, diff: diff, issues: issues)))
            return added.isEmpty ? 0 : 1
        }
        var lines: [String] = []
        if diff.isEmpty { lines.append("No change: flows/\(name).yaml already says that.") } else { lines += diff }
        lines += issues.map { "\($0.severity == .error ? "error" : "warning"): \($0.message)" }
        if !added.isEmpty {
            lines.append("Not written: the change adds \(count(added.count, "check error")).")
        } else if written {
            lines.append("Updated \(FileWalk.tilde(URL(filePath: path), home: env.homeDirectory)), committed. Pi gets it after Apply "
                         + "(Apply… on the Flows screen, or akit apply --home for the core layer).")
        } else if !diff.isEmpty {
            lines.append("Run again with --yes to write and commit it.")
        }
        out(lines.joined(separator: "\n"))
        return added.isEmpty ? 0 : 1
    }

    private static func brainFlow(_ name: String, brain: Brain) throws -> Flow {
        let url = BrainFlows.url(of: name, in: brain.root)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw Failure(message: "No flow \(name) in the brain (\(BrainFlows.names(in: brain.root).joined(separator: ", "))).")
        }
        do { return try Flow.decode(yaml: text) } catch { throw Failure(message: "flows/\(name).yaml can't be read: \(error.message)") }
    }

    private static func flowFile(_ name: String, project: URL, env: HarnessEnvironment) throws -> FlowFile {
        guard let file = FlowFile.list(project: project, env: env).first(where: { $0.name == name }) else {
            throw Failure(message: "No flow \(name). akit flow list shows the flows.")
        }
        return file
    }

    static func flowText(_ flow: Flow, file: FlowFile, tilde: (URL) -> String) -> String {
        var lines = ["\(flow.name) (\(file.scope.rawValue), \(tilde(file.url))), format \(flow.format), Pi ≥ \(flow.minPi)"]
        if !flow.tools.isEmpty { lines.append("Tools: \(flow.tools.joined(separator: ", "))") }
        for (index, step) in flow.steps.enumerated() {
            lines.append("\(index + 1) \(step.id): \(step.agent), \(step.model)\(step.thinking.map { " (thinking \($0))" } ?? "")"
                         + "\(step.gate ? ", gate" : ""), max rounds \(step.maxLoops)")
            if !step.skills.isEmpty { lines.append("    skills: \(step.skills.joined(separator: ", "))") }
            if !step.tools.isEmpty { lines.append("    tools: \(step.tools.joined(separator: ", "))\(step.bash ? "" : ", no bash")") }
            if !step.paths.isEmpty { lines.append("    writes: \(step.paths.joined(separator: ", "))") }
            if !step.extensions.isEmpty { lines.append("    extensions: \(step.extensions.joined(separator: ", "))") }
            if !step.checks.isEmpty { lines.append("    checks: \(step.checks.joined(separator: "; "))") }
            for (key, target) in step.routes.sorted(by: { $0.key < $1.key }) { lines.append("    \(key) → \(target)") }
        }
        return lines.joined(separator: "\n")
    }
}

private extension FlowFile {
    var error: String? {
        if case .failure(let error) = result { return error.message }
        return nil
    }
}
