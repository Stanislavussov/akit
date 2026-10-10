import AKitBrain
import AKitFoundation
import Foundation

/// `akit stats skill NAME`: where one skill is called, project by project, so a global skill that
/// only one project uses can move there (Move to Project). Counts calls, never listings: a skill
/// listed everywhere is called where it is needed. The JSON (`version` 1) is the contract for
/// `/akit` and the Move to Project sheet.
public struct SkillCallsReport: Encodable, Equatable, Sendable {
    public struct Window: Encodable, Equatable, Sendable {
        let from: String
        let to: String
        public let days: Int
    }

    /// The calls in one project's sessions on this Mac, or (project nil) in its sessions bound to no
    /// project at the report's confidences.
    public struct Place: Encodable, Equatable, Sendable {
        public let project: String?
        /// By the model in any harness, subagents included; Pi's are reads of its SKILL.md.
        public let modelCalls: Int
        /// Of `modelCalls`, those made in Pi.
        public let piModelCalls: Int
        /// `/name` and `<skill>` calls by the user.
        public let userCalls: Int
        /// Sessions with at least one of these calls.
        public let sessions: Int
        /// The latest of these calls.
        public let lastCall: String?

        public var calls: Int { modelCalls + userCalls }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(project, forKey: .project)
            try container.encode(modelCalls, forKey: .modelCalls)
            try container.encode(piModelCalls, forKey: .piModelCalls)
            try container.encode(userCalls, forKey: .userCalls)
            try container.encode(sessions, forKey: .sessions)
            try container.encode(lastCall, forKey: .lastCall)
        }

        private enum CodingKeys: String, CodingKey { case project, modelCalls, piModelCalls, userCalls, sessions, lastCall }
    }

    /// Other Macs' calls, from their usage summaries in the brain (counts per day, no sessions).
    public struct OtherMacs: Encodable, Equatable, Sendable {
        public struct Project: Encodable, Equatable, Sendable {
            public let project: String
            public let modelCalls: Int
            public let userCalls: Int
            /// Macs whose summary of this project has a call.
            public let macs: Int

            public var calls: Int { modelCalls + userCalls }
        }

        /// From their project summaries; a work Mac keeps those on itself, so they never show here.
        public let projects: [Project]
        /// From their machine summaries: every session of theirs, bound or not.
        public let modelCalls: Int
        public let userCalls: Int
        public let macs: Int

        public var calls: Int { modelCalls + userCalls }
        /// Calls of theirs in no project summary: unbound sessions, or a work Mac's projects.
        public var outsideProjects: Int { max(0, calls - projects.reduce(0) { $0 + $1.calls }) }
    }

    let version: Int
    let generated: String
    public let skill: String
    public let window: Window
    /// Binding confidences that count a session as a project's.
    public let bindings: [String]
    /// This Mac: projects with the most calls first, sessions bound to no project last.
    public let projects: [Place]
    public let otherMacs: OtherMacs
    public let notes: [String]

    /// This Mac's calls in sessions bound to no project.
    public var unbound: Place? { projects.first { $0.project == nil } }

    /// This Mac's and the other Macs' calls in one project.
    public func calls(in project: String) -> Int {
        (projects.first { $0.project == project }?.calls ?? 0) + (otherMacs.projects.first { $0.project == project }?.calls ?? 0)
    }

    private enum CodingKeys: String, CodingKey { case version, generated, skill, window, bindings, projects, otherMacs, notes }
}

public enum SkillCalls {
    static let piNote = "Pi records a model call as a read of the skill's SKILL.md"
    static let otherMacsNote = "Other Macs: their usage summaries in the brain (akit sync publishes them); a work Mac's projects never reach the brain"

    /// The report for `skill` over the last `days` days. With a brain, the other Macs' summaries are
    /// read too, as recommendations read them.
    public static func report(_ database: IndexDatabase, skill: String, days: Int = InsightsStats.defaultDays,
                              bindings: BindingSet = .default, brain: Brain?, env: HarnessEnvironment, hardware: String?,
                              notes: [String] = [], now: Date = Date()) throws -> SkillCallsReport {
        var others = UsageSummary.Others()
        if let brain {
            let machine = MachineProfile.load(home: env.homeDirectory)
            let store = ProjectStore.current(brain: brain.root, home: env.homeDirectory, machine: machine)
            others = UsageSummary.load(brain: brain.root, store: store,
                                       ownership: UsageSummary.ownership(database, machine: machine, hardware: hardware), now: now)
        }
        return try report(database, skill: skill, days: days, bindings: bindings, others: others,
                          notes: notes + (brain == nil ? [] : [otherMacsNote]), now: now)
    }

    static func report(_ database: IndexDatabase, skill: String, days: Int, bindings: BindingSet, others: UsageSummary.Others,
                       notes: [String], now: Date, calendar: Calendar = .current) throws -> SkillCallsReport {
        let from = now.addingTimeInterval(-Double(days) * 86_400)
        // A session counts as a project's only when bound at a confidence of the set; else it is unbound.
        let joined = """
            FROM skill_calls c LEFT JOIN bindings b ON b.session_key = c.session_key AND b.project_id IS NOT NULL
              AND b.confidence IN \(bindings.sqlList)
            WHERE c.skill = ? AND c.ts >= ? AND c.ts <= ? AND \(InsightsStats.countedCallsSQL)
            """
        let values: [any SQLBindable] = [skill, from.timeIntervalSince1970, now.timeIntervalSince1970]
        struct Counts { var model = 0, pi = 0, user = 0, sessions = 0, last: Double? }
        var counts: [String?: Counts] = [:]
        for row in try database.rows("SELECT b.project_id, c.by, c.harness, COUNT(*) \(joined) GROUP BY 1, 2, 3", values) {
            let count = row[3].int ?? 0
            var entry = counts[row[0].text] ?? Counts()
            if row[1].text == "model" {
                entry.model += count
                if row[2].text == "pi" { entry.pi += count }
            } else {
                entry.user += count
            }
            counts[row[0].text] = entry
        }
        for row in try database.rows("SELECT b.project_id, COUNT(DISTINCT c.session_key), MAX(c.ts) \(joined) GROUP BY 1", values) {
            counts[row[0].text, default: Counts()].sessions = row[1].int ?? 0
            counts[row[0].text, default: Counts()].last = row[2].double
        }
        var places: [SkillCallsReport.Place] = []
        for (project, entry) in counts {
            let last: String? = entry.last.map { Date(timeIntervalSince1970: $0).formatted(.iso8601) }
            places.append(.init(project: project, modelCalls: entry.model, piModelCalls: entry.pi, userCalls: entry.user,
                                sessions: entry.sessions, lastCall: last))
        }
        // Projects with the most calls first; sessions bound to no project last.
        func order(_ place: SkillCallsReport.Place) -> (Int, Int, String) { (place.project == nil ? 1 : 0, -place.calls, place.project ?? "") }
        places.sort { order($0) < order($1) }

        return SkillCallsReport(
            version: 1, generated: now.formatted(.iso8601), skill: skill,
            window: .init(from: from.formatted(.iso8601), to: now.formatted(.iso8601), days: days),
            bindings: bindings.names, projects: places,
            otherMacs: otherMacs(others, skill: skill, from: from, calendar: calendar),
            notes: notes + [piNote])
    }

    /// The other Macs' calls of `skill` on the days from `from` on (local days, as the summaries keep them).
    static func otherMacs(_ others: UsageSummary.Others, skill: String, from: Date, calendar: Calendar) -> SkillCallsReport.OtherMacs {
        let first = UsageSummary.day(from, calendar: calendar)
        func calls(_ file: UsageSummary.File) -> (model: Int, user: Int) {
            file.days.filter { $0.key >= first }.values.reduce((0, 0)) { sum, day in
                guard let counts = day.skills[skill], counts.count == 3 else { return sum }
                return (sum.0 + counts[1], sum.1 + counts[2])
            }
        }
        var projects: [SkillCallsReport.OtherMacs.Project] = []
        for (project, files) in others.projects {
            let each = files.values.map(calls).filter { $0.model + $0.user > 0 }
            guard !each.isEmpty else { continue }
            projects.append(.init(project: project, modelCalls: each.reduce(0) { $0 + $1.model }, userCalls: each.reduce(0) { $0 + $1.user },
                                  macs: each.count))
        }
        projects.sort { (-$0.calls, $0.project) < (-$1.calls, $1.project) }
        let machines = others.machines.values.map(calls).filter { $0.model + $0.user > 0 }
        return .init(projects: projects, modelCalls: machines.reduce(0) { $0 + $1.model }, userCalls: machines.reduce(0) { $0 + $1.user },
                     macs: machines.count)
    }
}
