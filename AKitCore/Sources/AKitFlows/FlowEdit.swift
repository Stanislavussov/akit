import Foundation

/// The edits `akit flow set | route | add-step | remove-step | move-step | set-flow` make to a
/// brain flow, the same ones the Flows screen makes by clicks. Pure: the command loads, checks,
/// shows the diff and commits.
public enum FlowEdit {
    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
        public init(_ message: String) { self.message = message }
    }

    /// Step fields `set` changes; the names are the flow file's, plus `max-rounds` for maxLoops.
    public static let stepFields = ["agent", "model", "harness", "thinking", "prompt", "skills", "tools", "checks", "paths", "bash",
                                    "extensions", "gate", "max-rounds"]
    public static let flowFields = ["tools", "minPi"]

    /// Sets one field of a step. Lists are comma separated (checks: `;`, since a command may hold
    /// commas); `none` or an empty value clears a list, `default` clears thinking and harness.
    public static func set(_ flow: Flow, step id: String, field: String, value: String) throws(Failure) -> Flow {
        var flow = flow
        guard let index = flow.index(of: id) else { throw Failure("The flow has no step \(id): \(flow.steps.map(\.id).joined(separator: ", ")).") }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleared = text.isEmpty || text == "none"
        let list = { (separator: Character) in cleared ? [] : text.split(separator: separator).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        var step = flow.steps[index]
        switch field {
        case "agent":
            guard !text.isEmpty else { throw Failure("An agent is needed: \(FlowTemplates.agents.joined(separator: ", ")).") }
            step.agent = text
        case "model":
            guard !text.isEmpty else { throw Failure("A model is needed (pi --list-models; on Claude Code: \(FlowStep.claudeModels.joined(separator: ", "))).") }
            step.model = text
        case "harness":
            switch text {
            case "pi", "default", "": step.harness = nil
            case FlowStep.claudeCode: step.harness = FlowStep.claudeCode
            default: throw Failure("harness is pi or \(FlowStep.claudeCode).")
            }
        case "thinking":
            if text == "default" || text.isEmpty { step.thinking = nil } else {
                guard FlowTemplates.thinkingLevels.contains(text) else {
                    throw Failure("thinking is default or one of \(FlowTemplates.thinkingLevels.joined(separator: ", ")).")
                }
                step.thinking = text
            }
        case "prompt": step.prompt = text.isEmpty ? nil : value.trimmingCharacters(in: .newlines)
        case "skills": step.skills = list(",")
        case "tools": step.tools = list(",")
        case "checks": step.checks = list(";")
        case "paths": step.paths = list(",")
        case "extensions": step.extensions = list(",")
        case "bash": step.bash = try yes(text, field)
        case "gate": step.gate = try yes(text, field)
        case "max-rounds", "maxLoops":
            guard let rounds = Int(text), (1...9).contains(rounds) else { throw Failure("max-rounds is a number from 1 to 9.") }
            step.maxLoops = rounds
        default:
            throw Failure("No step field \(field). Fields: \(stepFields.joined(separator: ", ")).")
        }
        flow.steps[index] = step
        return flow
    }

    /// Sets a flow-level field: `tools` (comma separated) or `minPi`.
    public static func setFlow(_ flow: Flow, field: String, value: String) throws(Failure) -> Flow {
        var flow = flow
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch field {
        case "tools": flow.tools = text == "none" ? [] : text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        case "minPi":
            guard text.split(separator: ".").count == 3, text.split(separator: ".").allSatisfy({ Int($0) != nil }) else { throw Failure("minPi is a version like 1.0.4.") }
            flow.minPi = text
        default: throw Failure("No flow field \(field). Fields: \(flowFields.joined(separator: ", ")).")
        }
        return flow
    }

    /// Sets or removes one route: KEY is `outcome:reason` or `outcome` (= `outcome:*`), TARGET a
    /// step id or `end`; `stop` (or nil) removes the route, so the default holds again.
    public static func route(_ flow: Flow, step id: String, key: String, target: String?) throws(Failure) -> Flow {
        var flow = flow
        guard let index = flow.index(of: id) else { throw Failure("The flow has no step \(id).") }
        let full = key.contains(":") ? key : "\(key):*"
        let outcome = String(full.prefix { $0 != ":" })
        guard ["done", "failed", "blocked"].contains(outcome), full.count > outcome.count + 1 else {
            throw Failure("A route key is done, failed or blocked, with :reason or alone (failed:tests, blocked).")
        }
        if let target, target != "stop" {
            guard target == FlowRouting.end || flow.step(target) != nil else {
                throw Failure("No step \(target): use a step id, end or stop.")
            }
            flow.steps[index].routes[full] = target
        } else {
            flow.steps[index].routes[full] = nil
        }
        return flow
    }

    /// A new step after `after` (else at the end), with the agent's template instructions.
    public static func addStep(_ flow: Flow, id: String?, agent: String, model: String, after: String?) throws(Failure) -> Flow {
        var flow = flow
        let taken = Set(flow.steps.map(\.id))
        let name = id ?? FlowTemplates.stepID(for: agent, taken: taken)
        guard !taken.contains(name) else { throw Failure("The flow has a step \(name) already.") }
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            throw Failure("A step id may use only letters, digits, _ and -.")
        }
        guard !model.isEmpty else { throw Failure("A model is needed: --model.") }
        var at = flow.steps.endIndex
        if let after {
            guard let index = flow.index(of: after) else { throw Failure("The flow has no step \(after).") }
            at = index + 1
        }
        flow.steps.insert(FlowStep(id: name, agent: agent, model: model, prompt: FlowTemplates.prompt(for: agent)), at: at)
        return flow
    }

    /// Removes a step and every route to it (those outcomes fall back to their default).
    public static func removeStep(_ flow: Flow, step id: String) throws(Failure) -> Flow {
        var flow = flow
        guard flow.step(id) != nil else { throw Failure("The flow has no step \(id).") }
        flow.steps.removeAll { $0.id == id }
        for index in flow.steps.indices { flow.steps[index].routes = flow.steps[index].routes.filter { $0.value != id } }
        return flow
    }

    /// Moves a step right after `after`, or first when `after` is nil.
    public static func moveStep(_ flow: Flow, step id: String, after: String?) throws(Failure) -> Flow {
        var flow = flow
        guard let from = flow.index(of: id) else { throw Failure("The flow has no step \(id).") }
        if let after, after == id || flow.step(after) == nil { throw Failure("No other step \(after) to move it after.") }
        let step = flow.steps.remove(at: from)
        flow.steps.insert(step, at: after.flatMap { flow.index(of: $0) }.map { $0 + 1 } ?? 0)
        return flow
    }

    private static func yes(_ text: String, _ field: String) throws(Failure) -> Bool {
        switch text {
        case "yes", "true", "on": true
        case "no", "false", "off": false
        default: throw Failure("\(field) is yes or no.")
        }
    }
}
