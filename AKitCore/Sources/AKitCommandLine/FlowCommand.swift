import AKitFlows
import AKitFoundation
import Foundation

/// `akit flow`: read and check the flow files Pi runs (docs/design/flows.md F12). AKit only models
/// a flow; Pi runs it (`/flow` in Pi), so there is no `akit flow run`.
extension AKitCLI {
    static let flowUsage = """
    akit flow: the flows Pi runs with /flow (docs/design/flows.md). Flow files are the project's
    .pi/flows/*.yaml, then ~/.pi/agent/flows/*.yaml; a project flow hides a home flow of the same
    name. AKit writes them (Apply); this command only reads.

      akit flow list [--project PATH] [--json]
                                        The flows with their scope and steps, or why a file can't
                                        be read. --json: [{name, scope, path, steps, error}]
      akit flow show NAME [--project PATH] [--json]
                                        A flow's steps: agent, model, skills, tools, routes, gate,
                                        max loops. --json: {name, scope, path, flow}
      akit flow check [NAME] [--project PATH] [--json]
                                        Check one flow or all before Apply: routes exist and are
                                        well formed, failed/blocked routes go back to an earlier
                                        step, step tools are in the flow's tools, no nested flows,
                                        check commands are plain (≤ 10, ≤ 120 chars), skills exist,
                                        reviewer and implementer models differ, this Mac's Pi has
                                        the features. Exit 1 on an error.
                                        --json: [{name, path, issues: [{severity, code, step, message}]}]
      akit flow schema                  Print flow.schema.json, the JSON Schema of a flow file.

    --project: the project folder (default: the current folder).
    """

    static func flow(_ arguments: [String], env: HarnessEnvironment, cwd: URL, out: (String) -> Void) throws -> Int32 {
        var args = Arguments(arguments)
        if args.flag("--help") || args.flag("-h") || args.isEmpty {
            out(flowUsage)
            return 0
        }
        let json = args.flag("--json")
        let project = resolve(args.value("--project") ?? ".", cwd: cwd, env: env)
        let command = args.positional()
        let tilde = { (url: URL) in FileWalk.tilde(url, home: env.homeDirectory) }
        switch command {
        case "schema":
            try args.finish()
            out(FlowSchema.text.trimmingCharacters(in: .newlines))
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
                    FlowCheck.check($0, knownModels: nil, knownSkills: skills, pi: pi)
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
        default:
            throw Failure(message: "Use: akit flow list|show NAME|check [NAME]|schema [--project PATH] [--json]. akit flow --help for more.")
        }
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
                         + "\(step.gate ? ", gate" : ""), max loops \(step.maxLoops)")
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
