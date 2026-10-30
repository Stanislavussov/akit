import AKitFoundation
import AKitLab
import Foundation

/// Write with AI…: Pi drafts a review role from the user's words with a writing skill the user
/// picks (AKit's own `review-role-writer` by default). One pass with no tools and no MCP: Pi
/// reads only the description, AKit's role format and the skill. The draft is checked as a role
/// and shown as a diff; nothing is saved before the user approves it.
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

        /// The text Pi reads.
        public func text() throws -> String {
            guard let file else { return ReviewRoleWriter.builtInSkill }
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { throw Failure(message: "Can't read \(file.path).") }
            return text
        }
    }

    public static let builtInName = "review-role-writer"

    /// The skills on this Mac that could write a role: the built-in one, then the brain's, then
    /// the harnesses' global ones. Review roles (`review-*`) are left out.
    public static func skills(brain: URL?, home: URL) -> [Skill] {
        var folders: [(URL, String)] = []
        if let brain { folders.append((brain.appending(path: "skills"), "brain")) }
        folders += [(home.appending(path: ".claude/skills"), "Claude Code"), (home.appending(path: ".pi/agent/skills"), "Pi"),
                    (home.appending(path: ".agents/skills"), "agents")]
        var seen = Set<String>()
        var found = [Skill.builtIn]
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
    public static func skill(named text: String, brain: URL?, home: URL, cwd: URL) throws -> Skill {
        let all = skills(brain: brain, home: home)
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
        public var id: String
        /// The user's words: what the role checks, for which code, what to leave alone.
        public var description: String
        public var skill: Skill
        public var level: ReviewConfigEditor.Level
        /// nil: the review's passes model (review.yaml), else Pi's default.
        public var model: ReviewModelChoice?

        public init(id: String, description: String, skill: Skill = .builtIn, level: ReviewConfigEditor.Level, model: ReviewModelChoice? = nil) {
            self.id = id
            self.description = description
            self.skill = skill
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
        let words = request.description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { throw Failure(message: "Say what the role checks.") }
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
        let current = existing.first { $0.id == request.id }.map { clean($0.text) }
        let system = clean(systemPrompt(skill: request.skill, skillText: skillText, roles: existing))
        try ReviewPasses.write(system, to: folder.appending(path: "prompt.md"))
        let task = clean(prompt(id: request.id, description: words, current: current))
        try ReviewPasses.write(task, to: folder.appending(path: "task.md"))

        var arguments = ["-p", "--mode", "json", "--offline", "--no-session"]
        if !model.model.isEmpty { arguments += ["--model", model.model] }
        if !model.thinking.isEmpty { arguments += ["--thinking", model.thinking] }
        arguments += ["--no-skills", "--no-context-files", "--no-prompt-templates", "--no-extensions", "--no-mcp", "--no-tools",
                      "--append-system-prompt", folder.appending(path: "prompt.md").path, "--", task]
        var environment = await ReviewPasses.passEnvironment(env)
        environment["AKIT_REVIEW_PASS"] = "role-writer"
        progress("Pi writes role \(request.id) with \(request.skill.name) (\(model.model.isEmpty ? "Pi's default model" : model.model))…")
        let output = await ReviewPasses.runPi(pi, arguments: arguments, directory: folder, environment: environment, timeout: timeout,
                                              stream: folder.appending(path: "pass.jsonl"), progress: { progress("  \($0)") })
        var send = SendRecord(purpose: "review-role-writer", session: output.session, runID: nil, destination: gate.destination, model: model.model,
                              inputCharacters: system.count + task.count, usage: output.usage)
        send.error = output.error
        _ = SendLog.appendAfterRun(send, env: env, out: progress)
        if let error = output.error { throw Failure(message: "Pi failed: \(error)") }
        guard let answer = output.answer else { throw Failure(message: "Pi gave no answer.") }
        let draft = role(from: answer)
        try ReviewPasses.write(draft, to: folder.appending(path: "SKILL.md"))
        do {
            let save = try ReviewConfigEditor.plan(.role, id: request.id, text: draft, level: request.level, home: home, brain: brain)
            return Result(save: save, model: model.model, credits: ReviewCredits.of(output.usage))
        } catch {
            throw Failure(message: "Pi's draft isn't a valid role: \(error.localizedDescription) The draft is in \(folder.appending(path: "SKILL.md").path).",
                          draft: draft)
        }
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

    static func systemPrompt(skill: Skill, skillText: String, roles: [ReviewRole]) -> String {
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
        ---

        <the checklist>
        ```

        Roles that exist already (stay out of what they cover, or say how this one differs):
        \(roles.map { "- \($0.id): \($0.description)" }.joined(separator: "\n"))

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

extension ReviewConfigEditor.Level {
    /// The project's slug; nil for the brain.
    public var slug: String? {
        if case .project(let slug) = self { slug } else { nil }
    }
}
