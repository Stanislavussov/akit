import AKitFoundation
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

    public struct Posting: Codable, Sendable, Hashable {
        public var marker: Sourced<String>
        public var severityThreshold: Sourced<ReviewSeverity>
        public var confidenceThreshold: Sourced<Double>
        public var maxInline: Sourced<Int>
        public var nitpicks: Sourced<Bool>
    }

    public var version = 1
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

    /// The run's MCP access: the project's, or every server with the default rules.
    public var access: ReviewMCPAccess { mcp ?? ReviewMCPAccess() }
}

/// Brain → project profile → one run (`docs/design/review.md`, "Levels").
public enum ReviewResolver {
    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    public static func resolve(catalog: ReviewCatalog, profile: ReviewProfile?, choices: ReviewRunChoices, mergeRequest: MergeRequestRef,
                               id: String, now: Date = .now) throws -> (spec: ReviewRunSpec, roles: [ReviewRole]) {
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
        var verifier = model(\.verifier)
        let passes = model(\.passes)
        // An empty verifier model means "the passes' model".
        if verifier.value.model.isEmpty { verifier.value.model = passes.value.model }

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
                                           maxInline: pick(\.maxInline, fallback: 7), nitpicks: pick(\.nitpicks, fallback: false)),
            capCredits: pick(\.capCredits, fallback: 150), constraints: profile?.constraints ?? [],
            pathInstructions: profile?.pathInstructions ?? [], knowledge: profile?.knowledge ?? [], gather: profile?.gather ?? [],
            workItems: choices.workItems, headSHA: nil, tracker: profile?.tracker, mcp: access)
        spec.notes = notes
        spec.links = links.isEmpty ? nil : links
        spec.mcpServers = servers
        return (spec, roles)
    }

    /// `akit review config show`: every resolved value with its source.
    public static func describe(_ spec: ReviewRunSpec) -> String {
        func line(_ name: String, _ value: String, _ source: ReviewSource) -> String { "  \(name): \(value)  [\(source.rawValue)]" }
        func model(_ choice: ReviewModelChoice) -> String {
            (choice.model.isEmpty ? "Pi's default model" : choice.model) + (choice.thinking.isEmpty ? "" : " · thinking \(choice.thinking)")
        }
        var lines = ["Project profile: \(spec.project ?? "none")",
                     line("scenario", spec.scenario.value, spec.scenario.source), "Roles:"]
        lines += spec.roles.map {
            "  \($0.id) [\($0.source.rawValue)] \($0.reason); min \($0.minSeverity.rawValue), at most \($0.maxFindings) findings"
        }
        lines += ["Models:", line("passes", model(spec.passes.value), spec.passes.source),
                  line("verifier", model(spec.verifier.value), spec.verifier.source), "Posting:",
                  line("marker", spec.posting.marker.value, spec.posting.marker.source),
                  line("severity_threshold", spec.posting.severityThreshold.value.rawValue, spec.posting.severityThreshold.source),
                  line("confidence_threshold", String(spec.posting.confidenceThreshold.value), spec.posting.confidenceThreshold.source),
                  line("max_inline", String(spec.posting.maxInline.value), spec.posting.maxInline.source),
                  line("nitpicks", String(spec.posting.nitpicks.value), spec.posting.nitpicks.source), "Cost:",
                  line("cap_credits_per_run", String(spec.capCredits.value), spec.capCredits.source)]
        if !spec.constraints.isEmpty { lines += ["Constraints [project]:"] + spec.constraints.map { "  - \($0)" } }
        if !spec.pathInstructions.isEmpty {
            lines += ["Path instructions [project]:"] + spec.pathInstructions.map {
                "  \($0.paths.joined(separator: ", ")): " + ($0.ignore ? "ignored" : $0.instructions ?? "")
            }
        }
        if !spec.knowledge.isEmpty { lines += ["Knowledge folders [project]:"] + spec.knowledge.map { "  \($0)" } }
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
                  "  in passes: " + (access.inPasses ? "yes" : "no, only the fetch pass")]
        if let tracker = spec.tracker { lines += ["Tracker [project]: \(tracker.kind) \(tracker.org)/\(tracker.project), work items \(tracker.wiRefRegex)"] }
        if let notes = spec.notes { lines += ["Notes [run]: \(notes.count) characters (context/notes.md)"] }
        if let links = spec.links, !links.isEmpty { lines += ["Links [run]:"] + links.map { "  \($0)" } }
        return lines.joined(separator: "\n")
    }
}

enum ReviewHash {
    static func sha256(_ text: String) -> String { Checksum.sha256(Data(text.utf8)) }
}
