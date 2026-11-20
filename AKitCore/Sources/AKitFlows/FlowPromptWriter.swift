import Foundation

/// Generate… on a step card: one model call writes or changes the step's prompt from the user's
/// request. This part is pure: the text sent and the check on the answer; the app makes the call
/// through Pi (`ModelCall`, with the sending policy, scrub and send log).
public enum FlowPromptWriter {
    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
        public init(message: String) { self.message = message }
    }

    /// The JSON answer (Pi gets the schema in its system prompt).
    public static let schema = #"{"type":"object","properties":{"prompt":{"type":"string"}},"required":["prompt"],"additionalProperties":false}"#

    /// What the runner wraps around a step's prompt (akit-flow.ts `prompt`), so the written prompt
    /// doesn't repeat it, and the rules that keep a step cheap and checkable.
    public static let system = """
        You write the prompt of one step of an AKit flow. Pi runs each step as a fresh agent with no \
        memory of the other steps. Before your prompt the runner already gives the agent: its role and step \
        name, the task, the base commit of the run's changes, the approved plan and the previous step's \
        handoff. After it, the runner asks for the tool flow_handoff with the outcome done, failed or \
        blocked and a reason. Don't repeat any of that.

        Write what this step does and how it decides its outcome:
        - imperative English, plain words, at most 120 words, no headings or lists unless they save words;
        - what to do, in order, and what not to do (a read-only step changes no files);
        - only the tools the step has; never ask for subagents, pushes or network calls;
        - when to end failed or blocked, with a one-word reason (notes, questions, no-repro …);
        - what to write into the handoff for the next step, briefly.
        Keep what the current prompt does well unless the request changes it. Answer in English even \
        when the request is in another language.
        """

    /// The input: the flow's steps in order, this step's settings and current prompt, and the
    /// user's request.
    public static func input(flow: Flow, step id: String, request: String) throws(Failure) -> String {
        guard let step = flow.step(id) else { throw Failure(message: "The flow has no step \(id).") }
        let wanted = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty || !(step.prompt ?? "").isEmpty else {
            throw Failure(message: "Say what the step should do.")
        }
        let order = flow.steps.enumerated().map { index, other in
            "\(index + 1). \(other.id) (\(other.agent))\(other.id == id ? "  ← this step" : "")"
        }.joined(separator: "\n")
        let tools = step.tools.isEmpty ? flow.tools : step.tools
        var lines = [
            "Flow \"\(flow.name)\":", order, "",
            "This step: \(step.id), agent \(step.agent), tools \(tools.joined(separator: ", "))"
                + (step.checks.isEmpty ? "" : "; the runner runs \(step.checks.joined(separator: ", ")) at its end")
                + (step.gate ? "; the user approves its result at a gate" : ""),
            "", "Current prompt:", step.prompt?.isEmpty == false ? step.prompt! : "(none)",
        ]
        lines += ["", "Request:", wanted.isEmpty ? "Make the current prompt shorter and clearer; keep what it asks." : wanted]
        return lines.joined(separator: "\n")
    }

    /// The new prompt from the model's answer: the JSON's "prompt", trimmed.
    public static func result(_ answer: String) throws(Failure) -> String {
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let object = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any],
              let prompt = (object["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty
        else { throw Failure(message: "The answer isn't the JSON asked for ({\"prompt\": …}). Try again, or with another model.") }
        return prompt
    }
}
