import Foundation
import Testing
@testable import AKitCommandLine
@testable import AKitInsights

/// `akit stats skill NAME`: one skill's calls per project, from facts written straight into a
/// temporary index (the helpers of `InsightsStatsTests`).
extension InsightsStatsTests {
    func callsReport(_ db: IndexDatabase, _ skill: String = "deploy", days: Int = 30, bindings: BindingSet = .default,
                     others: UsageSummary.Others = .init()) throws -> SkillCallsReport {
        try SkillCalls.report(db, skill: skill, days: days, bindings: bindings, others: others, notes: [], now: now)
    }

    @Test func skillCallsPerProjectAndUnbound() throws {
        let db = try database()
        for id in ["a1", "a2", "b1", "low", "free"] { try session(id, started: at(3), in: db) }
        try bind("a1", to: "github.com/me/app", .exact, in: db)
        try bind("a2", to: "github.com/me/app", .medium, in: db)
        try bind("b1", to: "github.com/me/site", .high, in: db)
        try bind("low", to: "github.com/me/site", .low, in: db)
        try call("a1", "deploy", at: at(3), in: db)
        try call("a1", "deploy", at: at(2), by: "user", in: db)
        try call("a2", "deploy", at: at(1), subagent: true, in: db)
        try call("b1", "deploy", at: at(2), in: db)
        // A low binding doesn't count by default: the session is unbound.
        try call("low", "deploy", at: at(2), in: db)
        try call("free", "deploy", at: at(4), by: "user", in: db)
        // Not counted: a built-in command, another skill, a call before the window.
        try call("free", "deploy", at: at(4), by: "user", kind: "command", in: db)
        try call("a1", "tdd", at: at(2), in: db)
        try call("a1", "deploy", at: at(40), in: db)
        // Pi: a model call is a read of SKILL.md, counted with the model's.
        try session("p1", started: at(1), harness: "pi", in: db)
        try db.run("""
            INSERT INTO bindings(session_key, project_id, method, confidence, decided_at, resolver_version) VALUES('pi:p1', ?, 'live', 'exact', 0, 1)
            """, "github.com/me/app")
        try call("p1", "deploy", at: at(1), harness: "pi", in: db)

        let report = try callsReport(db)
        #expect(report.projects.map(\.project) == ["github.com/me/app", "github.com/me/site", nil])
        let app = report.projects[0]
        #expect(app.modelCalls == 3 && app.piModelCalls == 1 && app.userCalls == 1 && app.sessions == 3 && app.calls == 4)
        #expect(app.lastCall == iso(at(1)))
        #expect(report.projects[1].calls == 1 && report.projects[1].sessions == 1)
        #expect(report.unbound?.modelCalls == 1 && report.unbound?.userCalls == 1 && report.unbound?.sessions == 2)
        #expect(report.calls(in: "github.com/me/app") == 4 && report.calls(in: "github.com/me/other") == 0)
        #expect(report.bindings == ["exact", "high", "medium"] && report.window.days == 30)

        // With low bindings the sibling session is the project's.
        let withLow = try callsReport(db, bindings: try BindingSet.parse("exact,high,medium,low"))
        #expect(withLow.projects.first { $0.project == "github.com/me/site" }?.calls == 2 && withLow.unbound?.calls == 1)
        // A wider window takes the old call.
        #expect(try callsReport(db, days: 60).projects[0].modelCalls == 4)
        // A skill nobody called: no places.
        #expect(try callsReport(db, "never").projects.isEmpty)
    }

    @Test func skillCallsOfOtherMacsFromTheirSummaries() throws {
        let db = try database()
        func file(_ key: String, _ days: [String: [String: [Int]]]) -> UsageSummary.File {
            .init(version: 1, machine: key, name: nil, updated: nil,
                  days: days.mapValues { .init(sessions: nil, firstContextSum: nil, firstContextN: nil, skills: $0, described: nil) },
                  descHashes: nil)
        }
        let recent = UsageSummary.day(Date(timeIntervalSince1970: at(2)), calendar: calendar)
        let old = UsageSummary.day(Date(timeIntervalSince1970: at(50)), calendar: calendar)
        var others = UsageSummary.Others()
        others.machines = ["m1": file("m1", [recent: ["deploy": [5, 3, 1]], old: ["deploy": [5, 9, 9]]]),
                           "m2": file("m2", [recent: ["deploy": [1, 0, 2], "tdd": [1, 4, 0]]]),
                           "m3": file("m3", [recent: ["tdd": [1, 1, 0]]])]
        others.projects = ["github.com/me/app": ["m1": file("m1", [recent: ["deploy": [2, 2, 1]]]),
                                                  "m2": file("m2", [recent: ["deploy": [1, 0, 1]]])],
                           "github.com/me/site": ["m1": file("m1", [old: ["deploy": [1, 5, 0]]])]]
        let report = try callsReport(db, others: others)
        let macs = report.otherMacs
        #expect(macs.modelCalls == 3 && macs.userCalls == 3 && macs.macs == 2)
        #expect(macs.projects == [.init(project: "github.com/me/app", modelCalls: 2, userCalls: 2, macs: 2)])
        #expect(macs.outsideProjects == 2)
        #expect(report.calls(in: "github.com/me/app") == 4)
    }

    @Test func skillCallsTextAndJSON() throws {
        let db = try database()
        try session("a1", started: at(3), in: db)
        try bind("a1", to: "github.com/me/app", .exact, in: db)
        try call("a1", "deploy", at: at(2), in: db)
        try call("a1", "deploy", at: at(2), by: "user", in: db)
        try session("free", started: at(3), in: db)
        try call("free", "deploy", at: at(1), in: db)
        let report = try callsReport(db)
        let text = AKitCLI.skillCallsText(report)
        #expect(text.contains("github.com/me/app: 2 calls (1 by the model, 1 by the user) in 1 session; last call"))
        #expect(text.contains("not bound to a project: 1 call (1 by the model) in 1 session"))
        #expect(!text.contains("Other Macs") && !text.contains("akit move skill"), "unbound calls: no hint")
        try db.run("DELETE FROM skill_calls WHERE session_key = 'claude:free'")
        #expect(AKitCLI.skillCallsText(try callsReport(db)).contains("Only github.com/me/app calls it: akit move skill deploy --to github.com/me/app moves it there."))

        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        #expect(Set(json.keys) == ["version", "generated", "skill", "window", "bindings", "projects", "otherMacs", "notes"])
        let places = try #require(json["projects"] as? [[String: Any]])
        #expect(Set(places[0].keys) == ["project", "modelCalls", "piModelCalls", "userCalls", "sessions", "lastCall"])
        #expect(places[1]["project"] is NSNull)
    }
}
