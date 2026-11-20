import Foundation

/// Built-in flows to copy into the brain (F10) and the agents a step can be. Feature follows
/// PurpleFlow; the other presets follow oh-my-claudecode's workflows (ralplan, ralph, tdd, debug,
/// code review, ai-slop-cleaner, research, deep interview), one Pi step per OMC role. The Feature prompts are adapted from PurpleFlow's `core/prompts` (clarify.md, plan.md,
/// implement.md, review.md, summary.md; https://github.com/PurpleSchool/purpleflow, MIT,
/// Copyright (c) 2026 PurpleSchool), translated to English and cut to what a Pi step needs.
public enum FlowTemplates {
    /// The agents a step can be, in the order of the Feature flow.
    public static let agents = ["clarifier", "planner", "architect", "critic", "tester", "debugger", "implementer",
                                "cleaner", "checker", "reviewer", "verifier", "researcher", "writer", "committer"]

    public struct Template: Identifiable, Sendable {
        public var id: String { name }
        public let name: String
        /// The OMC workflow it follows, shown next to the name.
        public let like: String?
        public let summary: String
        /// The flow with `model` for the makers, `reviewModel` for the judges and `checks` for the checks steps.
        public let make: @Sendable (_ model: String, _ reviewModel: String, _ checks: [String]) -> Flow
    }

    public static let all: [Template] = [
        Template(name: "feature", like: "autopilot", summary: "Clarify, plan, approve, implement, check, review, accept, commit",
                 make: { feature(model: $0, reviewModel: $1, checks: $2) }),
        Template(name: "ralplan", like: "ralplan", summary: "Plan, architect review, critic review until both approve, then you approve",
                 make: { m, r, _ in ralplan(model: m, reviewModel: r) }),
        Template(name: "ralph", like: "ralph", summary: "Implement, check, verify; loop until verified (up to 5 times), commit",
                 make: { ralph(model: $0, reviewModel: $1, checks: $2) }),
        Template(name: "tdd", like: "tdd", summary: "Write a failing test, implement, check, review, commit",
                 make: { tdd(model: $0, reviewModel: $1, checks: $2) }),
        Template(name: "debug", like: "debug / trace", summary: "Find the root cause, fix it, check, verify, commit",
                 make: { debug(model: $0, reviewModel: $1, checks: $2) }),
        Template(name: "review", like: "code-review", summary: "Read-only review of the branch's diff, a report with file and line",
                 make: { _, r, _ in review(reviewModel: r) }),
        Template(name: "deslop", like: "ai-slop-cleaner", summary: "Remove dead code and noise, keep behaviour, check, review, commit",
                 make: { deslop(model: $0, reviewModel: $1, checks: $2) }),
        Template(name: "research", like: "research", summary: "Read-only investigation, then a sourced report",
                 make: { m, _, _ in research(model: m) }),
        Template(name: "deep-interview", like: "deep-interview", summary: "Questions until the task is clear, a spec, you approve",
                 make: { m, _, _ in interview(model: m) }),
        Template(name: "autopilot", like: "autopilot", summary: "Interview, plan with architect and critic, implement, check, verify, commit",
                 make: { autopilot(model: $0, reviewModel: $1, checks: $2) }),
        Template(name: "plan", like: "plan", summary: "Study the project, write a plan, you approve; read only",
                 make: { m, _, _ in single("plan", "plan", "planner", model: m, gate: true) }),
        Template(name: "verify", like: "verify", summary: "Run the checks and prove the change works, from evidence",
                 make: { _, r, c in Flow(name: "verify", tools: read + ["bash"], steps: [
                     step("checks", "checker", model: r, tools: read + ["bash"], checks: c),
                     step("verify", "verifier", model: r, tools: read + ["bash"], routes: ["done:*": FlowRouting.end]),
                 ]) }),
        Template(name: "security-review", like: "security-review", summary: "Read-only security review of the diff: OWASP, secrets, unsafe calls",
                 make: { _, r, _ in single("security-review", "security", "reviewer", model: r, prompt: securityPrompt) }),
        Template(name: "interrogate", like: "interrogate", summary: "Three read-only attacks on the diff: correctness, security, edge cases",
                 make: { m, r, _ in interrogate(model: m, reviewModel: r) }),
        Template(name: "blast-radius", like: "blast-radius", summary: "Find what the change could break beyond the diff and run those checks",
                 make: { m, _, c in Flow(name: "blast-radius", tools: read + ["bash"], steps: [
                     step("map", "researcher", model: m, tools: read + ["bash"], prompt: blastPrompt),
                     step("checks", "checker", model: m, tools: read + ["bash"], checks: c, routes: ["done:*": FlowRouting.end]),
                 ]) }),
        Template(name: "fix-ci", like: "fix-ci", summary: "Read the failing checks, fix the real failures, rerun to green, commit",
                 make: { fixLoop("fix-ci", model: $0, reviewModel: $1, checks: $2, prompt: fixCIPrompt) }),
        Template(name: "fix-merge-conflicts", like: "fix-merge-conflicts", summary: "Resolve conflicts keeping both sides' intent, check, commit",
                 make: { fixLoop("fix-merge-conflicts", model: $0, reviewModel: $1, checks: $2, prompt: conflictsPrompt) }),
        Template(name: "hillclimb", like: "hillclimb", summary: "Measure, change one thing, measure again, keep only wins (up to 5 rounds)",
                 make: { hillclimb(model: $0, reviewModel: $1, checks: $2) }),
        Template(name: "sharpen", like: "sharpen", summary: "Turn a vague task into a target: consumer, change, done-check, non-goals",
                 make: { m, _, _ in single("sharpen", "sharpen", "clarifier", model: m, prompt: sharpenPrompt) }),
        Template(name: "how", like: "how", summary: "Explain how a subsystem works, cited to code; read only",
                 make: { m, _, _ in Flow(name: "how", tools: read + ["bash"], steps: [
                     step("explore", "researcher", model: m, tools: read + ["bash"]),
                     step("explain", "writer", model: m, tools: read, prompt: howPrompt, routes: ["done:*": FlowRouting.end]),
                 ]) }),
        Template(name: "why", like: "why", summary: "Why the code is the way it is: git history, issues, decisions; read only",
                 make: { m, _, _ in single("why", "why", "researcher", model: m, prompt: whyPrompt) }),
        Template(name: "deepinit", like: "deepinit", summary: "Write AGENTS.md files that map the codebase, then review them",
                 make: { m, r, _ in Flow(name: "deepinit", tools: all7, steps: [
                     step("document", "writer", model: m, tools: all7, prompt: deepinitPrompt),
                     step("review", "reviewer", model: r, tools: read, gate: true, routes: ["failed:*": "document"]),
                     step("commit", "committer", model: m, tools: ["read", "bash"], routes: ["done:*": FlowRouting.end]),
                 ]) }),
    ]

    /// Pi's thinking levels, lowest first (`pi --thinking`).
    public static let thinkingLevels = ["off", "minimal", "low", "medium", "high", "xhigh", "max"]

    /// Agents that do the work in code; the others think (plan, judge, explain).
    public static let doers: Set<String> = ["implementer", "tester", "debugger", "cleaner", "checker", "committer"]

    /// The user's defaults (2026-11-17): doers on `doer` (gpt-6 Luna), thinkers on `thinker`
    /// (gpt-6.1 Terra). A judge of the plan (critic, architect) gets `doer` when the planner is on
    /// `thinker`, so it never shares the planner's model (F6). Empty models keep the template's.
    public static func withDefaultModels(_ flow: Flow, doer: String?, thinker: String?) -> Flow {
        var flow = flow
        for index in flow.steps.indices {
            let agent = flow.steps[index].agent
            let pick = doers.contains(agent) || judgedMakers[agent] == ["planner"] ? doer : thinker
            if let pick, !pick.isEmpty { flow.steps[index].model = pick }
        }
        return flow
    }

    public static func template(named name: String) -> Template? { all.first { $0.name == name } }

    /// Each judge and the makers whose work it checks; its model must differ from theirs (F6).
    /// Code judges check the code, plan judges the plan: a reviewer may share the planner's model.
    public static let judgedMakers: [String: Set<String>] = [
        "reviewer": codeMakers, "verifier": codeMakers, "critic": ["planner"], "architect": ["planner"],
    ]
    static let codeMakers: Set<String> = ["implementer", "tester", "debugger", "cleaner"]
    public static var judges: Set<String> { Set(judgedMakers.keys) }
    public static var makers: Set<String> { judgedMakers.values.reduce(into: []) { $0.formUnion($1) } }

    /// A new step's id: the agent's verb (`implementer` → `implement`), `-2`, `-3` … when taken.
    public static func stepID(for agent: String, taken: Set<String>) -> String {
        let verbs = ["clarifier": "clarify", "planner": "plan", "implementer": "implement", "checker": "checks",
                     "reviewer": "review", "committer": "commit", "architect": "architect", "critic": "critique",
                     "tester": "test", "debugger": "trace", "cleaner": "clean", "verifier": "verify",
                     "researcher": "research", "writer": "report"]
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

    static let read = ["read", "grep", "find", "ls"]
    static let all7 = ["read", "bash", "edit", "write", "grep", "find", "ls"]

    static func step(_ id: String, _ agent: String, model: String, tools: [String], gate: Bool = false,
                     checks: [String] = [], maxLoops: Int = FlowStep.defaultMaxLoops, prompt: String? = nil,
                     routes: [String: String] = [:]) -> FlowStep {
        FlowStep(id: id, agent: agent, model: model, prompt: prompt ?? prompts[agent], tools: tools, gate: gate, checks: checks,
                 maxLoops: maxLoops, routes: routes)
    }

    /// A one-step read-only flow.
    static func single(_ name: String, _ id: String, _ agent: String, model: String, gate: Bool = false, prompt: String? = nil) -> Flow {
        Flow(name: name, tools: read + ["bash"], steps: [
            step(id, agent, model: model, tools: read + ["bash"], gate: gate, prompt: prompt, routes: ["failed:*": FlowRouting.end]),
        ])
    }

    /// OMC autopilot: deep interview, ralplan, ralph, in one flow.
    public static func autopilot(model: String, reviewModel: String, checks: [String]) -> Flow {
        Flow(name: "autopilot", tools: all7, steps: [
            step("clarify", "clarifier", model: model, tools: read, gate: true),
            step("plan", "planner", model: model, tools: read, maxLoops: 5, routes: ["blocked:*": "clarify"]),
            step("architect", "architect", model: reviewModel, tools: read + ["bash"], routes: ["failed:*": "plan"]),
            step("critique", "critic", model: reviewModel, tools: read + ["bash"], gate: true, routes: ["failed:*": "plan"]),
            step("implement", "implementer", model: model, tools: all7, maxLoops: 5, routes: ["blocked:*": "plan"]),
            step("checks", "checker", model: model, tools: read + ["bash"], checks: checks, maxLoops: 5, routes: ["failed:*": "implement"]),
            step("verify", "verifier", model: reviewModel, tools: read + ["bash"], gate: true, maxLoops: 5,
                 routes: ["failed:*": "implement", "blocked:*": "plan"]),
            step("commit", "committer", model: model, tools: ["read", "bash"], routes: ["done:*": FlowRouting.end]),
        ])
    }

    /// OMC interrogate: three attacks in a row (one step each, since steps don't run in parallel, D26).
    public static func interrogate(model: String, reviewModel: String) -> Flow {
        Flow(name: "interrogate", tools: read + ["bash"], steps: [
            step("correctness", "reviewer", model: reviewModel, tools: read + ["bash"],
                 prompt: attack("correctness: wrong results, broken states, crashes halfway")),
            step("security", "reviewer", model: model, tools: read + ["bash"], prompt: attackSecurity),
            step("edge-cases", "reviewer", model: reviewModel, tools: read + ["bash"],
                 prompt: attack("edge cases: empty, huge, repeated, parallel, unicode, time zones")),
            step("verdict", "writer", model: model, tools: read, prompt: verdictPrompt,
                 routes: ["done:*": FlowRouting.end, "failed:*": FlowRouting.end]),
        ])
    }

    /// A fix loop for one kind of failure: fix, check until green, commit.
    static func fixLoop(_ name: String, model: String, reviewModel: String, checks: [String], prompt: String) -> Flow {
        Flow(name: name, tools: all7, steps: [
            step("fix", "implementer", model: model, tools: all7, maxLoops: 5, prompt: prompt),
            step("checks", "checker", model: model, tools: read + ["bash"], checks: checks, maxLoops: 5, routes: ["failed:*": "fix"]),
            step("review", "reviewer", model: reviewModel, tools: read + ["bash"], gate: true, routes: ["failed:*": "fix"]),
            step("commit", "committer", model: model, tools: ["read", "bash"], routes: ["done:*": FlowRouting.end]),
        ])
    }

    /// OMC hillclimb: one change per round against a fixed baseline.
    public static func hillclimb(model: String, reviewModel: String, checks: [String]) -> Flow {
        Flow(name: "hillclimb", tools: all7, steps: [
            step("baseline", "researcher", model: model, tools: read + ["bash"], prompt: baselinePrompt),
            step("change", "implementer", model: model, tools: all7, maxLoops: 5, prompt: climbPrompt),
            step("checks", "checker", model: model, tools: read + ["bash"], checks: checks, maxLoops: 5, routes: ["failed:*": "change"]),
            step("measure", "verifier", model: reviewModel, tools: read + ["bash"], maxLoops: 5, prompt: measurePrompt,
                 routes: ["failed:*": "change"]),
            step("commit", "committer", model: model, tools: ["read", "bash"], routes: ["done:*": FlowRouting.end]),
        ])
    }

    static func attack(_ focus: String) -> String {
        """
        Another model made the change. Try to break it, read only: look for \(focus). For each problem give file, \
        line, the input that breaks it and what happens. Change nothing. Write the problems into the \
        handoff and end done even when you found some: the verdict step decides.
        """
    }

    static let securityPrompt = """
        Review the branch's diff for security, read only: injection (shell, SQL, path), secrets in code or logs, \
        unsafe file and network calls, missing auth or input checks, unsafe deserialization, dependency risks. For \
        each finding: file, line, how it is exploited, the fix. Change nothing. Findings: end failed with reason notes.
        """
    static let attackSecurity = attack("security: injection (shell, SQL, path), secrets, unsafe file and network calls, missing auth or input checks")
    static let verdictPrompt = """
        Merge the attacks' handoffs into one verdict for the user: blocking problems first (file, line, why), then \
        notes; drop duplicates. Blocking ones: end failed with reason blocking; else end done.
        """
    static let blastPrompt = """
        Map what the branch's change could break beyond the diff, read only: find every caller, importer and config \
        that uses the changed code (search and read), class each as certain, likely or unlikely to break, and name \
        the test or command that proves each certain and likely one. Write the list into the handoff.
        """
    static let fixCIPrompt = """
        The checks are red. Read the failures (run the failing commands), class each as real, flaky or environment, \
        and fix only the real ones with focused changes; name flaky and environment ones in the handoff without \
        changing them. Never skip or weaken a test.
        """
    static let conflictsPrompt = """
        The branch has merge conflicts. For each conflict read both sides' commits to learn each side's intent, then \
        resolve so both intents survive; never just take one side. Remove every conflict marker. List in the handoff \
        each file, both intents and how you kept them. Never force-push.
        """
    static let baselinePrompt = """
        Name the one metric the task improves and the command that measures it. Run it three times on the current \
        code and write the command, the values and their spread into the handoff. Change no code.
        """
    static let climbPrompt = """
        From the baseline and earlier rounds in the handoffs, make one change you expect to improve the metric. \
        Write the hypothesis into the handoff first. One idea per round.
        """
    static let measurePrompt = """
        Another model made this round's change. Run the baseline's measure command three times. Better beyond the \
        spread: end done with the numbers. Not better: undo the change (git restore) and end failed with the numbers \
        and why, so the next round tries another idea.
        """
    static let sharpenPrompt = """
        Turn the task into a sharp target, read only: who uses the result, what observable change they get, the \
        check that proves it is done, and what is out of scope. Read the code to ground each line. Ask at most one \
        question, only for a real fork: end blocked with reason questions. Else end done with the target.
        """
    static let howPrompt = """
        Explain how the subsystem from the previous handoff works for someone new to it: the purpose in one line, \
        then the main flow step by step with file and line, then the key data shapes, then the traps. Change no files.
        """
    static let whyPrompt = """
        Find why the code the task names is the way it is, read only: git log and blame, commit messages, linked \
        issues, design docs and comments. Quote human decisions word for word with their source. Label every claim \
        evidence, inference or guess.
        """
    static let deepinitPrompt = """
        Map the codebase for agents: write an AGENTS.md in the root and in each main folder saying what lives there, \
        the key files, how to build and test it, and the rules a change must keep. Short, checkable lines; no \
        restating what the code shows. Keep existing AGENTS.md text the user wrote.
        """

    /// OMC ralplan: planner, then architect and critic (another model) until both approve; you approve the plan.
    public static func ralplan(model: String, reviewModel: String) -> Flow {
        Flow(name: "ralplan", tools: read + ["bash"], steps: [
            step("plan", "planner", model: model, tools: read, maxLoops: 5),
            step("architect", "architect", model: reviewModel, tools: read + ["bash"], routes: ["failed:*": "plan"]),
            step("critique", "critic", model: reviewModel, tools: read + ["bash"], gate: true,
                 routes: ["failed:*": "plan", "done:*": FlowRouting.end]),
        ])
    }

    /// OMC ralph: implement, check and verify until a verifier on another model says done.
    public static func ralph(model: String, reviewModel: String, checks: [String]) -> Flow {
        Flow(name: "ralph", tools: all7, steps: [
            step("implement", "implementer", model: model, tools: all7, maxLoops: 5),
            step("checks", "checker", model: model, tools: read + ["bash"], checks: checks, maxLoops: 5, routes: ["failed:*": "implement"]),
            step("verify", "verifier", model: reviewModel, tools: read + ["bash"], maxLoops: 5, routes: ["failed:*": "implement"]),
            step("commit", "committer", model: model, tools: ["read", "bash"], routes: ["done:*": FlowRouting.end]),
        ])
    }

    /// OMC tdd: a failing test first, then the code that makes it pass.
    public static func tdd(model: String, reviewModel: String, checks: [String]) -> Flow {
        Flow(name: "tdd", tools: all7, steps: [
            step("test", "tester", model: model, tools: all7),
            step("implement", "implementer", model: model, tools: all7, routes: ["blocked:*": "test"]),
            step("checks", "checker", model: model, tools: read + ["bash"], checks: checks, routes: ["failed:*": "implement"]),
            step("review", "reviewer", model: reviewModel, tools: read + ["bash"], gate: true,
                 routes: ["failed:*": "implement", "blocked:*": "test"]),
            step("commit", "committer", model: model, tools: ["read", "bash"], routes: ["done:*": FlowRouting.end]),
        ])
    }

    /// OMC debug / trace: the root cause from evidence before any fix.
    public static func debug(model: String, reviewModel: String, checks: [String]) -> Flow {
        Flow(name: "debug", tools: all7, steps: [
            step("trace", "debugger", model: model, tools: read + ["bash"]),
            step("fix", "implementer", model: model, tools: all7, routes: ["blocked:*": "trace"]),
            step("checks", "checker", model: model, tools: read + ["bash"], checks: checks, routes: ["failed:*": "fix"]),
            step("verify", "verifier", model: reviewModel, tools: read + ["bash"], gate: true,
                 routes: ["failed:*": "fix", "blocked:*": "trace"]),
            step("commit", "committer", model: model, tools: ["read", "bash"], routes: ["done:*": FlowRouting.end]),
        ])
    }

    /// OMC code-review: one read-only step.
    public static func review(reviewModel: String) -> Flow {
        Flow(name: "review", tools: read + ["bash"], steps: [
            step("review", "reviewer", model: reviewModel, tools: read + ["bash"], routes: ["failed:*": FlowRouting.end]),
        ])
    }

    /// OMC ai-slop-cleaner: deletion first, behaviour kept, proved by the checks.
    public static func deslop(model: String, reviewModel: String, checks: [String]) -> Flow {
        Flow(name: "deslop", tools: all7, steps: [
            step("clean", "cleaner", model: model, tools: all7),
            step("checks", "checker", model: model, tools: read + ["bash"], checks: checks, routes: ["failed:*": "clean"]),
            step("review", "reviewer", model: reviewModel, tools: read + ["bash"], gate: true, routes: ["failed:*": "clean"]),
            step("commit", "committer", model: model, tools: ["read", "bash"], routes: ["done:*": FlowRouting.end]),
        ])
    }

    /// OMC research: read-only, the report in the handoff.
    public static func research(model: String) -> Flow {
        Flow(name: "research", tools: read + ["bash"], steps: [
            step("research", "researcher", model: model, tools: read + ["bash"]),
            step("report", "writer", model: model, tools: read, routes: ["done:*": FlowRouting.end]),
        ])
    }

    /// OMC deep-interview: questions until the task is clear, then a spec you approve.
    public static func interview(model: String) -> Flow {
        Flow(name: "deep-interview", tools: read, steps: [
            step("clarify", "clarifier", model: model, tools: read, gate: true, maxLoops: 5),
            step("plan", "planner", model: model, tools: read, gate: true,
                 routes: ["blocked:*": "clarify", "failed:*": "clarify", "done:*": FlowRouting.end]),
        ])
    }

    /// The Feature flow (the diagram in flows.md): `model` for every step, `reviewModel` for the
    /// review, so the reviewer's model differs from the implementer's (F6). Thinking is spent where
    /// it pays: high for the plan and the review, low for asking and committing. The plan lives in
    /// its handoff (the runner gives it to every later step), so the planner writes no file.
    public static func feature(model: String, reviewModel: String, checks: [String] = []) -> Flow {
        func step(_ id: String, _ agent: String, model: String = model, tools: [String], gate: Bool = false,
                  checks: [String] = [], thinking: String? = nil, routes: [String: String] = [:]) -> FlowStep {
            var step = Self.step(id, agent, model: model, tools: tools, gate: gate, checks: checks, routes: routes)
            step.thinking = thinking
            return step
        }
        return Flow(name: "feature", tools: ["read", "bash", "edit", "write", "grep", "find", "ls"], steps: [
            step("clarify", "clarifier", tools: read, thinking: "low"),
            step("plan", "planner", tools: read, gate: true, thinking: "high", routes: ["blocked:*": "clarify"]),
            step("implement", "implementer", tools: ["read", "bash", "edit", "write", "grep", "find", "ls"], routes: ["blocked:*": "plan"]),
            step("checks", "checker", tools: read + ["bash"], checks: checks, routes: ["failed:*": "implement", "blocked:*": "plan"]),
            step("review", "reviewer", model: reviewModel, tools: read + ["bash"], gate: true, thinking: "high",
                 routes: ["failed:*": "implement", "blocked:*": "plan"]),
            step("commit", "committer", tools: ["read", "bash"], thinking: "low",
                 routes: ["done:*": FlowRouting.end, "failed:*": "implement"]),
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
            command. Then give the plan in the handoff's plan field: steps, in order, each saying what changes in which \
            file, and check, one plain command that runs only the tests the task touches (the tests of the changed \
            modules and the new ones; name folders or filters, not only new files, since they do not exist before the \
            change). The checks step runs it. Risks and decisions go in notes. Change no code.
            """,
        "implementer": """
            Implement the plan (the plan's handoff above; a later handoff says what to fix). Run only the tests you need; the checks step runs the \
            full commands after you. Keep the change to what the plan asks; when the plan is wrong or not enough, end \
            blocked with the reason instead of guessing.
            """,
        "checker": """
            Run the project's tests and lint the plan names, read only, and say in the handoff which fail and why; \
            change no code. End failed when one is red. (With check commands set, the runner runs them and \
            this step starts no model.)
            """,
        "reviewer": """
            Another model made the change. Review the run's diff (git diff against the base commit named above) against the plan, read only: change nothing \
            and run no command that changes files. Go through the risks that apply: the plan's invariants, states and \
            their transitions, a crash halfway, repeats and parallel calls, access and data. Look also for what the plan \
            asks and the diff does not do (or does differently, or does on top), correctness errors, missing or fake \
            tests, security problems. The task and the plan are the contract: blocking is only what breaks them or must \
            be fixed before the change can be accepted; inputs and cases they don't name, style and optional ideas are \
            notes. When you reviewed before, check that your blocking notes were fixed and the fix broke nothing; \
            don't raise new wishes. Blocking problems: end failed with reason notes, each with file and line.
            """,
        "committer": """
            The user accepted the change. Write a short summary of the diff for them: what changed in behaviour (2-4 \
            points, in plain words, not a retelling of the lines), what it touches (modules, files or layers) and what \
            to look at (risks, removed code, changed contracts, missing tests; skip when none). Then commit the work \
            with an imperative message of at most 72 characters. Never push.
            """,
        "architect": """
            Another model wrote the plan in the previous handoff. Review it as an architect, read only: does it fit the \
            project's structure and module boundaries, are the interfaces and data shapes right, what breaks at the \
            edges (errors, states, concurrency, migrations), is there a simpler design. Give the strongest argument \
            against the plan and the trade-off it makes. Problems the plan must fix: end failed with reason notes, each \
            naming the plan section. A sound plan: end done with your notes.
            """,
        "critic": """
            Another model wrote the plan and an architect reviewed it (both handoffs). Be the critic, read only: check \
            that every requirement of the task is covered, every step is concrete and testable, the check command \
            proves the change, risks have a mitigation, and the architect's notes were answered. Missing or vague: end \
            failed with reason notes, each saying what to add. Ready to implement: end done with the final plan.
            """,
        "tester": """
            Write the tests first. From the task, add the smallest tests that describe the wanted behaviour, in the \
            project's test style, and run them: they must fail for the right reason (the behaviour is missing, not a \
            typo). Change no production code. Say in the handoff the test names, why they fail and the command that \
            runs them.
            """,
        "debugger": """
            Find the root cause before any fix. Reproduce the problem with a command, read the code paths it takes, \
            and test competing explanations against the evidence (logs, stack traces, git history). Change no code. \
            Write into the handoff: the reproduction command, the root cause with file and line, the evidence for it, \
            what you ruled out, and the smallest fix. Can't reproduce: end blocked with reason no-repro.
            """,
        "cleaner": """
            Clean the code the task names without changing behaviour. Deletion first: remove dead code, duplicates, \
            needless wrappers and abstractions, stale comments and debug leftovers; then simplify what stays. One kind \
            of cleanup at a time, run the tests between. Keep public interfaces. List in the handoff what you removed \
            and why it was safe.
            """,
        "verifier": """
            Another model made the change. Verify it is done, from evidence: run the commands that prove the task's \
            acceptance (tests, build, a reproduction), read the diff, and look for placeholders, skipped or fake \
            tests and unfinished branches. Change no files. Not done: end failed with reason notes, each saying what \
            is missing with file and line. Done: end done with the evidence you ran.
            """,
        "researcher": """
            Investigate the question in the task, read only: search the code, docs and history, run read-only \
            commands. Record each finding with its source (file and line, command output, URL) and label it \
            evidence, inference or guess. Write the findings and the open questions into the handoff.
            """,
        "writer": """
            Write the report from the previous handoff for the user: the answer first, then the findings with their \
            sources, then the open questions. Short sentences, no filler; keep code, paths and numbers exact. Change \
            no files.
            """,
    ]
}
