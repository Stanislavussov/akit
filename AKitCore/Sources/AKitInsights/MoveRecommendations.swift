import AKitFoundation
import Foundation

/// Rule `only-used-in-project`: a global skill (the core layer's, or a hand-installed global one)
/// that only one project calls is better off in that project (Move to Project, layers.md). Every
/// counted call of the last `moveWindowDays` days (this Mac's index and the other Macs' summaries,
/// as `akit stats skill` counts them) is in sessions bound to that one project; none is in a
/// session bound to no project; and the skill was listed with its description in at least
/// `minSessions` sessions outside it (the same size test as auto → manual), each of which pays for
/// a description it never used.
extension Recommender {
    static let moveRule = "only-used-in-project"
    /// The window of the calls and listings the rule looks at.
    public static let moveWindowDays = 30

    static func moveRecommendations(_ database: IndexDatabase, names: Set<String>, owners: [String: SkillOwner], options: Options,
                                    inputs: Inputs, calibration: ContextSize.Calibration, now: Date,
                                    calendar: Calendar) throws -> (shown: [RecommendReport.Recommendation], hidden: Int) {
        // The move goes through the brain.
        guard inputs.stats.hasBrain, inputs.brain != nil else { return ([], 0) }
        let from = now.addingTimeInterval(-Double(moveWindowDays) * 86_400)
        let firstDay = UsageSummary.day(from, calendar: calendar)
        let staleBefore = now.addingTimeInterval(-Double(options.staleDays) * 86_400)

        // Only skills with a counted call in the window, here or on another Mac, can qualify.
        var called = Set(try database.rows("""
            SELECT DISTINCT c.skill FROM skill_calls c WHERE c.ts >= ? AND c.ts <= ? AND c.skill IS NOT NULL AND \(InsightsStats.countedCallsSQL)
            """, from.timeIntervalSince1970, now.timeIntervalSince1970).compactMap { $0[0].text })
        for file in inputs.others.machines.values {
            for (date, day) in file.days where date >= firstDay {
                for (skill, counts) in day.skills where counts.count == 3 && counts[1] + counts[2] > 0 { called.insert(skill) }
            }
        }

        var shown: [RecommendReport.Recommendation] = [], hidden = 0
        for name in names.sorted() where called.contains(name) {
            guard let owner = owners[name], isGlobal(name, owner: owner, inputs: inputs) else { continue }
            let report = try SkillCalls.report(database, skill: name, days: moveWindowDays, bindings: options.bindings, others: inputs.others,
                                               notes: [], now: now, calendar: calendar)
            // K = 1: one project has every call, none is unbound, no other Mac's call is outside a project file.
            let projects = Set(report.projects.compactMap(\.project)).union(report.otherMacs.projects.map(\.project))
            guard projects.count == 1, let project = projects.first, !project.hasPrefix("home/"), report.unbound == nil,
                  report.otherMacs.outsideProjects == 0 else { continue }
            let calls = report.calls(in: project)
            guard calls > 0 else { continue }

            // The sessions that would lose it: listed with its description, outside the project.
            let scope = InsightsStats.Scope(project: nil, bindings: options.bindings, from: from, to: now, outside: project)
            let tally = try InsightsStats.tallies(database, scope: scope, starts: [name: from], descriptions: inputs.stats.descriptions,
                                                  calibration: calibration)[name] ?? InsightsStats.Tally()
            var elsewhere = 0, days = tally.listedDays, listing: Set<String> = [], stale: Set<String> = []
            for (key, file) in inputs.others.machines {
                let inProject = inputs.others.projects[project]?[key]
                var listed = 0
                for (date, day) in file.days where date >= firstDay {
                    let outside = UsageSummary.described(day, skill: name) - (inProject?.days[date].map { UsageSummary.described($0, skill: name) } ?? 0)
                    guard outside > 0 else { continue }
                    listed += outside
                    days.insert(date)
                }
                guard listed > 0 else { continue }
                elsewhere += listed
                listing.insert(key)
                let updated = file.updated.flatMap { ISO8601DateFormatter().date(from: $0) }
                if updated.map({ $0 < staleBefore }) ?? true { stale.insert(key) }
            }
            let sessions = tally.listedSessions.count + elsewhere
            guard sessions >= options.minSessions else { continue }

            let recommendationOwner = RecommendReport.Owner(kind: owner.kind.rawValue, name: owner.name)
            let id = moveID(owner: recommendationOwner, skill: name, project: project)
            if let entry = inputs.dismissed[id], Dismissals.hides(entry, approxContextSpace: tally.contextSpace) {
                hidden += 1
                continue
            }
            func display(_ key: String) -> String { inputs.others.machines[key]?.name ?? key }
            var machines: [RecommendReport.Machine] = []
            if !tally.listedSessions.isEmpty {
                machines.append(.init(name: inputs.thisMac, updated: inputs.lastImport?.formatted(.iso8601), stale: false))
            }
            for key in listing.sorted() {
                machines.append(.init(name: display(key), updated: inputs.others.machines[key]?.updated, stale: stale.contains(key)))
            }
            let sortedDays = days.sorted()
            // About the sessions outside the project: none of them called it (the rule), so the rate is 0 there.
            let evidence = RecommendReport.Evidence(
                sessions: sessions, distinctDays: days.count, from: sortedDays.first, to: sortedDays.last, machines: machines, binding: nil,
                approxContextSpace: tally.contextSpace, modelCalls: 0, userCalls: 0, callRate: 0,
                callRateUpperBound95: min(1, (3 / Double(max(sessions, 1)) * 1000).rounded() / 1000))
            let text = "Only used in \(project) (\(calls) call\(calls == 1 ? "" : "s") / \(moveWindowDays) days), but listed with its description in "
                + "\(sessions) session\(sessions == 1 ? "" : "s") elsewhere. Move it there, so other sessions stop paying for its description: "
                + "Move to Project… (Skills or Insights), or \(moveCommand(skill: name, project: project))."
            shown.append(.init(id: id, type: "advice", stale: !stale.isEmpty, owner: recommendationOwner, skill: name, scope: .init(project: nil),
                               action: .init(kind: RecommendReport.Action.moveToProject, text: text, project: project, calls: calls),
                               evidence: evidence, patch: nil, staleMachines: stale.sorted().map(display)))
        }
        return (shown, hidden)
    }

    /// The core layer's skill, or a global copy that is not AKit's (hand-installed). Plugin, built-in and
    /// unknown skills are left out: AKit can't move them, or can't tell where they come from.
    static func isGlobal(_ name: String, owner: SkillOwner, inputs: Inputs) -> Bool {
        switch owner {
        case .layer(let layers): layers.contains("core")
        case .handInstalled: inputs.stats.globalSkills.contains(name)
        case .plugin, .builtIn, .unknown, .unrendered: false
        }
    }

    /// The command that moves it: `akit move skill NAME --to PROJECT`.
    public static func moveCommand(skill: String, project: String) -> String { "akit move skill \(skill) --to \(project)" }

    /// `"r-"` + 10 hex characters of SHA-256 over the rule, owner, skill and project, as `id` does for
    /// auto → manual. A hand-installed skill's name stands for its path.
    static func moveID(owner: RecommendReport.Owner, skill: String, project: String) -> String {
        let name = owner.kind == SkillOwner.Kind.handInstalled.rawValue ? skill : owner.name ?? ""
        let text = [moveRule, owner.kind, name, skill, project].joined(separator: "|")
        return "r-" + Checksum.sha256(Data(text.utf8)).prefix(10)
    }
}
