import Foundation

/// What this Mac's Pi can do: its version and the features the probe found (F20,
/// `~/.akit/local/pi-capabilities.json`). Feature names are `FlowPiFeature` raw values.
public struct PiCapabilities: Codable, Equatable, Sendable {
    public var version: String?
    public var features: Set<String>

    public init(version: String?, features: Set<String>) {
        self.version = version
        self.features = features
    }
}

/// Pi features a flow needs at run time (flows.md, "Pi facts").
public enum FlowPiFeature: String, CaseIterable, Sendable {
    case modeJSON = "mode-json"
    case sessionDir = "session-dir"
    case noExtensions = "no-extensions"
    case noSkills = "no-skills"
    case skill
    case toolCallBlock = "tool-call-block"
    case thinking
    case uiConfirm = "ui-confirm"

    /// What `flow` uses: the child command always; `--skill`, `--thinking` and gates only when a step has them.
    public static func required(by flow: Flow) -> [FlowPiFeature] {
        var needed: [FlowPiFeature] = [.modeJSON, .sessionDir, .noExtensions, .noSkills, .toolCallBlock]
        if flow.steps.contains(where: { !$0.skills.isEmpty }) { needed.append(.skill) }
        if flow.steps.contains(where: { $0.thinking != nil }) { needed.append(.thinking) }
        if flow.steps.contains(where: \.gate) { needed.append(.uiConfirm) }
        return needed
    }
}

/// One finding of `akit flow check`.
public struct FlowIssue: Codable, Equatable, Sendable {
    public enum Severity: String, Codable, Sendable { case error, warning }

    public enum Code: String, Codable, Sendable {
        case unreadable
        case noSteps = "no-steps"
        case newerFormat = "newer-format"
        case duplicateStep = "duplicate-step"
        case unknownRouteTarget = "unknown-route-target"
        case malformedRouteKey = "malformed-route-key"
        case backRouteForward = "back-route-forward"
        case toolNotInFlow = "tool-not-in-flow"
        case nestedFlow = "nested-flow"
        case unsafeCheckCommand = "unsafe-check-command"
        case tooManyCheckCommands = "too-many-check-commands"
        case unknownModel = "unknown-model"
        case unknownSkill = "unknown-skill"
        case modelsNotChecked = "models-not-checked"
        case skillsNotChecked = "skills-not-checked"
        case reviewerSameModel = "reviewer-same-model"
        case piTooOld = "pi-too-old"
        case missingPiFeature = "missing-pi-feature"
        case piNotChecked = "pi-not-checked"
        case unknownHarness = "unknown-harness"
        case claudeStepWrites = "claude-step-writes"
        case claudeStepPiOnly = "claude-step-pi-only"
    }

    public var severity: Severity
    public var code: Code
    public var step: String?
    public var message: String

    public init(_ severity: Severity, _ code: Code, step: String? = nil, _ message: String) {
        self.severity = severity
        self.code = code
        self.step = step
        self.message = message
    }
}

/// The checks before Apply (F3, F6, F13, F19, F20). Pure: the known models, skills and Pi
/// features come in as parameters; `nil` means unknown, which is a warning, not a pass.
public enum FlowCheck {
    /// OMC's verify-command rules (oh-my-claudecode 5.8.0 guardrails).
    public static let maxCheckCommands = 10
    public static let maxCheckLength = 120
    /// Tools that would start another agent or flow inside a step (D28, F13).
    public static let nestingTools: Set<String> = ["akit_flow", "subagent", "task", "agent"]

    private static var commandPattern: Regex<Substring> { /^[A-Za-z][A-Za-z0-9 _.:\/=%@-]*$/ }
    private static var routeKeyPattern: Regex<(Substring, Substring, Substring)> { /^(done|failed|blocked):(\*|[A-Za-z0-9][A-Za-z0-9_.-]*)$/ }

    /// A Claude Code step (F21) is read-only; its skills work (listed in its system prompt), Pi's
    /// extensions and path rules don't.
    static func claudeIssues(_ step: FlowStep, flowTools: [String]) -> [FlowIssue] {
        var issues: [FlowIssue] = []
        let writes = (step.tools.isEmpty ? flowTools : step.tools).filter { !FlowStep.claudeTools.contains($0) }
        if !writes.isEmpty {
            issues.append(.init(.error, .claudeStepWrites, step: step.id,
                                "Step \(step.id) runs on Claude Code, which is read-only in a flow: drop \(writes.joined(separator: ", ")) from its tools."))
        }
        if !step.extensions.isEmpty || !step.paths.isEmpty {
            issues.append(.init(.warning, .claudeStepPiOnly, step: step.id,
                                "Step \(step.id) runs on Claude Code: its extensions and paths are Pi's and are not used."))
        }
        return issues
    }

    /// `claudeSkills`: the skills in Claude Code's own folders, which a Claude Code step may load too.
    public static func check(_ flow: Flow, knownModels: Set<String>?, knownSkills: Set<String>?,
                             pi: PiCapabilities?, claudeSkills: Set<String> = []) -> [FlowIssue] {
        var issues: [FlowIssue] = []
        if flow.format > Flow.currentFormat {
            issues.append(.init(.error, .newerFormat, "akit-flow-format \(flow.format) is newer than this AKit (\(Flow.currentFormat)); update AKit."))
        }
        if flow.steps.isEmpty { issues.append(.init(.error, .noSteps, "The flow has no steps.")) }
        var seen = Set<String>()
        for step in flow.steps where !seen.insert(step.id).inserted {
            issues.append(.init(.error, .duplicateStep, step: step.id, "Step \(step.id) is in the flow twice."))
        }
        let flowTools = Set(flow.tools)
        for (index, step) in flow.steps.enumerated() {
            issues += routeIssues(step, at: index, in: flow)
            for tool in step.tools where !flowTools.contains(tool) {
                issues.append(.init(.error, .toolNotInFlow, step: step.id, "Tool \(tool) of step \(step.id) is not in the flow's tools."))
            }
            for tool in step.tools where nestingTools.contains(tool) {
                issues.append(.init(.error, .nestedFlow, step: step.id, "Step \(step.id) may not start agents or flows (\(tool)); make it another step."))
            }
            issues += commandIssues(step)
            if let harness = step.harness, harness != FlowStep.claudeCode {
                issues.append(.init(.error, .unknownHarness, step: step.id, "Step \(step.id) runs on \(harness); a step runs on Pi or claude-code."))
            }
            if step.isClaudeCode {
                issues += claudeIssues(step, flowTools: flow.tools)
            } else if let knownModels, !knownModels.contains(step.model) {
                issues.append(.init(.error, .unknownModel, step: step.id, "Model \(step.model) of step \(step.id) is not one Pi knows."))
            }
            if let knownSkills {
                let known = step.isClaudeCode ? knownSkills.union(claudeSkills) : knownSkills
                for skill in step.skills where !known.contains(skill) {
                    issues.append(.init(.error, .unknownSkill, step: step.id, step.isClaudeCode
                        ? "Skill \(skill) of step \(step.id) is in neither Pi's nor Claude Code's skill folders."
                        : "Skill \(skill) of step \(step.id) is not installed for Pi."))
                }
            }
        }
        if knownModels == nil { issues.append(.init(.warning, .modelsNotChecked, "Models not checked: the list of Pi's models is unknown here.")) }
        if knownSkills == nil { issues.append(.init(.warning, .skillsNotChecked, "Skills not checked: the list of Pi's skills is unknown here.")) }
        for reviewer in flow.steps {
            guard let judged = FlowTemplates.judgedMakers[reviewer.agent] else { continue }
            let implementers = flow.steps.filter { judged.contains($0.agent) }
            for implementer in implementers where implementer.model == reviewer.model {
                issues.append(.init(.error, .reviewerSameModel, step: reviewer.id,
                                    "Step \(reviewer.id) reviews with \(reviewer.model), the model of \(implementer.id); pick another model."))
            }
        }
        issues += piIssues(flow, pi: pi)
        return issues
    }

    static func routeIssues(_ step: FlowStep, at index: Int, in flow: Flow) -> [FlowIssue] {
        var issues: [FlowIssue] = []
        for (key, target) in step.routes.sorted(by: { $0.key < $1.key }) {
            guard let match = key.wholeMatch(of: routeKeyPattern) else {
                issues.append(.init(.error, .malformedRouteKey, step: step.id,
                                    "Route \(key) of step \(step.id) is not outcome:reason (done, failed or blocked; reason or *)."))
                continue
            }
            if target == FlowRouting.end { continue }
            guard let targetIndex = flow.index(of: target) else {
                issues.append(.init(.error, .unknownRouteTarget, step: step.id, "Route \(key) of step \(step.id) goes to \(target), not a step of the flow."))
                continue
            }
            // On failed or blocked a route goes back to work: to this step or an earlier one.
            if match.1 != "done", targetIndex > index {
                issues.append(.init(.error, .backRouteForward, step: step.id,
                                    "Route \(key) of step \(step.id) goes back to \(target), a later step; it must go to an earlier one."))
            }
        }
        return issues
    }

    static func commandIssues(_ step: FlowStep) -> [FlowIssue] {
        var issues: [FlowIssue] = []
        if step.checks.count > maxCheckCommands {
            issues.append(.init(.error, .tooManyCheckCommands, step: step.id,
                                "Step \(step.id) has \(step.checks.count) check commands; at most \(maxCheckCommands)."))
        }
        for command in step.checks where !isSafeCommand(command) {
            issues.append(.init(.error, .unsafeCheckCommand, step: step.id,
                                "Check command “\(command)” of step \(step.id) is not a plain command (letters, digits, space and _.:/=%@-, at most \(maxCheckLength) characters)."))
        }
        return issues
    }

    public static func isSafeCommand(_ command: String) -> Bool {
        command.count <= maxCheckLength && command.wholeMatch(of: commandPattern) != nil
    }

    static func piIssues(_ flow: Flow, pi: PiCapabilities?) -> [FlowIssue] {
        guard let pi else { return [.init(.warning, .piNotChecked, "Pi's features not checked: no pi-capabilities.json on this Mac (akit doctor writes it).")] }
        var issues: [FlowIssue] = []
        if let version = pi.version, compare(version, flow.minPi) == .orderedAscending {
            issues.append(.init(.error, .piTooOld, "Pi \(version) is older than the flow's minimum \(flow.minPi)."))
        }
        for feature in FlowPiFeature.required(by: flow) where !pi.features.contains(feature.rawValue) {
            issues.append(.init(.error, .missingPiFeature, "This Mac's Pi lacks \(feature.rawValue), which the flow needs."))
        }
        return issues
    }

    /// Dotted version order, numbers compared as numbers (`1.10.0` > `1.9.2`); anything after a `-` is ignored.
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        func parts(_ v: String) -> [Int] {
            (v.split(separator: "-").first ?? "").split(separator: ".").map { Int($0) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}
