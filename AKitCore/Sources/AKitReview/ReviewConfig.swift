import Foundation
import Yams

/// A review role: one `SKILL.md` whose frontmatter has an `akit-review:` block
/// (`docs/design/review.md`, "Role"). The body is the checklist the model reads.
public struct ReviewRole: Sendable, Hashable, Identifiable {
    /// `security` for the skill `review-security`.
    public var id: String
    public var description: String
    public var minSeverity: ReviewSeverity
    public var maxFindings: Int
    /// What the role needs from the context pack: `diff`, `full_files`, `wi`, `history`, `tests`.
    public var needs: [String]
    public var doNotComment: [String]
    /// The whole file, frontmatter included: what Pi loads with `--skill`.
    public var text: String
    public var source: ReviewSource
    /// The file it was read from; nil for a built-in role.
    public var file: URL?

    public var skillName: String { "review-\(id)" }

    public struct Failure: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Reads a role from its SKILL.md text. The name must be `review-<id>`.
    public static func parse(_ text: String, source: ReviewSource, file: URL? = nil) throws -> ReviewRole {
        let where_ = file?.path ?? "a built-in role"
        guard let header = ReviewYAML.frontmatter(text) else { throw Failure(message: "\(where_): no --- frontmatter.") }
        let map: [String: Any]
        do {
            map = try (Yams.load(yaml: header) as? [String: Any]) ?? [:]
        } catch {
            throw Failure(message: "\(where_): the frontmatter isn't valid YAML (\(error.localizedDescription)).")
        }
        guard let name = map["name"] as? String, name.hasPrefix("review-"), name.count > "review-".count else {
            throw Failure(message: "\(where_): the name must be review-<id>.")
        }
        let id = String(name.dropFirst("review-".count))
        guard ReviewYAML.isID(id) else { throw Failure(message: "\(where_): \(name) may use only a-z, 0-9 and -.") }
        let review = map["akit-review"] as? [String: Any] ?? [:]
        let severity = try (review["min_severity"] as? String).map { text in
            guard let value = ReviewSeverity(rawValue: text) else {
                throw Failure(message: "\(where_): min_severity \(text) is not one of \(ReviewSeverity.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            return value
        } ?? .medium
        let max = review["max_findings"] as? Int ?? 3
        guard (1...20).contains(max) else { throw Failure(message: "\(where_): max_findings must be 1–20.") }
        return ReviewRole(id: id, description: map["description"] as? String ?? "", minSeverity: severity, maxFindings: max,
                          needs: ReviewYAML.strings(review["needs"]), doNotComment: ReviewYAML.strings(review["do_not_comment"]),
                          text: text, source: source, file: file)
    }
}

/// A review scenario: which roles run and what to check (`docs/design/review.md`, "Scenario").
public struct ReviewScenario: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var required: [String]
    public var optional: [String]
    public var checks: [String]
    public var contextRequired: [String]
    public var text: String
    public var source: ReviewSource
    public var file: URL?

    public static func parse(_ text: String, source: ReviewSource, file: URL? = nil) throws -> ReviewScenario {
        let where_ = file?.path ?? "a built-in scenario"
        let map: [String: Any]
        do {
            map = try (Yams.load(yaml: text) as? [String: Any]) ?? [:]
        } catch {
            throw ReviewRole.Failure(message: "\(where_): not valid YAML (\(error.localizedDescription)).")
        }
        guard let id = map["id"] as? String, ReviewYAML.isID(id) else {
            throw ReviewRole.Failure(message: "\(where_): id is missing or uses other characters than a-z, 0-9 and -.")
        }
        let roles = map["roles"] as? [String: Any] ?? [:]
        return ReviewScenario(id: id, title: map["title"] as? String ?? id.capitalized, required: ReviewYAML.strings(roles["required"]),
                              optional: ReviewYAML.strings(roles["optional"]), checks: ReviewYAML.strings(map["checks"]),
                              contextRequired: ReviewYAML.strings(map["context_required"]), text: text, source: source, file: file)
    }
}

/// Model and thinking level of a pass.
public struct ReviewModelChoice: Codable, Sendable, Hashable {
    /// `provider/model`, as Pi's `--model` takes it; empty = Pi's default.
    public var model: String
    /// off, minimal, low, medium, high, xhigh; empty = Pi's default.
    public var thinking: String

    public init(model: String, thinking: String = "") {
        self.model = model
        self.thinking = thinking
    }
}

/// The posting thresholds and the cost cap (`review.yaml`, a profile's `review:`, a run's choices).
/// Every field is optional so each level sets only what it changes.
public struct ReviewSettingsPatch: Sendable, Hashable {
    public var passes: ReviewModelChoice?
    public var verifier: ReviewModelChoice?
    public var marker: String?
    public var severityThreshold: ReviewSeverity?
    public var confidenceThreshold: Double?
    public var maxInline: Int?
    public var nitpicks: Bool?
    public var capCredits: Int?
    /// Over this many changed lines the passes ask first (`cost: max_changed_lines`).
    public var maxChangedLines: Int?

    public init(passes: ReviewModelChoice? = nil, verifier: ReviewModelChoice? = nil, marker: String? = nil,
                severityThreshold: ReviewSeverity? = nil, confidenceThreshold: Double? = nil, maxInline: Int? = nil,
                nitpicks: Bool? = nil, capCredits: Int? = nil) {
        self.passes = passes
        self.verifier = verifier
        self.marker = marker
        self.severityThreshold = severityThreshold
        self.confidenceThreshold = confidenceThreshold
        self.maxInline = maxInline
        self.nitpicks = nitpicks
        self.capCredits = capCredits
    }

    /// `review.yaml`: `models: {passes, verifier}`, `thinking: {passes, verifier}`, `posting: {…}`,
    /// `cost: {cap_credits_per_run}`. A profile's `review:` block takes the same keys flat
    /// (`max_inline: 5`) or nested; both are read.
    public static func parse(_ map: [String: Any], where where_: String) throws -> ReviewSettingsPatch {
        let models = map["models"] as? [String: Any] ?? [:]
        let thinking = map["thinking"] as? [String: Any] ?? [:]
        let posting = (map["posting"] as? [String: Any] ?? [:]).merging(map) { nested, _ in nested }
        let cost = map["cost"] as? [String: Any] ?? [:]
        func choice(_ key: String) -> ReviewModelChoice? {
            let model = models[key] as? String
            let level = thinking[key] as? String
            guard model != nil || level != nil else { return nil }
            return ReviewModelChoice(model: model ?? "", thinking: level ?? "")
        }
        var patch = ReviewSettingsPatch(passes: choice("passes"), verifier: choice("verifier"))
        patch.marker = posting["marker"] as? String
        if let text = posting["severity_threshold"] as? String {
            guard let value = ReviewSeverity(rawValue: text) else {
                throw ReviewRole.Failure(message: "\(where_): severity_threshold \(text) is not a severity.")
            }
            patch.severityThreshold = value
        }
        if let value = posting["confidence_threshold"].flatMap(ReviewYAML.number) {
            guard (0...1).contains(value) else { throw ReviewRole.Failure(message: "\(where_): confidence_threshold must be 0–1.") }
            patch.confidenceThreshold = value
        }
        if let value = posting["max_inline"] as? Int {
            guard (0...50).contains(value) else { throw ReviewRole.Failure(message: "\(where_): max_inline must be 0–50.") }
            patch.maxInline = value
        }
        patch.nitpicks = posting["nitpicks"] as? Bool
        if let value = (cost["cap_credits_per_run"] ?? map["cap_credits_per_run"]) as? Int {
            guard value > 0 else { throw ReviewRole.Failure(message: "\(where_): cap_credits_per_run must be above 0.") }
            patch.capCredits = value
        }
        if let value = (cost["max_changed_lines"] ?? map["max_changed_lines"]) as? Int {
            guard value > 0 else { throw ReviewRole.Failure(message: "\(where_): max_changed_lines must be above 0.") }
            patch.maxChangedLines = value
        }
        return patch
    }
}

/// A project profile: `~/.akit/local/review/projects/<slug>.yaml` (`docs/design/review.md`,
/// "Project profile"). Only on this Mac; never in the brain.
public struct ReviewProfile: Sendable, Hashable {
    public struct PathInstruction: Codable, Sendable, Hashable {
        public var paths: [String]
        public var instructions: String?
        public var ignore: Bool

        public init(paths: [String], instructions: String? = nil, ignore: Bool = false) {
            self.paths = paths
            self.instructions = instructions
            self.ignore = ignore
        }
    }

    public struct GatherCommand: Codable, Sendable, Hashable {
        public var name: String
        public var run: String
        public var timeoutSeconds: Int

        public init(name: String, run: String, timeoutSeconds: Int = 600) {
            self.name = name
            self.run = run
            self.timeoutSeconds = timeoutSeconds
        }
    }

    /// The work item tracker, named to the fetch pass: Pi reads it through its MCP server.
    public struct Tracker: Codable, Sendable, Hashable {
        /// `azure-devops`.
        public var kind: String
        public var org: String
        public var project: String
        /// Finds work item numbers in a title, description or branch: the first group is the number.
        public var wiRefRegex: String

        public init(kind: String = "azure-devops", org: String, project: String, wiRefRegex: String = "(?:AB#|WI-)(\\d+)") {
            self.kind = kind
            self.org = org
            self.project = project
            self.wiRefRegex = wiRefRegex
        }
    }

    public var slug: String
    public var project: String
    /// `https://gitlab.corp.example`.
    public var gitlabHost: String
    public var gitlabProjectPath: String
    /// The local clone the worktree is made from.
    public var checkout: String?
    public var tracker: Tracker?
    /// Which of Pi's MCP servers and tools the review may use.
    public var mcp: ReviewMCPAccess
    public var defaultScenario: String?
    public var knowledge: [String]
    public var gather: [GatherCommand]
    public var constraints: [String]
    public var pathInstructions: [PathInstruction]
    public var rolesOff: [String]
    public var rolesAdd: [String]
    public var settings: ReviewSettingsPatch
    /// `pi:`: extra flags of the passes and Pi steps after the roles, for every run of the project.
    public var pi = ReviewPiExtras()
    public var file: URL?

    public init(slug: String, project: String, gitlabHost: String, gitlabProjectPath: String, checkout: String? = nil,
                tracker: Tracker? = nil, mcp: ReviewMCPAccess = ReviewMCPAccess(), defaultScenario: String? = nil, knowledge: [String] = [], gather: [GatherCommand] = [],
                constraints: [String] = [], pathInstructions: [PathInstruction] = [], rolesOff: [String] = [], rolesAdd: [String] = [],
                settings: ReviewSettingsPatch = ReviewSettingsPatch(), file: URL? = nil) {
        self.slug = slug
        self.project = project
        self.gitlabHost = gitlabHost
        self.gitlabProjectPath = gitlabProjectPath
        self.checkout = checkout
        self.tracker = tracker
        self.mcp = mcp
        self.defaultScenario = defaultScenario
        self.knowledge = knowledge
        self.gather = gather
        self.constraints = constraints
        self.pathInstructions = pathInstructions
        self.rolesOff = rolesOff
        self.rolesAdd = rolesAdd
        self.settings = settings
        self.file = file
    }

    /// Whether this profile is for the merge request's GitLab project.
    public func matches(_ mr: MergeRequestRef) -> Bool {
        func host(_ text: String) -> String {
            var value = text.lowercased()
            while value.hasSuffix("/") { value.removeLast() }
            return value
        }
        return host(gitlabHost) == host(mr.host) && gitlabProjectPath.lowercased() == mr.projectPath.lowercased()
    }

    public static func parse(_ text: String, slug: String, file: URL? = nil) throws -> ReviewProfile {
        let where_ = file?.path ?? slug
        let map: [String: Any]
        do {
            map = try (Yams.load(yaml: text) as? [String: Any]) ?? [:]
        } catch {
            throw ReviewRole.Failure(message: "\(where_): not valid YAML (\(error.localizedDescription)).")
        }
        let gitlab = map["gitlab"] as? [String: Any] ?? [:]
        guard let host = gitlab["host"] as? String, let path = gitlab["project_path"] as? String else {
            throw ReviewRole.Failure(message: "\(where_): gitlab: { host, project_path } is required.")
        }
        var tracker: Tracker?
        if let value = map["tracker"] as? [String: Any] {
            let kind = value["kind"] as? String ?? "azure-devops"
            guard let org = value["org"] as? String, let project = value["project"] as? String else {
                throw ReviewRole.Failure(message: "\(where_): tracker needs org and project.")
            }
            let regex = value["wi_ref_regex"] as? String ?? Tracker(org: org, project: project).wiRefRegex
            guard (try? NSRegularExpression(pattern: regex)) != nil else {
                throw ReviewRole.Failure(message: "\(where_): wi_ref_regex is not a valid regular expression.")
            }
            tracker = Tracker(kind: kind, org: org, project: project, wiRefRegex: regex)
        }
        let gather = try (map["gather"] as? [[String: Any]] ?? []).map { entry -> GatherCommand in
            guard let name = entry["name"] as? String, ReviewYAML.isID(name), let run = entry["run"] as? String else {
                throw ReviewRole.Failure(message: "\(where_): each gather entry needs a name (a-z, 0-9, -) and run.")
            }
            return GatherCommand(name: name, run: run, timeoutSeconds: entry["timeout_s"] as? Int ?? 600)
        }
        let instructions = (map["path_instructions"] as? [[String: Any]] ?? []).map {
            PathInstruction(paths: ReviewYAML.strings($0["paths"]), instructions: $0["instructions"] as? String,
                            ignore: $0["ignore"] as? Bool ?? false)
        }
        let roles = map["roles"] as? [String: Any] ?? [:]
        var profile = ReviewProfile(slug: slug, project: map["project"] as? String ?? slug, gitlabHost: host, gitlabProjectPath: path,
                             checkout: map["checkout"] as? String, tracker: tracker,
                             mcp: try ReviewMCPAccess.parse(map["mcp"] as? [String: Any], where: where_), defaultScenario: map["default_scenario"] as? String,
                             knowledge: ReviewYAML.strings(map["knowledge"]), gather: gather,
                             constraints: ReviewYAML.strings(map["constraints"]), pathInstructions: instructions,
                             rolesOff: ReviewYAML.strings(roles["off"]), rolesAdd: ReviewYAML.strings(roles["add"]),
                             settings: try ReviewSettingsPatch.parse(map["review"] as? [String: Any] ?? [:], where: where_), file: file)
        profile.pi = try ReviewPiExtras.parse(map["pi"], where: where_)
        return profile
    }
}

/// Small YAML helpers shared by the config readers.
enum ReviewYAML {
    /// The text between the first two `---` lines.
    static func frontmatter(_ text: String) -> String? {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: ["\u{FEFF}"]) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return nil }
        return lines[1..<end].joined(separator: "\n")
    }

    /// The text after the frontmatter.
    static func body(_ text: String) -> String {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return text }
        return lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func strings(_ value: Any?) -> [String] {
        if let list = value as? [Any] { return list.compactMap { $0 as? String ?? ($0 as? CustomStringConvertible)?.description } }
        if let one = value as? String { return [one] }
        return []
    }

    static func number(_ value: Any) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        return nil
    }

    /// Ids of roles, scenarios and gather commands: they become file and folder names.
    static func isID(_ text: String) -> Bool {
        text.range(of: "^[a-z0-9][a-z0-9-]{0,62}$", options: .regularExpression) != nil
    }
}
