import Foundation

/// Built-in flows to copy into the brain (F10) and the agents a step can be. v1 has Feature only.
/// The step prompts are adapted from PurpleFlow's `core/prompts` (clarify.md, plan.md,
/// implement.md, review.md, summary.md; https://github.com/PurpleSchool/purpleflow, MIT,
/// Copyright (c) 2026 PurpleSchool), translated to English and cut to what a Pi step needs.
public enum FlowTemplates {
    /// The agents a step can be, in the order of the Feature flow.
    public static let agents = ["clarifier", "planner", "implementer", "checker", "reviewer", "committer"]

    public struct Template: Identifiable, Sendable {
        public var id: String { name }
        public let name: String
        public let summary: String
    }

    public static let all = [Template(name: "feature", summary: "Clarify, plan, approve, implement, check, review, accept, commit")]

    /// A new step's id: the agent's verb (`implementer` → `implement`), `-2`, `-3` … when taken.
    public static func stepID(for agent: String, taken: Set<String>) -> String {
        let verbs = ["clarifier": "clarify", "planner": "plan", "implementer": "implement", "checker": "checks",
                     "reviewer": "review", "committer": "commit"]
        let base = verbs[agent] ?? agent
        var id = base, number = 2
        while taken.contains(id) {
            id = "\(base)-\(number)"
            number += 1
        }
        return id
    }

    /// What a new step of this agent does by default.
    public static func prompt(for agent: String) -> String? { prompts[agent] }

    /// The Feature flow (the diagram in flows.md): `model` for every step, `reviewModel` for the
    /// review, so the reviewer's model differs from the implementer's (F6).
    public static func feature(model: String, reviewModel: String, checks: [String] = []) -> Flow {
        func step(_ id: String, _ agent: String, model: String = model, tools: [String], gate: Bool = false,
                  checks: [String] = [], routes: [String: String] = [:]) -> FlowStep {
            FlowStep(id: id, agent: agent, model: model, prompt: prompts[agent], tools: tools, gate: gate, checks: checks, routes: routes)
        }
        let read = ["read", "grep", "find", "ls"]
        return Flow(name: "feature", tools: ["read", "bash", "edit", "write", "grep", "find", "ls"], steps: [
            step("clarify", "clarifier", tools: read),
            step("plan", "planner", tools: read + ["write"], gate: true, routes: ["blocked:*": "clarify"]),
            step("implement", "implementer", tools: ["read", "bash", "edit", "write", "grep", "find", "ls"], routes: ["blocked:*": "plan"]),
            step("checks", "checker", tools: read + ["bash"], checks: checks, routes: ["failed:*": "implement", "blocked:*": "plan"]),
            step("review", "reviewer", model: reviewModel, tools: read + ["bash"], gate: true,
                 routes: ["failed:*": "implement", "blocked:*": "plan"]),
            step("commit", "committer", tools: ["read", "bash"], routes: ["done:*": FlowRouting.end, "failed:*": "implement"]),
        ])
    }

    static let prompts: [String: String] = [
        "clarifier": """
            Before the plan, check whether the task is clear enough to plan without guessing. Read the project \
            (read only, change nothing) just enough to see where the task is ambiguous: which behaviours are possible, \
            which places it touches, what the wording leaves open. Ask only when a plan without the answer would be a \
            guess and a wrong choice means redoing work; never ask what the code shows. At most 4 questions, the most \
            important first, each with 2-4 short options (the likeliest first) and one sentence on why it matters. \
            A clear task is the usual case: then end done with no questions. Questions: end blocked with reason questions.
            """,
        "planner": """
            Plan the change for the task. First study the project: its structure, the code and test style, the test \
            command. Then write the plan into the handoff: what changes, file by file, the steps in order, and one \
            check command that runs only the tests the task touches (the tests of the changed modules and the new ones; \
            name folders or filters, not only new files, since they do not exist before the change). Change no code.
            """,
        "implementer": """
            Implement the plan from the previous step's handoff. Run only the tests you need; the checks step runs the \
            full commands after you. Keep the change to what the plan asks; when the plan is wrong or not enough, end \
            blocked with the reason instead of guessing.
            """,
        "checker": """
            The runner runs this step's check commands after you. Read the failures the handoff names, if any, and say \
            in the handoff which tests fail and why; change no code. End failed when a check is red.
            """,
        "reviewer": """
            Another model implemented the change. Review the branch's diff against the plan, read only: change nothing \
            and run no command that changes files. Go through the risks that apply: the plan's invariants, states and \
            their transitions, a crash halfway, repeats and parallel calls, access and data. Look also for what the plan \
            asks and the diff does not do (or does differently, or does on top), correctness errors, missing or fake \
            tests, security problems. Blocking is only what must be fixed before the change can be accepted; style and \
            optional ideas are notes. Blocking problems: end failed with reason notes, each with file and line.
            """,
        "committer": """
            The user accepted the change. Write a short summary of the diff for them: what changed in behaviour (2-4 \
            points, in plain words, not a retelling of the lines), what it touches (modules, files or layers) and what \
            to look at (risks, removed code, changed contracts, missing tests; skip when none). Then commit the work \
            with an imperative message of at most 72 characters. Never push.
            """,
    ]
}
