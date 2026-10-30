import AKitFoundation
import AKitLab
import Foundation

/// Write with AI…: Pi drafts a review role or scenario from the user's words with a writing skill
/// the user picks (AKit's own `review-role-writer` or `review-scenario-writer` by default). One
/// pass with no tools and no MCP: Pi reads only the description, AKit's format, the existing
/// roles, the skills it may link and the writing skill. The draft is checked and shown as a
/// diff; nothing is saved before the user approves it.
public enum ReviewRoleWriter {
    public struct Failure: Error, LocalizedError {
        public let message: String
        /// Pi's answer when it wasn't a valid role, to show the user.
        public var draft: String?
        public var errorDescription: String? { message }
    }

    /// A skill that can write the role.
    public struct Skill: Hashable, Sendable, Identifiable {
        public var name: String
        public var description: String
        /// Where it comes from: "built-in", "brain", "Claude Code", "Pi", "agents".
        public var place: String
        /// Its SKILL.md; nil for the built-in one.
        public var file: URL?
        public var id: String { file?.path ?? "built-in:\(name)" }

        public static let builtIn = Skill(name: builtInName, description: "AKit's guide to writing a review role", place: "built-in", file: nil)
        public static let builtInScenario = Skill(name: builtInScenarioName, description: "AKit's guide to writing a review scenario",
                                                  place: "built-in", file: nil)

        /// AKit's own writing skill for a role or a scenario.
        public static func builtIn(for kind: ReviewConfigEditor.Kind) -> Skill { kind == .scenario ? builtInScenario : builtIn }

        /// The text Pi reads.
        public func text() throws -> String {
            guard let file else { return name == ReviewRoleWriter.builtInScenarioName ? ReviewRoleWriter.builtInScenarioSkill : ReviewRoleWriter.builtInSkill }
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { throw Failure(message: "Can't read \(file.path).") }
            return text
        }
    }

    public static let builtInName = "review-role-writer"
    public static let builtInScenarioName = "review-scenario-writer"

    /// The skills on this Mac that could write a role or a scenario: the built-in one, then the
    /// brain's, then the harnesses' global ones. Review roles (`review-*`) are left out. The same
    /// skills (without the built-in) are what a role or a scenario can link.
    public static func skills(brain: URL?, home: URL, for kind: ReviewConfigEditor.Kind = .role) -> [Skill] {
        var folders: [(URL, String)] = []
        if let brain { folders.append((brain.appending(path: "skills"), "brain")) }
        folders += [(home.appending(path: ".claude/skills"), "Claude Code"), (home.appending(path: ".pi/agent/skills"), "Pi"),
                    (home.appending(path: ".agents/skills"), "agents")]
        var seen = Set<String>()
        var found = [Skill.builtIn(for: kind)]
        for (folder, place) in folders {
            for skill in FileWalk.children(of: folder).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let file = skill.appending(path: "SKILL.md")
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                let key = file.resolvingSymlinksInPath().path
                guard !skill.lastPathComponent.hasPrefix("review-"), seen.insert(key).inserted else { continue }
                let map = ReviewYAML.frontmatter(text).flatMap { try? ReviewYAML.map($0) } ?? [:]
                found.append(Skill(name: map["name"] as? String ?? skill.lastPathComponent, description: map["description"] as? String ?? "",
                                   place: place, file: file))
            }
        }
        return found
    }

    /// A skill named on the command line: a path to a SKILL.md or its folder, else a name from
    /// `skills`.
    public static func skill(named text: String, brain: URL?, home: URL, cwd: URL, for kind: ReviewConfigEditor.Kind = .role) throws -> Skill {
        let all = skills(brain: brain, home: home, for: kind)
        if text.contains("/") || text.hasPrefix("~") {
            let path = text.hasPrefix("~/") ? home.path + text.dropFirst() : text
            var url = path.hasPrefix("/") ? URL(filePath: path) : cwd.appending(path: path)
            if FileWalk.isDirectory(url) { url = url.appending(path: "SKILL.md") }
            // Only a skill: its text goes to the model, so no other file may pass for one.
            guard url.lastPathComponent == "SKILL.md" else { throw Failure(message: "\(text) is not a skill: give its folder or its SKILL.md.") }
            guard FileManager.default.fileExists(atPath: url.path) else { throw Failure(message: "There is no skill file \(url.path).") }
            return Skill(name: url.deletingLastPathComponent().lastPathComponent, description: "", place: "file", file: url)
        }
        guard let skill = all.first(where: { $0.name == text }) else {
            throw Failure(message: "There is no skill \(text). The skills: " + all.map(\.name).joined(separator: ", ") + ".")
        }
        return skill
    }

    public struct Request: Sendable {
        /// `.role` or `.scenario`.
        public var kind: ReviewConfigEditor.Kind
        public var id: String
        /// The user's words: what the role checks, or the problem the scenario solves.
        public var description: String
        public var skill: Skill
        public var level: ReviewConfigEditor.Level
        /// nil: the review's passes model (review.yaml), else Pi's default.
        public var model: ReviewModelChoice?

        public init(kind: ReviewConfigEditor.Kind = .role, id: String, description: String, skill: Skill? = nil, level: ReviewConfigEditor.Level,
                    model: ReviewModelChoice? = nil) {
            self.kind = kind
            self.id = id
            self.description = description
            self.skill = skill ?? .builtIn(for: kind)
            self.level = level
            self.model = model
        }
    }

    public struct Result: Sendable {
        public var save: ReviewConfigEditor.Save
        public var model: String
        public var credits: Double
    }

    /// Runs the pass and returns the checked role as a save to show. Throws when Pi can't run
    /// or its answer isn't a role (the failure carries the draft).
    public static func write(_ request: Request, brain: URL, env: HarnessEnvironment, timeout: TimeInterval = 10 * 60,
                             progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Result {
        let home = env.homeDirectory
        guard ReviewYAML.isID(request.id) else { throw Failure(message: "\(request.id): use a-z, 0-9 and -.") }
        guard request.kind == .role || request.kind == .scenario else { throw Failure(message: "AI writes only a role or a scenario.") }
        let scenario = request.kind == .scenario
        let words = request.description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { throw Failure(message: scenario ? "Say what the scenario is for." : "Say what the role checks.") }
        guard let pi = env.findExecutable("pi") else { throw Failure(message: "Pi (pi) is not installed.") }
        let catalog = ReviewCatalog.load(home: home, brain: brain)
        let profile = request.level.slug.flatMap { slug in catalog.profiles.first { $0.slug == slug } }
        // The review's passes model at this level; an empty model or thinking in the request keeps it.
        let passes = configuredModel(catalog: catalog, profile: profile)
        var model = request.model ?? passes
        if model.model.isEmpty { model.model = passes.model }
        if model.thinking.isEmpty { model.thinking = passes.thinking }
        let gate = try await ReviewPasses.gate(model: model.model, env: env)
        // What goes to the model is masked and scrubbed like the debug pass's log.
        let own = LabSettings.load(env: env).scrub
        func clean(_ text: String) -> String { Scrubber.scrub(SecretFilter.masked(text), own: own).text }
        let skillText = clean(try request.skill.text())

        let folder = ReviewPaths(home: home).folder.appending(path: "role-writer/\(stamp())-\(request.id)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let existing = catalog.roles(for: profile)
        let current = scenario ? catalog.scenarios(for: profile).first { $0.id == request.id }.map { clean($0.text) }
            : existing.first { $0.id == request.id }.map { clean($0.text) }
        let system = clean(scenario ? scenarioSystemPrompt(skill: request.skill, skillText: skillText, roles: existing, linkable: catalog.skills)
                           : systemPrompt(skill: request.skill, skillText: skillText, roles: existing, linkable: catalog.skills))
        try ReviewPasses.write(system, to: folder.appending(path: "prompt.md"))
        let task = clean(scenario ? scenarioPrompt(id: request.id, description: words, current: current)
                         : prompt(id: request.id, description: words, current: current))
        try ReviewPasses.write(task, to: folder.appending(path: "task.md"))

        var arguments = ["-p", "--mode", "json", "--offline", "--no-session"]
        if !model.model.isEmpty { arguments += ["--model", model.model] }
        if !model.thinking.isEmpty { arguments += ["--thinking", model.thinking] }
        arguments += ["--no-skills", "--no-context-files", "--no-prompt-templates", "--no-extensions", "--no-mcp", "--no-tools",
                      "--append-system-prompt", folder.appending(path: "prompt.md").path, "--", task]
        var environment = await ReviewPasses.passEnvironment(env)
        environment["AKIT_REVIEW_PASS"] = "role-writer"
        progress("Pi writes \(request.kind.rawValue) \(request.id) with \(request.skill.name) (\(model.model.isEmpty ? "Pi's default model" : model.model))…")
        let output = await ReviewPasses.runPi(pi, arguments: arguments, directory: folder, environment: environment, timeout: timeout,
                                              stream: folder.appending(path: "pass.jsonl"), progress: { progress("  \($0)") })
        var send = SendRecord(purpose: scenario ? "review-scenario-writer" : "review-role-writer", session: output.session, runID: nil, destination: gate.destination, model: model.model,
                              inputCharacters: system.count + task.count, usage: output.usage)
        send.error = output.error
        _ = SendLog.appendAfterRun(send, env: env, out: progress)
        if let error = output.error { throw Failure(message: "Pi failed: \(error)") }
        guard let answer = output.answer else { throw Failure(message: "Pi gave no answer.") }
        let draft = scenario ? self.scenario(from: answer) : role(from: answer)
        let draftFile = folder.appending(path: scenario ? "\(request.id).yaml" : "SKILL.md")
        try ReviewPasses.write(draft, to: draftFile)
        do {
            if scenario {
                // Only roles that exist: a name the model made up would stop every run of it.
                let parsed = try ReviewScenario.parse(draft, source: .brain)
                let unknown = parsed.roleIDs.filter { id in !existing.contains { $0.id == id } }
                guard unknown.isEmpty else {
                    throw ReviewConfigEditor.Failure(message: "it names roles that don't exist: \(unknown.joined(separator: ", ")).")
                }
                guard !parsed.required.isEmpty else { throw ReviewConfigEditor.Failure(message: "it has no required role.") }
            }
            let save = try ReviewConfigEditor.plan(request.kind, id: request.id, text: draft, level: request.level, home: home, brain: brain)
            return Result(save: save, model: model.model, credits: ReviewCredits.of(output.usage))
        } catch {
            throw Failure(message: "Pi's draft isn't a valid \(request.kind.rawValue): \(error.localizedDescription) The draft is in \(draftFile.path).",
                          draft: draft)
        }
    }

    /// The scenario YAML in Pi's answer: inside the first fence when there is one.
    static func scenario(from answer: String) -> String {
        var lines = answer.components(separatedBy: "\n")
        if let open = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }) {
            let close = lines[(open + 1)...].firstIndex { $0.trimmingCharacters(in: .whitespaces) == "```" }
            lines = Array(lines[(open + 1)..<(close ?? lines.count)])
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// The SKILL.md in Pi's answer: inside a fence when there is one, from the first `---` on.
    static func role(from answer: String) -> String {
        var lines = answer.components(separatedBy: "\n")
        // Inside the first fence: up to the bare fence that closes it, skipping fences opened inside.
        if let open = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }) {
            var depth = 0
            var close: Int?
            for index in (open + 1)..<lines.count {
                let line = lines[index].trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("```") else { continue }
                if line.count > 3, line.dropFirst(3).allSatisfy({ $0 != "`" }) { depth += 1; continue }
                if depth == 0 { close = index; break }
                depth -= 1
            }
            lines = Array(lines[(open + 1)..<(close ?? lines.count)])
        }
        var text = lines.joined(separator: "\n")
        if let start = text.range(of: "---\n") { text = String(text[start.lowerBound...]) }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text + "\n"
    }

    /// The passes model a review at this level would use: the project's `review:`, the brain's,
    /// the built-in one.
    public static func configuredModel(catalog: ReviewCatalog, profile: ReviewProfile?) -> ReviewModelChoice {
        var choice = catalog.builtInDefaults.passes ?? ReviewModelChoice(model: "")
        for patch in [catalog.brainDefaults.passes, profile?.settings.passes].compactMap({ $0 }) {
            if !patch.model.isEmpty { choice.model = patch.model }
            if !patch.thinking.isEmpty { choice.thinking = patch.thinking }
        }
        return choice
    }

    static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: .now)
    }

    static func prompt(id: String, description: String, current: String?) -> String {
        var lines = ["Write the AKit Review role review-\(id) from what the user wants:", "", description, ""]
        if let current {
            lines += ["The role exists already; improve this text rather than start over:", "", "```markdown", current, "```", ""]
        }
        lines.append("Answer with the whole SKILL.md in one ```markdown fence and nothing else.")
        return lines.joined(separator: "\n")
    }

    /// The skills a draft may link, one line each (at most 80).
    static func linkableList(_ skills: [Skill]) -> String {
        guard !skills.isEmpty else { return "(none on this Mac: leave skills: out)" }
        return skills.prefix(80).map { "- \($0.name): \($0.description.isEmpty ? "(no description)" : String($0.description.prefix(160)))" }
            .joined(separator: "\n")
    }

    static func scenarioPrompt(id: String, description: String, current: String?) -> String {
        var lines = ["Write the AKit Review scenario \(id) from what the user wants:", "", description, ""]
        if let current {
            lines += ["The scenario exists already; improve this text rather than start over:", "", "```yaml", current, "```", ""]
        }
        lines.append("Answer with the whole YAML in one ```yaml fence and nothing else.")
        return lines.joined(separator: "\n")
    }

    static func scenarioSystemPrompt(skill: Skill, skillText: String, roles: [ReviewRole], linkable: [Skill]) -> String {
        """
        You write one review scenario for AKit Review: an AI code review of merge requests, run in Pi. A scenario says \
        which review roles run for one kind of change, which questions the review must answer, and which skills the \
        passes load.

        The format AKit checks (a draft that breaks it is refused):

        ```yaml
        id: <id>
        title: <a short title>
        roles: { required: [<role id>, …], optional: [<role id>, …] }
        checks:                       # questions the review answers for this kind of change
          - "Is the cause fixed, not the symptom?"
        context_required: [wi, full_files]   # what the review needs: wi, full_files, history, tests
        skills: [<skill name>, …]     # optional: skills every pass loads (only from the list below)
        ```

        The roles you may use (only these ids; a check no role covers goes under checks:):
        \(roles.map { "- \($0.id): \($0.description)" }.joined(separator: "\n"))

        The skills you may link (only these names; link one only when it helps this kind of change):
        \(linkableList(linkable))

        The user picked the skill "\(skill.name)" to guide how you write it. Follow it where it fits this format:

        <skill>
        \(skillText)
        </skill>
        """
    }

    static func systemPrompt(skill: Skill, skillText: String, roles: [ReviewRole], linkable: [Skill] = []) -> String {
        """
        You write one review role for AKit Review: an AI code review of merge requests, run in Pi. A role is one \
        SKILL.md that a review pass loads; its body is the checklist the reviewing model follows on a diff.

        The format AKit checks (a draft that breaks it is refused):

        ```markdown
        ---
        name: review-<id>
        description: "One line: what the role reviews a change for"
        akit-review:
          min_severity: low           # nit, low, medium, high or critical: findings below it are dropped
          max_findings: 6             # 1–20
          needs: [diff, full_files]   # what the pass reads: diff, full_files, wi (work items), history, tests
          do_not_comment:             # what this role must leave alone
            - style, and naming taste
          skills: [<skill name>]      # optional: other skills this role's pass loads (only from the list below)
        ---

        <the checklist>
        ```

        Roles that exist already (stay out of what they cover, or say how this one differs):
        \(roles.map { "- \($0.id): \($0.description)" }.joined(separator: "\n"))

        Skills the role may link with skills: (only these names; link one only when the user's words call for it or it \
        holds the rules this role checks):
        \(linkableList(linkable))

        The user picked the skill "\(skill.name)" to guide how you write it. Follow it where it fits this format:

        <skill>
        \(skillText)
        </skill>
        """
    }

    /// AKit's own writing skill: what makes a role precise enough for a reviewing model.
    public static let builtInSkill = """
    ---
    name: review-role-writer
    description: "Write an AKit Review role: a checklist a reviewing model can apply to a diff"
    ---

    # Writing a review role

    A role is read by a model that sees one merge request. It must find every potential problem of
    its kind, each with an honest severity and confidence, and nothing outside its kind. Write it so:

    1. **One concern.** A role checks one kind of problem (performance, translations, a team rule).
       Its name is given in the task (`review-<id>`): keep it exactly. If the user's words cover two concerns, keep the main one and
       say the rest in `do_not_comment`.
    2. **Checks the model can see in a diff.** Each line of the checklist is a concrete pattern
       with its why: "A query inside a loop over request data: one query per item". Never "check
       the quality" or "look for issues".
    3. **What is not a finding.** Add the cases that look like the problem but are fine, and the
       topics other roles own, under `do_not_comment` (style, naming taste, tests unless this is the
       tests role).
    4. **Severity on purpose.** Write `min_severity: low` unless the user asks otherwise: the developer sees every potential
       problem in AKit with its severity, and only confident ones of `medium` or more reach the merge
       request; `high` for roles that should speak only about breakage or data loss.
    5. **Room for findings.** Write `max_findings: 6`; fewer for a narrow role.
    6. **Only the context it needs.** `needs: [diff]` for patterns in changed lines; add
       `full_files` when the surrounding code decides; `wi` when the work item's criteria matter;
       `history` for regressions; `tests` for test results.
    7. **Evidence.** End the checklist with: every finding quotes the changed line it is about and
       says what breaks, for whom, and how to fix it.
    8. **The user's words win.** Keep their project terms, examples and limits exactly; never
       invent rules, libraries or file paths they didn't give.

    Keep the body under about 40 lines: a short intro, the checklist, then "Not a finding:" items.
    """
}

extension ReviewRoleWriter {
    /// AKit's own writing skill for scenarios.
    public static let builtInScenarioSkill = """
    ---
    name: review-scenario-writer
    description: "Write an AKit Review scenario: which roles and skills review one kind of change"
    ---

    # Writing a review scenario

    A scenario is picked for one kind of merge request (a feature, a bug fix, an upgrade, a
    migration). Write it so:

    1. **One kind of change.** The id is given in the task: keep it exactly. The title says the
       kind in two or three words.
    2. **Few required roles.** Required: the roles that must speak on every change of this kind
       (two to four). Optional: roles that help only sometimes; the user turns them on per run.
       Use only the roles listed; never invent one.
    3. **Checks as questions.** Each line of `checks:` is one question the review must answer
       for this kind of change, concrete and with its why: "Does a regression test reproduce the
       bug?". A need no role covers goes here.
    4. **Context it needs.** `context_required`: `wi` when the work item's criteria matter,
       `full_files` when surrounding code decides, `history` for regressions, `tests` for test results.
    5. **Skills only when they help.** `skills:` links skills from the list whose rules this
       kind of change must follow (a framework guide, a team's checklist). None is fine.
    6. **The user's words win.** Keep their terms and limits; never invent rules, libraries or
       file paths they didn't give.
    """
}

extension ReviewConfigEditor.Level {
    /// The project's slug; nil for the brain.
    public var slug: String? {
        if case .project(let slug) = self { slug } else { nil }
    }
}
