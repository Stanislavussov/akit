import CryptoKit
import Foundation

/// `akit recommend`: auto skills the model never calls. The JSON (`version` 1) is the contract for
/// `/akit` and a later Insights screen. Counts are recorded; sizes are estimates (≈).
struct RecommendReport: Encodable, Equatable {
    struct Rule: Encodable, Equatable {
        let name: String
        let minSessions: Int
        let minDistinctDays: Int
        let staleAfterDays: Int
        let bindings: [String]
    }

    struct Summary: Encodable, Equatable {
        /// ≈ tokens per request of the skills listed in scope, by owner (as in `akit stats`).
        let approxContextPerRequestByOwner: [StatsReport.OwnerSummary]
    }

    struct Owner: Encodable, Equatable {
        let kind: String
        let name: String?

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(kind, forKey: .kind)
            try container.encode(name, forKey: .name)
        }

        private enum CodingKeys: String, CodingKey { case kind, name }
    }

    struct Scope: Encodable, Equatable {
        /// nil: every session, on every Mac.
        let project: String?

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(project, forKey: .project)
        }

        private enum CodingKeys: String, CodingKey { case project }
    }

    struct Action: Encodable, Equatable {
        /// `layerPatch`, or the advice: `disablePluginInProject`, `disablePluginGlobally`, `unusedPluginSkills`
        /// (information: some of a plugin's skills are used), `importManual`, `applyUnmanaged`, `reapply`,
        /// `listInLayer`, `editByHand`.
        let kind: String
        /// Patches: the layer and the diff of its layer.yaml.
        var layer: String?
        var diff: String?
        /// What to do, in words (advice; for a patch, what else it needs).
        var text: String?
    }

    struct Machine: Encodable, Equatable {
        let name: String
        /// ISO 8601: when its summary was published (this Mac: its last import).
        let updated: String?
        let stale: Bool

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encode(updated, forKey: .updated)
            try container.encode(stale, forKey: .stale)
        }

        private enum CodingKeys: String, CodingKey { case name, updated, stale }
    }

    /// How this Mac's counted sessions are bound to the project: their methods and the lowest confidence.
    struct Binding: Encodable, Equatable {
        let methods: [String]
        let confidence: String?

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(methods, forKey: .methods)
            try container.encode(confidence, forKey: .confidence)
        }

        private enum CodingKeys: String, CodingKey { case methods, confidence }
    }

    struct Evidence: Encodable, Equatable {
        /// Main sessions it was listed in, on every Mac in scope.
        let sessions: Int
        /// Distinct local calendar days it was listed, on every Mac in scope.
        let distinctDays: Int
        /// First and last of those days (`yyyy-MM-dd`).
        let from: String?
        let to: String?
        let machines: [Machine]
        /// nil for the global scope.
        let binding: Binding?
        /// ≈ Σ over this Mac's listed sessions of description tokens × requests (other Macs record no requests per skill).
        let approxContextSpace: Int
        let modelCalls: Int
        let userCalls: Int
        let callRate: Double
        /// With 0 model calls in n sessions the true rate is below 3/n (95 %).
        let callRateUpperBound95: Double
        /// Plugin advice (`skill` is `*`): the plugin's skills it is about; not encoded otherwise.
        var skills: [String]?

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(sessions, forKey: .sessions)
            try container.encode(distinctDays, forKey: .distinctDays)
            try container.encode(from, forKey: .from)
            try container.encode(to, forKey: .to)
            try container.encode(machines, forKey: .machines)
            try container.encode(binding, forKey: .binding)
            try container.encode(approxContextSpace, forKey: .approxContextSpace)
            try container.encode(modelCalls, forKey: .modelCalls)
            try container.encode(userCalls, forKey: .userCalls)
            try container.encode(callRate, forKey: .callRate)
            try container.encode(callRateUpperBound95, forKey: .callRateUpperBound95)
            try container.encodeIfPresent(skills, forKey: .skills)
        }

        private enum CodingKeys: String, CodingKey {
            case sessions, distinctDays, from, to, machines, binding, approxContextSpace, modelCalls, userCalls, callRate,
                 callRateUpperBound95, skills
        }
    }

    struct Recommendation: Encodable, Equatable {
        let id: String
        /// `patch` (a layer.yaml edit, `akit recommend apply`) or `advice`.
        let type: String
        /// Another Mac's summary is older than `staleAfterDays`: it may have called the skill since.
        let stale: Bool
        let owner: Owner
        /// The skill; `*` for plugin advice, which is about the whole plugin (its skills in `evidence.skills`).
        let skill: String
        let scope: Scope
        let action: Action
        let evidence: Evidence
        /// Not encoded: the layer.yaml before and after a patch, and the stale Macs' names.
        var patch: (before: String, after: String)?
        var staleMachines: [String] = []

        var isPatch: Bool { type == "patch" }
        /// What it is about, in words: the skill, or the plugin.
        var subject: String { skill == Recommender.wholePlugin ? "plugin \(owner.name ?? "")" : skill }

        static func == (lhs: Recommendation, rhs: Recommendation) -> Bool {
            lhs.id == rhs.id && lhs.type == rhs.type && lhs.stale == rhs.stale && lhs.owner == rhs.owner && lhs.skill == rhs.skill
                && lhs.scope == rhs.scope && lhs.action == rhs.action && lhs.evidence == rhs.evidence
                && lhs.patch?.before == rhs.patch?.before && lhs.patch?.after == rhs.patch?.after && lhs.staleMachines == rhs.staleMachines
        }

        private enum CodingKeys: String, CodingKey { case id, type, stale, owner, skill, scope, action, evidence }
    }

    struct NoData: Encodable, Equatable {
        let skill: String
        /// `piOnly`: only Pi sees it or calls it, and Pi records no skill list.
        let reason: String
    }

    let version: Int
    let rule: Rule
    let summary: Summary
    let recommendations: [Recommendation]
    let noData: [NoData]
    let hiddenByDismissal: Int
    let omitted: Int
    /// Not encoded: import notes, shown by the text output (and on stderr with --json), and the project in scope.
    var notes: [String] = []
    var project: String?
    /// Not encoded: the k behind the ≈ sizes, for the text output.
    var calibration = ContextSize.defaults

    private enum CodingKeys: String, CodingKey { case version, rule, summary, recommendations, noData, hiddenByDismissal, omitted }
}

/// Rule `auto-to-manual`: a skill listed in at least N sessions on at least D distinct local days,
/// summed over this Mac's index and the other Macs' summaries, and never called by the model
/// anywhere (other Macs, subagents, Pi), is better off manual. What to do depends on who owns it:
/// a layer gets a `layer.yaml` patch, anything else advice. See docs/design/session-insights.md.
enum Recommender {
    static let rule = "auto-to-manual"
    static let defaultMinSessions = 20
    static let defaultMinDays = 14
    static let defaultTop = 10
    /// The `skill` of plugin advice: it is about the whole plugin.
    static let wholePlugin = "*"

    struct Options {
        /// A project id; nil: every session on every Mac.
        var project: String?
        var bindings = BindingSet.default
        var minSessions = Recommender.defaultMinSessions
        var minDays = Recommender.defaultMinDays
        /// Another Mac's summary older than this flags a recommendation; nil: `minDays`.
        var staleAfterDays: Int?
        /// Recommendations shown; nil: all.
        var top: Int? = Recommender.defaultTop

        var staleDays: Int { staleAfterDays ?? minDays }
    }

    /// What the index doesn't know.
    struct Inputs {
        /// Owners, descriptions, description windows (brain and other Macs), Pi-only skills.
        var stats = InsightsStats.Inputs()
        var brain: Brain?
        /// Other Macs' summaries (their machine files, and project files of the project store).
        var others = UsageSummary.Others()
        /// Project scope: when each layer first applied in the project (`LayerHistory`).
        var layerStarts: [String: Date] = [:]
        var dismissed: [String: Dismissals.Entry] = [:]
        /// This Mac's name in the evidence, and its last import.
        var thisMac = "this Mac"
        var lastImport: Date?
    }

    /// Counts of one skill in other Macs' files from a local day on.
    private struct Elsewhere {
        var listed = 0
        var model = 0
        var user = 0
        var days: Set<String> = []
        /// Keys of the files that mention the skill at all, and of those listing it from the day on.
        var keys: Set<String> = []
        var listing: Set<String> = []
    }

    private static func sum(_ files: [String: UsageSummary.File], skill: String, from day: String) -> Elsewhere {
        var result = Elsewhere()
        for (key, file) in files {
            for (date, entry) in file.days {
                guard let counts = entry.skills[skill], counts.count == 3 else { continue }
                result.keys.insert(key)
                guard date >= day else { continue }
                result.listed += counts[0]
                result.model += counts[1]
                result.user += counts[2]
                if counts[0] > 0 {
                    result.days.insert(date)
                    result.listing.insert(key)
                }
            }
        }
        return result
    }

    static func recommend(_ database: IndexDatabase, options: Options = Options(), inputs: Inputs = Inputs(), now: Date = Date(),
                          calendar: Calendar = .current) throws -> RecommendReport {
        let epoch = Date(timeIntervalSince1970: 0)
        let scope = InsightsStats.Scope(project: options.project, bindings: options.bindings, from: epoch, to: now)
        let brain = inputs.brain
        // Other Macs: their data in scope, and their machine files for calls anywhere.
        let scoped = options.project.map { inputs.others.projects[$0] ?? [:] } ?? inputs.others.machines
        let everywhere = inputs.others.machines

        var names = Set(try InsightsStats.listedNames(database, scope: scope))
        for file in scoped.values {
            for day in file.days.values {
                for (skill, counts) in day.skills where (counts.first ?? 0) > 0 { names.insert(skill) }
            }
        }
        func owner(of name: String) -> SkillOwner {
            let known = inputs.stats.owners[name]
            if let known, known != .builtIn { return known }
            if let colon = name.firstIndex(of: ":") { return .plugin(String(name[..<colon])) }
            // Not installed on this Mac (listed on another one): a brain layer that lists it owns it.
            let listing = brain?.layers.filter { $0.skills.contains { $0.name == name } }.map(\.name).sorted() ?? []
            return listing.isEmpty ? known ?? .unknown : .layer(listing)
        }
        let owners = Dictionary(uniqueKeysWithValues: names.map { ($0, owner(of: $0)) })

        // Counting starts at the description window and, in a project, when the owning layer arrived there.
        let hashStarts = try DescriptionWindow.hashStarts(database, otherMacs: inputs.stats.otherMacHashes, calendar: calendar)
        var descriptionStarts: [String: Date] = [:], starts: [String: Date] = [:]
        for name in names {
            let description = inputs.stats.brainStarts[name] ?? hashStarts[name]?.date ?? epoch
            descriptionStarts[name] = description
            var layerStart: Date?
            if options.project != nil {
                switch owners[name] {
                case .layer(let layers)?, .unrendered(let layers, _)?: layerStart = layers.compactMap { inputs.layerStarts[$0] }.min()
                default: break
                }
            }
            starts[name] = max(description, layerStart ?? epoch)
        }
        let calibration = try ContextSize.calibration(database)
        let tallies = try InsightsStats.tallies(database, scope: scope, starts: starts, descriptions: inputs.stats.descriptions,
                                                calibration: calibration)
        let modelInScope = try modelCalls(database, scope: scope, starts: starts)
        let global = InsightsStats.Scope(project: nil, bindings: options.bindings, from: epoch, to: now)
        let modelAnywhere = options.project == nil ? modelInScope : try modelCalls(database, scope: global, starts: descriptionStarts)
        let pluginsElsewhere = try options.project.map { try pluginsUsed(database, outside: $0, bindings: options.bindings,
                                                                         others: inputs.others) } ?? []
        let staleBefore = now.addingTimeInterval(-Double(options.staleDays) * 86_400)
        func isStale(_ file: UsageSummary.File) -> Bool {
            guard let updated = file.updated.flatMap({ ISO8601DateFormatter().date(from: $0) }) else { return true }
            return updated < staleBefore
        }
        func display(_ key: String) -> String { inputs.others.machines[key]?.name ?? key }

        /// One listed skill's counts from its start: this Mac's, and the other Macs' in scope and anywhere.
        struct Counted {
            let name: String
            let tally: InsightsStats.Tally
            let startDay: String
            let other: Elsewhere
            let anywhere: Elsewhere
            /// Model calls in scope, and anywhere.
            let modelInScope: Int
            let modelAnywhere: Int
        }
        /// Sessions and distinct days that listed any of the skills. Another Mac's day counts the
        /// most sessions any one of them was listed in (its files count per skill, not per session).
        func listed(_ covered: [Counted]) -> (here: Set<String>, sessions: Int, days: Set<String>) {
            var here: Set<String> = [], days: Set<String> = []
            for item in covered {
                here.formUnion(item.tally.listedSessions)
                days.formUnion(item.tally.listedDays.union(item.other.days))
            }
            var elsewhere = 0
            for file in scoped.values {
                for (date, entry) in file.days {
                    elsewhere += covered.map { date >= $0.startDay ? (entry.skills[$0.name].flatMap { $0.count == 3 ? $0[0] : nil } ?? 0) : 0 }
                        .max() ?? 0
                }
            }
            return (here, here.count + elsewhere, days)
        }
        func enough(_ covered: [Counted]) -> Bool {
            let counts = listed(covered)
            return counts.sessions >= options.minSessions && counts.days.count >= options.minDays
        }

        var recommendations: [RecommendReport.Recommendation] = []
        var hidden = 0
        func add(_ covered: [Counted], owner: RecommendReport.Owner, skill: String, idSkill: String, action: RecommendReport.Action,
                 patch: (before: String, after: String)?, skills: [String]? = nil) throws {
            let id = id(owner: owner, skill: idSkill, project: options.project)
            let contextSpace = covered.reduce(0) { $0 + $1.tally.contextSpace }
            if let entry = inputs.dismissed[id], Dismissals.hides(entry, approxContextSpace: contextSpace) {
                hidden += 1
                return
            }
            let (here, sessions, days) = listed(covered)
            // Only Macs whose summary mentions a skill: a retired Mac that never saw it flags nothing.
            var staleKeys: Set<String> = [], listing: Set<String> = []
            for item in covered {
                staleKeys.formUnion(item.other.keys.filter { scoped[$0].map(isStale) ?? false })
                staleKeys.formUnion(item.anywhere.keys.filter { everywhere[$0].map(isStale) ?? false })
                listing.formUnion(item.other.listing)
            }
            var machines: [RecommendReport.Machine] = []
            if !here.isEmpty {
                machines.append(.init(name: inputs.thisMac, updated: inputs.lastImport?.formatted(.iso8601), stale: false))
            }
            for key in listing.union(staleKeys).sorted() {
                let file = scoped[key] ?? everywhere[key]
                machines.append(.init(name: display(key), updated: file?.updated, stale: staleKeys.contains(key)))
            }
            let sortedDays = days.sorted()
            let evidence = RecommendReport.Evidence(
                sessions: sessions, distinctDays: days.count, from: sortedDays.first, to: sortedDays.last, machines: machines,
                binding: options.project == nil ? nil : try binding(database, sessions: here),
                approxContextSpace: contextSpace, modelCalls: 0,
                userCalls: covered.reduce(0) { $0 + $1.tally.userCalls + $1.other.user }, callRate: 0,
                callRateUpperBound95: min(1, (3 / Double(max(sessions, 1)) * 1000).rounded() / 1000), skills: skills)
            recommendations.append(.init(
                id: id, type: patch == nil ? "advice" : "patch", stale: !staleKeys.isEmpty, owner: owner, skill: skill,
                scope: .init(project: options.project), action: action, evidence: evidence, patch: patch,
                staleMachines: staleKeys.sorted().map(display)))
        }

        var byPlugin: [String: [Counted]] = [:]
        for name in names.sorted() {
            guard let start = starts[name], let owner = owners[name] else { continue }
            if case .builtIn = owner { continue }  // cost only (summary)
            let other = sum(scoped, skill: name, from: UsageSummary.day(start, calendar: calendar))
            let anywhere = sum(everywhere, skill: name, from: UsageSummary.day(descriptionStarts[name] ?? epoch, calendar: calendar))
            let counted = Counted(name: name, tally: tallies[name] ?? InsightsStats.Tally(), startDay: UsageSummary.day(start, calendar: calendar),
                                  other: other, anywhere: anywhere, modelInScope: (modelInScope[name] ?? 0) + other.model,
                                  modelAnywhere: (modelAnywhere[name] ?? 0) + anywhere.model)
            // A plugin is enabled or disabled as a whole: its skills are judged together below.
            if case .plugin(let plugin) = owner {
                byPlugin[plugin, default: []].append(counted)
                continue
            }
            guard enough([counted]) else { continue }
            // Any model call blocks, in scope or anywhere else: the fix (a layer, an import) is shared.
            guard counted.modelInScope == 0, counted.modelAnywhere == 0 else { continue }
            guard let (recommendationOwner, action, patch) = self.action(for: name, owner: owner, brain: brain, hasBrain: inputs.stats.hasBrain,
                                                                        project: options.project, pluginUsedElsewhere: false)
            else { continue }
            try add([counted], owner: recommendationOwner, skill: name, idSkill: name, action: action, patch: patch)
        }

        for (plugin, skills) in byPlugin.sorted(by: { $0.key < $1.key }) {
            let owner = RecommendReport.Owner(kind: SkillOwner.Kind.plugin.rawValue, name: plugin)
            if skills.allSatisfy({ $0.modelInScope == 0 }) {
                // None of its skills called here: disable it, in this project when another one uses it.
                guard enough(skills) else { continue }
                let usedElsewhere = skills.contains { $0.modelAnywhere > 0 } || pluginsElsewhere.contains(plugin)
                guard let (_, action, _) = self.action(for: wholePlugin, owner: .plugin(plugin), brain: brain, hasBrain: inputs.stats.hasBrain,
                                                       project: options.project, pluginUsedElsewhere: usedElsewhere)
                else { continue }
                try add(skills, owner: owner, skill: wholePlugin, idSkill: wholePlugin, action: action, patch: nil,
                        skills: skills.map(\.name))
            } else {
                // Some are used, so the plugin stays; say once how much its never-called skills take.
                let unused = skills.filter { $0.modelInScope == 0 && enough([$0]) }
                guard !unused.isEmpty else { continue }
                let space = unused.reduce(0) { $0 + $1.tally.contextSpace }
                let text = "\(unused.count) of \(skills.count) listed skills of \(plugin) were never called by the model"
                    + "\(options.project.map { " in \($0)" } ?? "") (≈ \(ContextSize.short(space)) context space); a plugin is enabled or disabled as a whole, "
                    + "and the model uses its other skills."
                try add(unused, owner: owner, skill: wholePlugin, idSkill: wholePlugin + "unused",
                        action: .init(kind: "unusedPluginSkills", text: text), patch: nil, skills: unused.map(\.name))
            }
        }
        recommendations.sort {
            ($0.stale ? 1 : 0, -$0.evidence.approxContextSpace, $0.skill, $0.owner.name ?? "")
                < ($1.stale ? 1 : 0, -$1.evidence.approxContextSpace, $1.skill, $1.owner.name ?? "")
        }
        let shown = options.top.map { Array(recommendations.prefix(max(0, $0))) } ?? recommendations

        let byOwner = SkillOwner.Kind.allCases.map { kind in
            let owned = tallies.filter { names.contains($0.key) && owners[$0.key]?.kind == kind && $0.value.latest != nil }
            return StatsReport.OwnerSummary(owner: kind.rawValue, skills: owned.count,
                                            approxTokens: owned.values.reduce(0) { $0 + ($1.latest?.tokens ?? 0) })
        }
        return RecommendReport(
            version: 1,
            rule: .init(name: rule, minSessions: options.minSessions, minDistinctDays: options.minDays, staleAfterDays: options.staleDays,
                        bindings: options.bindings.names),
            summary: .init(approxContextPerRequestByOwner: byOwner),
            recommendations: shown,
            noData: try noData(database, scope: scope, listed: names, piOnly: inputs.stats.piOnly),
            hiddenByDismissal: hidden, omitted: recommendations.count - shown.count, notes: inputs.stats.importNotes,
            project: options.project, calibration: calibration)
    }

    /// Everything `recommend` needs besides the index: owners and windows (as `akit stats`), the
    /// other Macs' summaries, the project's layer dates and the dismissals of the scope.
    static func inputs(env: HarnessEnvironment, database: IndexDatabase, brain: Brain?, project: String?, projectsRoot: URL,
                       hostName: String, run: CommandRunner? = nil) async throws -> Inputs {
        let home = env.homeDirectory
        let machine = MachineProfile.load(home: home)
        let store = brain.map { ProjectStore.current(brain: $0.root, home: home, machine: machine) } ?? .local(home: home)
        var inputs = Inputs()
        inputs.stats = try await InsightsStats.inputs(env: env, database: database, brain: brain, projectsRoot: projectsRoot,
                                                      hostName: hostName, run: run)
        inputs.brain = brain
        if let brain {
            let own = UsageSummary.ownKeys(database).all.union([machine.id, machine.pseudonym].compactMap { $0 })
            inputs.others = UsageSummary.load(brain: brain.root, store: store, excludingOwn: own)
        }
        var host = hostName
        if host.hasSuffix(".local") { host.removeLast(".local".count) }
        inputs.thisMac = machine.name ?? host
        inputs.lastImport = try database.value("SELECT MAX(imported_at) FROM sources")?.double.map(Date.init(timeIntervalSince1970:))
        return try await scoped(inputs, to: project, env: env, database: database, run: run)
    }

    /// The inputs with the scope's own parts: a project's layer dates, and the scope's dismissals.
    static func scoped(_ inputs: Inputs, to project: String?, env: HarnessEnvironment, database: IndexDatabase,
                       run: CommandRunner? = nil) async throws -> Inputs {
        let home = env.homeDirectory
        let store = inputs.brain.map { ProjectStore.current(brain: $0.root, home: home) } ?? .local(home: home)
        var inputs = inputs
        inputs.layerStarts = [:]
        if let project {
            inputs.layerStarts = try await LayerHistory.starts(project: project, database: database, store: store, brain: inputs.brain,
                                                               env: env, run: run)
        }
        inputs.dismissed = Dismissals.load(project: project, brain: inputs.brain?.root, home: home, store: store)
        return inputs
    }

    /// Projects a recommendation id may belong to: bound in the index, or with a record in the brain
    /// or this Mac's store.
    static func knownProjects(_ database: IndexDatabase, brain: Brain?, home: URL, bindings: BindingSet) throws -> [String] {
        var ids = Set(try UsageSummary.boundProjects(database, bindings: bindings))
        if let brain {
            ids.formUnion(BrainRemove.savedAnswers(brain: brain, home: home).map(\.id))
        } else {
            ids.formUnion(BrainRemove.savedAnswers(in: .local(home: home)).map(\.id))
        }
        return ids.sorted()
    }

    // MARK: - Queries

    /// Model calls per skill in the scope's sessions from each skill's start: any harness, subagents
    /// included, in a session that listed it or not.
    static func modelCalls(_ database: IndexDatabase, scope: InsightsStats.Scope, starts: [String: Date]) throws -> [String: Int] {
        let (scoped, values) = scope.cte
        let startsJSON = String(decoding: try JSONEncoder().encode(starts.mapValues(\.timeIntervalSince1970)), as: UTF8.self)
        var calls: [String: Int] = [:]
        for row in try database.rows("""
            WITH \(scoped), starts AS (SELECT key AS skill, value AS start FROM json_each(?))
            SELECT c.skill, COUNT(*) FROM skill_calls c JOIN scoped s ON s.key = c.session_key JOIN starts st ON st.skill = c.skill
            WHERE c.by = 'model' AND c.ts >= st.start GROUP BY c.skill
            """, values + [startsJSON]) {
            if let skill = row[0].text, let count = row[1].int { calls[skill] = count }
        }
        return calls
    }

    /// Plugins with a skill called (by the model or the user) outside the project: in this Mac's
    /// sessions not bound to it, or in other Macs' machine files beyond their files of the project.
    static func pluginsUsed(_ database: IndexDatabase, outside project: String, bindings: BindingSet,
                            others: UsageSummary.Others) throws -> Set<String> {
        var used = Set(try database.rows("""
            SELECT DISTINCT substr(c.skill, 1, instr(c.skill, ':') - 1) FROM skill_calls c
            WHERE instr(c.skill, ':') > 1 AND (c.by = 'model' OR COALESCE(json_extract(c.extra, '$.kind'), 'skill') = 'skill')
              AND NOT EXISTS(SELECT 1 FROM bindings b WHERE b.session_key = c.session_key AND b.project_id = ?
                             AND b.confidence IN \(bindings.sqlList))
            """, project).compactMap { $0[0].text })
        func calls(_ files: [String: UsageSummary.File]) -> [String: Int] {
            var result: [String: Int] = [:]
            for file in files.values {
                for day in file.days.values {
                    for (skill, counts) in day.skills where counts.count == 3 {
                        guard let colon = skill.firstIndex(of: ":") else { continue }
                        result[String(skill[..<colon]), default: 0] += counts[1] + counts[2]
                    }
                }
            }
            return result
        }
        let inProject = calls(others.projects[project] ?? [:])
        for (plugin, count) in calls(others.machines) where count > inProject[plugin] ?? 0 { used.insert(plugin) }
        return used
    }

    /// Methods and lowest confidence of these sessions' bindings.
    static func binding(_ database: IndexDatabase, sessions: Set<String>) throws -> RecommendReport.Binding {
        let keys = String(decoding: try JSONEncoder().encode(sessions.sorted()), as: UTF8.self)
        var methods: Set<String> = [], confidences: [Confidence] = []
        for row in try database.rows("""
            SELECT DISTINCT method, confidence FROM bindings WHERE session_key IN (SELECT value FROM json_each(?))
            """, keys) {
            if let method = row[0].text { methods.insert(method) }
            if let confidence = row[1].text.flatMap(Confidence.init(rawValue:)) { confidences.append(confidence) }
        }
        return .init(methods: BindingMethod.allCases.map(\.rawValue).filter(methods.contains), confidence: confidences.min()?.rawValue)
    }

    /// Skills there is nothing to judge by: installed only where Pi sees them, or called in Pi but
    /// never listed (Pi records no skill list).
    static func noData(_ database: IndexDatabase, scope: InsightsStats.Scope, listed: Set<String>,
                       piOnly: Set<String>) throws -> [RecommendReport.NoData] {
        let (scoped, values) = scope.cte
        let piCalled = try database.rows("""
            WITH \(scoped) SELECT DISTINCT c.skill FROM skill_calls c JOIN scoped s ON s.key = c.session_key
            WHERE c.harness = 'pi' AND c.skill IS NOT NULL
            """, values).compactMap { $0[0].text }
        return piOnly.union(piCalled).subtracting(listed).sorted().map { .init(skill: $0, reason: "piOnly") }
    }

    // MARK: - Actions

    /// Who the recommendation is for and what to do; nil when there is nothing to recommend (a
    /// layer pins the skill with `keep_auto`, or it is built in).
    static func action(for skill: String, owner: SkillOwner, brain: Brain?, hasBrain: Bool, project: String?,
                       pluginUsedElsewhere: Bool)
        -> (owner: RecommendReport.Owner, action: RecommendReport.Action, patch: (before: String, after: String)?)? {
        switch owner {
        case .layer(let layers), .unrendered(let layers, _):
            let entries = layers.compactMap { name -> (layer: Layer, skill: LayerSkill)? in
                guard let layer = brain?.layers.first(where: { $0.name == name }),
                      let entry = layer.skills.first(where: { $0.name == skill }) else { return nil }
                return (layer, entry)
            }
            if entries.contains(where: \.skill.keepAuto) { return nil }
            var unrenderedNote: String?
            if case .unrendered(_, let file) = owner { unrenderedNote = unmanagedAdvice(skill: skill, file: file, layers: layers) }
            if let auto = entries.first(where: { $0.skill.mode == .auto }) {
                let layer = auto.layer.name
                let owner = RecommendReport.Owner(kind: SkillOwner.Kind.layer.rawValue, name: layer)
                do {
                    let before = try String(contentsOf: auto.layer.manifest, encoding: .utf8)
                    let after = try LayerPatch.edit(before, skill: skill, layer: layer, change: .manual)
                    let diff = AKitCLI.unifiedDiff(TextDiff.lines(from: before, to: after)).joined(separator: "\n")
                    return (owner, .init(kind: "layerPatch", layer: layer, diff: diff, text: unrenderedNote), (before, after))
                } catch {
                    let reason = (error as? LayerPatch.Failure)?.message ?? error.localizedDescription
                    return (owner, .init(kind: "editByHand", layer: layer,
                                         text: "Set mode: manual for \(skill) in \(LayerPatch.path(layer: layer)) by hand. \(reason)"), nil)
                }
            }
            if let unrenderedNote {
                return (.init(kind: SkillOwner.Kind.unknown.rawValue, name: nil), .init(kind: "applyUnmanaged", text: unrenderedNote), nil)
            }
            return (.init(kind: SkillOwner.Kind.layer.rawValue, name: layers.joined(separator: ",")),
                    .init(kind: "reapply", text: "\(layers.joined(separator: ", ")) already \(layers.count == 1 ? "lists" : "list") it as manual, "
                          + "but it is still listed: run akit plan/apply in the projects using \(layers.count == 1 ? "it" : "them") "
                          + "(akit apply --home for this Mac's home folder)."), nil)
        case .plugin(let plugin):
            // `skill` is `*`: a plugin is enabled or disabled as a whole, and the model called none of its skills.
            let owner = RecommendReport.Owner(kind: SkillOwner.Kind.plugin.rawValue, name: plugin)
            let why = "The model called none of \(plugin)'s skills\(project.map { " in \($0)" } ?? ""), and a plugin is enabled or "
                + "disabled as a whole."
            if project != nil, pluginUsedElsewhere {
                return (owner, .init(kind: "disablePluginInProject",
                                     text: "\(why) Disable it there (enabledPlugins in the project's .claude/settings.json, or /plugin); "
                                         + "other projects use it."), nil)
            }
            return (owner, .init(kind: "disablePluginGlobally",
                                 text: "\(why) If you need none of them, disable it (/plugin in Claude Code)"
                                     + "\(project == nil ? "" : "; no other project uses it either")."), nil)
        case .handInstalled(let path):
            return (.init(kind: SkillOwner.Kind.handInstalled.rawValue, name: path),
                    .init(kind: "importManual",
                          text: "Import \(path) into the brain in manual mode (AKit app: Brain → Import Skills…), then apply the layer "
                              + "(akit apply --home for the core layer)."), nil)
        case .unknown:
            let owner = RecommendReport.Owner(kind: SkillOwner.Kind.unknown.rawValue, name: nil)
            guard hasBrain else {
                return (owner, .init(kind: "editByHand",
                                     text: "Without a brain AKit can't tell where \(skill) comes from. Add disable-model-invocation: true "
                                         + "to its SKILL.md by hand, or set up a brain (akit setup) and import it in manual mode."), nil)
            }
            return (owner, .init(kind: "listInLayer",
                                 text: "The brain has a skill named \(skill), but no layer lists it and AKit didn't write the installed copy. "
                                     + "List it in a layer with mode: manual, then apply with --include-unmanaged."), nil)
        case .builtIn:
            return nil
        }
    }

    /// The layers list the skill, but AKit didn't write the installed copy, so their mode doesn't reach it.
    static func unmanagedAdvice(skill: String, file: String, layers: [String]) -> String {
        let include = "--include \(Render.skillsFolder)/\(skill)/SKILL.md"
        let whose = layers.count == 1 ? "the \(layers[0]) layer's" : "the brain's (\(layers.joined(separator: ", ")))"
        // A copy in a dot folder of the home (~/.agents/skills, ~/.claude/skills) is the home render's.
        let command = file.hasPrefix("~/.") ? "akit apply --home --include-unmanaged (or akit apply --home \(include))"
            : "akit apply <project> \(include)"
        return "The installed copy \(file) wasn't written by AKit, so \(whose) manual mode doesn't reach it. Run \(command) "
            + "so it takes effect."
    }

    /// `"r-"` + the first 10 hex characters of SHA-256 over rule, owner, skill and scope: the same
    /// recommendation keeps its id across runs and Macs.
    static func id(owner: RecommendReport.Owner, skill: String, project: String?) -> String {
        let text = [rule, owner.kind, owner.name ?? "", skill, project ?? "global"].joined(separator: "|")
        return "r-" + ProjectSetup.sha256(Data(text.utf8)).prefix(10)
    }
}
