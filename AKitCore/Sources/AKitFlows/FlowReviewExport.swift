import AKitFoundation
import Foundation

/// Export for Review on the Flows screen: one Markdown file with everything that shapes a flow's
/// run, to hand to an agent next to it for a review. The flow at a glance, how the runner works,
/// and for each step its settings, routes, child command, guard, instructions, the prompt it gets
/// on its first round (the runner's layout, with placeholders for what only a run knows) and the
/// full text of its skills; then the flow file and the exact runner code that builds prompts and
/// handoffs. The whole text goes through the send scrub: it is meant to leave the machine.
public enum FlowReviewExport {
    /// A piece of the runner's source, quoted as is (`FlowRender.reviewExcerpts`).
    public struct Excerpt: Sendable {
        public let title: String
        public let file: String
        public let code: String
        public init(title: String, file: String, code: String) {
            self.title = title
            self.file = file
            self.code = code
        }
    }

    public struct Result: Sendable {
        public let text: String
        /// How many values the scrub masked.
        public let masked: Int
    }

    /// The runner's fixed sentences (akit-flow.ts `prompt`); a test keeps them equal to the source.
    public static let precedence = "How to weigh what you get: the approved plan says what to build; the handoffs say what is true now, and a later handoff wins over an older one; a note from the user at a gate wins over both."
    public static let toolsLine = "Work with these; a tool you don't have is not a reason to end blocked."
    public static let earlierTitle = "Earlier steps, oldest first (short; the newest weigh most):"
    public static let questionsTitle = "Open questions from earlier steps (answer them if your step can):"
    public static let mostRecentEnd = "it weighs most for where things stand:"
    public static let ownResult = "build on it; don't start over."
    public static let disputeLine = "don't comply: end blocked with reason disputed and give your arguments in notes; the user decides."
    public static let piEnd = "When the step is finished, call the tool flow_handoff once with what you did and the outcome: done, failed or blocked (with a reason)."
    public static let claudeEnd = "When the step is finished, answer with the handoff in the JSON schema you were given: what you did and the outcome: done, failed or blocked (with a reason)."
    public static let claudeBash = "On Claude Code, bash runs only commands that read (git log, git diff, cat, ls); anything that writes or runs a program, tests included, is denied. The runner runs the step's checks itself."
    /// Every fixed sentence above, for the test against the runner's source.
    public static let runnerPhrases = [precedence, toolsLine, earlierTitle, questionsTitle, mostRecentEnd, ownResult, disputeLine, piEnd, claudeEnd, claudeBash]

    /// The guard's tools when neither the step nor the flow names any (akit-flow-guard.ts DEFAULT_TOOLS).
    static let defaultTools = ["read", "bash", "edit", "write", "grep", "find", "ls"]
    /// Pi's tool names → Claude Code's (claude-adapter.ts CLAUDE_TOOLS).
    static let claudeToolNames = ["read": "Read", "grep": "Grep", "find": "Glob", "ls": "Glob", "bash": "Bash"]
    /// Pi's thinking levels → Claude Code's --effort.
    static let claudeEffort = ["off": "low", "minimal": "low", "low": "low", "medium": "medium", "high": "high", "xhigh": "xhigh", "max": "max"]
    /// The most of one skill file the export quotes.
    static let skillLimit = 20_000

    /// The export of `flow` as it is on screen. `source` says where it comes from (the brain file,
    /// or that it has unsaved changes); `issues` is the flow check's answer.
    public static func markdown(flow: Flow, source: String, project: URL?, env: HarnessEnvironment, issues: [FlowIssue],
                                runner: [Excerpt], now: Date = Date()) -> Result {
        var out: [String] = []
        let date = ISO8601DateFormatter.string(from: now, timeZone: .current, formatOptions: [.withFullDate])
        out += ["# Flow \"\(flow.name)\": review pack", "",
                "Exported by AKit on \(date) from \(source). Project: \(project?.lastPathComponent ?? "none (the home folder's flows)"). "
                    + "Run it in Pi with `/flow \(flow.name) <task>`; needs Pi \(flow.minPi) or newer.", ""]
        out += request
        out += runnerRules
        out += glance(flow)
        out += checkSection(issues)
        for (index, step) in flow.steps.enumerated() {
            out += stepSection(step, index: index, flow: flow, issues: issues.filter { $0.step == step.id })
        }
        let skills = flow.steps.flatMap(\.skills).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        if !skills.isEmpty {
            out += ["## Skills", "", "Each skill once, with the steps that load it. A Pi step gets the names and descriptions up front and reads a SKILL.md when its task needs it. A Claude Code step has no skills of its own in a flow (--safe-mode): it gets only its step's skills, from Pi's folders or else Claude Code's, as a list in its system prompt, and reads each SKILL.md with Read; it has no Skill tool, and a skill's scripts need Bash.", ""]
            for name in skills {
                out += skillSection(name, steps: flow.steps.filter { $0.skills.contains(name) }, flow: flow, project: project, env: env)
            }
        }
        out += ["## The flow file", "", "```yaml", ((try? flow.yaml()) ?? "(can't encode)").trimmingCharacters(in: .newlines), "```", ""]
        if !runner.isEmpty {
            out += ["## Runner code (exact excerpts)", "",
                    "The parts of AKit's Pi extension that build each step's prompt, pass handoffs on and start the child. The rest of the runner is in `.pi/extensions/akit-flow/`.", ""]
            for excerpt in runner {
                out += ["### \(excerpt.title) (`\(excerpt.file)`)", "", "```ts", excerpt.code.trimmingCharacters(in: .newlines), "```", ""]
            }
        }
        let scrubbed = Scrubber.scrub(out.joined(separator: "\n"))
        let masked = scrubbed.counts.values.reduce(0, +)
        guard masked > 0 else { return Result(text: scrubbed.text, masked: 0) }
        let note = "> AKit masked \(masked) value\(masked == 1 ? "" : "s") that look like secrets, hosts or e-mails before export.\n"
        var lines = scrubbed.text.components(separatedBy: "\n")
        lines.insert(note, at: min(4, lines.count))
        return Result(text: lines.joined(separator: "\n"), masked: masked)
    }

    // MARK: Sections

    private static let request = [
        "## What to review", "",
        "This is an AKit flow: a fixed chain of agent steps that Pi runs for one task. Each step is a fresh agent with no memory of the others; it gets the prompt shown under its step and ends with a handoff. Please review it and answer with concrete changes per step (the field and its new value or text). Look for:",
        "- instructions that contradict each other, the step's tools, its routes or the runner's own prompt (which the instructions shouldn't repeat);",
        "- a step asked to do what its tools don't allow (read-only steps, no bash);",
        "- handoffs: does each step write what the next one needs, and does each step use what it gets (plan, notes, files, open questions)?",
        "- routes: loops that can't make progress, a rejection with no way back, outcomes or reasons no step ever produces, gates in the wrong place;",
        "- cost: model and reasoning matched to each step's work, skills a step doesn't need, checks that could replace a model;",
        "- questions the user is asked that the flow could settle itself, and the other way round.",
        "",
    ]

    private static let runnerRules = [
        "## How the runner works", "",
        "- Every step is a fresh child process: `pi` (the default) or `claude -p` (a step that runs on Claude Code, read-only). The run has its own git worktree; the runner commits after every step.",
        "- A step ends with a handoff (schema below: goal, done, files, open_questions, notes, plan, outcome, reason). The runner adds what git saw (`changed`), which wins over the files the model named. No valid handoff: the step runs once more, then the run stops.",
        "- Prompt order, the same every time so Pi's cache keeps the start: role and step, task, the diff command (steps with bash), the tools line, the step's instructions, how to weigh inputs, one line per earlier step, open questions, the plan (from the last planner step), the step's own last result (on a rerun), the most recent handoff in full, the user's note, the dispute line, the tail of failed checks, the closing line. Notes are cut at 4000 characters in prompts.",
        "- Routes: `outcome:reason` or `outcome:*` → a step id or `end`. Without a route, done goes on to the next step (or ends after the last); failed and blocked stop and ask the user.",
        "- Max rounds: how many times the run may enter a step (the first try plus reworks), not the agent's turns inside it. At the limit, and on an outcome with no route, the user picks: one more round, accept as is, send back with a note, or stop.",
        "- A step that was rejected by another one may end `blocked:disputed` with its arguments; without its own route for that, the user decides who is right.",
        "- Checks: commands the runner runs at the step's end without a shell; a red check turns done into failed and the next prompt gets its last lines. A checker step with checks starts no model; it also runs the plan's own check command.",
        "- A gate after a step: the user approves its result or sends it back with a note, which then weighs most.",
        "",
    ]

    private static func glance(_ flow: Flow) -> [String] {
        var out = ["## The flow at a glance", "",
                   "Flow tools: \(flow.tools.isEmpty ? "none set (Pi's built-ins)" : flow.tools.joined(separator: ", ")).", "",
                   "| # | Step | Agent | Runs on | Model | Reasoning | Done → | Failed → | Blocked → | Max rounds | Gate |",
                   "|---|---|---|---|---|---|---|---|---|---|---|"]
        for (index, step) in flow.steps.enumerated() {
            let cells = ["\(index + 1)", step.id, step.agent, step.isClaudeCode ? "Claude Code" : "Pi", step.model.isEmpty ? "(none)" : step.model,
                         step.thinking ?? "model default", target(step, index: index, flow: flow, outcome: "done"),
                         target(step, index: index, flow: flow, outcome: "failed"), target(step, index: index, flow: flow, outcome: "blocked"),
                         "\(step.maxLoops)", step.gate ? "yes" : ""]
            out.append("| " + cells.map { $0.replacingOccurrences(of: "|", with: "\\|") }.joined(separator: " | ") + " |")
        }
        return out + [""]
    }

    private static func checkSection(_ issues: [FlowIssue]) -> [String] {
        guard !issues.isEmpty else { return ["## Flow check", "", "No problems found.", ""] }
        return ["## Flow check", ""] + issues.map { "- \($0.severity.rawValue) (\($0.code.rawValue)): \($0.message)" } + [""]
    }

    private static func stepSection(_ step: FlowStep, index: Int, flow: Flow, issues: [FlowIssue]) -> [String] {
        let tools = effectiveTools(step, flow: flow)
        var out = ["## Step \(index + 1): \(step.id)", ""]
        out += [
            "- Agent: \(step.agent)",
            "- Runs on: \(step.isClaudeCode ? "Claude Code (`claude -p`, read-only)" : "Pi")",
            "- Model: \(step.model.isEmpty ? "(none)" : step.model); reasoning: \(step.thinking.map { step.isClaudeCode ? "\($0) (claude --effort \(claudeEffort[$0] ?? $0))" : $0 } ?? "the model's default")",
            "- Tools: \(tools.joined(separator: ", "))\(step.tools.isEmpty ? " (the flow's)" : "")"
                + (step.isClaudeCode ? "; as Claude Code tools: \(claudeTools(step, flow: flow).joined(separator: ", "))" : ""),
        ]
        if step.isClaudeCode {
            out.append("- Claude Code's own setup is off (--safe-mode, --strict-mcp-config): no skills of its own, hooks, plugins or MCP servers. The runner adds the project's AGENTS.md (else CLAUDE.md) and the step's skills to its system prompt; every command that needs a permission is denied")
        } else {
            if tools.contains("edit") || tools.contains("write") {
                out.append("- Writes: \(step.paths.isEmpty ? "anywhere in the worktree" : step.paths.joined(separator: ", "))")
            } else {
                out.append("- Read only: no edit or write")
            }
            if tools.contains("bash") && !step.bash { out.append("- bash: blocked by the guard (paths restrict writes)") }
            if !step.extensions.isEmpty { out.append("- Extensions: \(step.extensions.joined(separator: ", "))") }
        }
        out.append("- Skills: \(step.skills.isEmpty ? "none" : step.skills.joined(separator: ", ") + " (their texts are under Skills below)")")
        out.append("- Checks: \(step.checks.isEmpty ? "none" : step.checks.map { "`\($0)`" }.joined(separator: ", "))"
                   + (step.agent == "checker" ? "; plus the plan's own check command" : ""))
        out.append("- Max rounds: \(step.maxLoops)\(step.gate ? "; a gate after it: the user approves or sends it back with a note" : "")")
        out += ["", "Routes:"]
        for outcome in ["done", "failed", "blocked"] {
            let specific = step.routes.filter { $0.key.hasPrefix("\(outcome):") && $0.key != "\(outcome):*" }.sorted { $0.key < $1.key }
            for (key, to) in specific { out.append("- \(key) → \(to)") }
            let fallback = target(step, index: index, flow: flow, outcome: outcome)
            out.append("- \(outcome)\(specific.isEmpty ? "" : " (any other reason)") → \(fallback)\(step.routes["\(outcome):*"] == nil ? " (default)" : "")")
        }
        if !issues.isEmpty { out += ["", "Check:"] + issues.map { "- \($0.severity.rawValue): \($0.message)" } }
        out += ["", "Child:", "", "```sh", childCommand(step, flow: flow), "```", ""]
        if codeOnly(step) {
            out += ["No model runs in this step: the runner runs its checks and passes the previous step's handoff on with the result.", ""]
        } else {
            out += ["### Instructions", "", "```text", step.prompt?.isEmpty == false ? step.prompt! : "(none)", "```", ""]
            out += ["### What the agent gets on its first round", "",
                    "The runner's layout when every step before it ended done; `<…>` is what only a run knows.", "",
                    "```text", firstPrompt(step, index: index, flow: flow), "```", ""]
            out += ["On a later round the prompt also has, in this order: the step's own last handoff (\"Your own result last time…\"), "
                    + "the handoff of the step that sent the work back as the most recent one, the user's note from a gate or a stop, "
                    + "the dispute line when another step rejected it, and the last lines of failed checks.", ""]
        }
        return out
    }

    private static func skillSection(_ name: String, steps: [FlowStep], flow: Flow, project: URL?, env: HarnessEnvironment) -> [String] {
        let used = "Used by: \(steps.map { $0.isClaudeCode ? "\($0.id) (Claude Code)" : $0.id }.joined(separator: ", "))."
        let pi = skillPath(name, project: project, env: env)
        let claude = steps.contains(where: \.isClaudeCode) ? skillPath(name, project: project, env: env, claude: true) : nil
        if pi == nil, claude != nil, steps.contains(where: { !$0.isClaudeCode }) {
            return ["### \(name)", "", used, "",
                    "Only in Claude Code's skill folders: the Pi steps that list it stop the run (skill-missing).", ""]
        }
        guard let path = pi ?? claude else {
            return ["### \(name)", "", used, "", "Not installed: the runner stops the run at a step that needs it (skill-missing).", ""]
        }
        var isFolder: ObjCBool = false
        FileManager.default.fileExists(atPath: path.path, isDirectory: &isFolder)
        let file = isFolder.boolValue ? path.appending(path: "SKILL.md") : path
        var out = ["### \(name)", "", "\(used) `\(FileWalk.tilde(file, home: env.homeDirectory))`", ""]
        if var text = try? String(contentsOf: file, encoding: .utf8) {
            if text.count > skillLimit { text = String(text.prefix(skillLimit)) + "\n… (cut at \(skillLimit) characters)" }
            out += ["````markdown", text.trimmingCharacters(in: .newlines), "````", ""]
        } else {
            out += ["(can't read it)", ""]
        }
        if isFolder.boolValue {
            let others = otherFiles(in: path)
            if !others.isEmpty { out += ["Other files in the skill (read on demand): \(others.joined(separator: ", "))", ""] }
            let scripts = others.filter { ["sh", "py", "js", "mjs", "ts", "rb"].contains(($0 as NSString).pathExtension) }
            let blind = steps.filter { $0.isClaudeCode && !claudeTools($0, flow: flow).contains("Bash") }.map(\.id)
            if !scripts.isEmpty, !blind.isEmpty {
                out += ["Warning: the skill has scripts (\(scripts.joined(separator: ", "))), but \(blind.joined(separator: ", ")) runs on Claude Code without Bash: it can read them, not run them.", ""]
            }
        }
        return out
    }

    // MARK: What the runner does (mirrors akit-flow.ts)

    /// Where `outcome` goes without a reason of its own: the route, else next / end / stop and ask.
    static func target(_ step: FlowStep, index: Int, flow: Flow, outcome: String) -> String {
        if let to = step.routes["\(outcome):*"] { return to == FlowRouting.end ? "end" : to }
        guard outcome == "done" else { return "stop and ask" }
        return index + 1 < flow.steps.count ? flow.steps[index + 1].id : "end"
    }

    static func effectiveTools(_ step: FlowStep, flow: Flow) -> [String] {
        !step.tools.isEmpty ? step.tools : !flow.tools.isEmpty ? flow.tools : defaultTools
    }

    static func claudeTools(_ step: FlowStep, flow: Flow) -> [String] {
        var seen = Set<String>()
        return effectiveTools(step, flow: flow).compactMap { claudeToolNames[$0] }.filter { seen.insert($0).inserted }
    }

    static func codeOnly(_ step: FlowStep) -> Bool { step.agent == "checker" && !step.checks.isEmpty }

    /// The prompt of the step's first round on the straight path: the step before it ended done.
    static func firstPrompt(_ step: FlowStep, index: Int, flow: Flow) -> String {
        let tools = effectiveTools(step, flow: flow)
        var lines = ["You are the \(step.agent) step \"\(step.id)\" of the AKit flow \"\(flow.name)\" (run <run id>).", "Task: <the task given to /flow>"]
        if tools.contains("bash") { lines.append("The run's changes: git diff <base commit>") }
        lines.append("Your tools: \(tools.joined(separator: ", ")). \(toolsLine)")
        if step.isClaudeCode, tools.contains("bash") { lines.append(claudeBash) }
        if let prompt = step.prompt, !prompt.isEmpty { lines += ["", prompt] }
        lines += ["", precedence]
        let previous = index > 0 ? flow.steps[index - 1] : nil
        let planner = step.agent == "planner" ? nil : flow.steps[..<index].last { $0.agent == "planner" }
        let earlier = flow.steps[..<index].filter { $0.id != previous?.id && $0.id != planner?.id }
        if !earlier.isEmpty {
            lines += ["", earlierTitle] + earlier.map { "- \($0.id) (\($0.agent), attempt 1): done · <goal> · did: <up to 3 items> · files: <up to 6 paths>" }
        }
        if index > 0 { lines += ["", questionsTitle, "- <each open question of the steps before, when there are any>"] }
        if let planner, planner.id != previous?.id {
            lines += ["", "The plan (handoff of the step \"\(planner.id)\"):", handoffPlaceholder(from: planner.id, plan: true)]
        }
        if let previous {
            lines += ["", "Most recent: the handoff from the step \"\(previous.id)\" (done); \(mostRecentEnd)",
                      handoffPlaceholder(from: previous.id, plan: previous.agent == "planner")]
        }
        lines += ["", step.isClaudeCode ? claudeEnd : piEnd]
        return lines.joined(separator: "\n")
    }

    private static func handoffPlaceholder(from step: String, plan: Bool) -> String {
        var lines = ["{", "  \"from\": { \"step\": \"\(step)\", \"outcome\": \"done\", … },", "  \"goal\": \"<one line>\",",
                     "  \"done\": [\"<what it did>\", …],", "  \"files\": [{ \"path\": \"<file>\", \"change\": \"<added, changed or removed>\" }, …],",
                     "  \"open_questions\": [\"…\"],", "  \"notes\": \"<what the next step must know, at most 4000 characters>\""]
        if plan { lines[lines.count - 1] += ","; lines.append("  \"plan\": { \"steps\": [\"…\"], \"check\": \"<one plain command>\" }") }
        return (lines + ["}"]).joined(separator: "\n")
    }

    static func childCommand(_ step: FlowStep, flow: Flow) -> String {
        if codeOnly(step) { return step.checks.joined(separator: "\n") }
        if step.isClaudeCode {
            var parts = ["claude -p \"<the prompt below>\"", "--output-format json", "--model \(step.model)", "--tools \(claudeTools(step, flow: flow).joined(separator: ","))",
                         "--safe-mode --strict-mcp-config --permission-prompts none", "--session-id <new uuid>", "--json-schema '<the handoff schema>'",
                         "--append-system-prompt '<the project's AGENTS.md, else CLAUDE.md\(step.skills.isEmpty ? "" : "; the skills: name, description, SKILL.md path")>'"]
            if let thinking = step.thinking, let effort = claudeEffort[thinking] { parts.append("--effort \(effort)") }
            for name in step.skills { parts.append("--add-dir <\(name) folder>") }
            return parts.joined(separator: " \\\n  ")
        }
        var parts = ["pi --mode json --session-dir <run>/sessions", "-ns"]
        parts += step.skills.map { "--skill <\($0) folder>" }
        parts += ["-ne", "-e akit-flow-guard.ts", "-e akit-flow-handoff.ts"] + step.extensions.map { "-e \($0)" }
        parts.append("--model \(step.model.isEmpty ? "<none>" : step.model)" + (step.thinking.map { " --thinking \($0)" } ?? ""))
        parts.append("-t \((effectiveTools(step, flow: flow) + ["flow_handoff"]).joined(separator: ","))")
        parts.append("-- \"<the prompt below>\"")
        return parts.joined(separator: " \\\n  ")
    }

    /// Where the runner finds a skill (akit-flow.ts `resolveSkill`), in its order; a Claude Code
    /// step also looks in Claude Code's own folders, after Pi's.
    static func skillPath(_ name: String, project: URL?, env: HarnessEnvironment, claude: Bool = false) -> URL? {
        let fm = FileManager.default
        if name.hasPrefix("/") { return fm.fileExists(atPath: name) ? URL(filePath: name) : nil }
        let home = env.homeDirectory
        var candidates = [project?.appending(path: ".pi/skills/\(name)"), home.appending(path: ".pi/agent/skills/\(name)"),
                          project?.appending(path: ".agents/skills/\(name)"), home.appending(path: ".agents/skills/\(name)")]
        if claude { candidates += [project?.appending(path: ".claude/skills/\(name)"), home.appending(path: ".claude/skills/\(name)")] }
        return candidates.compactMap { $0 }.first { fm.fileExists(atPath: $0.path) }
    }

    private static func otherFiles(in folder: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                              options: [.skipsHiddenFiles]) else { return [] }
        var names: [String] = []
        for case let url as URL in enumerator where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            let relative = String(url.standardizedFileURL.path.dropFirst(folder.standardizedFileURL.path.count + 1))
            if relative != "SKILL.md" { names.append(relative) }
            if names.count == 30 { names.append("…"); break }
        }
        return names.sorted()
    }
}
