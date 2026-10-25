import AKitFoundation
import AKitLab
import Foundation

/// What one run chooses on top of the brain and the project (New Review… or the command line).
public struct ReviewRunChoices: Sendable, Hashable {
    public var scenario: String?
    /// Optional roles of the scenario (or any role) turned on for this run.
    public var rolesOn: [String]
    /// Roles turned off for this run, required ones included.
    public var rolesOff: [String]
    public var settings: ReviewSettingsPatch
    /// Work item numbers given by hand (`--wi`).
    public var workItems: [Int]
    /// The user's own context for this run: what the change is for, what to focus on (`--note`).
    public var notes: String
    /// Links the fetch pass reads through Pi's MCP servers (`--link`); https only.
    public var links: [String]
    /// Pi MCP servers added for this run as read-only context servers (`--extra-server`), on top
    /// of the profile's.
    public var extraServers: [String]
    /// Pi flags and steps for this run (`--pi-flag`, `--step`), on top of the brain's and the profile's.
    public var pi = ReviewPiExtras()
    /// Review the whole merge request again, not only what changed since the last review (R28).
    public var fullReview = false
    /// The knowledge base of this run's card (`--knowledge-base WORLD|PATH`), over the profile's.
    public var knowledgeBase: String?
    /// The card's size in tokens for this run (`--knowledge-budget N`), over the profile's.
    public var knowledgeBudget: Int?
    /// Review only what changed after this commit of the merge request (`URL@COMMIT`); nil = the merge base.
    public var fromCommit: String?
    /// Other merge requests reviewed in the same run, in order (`akit review URL URL…`).
    public var linked: [ReviewMergeRequestEntry] = []

    public init(scenario: String? = nil, rolesOn: [String] = [], rolesOff: [String] = [], settings: ReviewSettingsPatch = ReviewSettingsPatch(),
                workItems: [Int] = [], notes: String = "", links: [String] = [], extraServers: [String] = []) {
        self.scenario = scenario
        self.rolesOn = rolesOn
        self.rolesOff = rolesOff
        self.settings = settings
        self.workItems = workItems
        self.notes = notes
        self.links = links
        self.extraServers = extraServers
    }
}

/// One MCP server a run may use and who chose it (`run.json`).
public struct ReviewServerChoice: Codable, Sendable, Hashable {
    /// A Pi server name, or a name pattern for the defaults (`*gitlab*`).
    public var name: String
    /// `built-in` (the defaults), `project` (the profile) or `run` (New Review…, `--extra-server`).
    public var source: ReviewSource
    /// A context server: its tools only read, in every pass.
    public var readOnly: Bool

    public init(name: String, source: ReviewSource, readOnly: Bool) {
        self.name = name
        self.source = source
        self.readOnly = readOnly
    }
}

/// Exactly what one run used, with the source of each value: `<run>/run.json` (R10).
public struct ReviewRunSpec: Codable, Sendable, Hashable {
    public struct Role: Codable, Sendable, Hashable {
        public var id: String
        public var source: ReviewSource
        /// Required by the scenario, optional and turned on, or added by the project.
        public var reason: String
        public var minSeverity: ReviewSeverity
        public var maxFindings: Int
        public var needs: [String]
        public var doNotComment: [String]
        /// The role's SKILL.md as copied into `<run>/roles/review-<id>/SKILL.md`.
        public var sha256: String
    }

    /// A Pi step after the roles (`docs/design/review.md`, "Pi steps"): a subagent, a prompt
    /// template, a skill or a plain instruction, run as AKit's own pass with the review's tools.
    public struct Step: Codable, Sendable, Hashable {
        /// `pi-reviewer`, `pi-review-api`, `pi-step-2`: the findings' role, the pass `step-<id>`.
        public var id: String
        /// nil: a plain instruction.
        public var kind: ReviewPiLibrary.Item.Kind?
        /// The agent, template or skill; empty for a plain instruction.
        public var name: String
        /// As configured: `/run reviewer check the retries`.
        public var command: String
        /// `user`, or the package it came from.
        public var origin: String?
        public var source: ReviewSource
        /// What the pass reads: the agent's prompt, the expanded template, the skill; secrets masked.
        public var instructions: String
        /// The task after the name, or the request after a skill.
        public var task: String
        public var model: ReviewModelChoice
        public var minSeverity: ReviewSeverity
        public var maxFindings: Int
        /// An agent's tools the pass doesn't get: a review pass only reads.
        public var toolsLeftOut: [String]

        /// The step as a role: its limits for the findings tool and the candidates.
        public var role: Role {
            Role(id: id, source: source, reason: "Pi step \(command)", minSeverity: minSeverity, maxFindings: maxFindings, needs: [],
                 doNotComment: [], sha256: ReviewHash.sha256(instructions))
        }
    }

    public struct Posting: Codable, Sendable, Hashable {
        public var marker: Sourced<String>
        public var severityThreshold: Sourced<ReviewSeverity>
        public var confidenceThreshold: Sourced<Double>
        public var maxInline: Sourced<Int>
        /// nil in runs made before 2026-10-23: no limit of its own.
        public var maxInlineMedium: Sourced<Int>?
        /// The comments' language (`ReviewLanguage`); nil in runs made before 2026-10-23.
        public var language: Sourced<String>?

        public var languageCode: String { language?.value ?? ReviewLanguage.czech }
    }

    /// 2 since 2026-10-23: the verifier's model is the user's choice (R25).
    public var version = 2
    /// The developer's own change (R33), set by Gather; nil before Gather and in older runs.
    public var ownChange: Bool?
    /// The user asked for the whole merge request again (Full review, `--full`).
    public var fullReview: Bool?
    /// A rerun after a push (R28), set by Gather: what changed since the last reviewed head.
    public var rerun: ReviewRerunInfo?
    /// The commit the developer asked to review from (as typed); nil = the merge base.
    public var fromCommit: String?
    /// Filled by Gather when `fromCommit` resolved: the lines after it.
    public var since: ReviewSince?
    /// Other merge requests of the same change, reviewed in this run; nil for one merge request.
    public var linked: [ReviewLinkedChange]?
    public var id: String
    public var created: Date
    public var mergeRequest: MergeRequestRef
    /// The project profile's slug; nil when none matched.
    public var project: String?
    public var scenario: Sourced<String>
    public var checks: [String]
    public var contextRequired: [String]
    public var roles: [Role]
    public var passes: Sourced<ReviewModelChoice>
    public var verifier: Sourced<ReviewModelChoice>
    public var posting: Posting
    public var capCredits: Sourced<Int>
    public var constraints: [String]
    public var pathInstructions: [ReviewProfile.PathInstruction]
    public var knowledge: [String]
    /// The knowledge base Gather makes the card from (K18): a world name or a path; nil = none
    /// (a `knowledge:` folder that is a base still gives one).
    public var knowledgeBase: Sourced<String>?
    /// The knowledge card's size in tokens; nil in runs made before 2026-10-25.
    public var knowledgeBudget: Sourced<Int>?
    /// Filled by Gather: the folder of the base the card came from, which the review passes'
    /// `akit_kb_search` / `akit_kb_show` read (`AKIT_REVIEW_KB_BASE`); nil without a base.
    public var knowledgeBasePath: String?
    public var gather: [ReviewProfile.GatherCommand]
    public var workItems: [Int]
    /// Filled by Gather: the commit the worktree and every finding refer to.
    public var headSHA: String?
    /// The project's tracker, named to the fetch pass; nil without a profile or a tracker.
    public var tracker: ReviewProfile.Tracker?
    /// Pi's MCP servers and tools this run may use; nil in runs made before MCP (2026-10-15).
    public var mcp: ReviewMCPAccess?
    /// A review of a local workspace instead of a merge request: the range and what it holds.
    public var local: ReviewLocalTarget?
    /// The user's notes for this run, secrets masked; Gather writes them to `context/notes.md`.
    public var notes: String?
    /// Links the fetch pass reads; what it got is in `context/links.md`.
    public var links: [String]?
    /// Filled by Gather: the links the fetch pass couldn't read.
    public var linksUnread: [String]?
    /// The servers of `mcp` with the level that chose each; nil in runs made before 2026-10-22.
    public var mcpServers: [ReviewServerChoice]?
    /// Pi steps after the roles; nil in runs made before 2026-10-22.
    public var steps: [Step]?
    /// Extra Pi flags of the brief, the roles, the steps and the verifier, by the level that added them.
    public var piFlags: [Sourced<[String]>]?

    /// Over this many changed lines the passes ask first; nil in runs made before 2026-10-22.
    public var maxChangedLines: Sourced<Int>?
    /// Whether the `impact` pass looks in other repositories (R42); nil in runs made before 2026-10-24.
    public var impact: Sourced<ReviewImpact>?
    /// Roles the user turned off (the project profile's `roles: off` and the run's choices); R44
    /// never adds one of them back. nil when none, or in runs made before 2026-10-24.
    public var rolesOff: [String]?

    /// The run's `impact`: `auto` when the run predates it.
    public var impactMode: ReviewImpact { impact?.value ?? .auto }

    /// The overview's language (R46); nil in runs made before 2026-10-24.
    public var summaryLanguage: Sourced<LabLanguage>?

    /// The overview's language: the run's, or for an older run the Mac's preferred one, else English.
    public func overviewLanguage(preferred: [String] = Locale.preferredLanguages) -> LabLanguage {
        summaryLanguage?.value ?? ReviewResolver.preferredLanguage(preferred)
    }

    /// Every extra flag, in level order.
    public var extraFlags: [String] { (piFlags ?? []).flatMap(\.value) }

    /// The run's MCP access: the project's, or every server with the default rules.
    public var access: ReviewMCPAccess { mcp ?? ReviewMCPAccess() }
}

extension ReviewRunSpec {
    /// The limits of a self-review: `low` findings too, and more of them inline.
    public static let ownSeverity = ReviewSeverity.low
    public static let ownMaxInline = 10

    /// R33: a review of the developer's own change also lists `low` findings and has a higher
    /// inline limit. Only built-in values change: what a brain, a profile or the run set stays.
    public mutating func applyMode(own: Bool) {
        ownChange = own
        guard own else { return }
        // A brain's review.yaml starts as a copy of the defaults: a default value there is no choice.
        func untouched<T: Equatable>(_ value: Sourced<T>?, _ fallback: T) -> Bool {
            guard let value else { return false }
            return value.source == .builtIn || (value.source == .brain && value.value == fallback)
        }
        if untouched(posting.severityThreshold, .medium) { posting.severityThreshold = Sourced(Self.ownSeverity, .builtIn) }
        if untouched(posting.maxInline, 5) { posting.maxInline = Sourced(Self.ownMaxInline, .builtIn) }
        if untouched(posting.maxInlineMedium, 3) { posting.maxInlineMedium = Sourced(Self.ownMaxInline, .builtIn) }
    }

    /// Why the run can't start: the verifier's model is the user's choice (R25), so a run
    /// without one stops before anything is spent. nil when it is set.
    public var verifierProblem: String? {
        // A run made before R25 had the passes' model (or Pi's default) as its verifier.
        guard verifier.value.model.isEmpty, version >= 2 else { return nil }
        return "No verifier model: set one for this run (Verifier model in New Review…, --verifier-model), in the project profile "
            + "(review: { models: { verifier: … } }) or in review.yaml (models: verifier). Best a strong model of another family than the passes'."
    }
}

/// Brain → project profile → one run (`docs/design/review.md`, "Levels").
public enum ReviewResolver {
    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    public static func resolve(catalog: ReviewCatalog, profile: ReviewProfile?, choices: ReviewRunChoices, mergeRequest: MergeRequestRef,
                               id: String, now: Date = .now, pi: ReviewPiLibrary = ReviewPiLibrary(),
                               preferredLanguages: [String] = Locale.preferredLanguages) throws -> (spec: ReviewRunSpec, roles: [ReviewRole]) {
        let scenarios = catalog.scenarios(for: profile)
        let scenario: Sourced<String>
        if let chosen = choices.scenario {
            scenario = Sourced(chosen, .run)
        } else if let preset = profile?.defaultScenario {
            scenario = Sourced(preset, .project)
        } else {
            scenario = Sourced("feature", catalog.scenarios.first { $0.id == "feature" }?.source ?? .builtIn)
        }
        guard let definition = scenarios.first(where: { $0.id == scenario.value }) else {
            throw Failure(message: "There is no scenario \(scenario.value). Known: \(scenarios.map(\.id).joined(separator: ", ")).")
        }
        let available = catalog.roles(for: profile)
        var picked: [(id: String, reason: String)] = definition.required.map { ($0, "required by \(definition.id)") }
        for id in profile?.rolesAdd ?? [] where !picked.contains(where: { $0.id == id }) { picked.append((id, "added by the project")) }
        for id in choices.rolesOn where !picked.contains(where: { $0.id == id }) {
            picked.append((id, definition.optional.contains(id) ? "optional, turned on" : "added for this run"))
        }
        let off = Set((profile?.rolesOff ?? []) + choices.rolesOff)
        picked.removeAll { off.contains($0.id) && !choices.rolesOn.contains($0.id) }
        let roles = try picked.map { pick -> ReviewRole in
            guard let role = available.first(where: { $0.id == pick.id }) else {
                throw Failure(message: "There is no role \(pick.id) (\(pick.reason)). Known: \(available.map(\.id).joined(separator: ", ")).")
            }
            return role
        }
        guard !roles.isEmpty else { throw Failure(message: "No role is left to run: every role of \(definition.id) is turned off.") }

        let builtIn = catalog.builtInDefaults
        let brain = catalog.brainDefaults
        let project = profile?.settings ?? ReviewSettingsPatch()
        let run = choices.settings
        func pick<T>(_ key: KeyPath<ReviewSettingsPatch, T?>, fallback: T) -> Sourced<T> where T: Codable & Sendable & Hashable {
            if let value = run[keyPath: key] { return Sourced(value, .run) }
            if let value = project[keyPath: key] { return Sourced(value, .project) }
            if let value = brain[keyPath: key] { return Sourced(value, .brain) }
            return Sourced(builtIn[keyPath: key] ?? fallback, .builtIn)
        }
        func model(_ key: KeyPath<ReviewSettingsPatch, ReviewModelChoice?>) -> Sourced<ReviewModelChoice> {
            var value = ReviewModelChoice(model: "")
            var source = ReviewSource.builtIn
            for (patch, level) in [(builtIn, ReviewSource.builtIn), (brain, .brain), (project, .project), (run, .run)] {
                guard let choice = patch[keyPath: key] else { continue }
                if !choice.model.isEmpty { value.model = choice.model; source = level }
                if !choice.thinking.isEmpty { value.thinking = choice.thinking; source = level }
            }
            return Sourced(value, source)
        }
        let verifier = model(\.verifier)
        let passes = model(\.passes)
        // The verifier's model is the user's choice (R25): an empty one stops the passes.

        // MCP servers: the profile's (or the defaults), plus context servers from the profile and the run.
        for server in choices.extraServers where !ReviewMCPAccess.isServerName(server) {
            throw Failure(message: "\(server) is not a Pi MCP server name (letters, digits, _ and -).")
        }
        let base = profile?.mcp ?? ReviewMCPAccess()
        let access = base.adding(extraServers: choices.extraServers)
        var servers: [ReviewServerChoice] = base.servers.isEmpty
            ? (ReviewMCPAccess.defaultServerWords.map { "*\($0)*" } + ["ado"]).map { ReviewServerChoice(name: $0, source: .builtIn, readOnly: false) }
            : base.servers.map { ReviewServerChoice(name: $0, source: .project, readOnly: false) }
        for server in access.extraServers where access.isExtra(server: server) {
            let fromProfile = base.extraServers.contains { $0.lowercased() == server.lowercased() }
            servers.append(ReviewServerChoice(name: server, source: fromProfile ? .project : .run, readOnly: true))
        }
        let notes: String?
        let links: [String]
        do {
            notes = try ReviewContext.notes(choices.notes)
            links = try ReviewContext.links(choices.links)
        } catch {
            throw Failure(message: error.localizedDescription)
        }

        var spec = ReviewRunSpec(
            id: id, created: now, mergeRequest: mergeRequest, project: profile?.slug, scenario: scenario,
            checks: definition.checks, contextRequired: definition.contextRequired,
            roles: zip(picked, roles).map { pick, role in
                ReviewRunSpec.Role(id: role.id, source: role.source, reason: pick.reason, minSeverity: role.minSeverity,
                                   maxFindings: role.maxFindings, needs: role.needs, doNotComment: role.doNotComment,
                                   sha256: ReviewHash.sha256(role.text))
            },
            passes: passes, verifier: verifier,
            posting: ReviewRunSpec.Posting(marker: pick(\.marker, fallback: "🤖"),
                                           severityThreshold: pick(\.severityThreshold, fallback: .medium),
                                           confidenceThreshold: pick(\.confidenceThreshold, fallback: 0.8),
                                           maxInline: pick(\.maxInline, fallback: 5),
                                           maxInlineMedium: pick(\.maxInlineMedium, fallback: 3),
                                           language: pick(\.language, fallback: ReviewLanguage.czech)),
            capCredits: pick(\.capCredits, fallback: 600), constraints: profile?.constraints ?? [],
            pathInstructions: profile?.pathInstructions ?? [], knowledge: profile?.knowledge ?? [], gather: profile?.gather ?? [],
            workItems: choices.workItems, headSHA: nil, tracker: profile?.tracker, mcp: access)
        spec.notes = notes
        spec.links = links.isEmpty ? nil : links
        spec.mcpServers = servers
        spec.fullReview = choices.fullReview ? true : nil
        spec.maxChangedLines = pick(\.maxChangedLines, fallback: 6000)
        spec.impact = pick(\.impact, fallback: .auto)
        spec.summaryLanguage = pick(\.summaryLanguage, fallback: preferredLanguage(preferredLanguages))
        let turnedOff = off.filter { !choices.rolesOn.contains($0) }.sorted()
        spec.rolesOff = turnedOff.isEmpty ? nil : turnedOff
        if let base = choices.knowledgeBase {
            spec.knowledgeBase = Sourced(base, .run)
        } else if let base = profile?.knowledgeBase {
            spec.knowledgeBase = Sourced(base, .project)
        }
        if let budget = choices.knowledgeBudget {
            spec.knowledgeBudget = Sourced(budget, .run)
        } else if let budget = profile?.knowledgeBudget {
            spec.knowledgeBudget = Sourced(budget, .project)
        } else {
            spec.knowledgeBudget = Sourced(ReviewKnowledgeCard.defaultBudget, .builtIn)
        }
        let levels: [(ReviewPiExtras, ReviewSource)] = [(catalog.brainPi, .brain), (profile?.pi ?? ReviewPiExtras(), .project), (choices.pi, .run)]
        for (extras, _) in levels {
            if let problem = ReviewPiFlags.problem(extras.flags) { throw Failure(message: "Pi flags: \(problem)") }
        }
        let flags = levels.filter { !$0.0.flags.isEmpty }.map { Sourced($0.0.flags, $0.1) }
        spec.piFlags = flags.isEmpty ? nil : flags
        var steps: [ReviewRunSpec.Step] = []
        for (extras, source) in levels {
            for config in extras.steps where !steps.contains(where: { $0.command == config.command }) {
                steps.append(try step(config, number: steps.count + 1, source: source, library: pi, passes: passes.value,
                                      taken: Set(spec.roles.map(\.id) + steps.map(\.id))))
            }
        }
        spec.steps = steps.isEmpty ? nil : steps
        return (spec, roles)
    }

    /// A configured step resolved against the user's Pi set-up. Throws when the agent, template
    /// or skill isn't there.
    static func step(_ config: ReviewStepConfig, number: Int, source: ReviewSource, library: ReviewPiLibrary, passes: ReviewModelChoice,
                     taken: Set<String>) throws -> ReviewRunSpec.Step {
        let (kind, name, arguments) = config.parsed
        var instructions = arguments
        var task = ""
        var model = passes
        var origin: String?
        var leftOut: [String] = []
        if let kind {
            guard !name.isEmpty else { throw Failure(message: "Pi step \(config.command): name the \(kind.rawValue) after the command.") }
            guard let item = library.item(kind, name) else {
                let known = library.items.filter { $0.kind == kind }.map(\.name)
                let what = kind == .agent ? "subagent" : kind == .template ? "prompt template" : "skill"
                throw Failure(message: "Pi step \(config.command): there is no \(what) \(name) in your Pi set-up"
                              + (known.isEmpty ? "." : ". Known: \(known.joined(separator: ", ")).")
                              + (kind == .template && name != "run" ? " Extension commands don't run in a review pass; only prompt templates, /skill:… and /run <subagent>." : ""))
            }
            origin = item.origin
            switch kind {
            case .agent:
                instructions = item.body
                task = arguments
                model = library.model(of: item, passes: passes)
                let reading: Set<String> = ["read", "grep", "find", "ls"]
                leftOut = item.tools.isEmpty ? ["bash", "edit", "write"] : item.tools.filter { !reading.contains($0) }
            case .template:
                instructions = ReviewPiTemplate.expand(item.body, arguments: arguments)
            case .skill:
                instructions = item.body
                task = arguments
            }
        }
        guard !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure(message: "Pi step \(config.command) has no instructions.")
        }
        var id = String(("pi-" + (name.isEmpty ? "step-\(number)" : name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined())).prefix(50))
        if !ReviewYAML.isID(id) { id = "pi-step-\(number)" }
        // Every step has its own pass file: an id a role or an earlier step has gets a suffix.
        let base = id
        var suffix = 2
        while taken.contains(id) {
            id = "\(base)-\(suffix)"
            suffix += 1
        }
        return ReviewRunSpec.Step(id: id, kind: kind, name: name, command: SecretFilter.masked(config.command), origin: origin, source: source,
                                  instructions: SecretFilter.masked(instructions), task: SecretFilter.masked(task), model: model,
                                  minSeverity: config.minSeverity ?? .medium, maxFindings: config.maxFindings ?? 5, toolsLeftOut: leftOut)
    }

    /// The default overview language (R46): the first of the Mac's preferred languages
    /// (`Locale.preferredLanguages`, such as `ru-CZ` or `zh-Hans`) by its language code before
    /// the first `-`, when it is a `LabLanguage`; else English (`fil` is not Finnish).
    public static func preferredLanguage(_ preferred: [String]) -> LabLanguage {
        guard let first = preferred.first else { return .english }
        let code = first.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
        return LabLanguage(rawValue: code.lowercased()) ?? .english
    }

    /// `akit review config show`: every resolved value with its source.
    public static func describe(_ spec: ReviewRunSpec) -> String {
        func line(_ name: String, _ value: String, _ source: ReviewSource) -> String { "  \(name): \(value)  [\(source.rawValue)]" }
        func model(_ choice: ReviewModelChoice) -> String {
            (choice.model.isEmpty ? "Pi's default model" : choice.model) + (choice.thinking.isEmpty ? "" : " · thinking \(choice.thinking)")
        }
        var lines = ["Project profile: \(spec.project ?? "none")",
                     line("scenario", spec.scenario.value, spec.scenario.source)]
        if let own = spec.ownChange {
            lines.append(own ? "  mode: your own change (low findings too, up to \(ReviewRunSpec.ownMaxInline) inline)" : "  mode: a colleague's merge request")
        }
        lines.append("Roles:")
        lines += spec.roles.map {
            "  \($0.id) [\($0.source.rawValue)] \($0.reason); min \($0.minSeverity.rawValue), at most \($0.maxFindings) findings"
        }
        lines += ["Models:", line("passes", model(spec.passes.value), spec.passes.source),
                  spec.verifier.value.model.isEmpty ? "  verifier: not set (required: --verifier-model or models.verifier)"
                    : line("verifier", model(spec.verifier.value), spec.verifier.source), "Posting:",
                  line("marker", spec.posting.marker.value, spec.posting.marker.source),
                  line("severity_threshold", spec.posting.severityThreshold.value.rawValue, spec.posting.severityThreshold.source),
                  line("confidence_threshold", String(spec.posting.confidenceThreshold.value), spec.posting.confidenceThreshold.source),
                  line("max_inline", String(spec.posting.maxInline.value), spec.posting.maxInline.source)]
        if let medium = spec.posting.maxInlineMedium { lines.append(line("max_inline_medium", String(medium.value), medium.source)) }
        if let language = spec.posting.language { lines.append(line("language", language.value, language.source)) }
        lines += [
                  "Cost:",
                  line("cap_credits_per_run", String(spec.capCredits.value), spec.capCredits.source)]
        if let size = spec.maxChangedLines { lines.append(line("max_changed_lines", String(size.value), size.source)) }
        if let impact = spec.impact { lines += ["Other repositories:", line("impact", impact.value.rawValue, impact.source)] }
        if let language = spec.summaryLanguage {
            lines += ["Overview:", line("summary_language", "\(language.value.rawValue) (\(language.value.name))", language.source)]
        }
        if !spec.constraints.isEmpty { lines += ["Constraints [project]:"] + spec.constraints.map { "  - \($0)" } }
        if !spec.pathInstructions.isEmpty {
            lines += ["Path instructions [project]:"] + spec.pathInstructions.map {
                "  \($0.paths.joined(separator: ", ")): " + ($0.ignore ? "ignored" : $0.instructions ?? "")
            }
        }
        if !spec.knowledge.isEmpty { lines += ["Knowledge folders [project]:"] + spec.knowledge.map { "  \($0)" } }
        if let base = spec.knowledgeBase { lines.append(line("knowledge_base", base.value, base.source)) }
        if let budget = spec.knowledgeBudget { lines.append(line("knowledge_budget", String(budget.value), budget.source)) }
        if !spec.gather.isEmpty { lines += ["Gather commands [project]:"] + spec.gather.map { "  \($0.name): \($0.run)" } }
        let access = spec.access
        let source = spec.project == nil ? "default" : "project"
        lines += ["MCP (Pi's servers) [\(source)]:",
                  "  servers: " + (access.servers.isEmpty ? "those named like gitlab, azure, devops or ado" : access.servers.joined(separator: ", "))]
        for server in (spec.mcpServers ?? []).filter(\.readOnly) {
            lines.append("  context server (read only): \(server.name)  [\(server.source.rawValue)]"
                         + (ReviewMCPAccess.warning(forServer: server.name) == nil ? "" : "  ! a browser, file or web fetch server"))
        }
        for server in access.extrasTakenAsBase {
            lines.append("  ! extra server \(server) is one of the run's own servers (GitLab or the tracker): it keeps that role, "
                         + "and Send Drafts may write with it")
        }
        lines += ["  read: get_/list_/search_/… tools, tools marked read-only" + (access.read.isEmpty ? "" : ", " + access.read.joined(separator: ", ")),
                  "  write (Send Drafts only): " + access.write.joined(separator: ", "),
                  "  in passes: " + (!access.inPasses ? "no, only the fetch pass"
                    : access.allServers ? "every server of your Pi, reading tools only (browser, file and web fetch servers only when named)" : "yes")]
        if let tracker = spec.tracker { lines += ["Tracker [project]: \(tracker.kind) \(tracker.org)/\(tracker.project), work items \(tracker.wiRefRegex)"] }
        if let flags = spec.piFlags {
            lines += ["Pi flags:"] + flags.map { "  \($0.value.joined(separator: " "))  [\($0.source.rawValue)]" }
        }
        if let steps = spec.steps {
            lines += ["Pi steps (after the roles, with the review's reading tools):"]
            for step in steps {
                var line = "  \(step.id): \(step.command)  [\(step.source.rawValue)]"
                if let origin = step.origin { line += " from \(origin)" }
                if step.kind == .agent { line += "; model \(step.model.model.isEmpty ? "Pi's default" : step.model.model)" }
                line += "; at most \(step.maxFindings) findings, min \(step.minSeverity.rawValue)"
                lines.append(line)
                if !step.toolsLeftOut.isEmpty { lines.append("    without its tools \(step.toolsLeftOut.joined(separator: ", ")): a review pass only reads") }
            }
        }
        if let notes = spec.notes { lines += ["Notes [run]: \(notes.count) characters (context/notes.md)"] }
        if let links = spec.links, !links.isEmpty { lines += ["Links [run]:"] + links.map { "  \($0)" } }
        return lines.joined(separator: "\n")
    }
}

enum ReviewHash {
    static func sha256(_ text: String) -> String { Checksum.sha256(Data(text.utf8)) }
}
