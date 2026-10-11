import Foundation
import Testing
import AKitBrain
import AKitFoundation
@testable import AKitCommandLine
@testable import AKitInsights

/// Rule `only-used-in-project`: a global skill only one project calls gets "Only used in <project>"
/// with Move to Project. Same fixtures as `RecommenderTests` (a fake home, a temporary index).
extension RecommenderTests {
    static let other = "github.com/acme/site"

    /// tdd in the core layer: listed with its description in `outside` unbound sessions and in two
    /// sessions of the project, which has a model call.
    func onlyInProject(outside: Int = 20, in db: IndexDatabase) throws {
        try listedSessions(["tdd"], count: outside, id: "o", in: db)
        try listedSessions(["tdd"], count: 2, days: 2, id: "p", project: Self.project, in: db)
        try call("p0", "tdd", at: at(1, 10), in: db)
    }

    func clear(_ db: IndexDatabase) throws {
        for table in ["sessions", "skill_listings", "skill_calls", "bindings", "requests"] { try db.run("DELETE FROM \(table)") }
    }

    func moves(_ report: RecommendReport) -> [RecommendReport.Recommendation] {
        report.recommendations.filter { $0.action.kind == RecommendReport.Action.moveToProject }
    }

    @Test func aCoreSkillCalledOnlyInOneProjectIsRecommendedToMoveThere() async throws {
        let brain = try await writeBrain()
        let db = try database()
        try onlyInProject(in: db)
        let report = try recommend(db, .init(top: nil), layerInputs(brain))
        let item = try #require(moves(report).first, "\(report.recommendations.map(\.action.kind))")
        #expect(report.recommendations.count == 1, "the model call keeps auto → manual away")
        #expect(item.skill == "tdd" && item.type == "advice" && item.owner == .init(kind: "layer", name: "core"))
        #expect(item.action.project == Self.project && item.action.calls == 1)
        #expect(item.action.text?.hasPrefix("Only used in \(Self.project) (1 call / 30 days)") == true)
        #expect(item.evidence.sessions == 20 && item.evidence.modelCalls == 0 && item.evidence.approxContextSpace == 200, "\(item.evidence)")
        #expect(item.id == Recommender.moveID(owner: item.owner, skill: "tdd", project: Self.project) && item.id.hasPrefix("r-"))

        // The command prints it with the move line; the JSON carries the project and the calls.
        let text = AKitCLI.recommendText(report, details: false)
        #expect(text.contains("only used in \(Self.project) (1 call / 30 days)"), "\(text)")
        #expect(text.contains("  move: akit move skill tdd --to \(Self.project)"))
        let json = try #require(try JSONSerialization.jsonObject(with: try JSONEncoder().encode(report)) as? [String: Any])
        let action = try #require(((json["recommendations"] as? [[String: Any]])?.first)?["action"] as? [String: Any])
        #expect(action["kind"] as? String == "moveToProject" && action["project"] as? String == Self.project && action["calls"] as? Int == 1)
    }

    @Test func callsElsewhereOrTooFewSessionsOutsideStopTheMoveRecommendation() async throws {
        let brain = try await writeBrain()
        // A call in a session bound to no project.
        let unbound = try database()
        try onlyInProject(in: unbound)
        try call("o0", "tdd", at: at(1, 11), by: "user", in: unbound)
        #expect(moves(try recommend(unbound, .init(top: nil), layerInputs(brain))).isEmpty)

        // Calls in two projects.
        try clear(unbound)
        let two = unbound
        try onlyInProject(in: two)
        try listedSessions(["tdd"], count: 1, days: 1, id: "q", project: Self.other, in: two)
        try call("q0", "tdd", at: at(1, 12), in: two)
        #expect(moves(try recommend(two, .init(top: nil), layerInputs(brain))).isEmpty)

        // 19 sessions outside: below the size test. In a project scope it is never shown.
        try clear(two)
        let few = two
        try onlyInProject(outside: 19, in: few)
        #expect(moves(try recommend(few, .init(top: nil), layerInputs(brain))).isEmpty)
        #expect(moves(try recommend(few, .init(minSessions: 19, top: nil), layerInputs(brain))).count == 1)
        #expect(moves(try recommend(few, .init(project: Self.project, minSessions: 19, top: nil), layerInputs(brain))).isEmpty)
        // A call older than 30 days doesn't count: no call in the window, nothing to move.
        #expect(moves(try Recommender.recommend(few, options: .init(minSessions: 19, top: nil), inputs: layerInputs(brain),
                                                now: now.addingTimeInterval(40 * 86_400), calendar: calendar)).isEmpty)
    }

    @Test func otherMacsCountInTheirProjectFilesAndBlockOutsideThem() async throws {
        let brain = try await writeBrain()
        let db = try database()
        // This Mac: 10 sessions outside, too few alone; the other Mac adds 10 described sessions outside the project.
        try onlyInProject(outside: 10, in: db)
        var inputs = layerInputs(brain)
        let key = "abcdef0123456789"
        inputs.others.machines[key] = otherMac(days: [day(2): ["tdd": [12, 1, 0]]])
        inputs.others.projects[Self.project] = [key: otherMac(days: [day(2): ["tdd": [2, 1, 0]]])]
        let item = try #require(moves(try recommend(db, .init(top: nil), inputs)).first)
        #expect(item.action.calls == 2 && item.evidence.sessions == 20 && item.evidence.machines.map(\.name) == ["this Mac", "mbp"])

        // A call of theirs outside every project file (an unbound session, or a work Mac's project) blocks it.
        inputs.others.machines[key] = otherMac(days: [day(2): ["tdd": [12, 2, 0]]])
        #expect(moves(try recommend(db, .init(top: nil), inputs)).isEmpty)
    }

    @Test func onlyGlobalSkillsTheBrainCanMoveAreRecommended() async throws {
        let db = try database()
        try onlyInProject(in: db)
        // Without a brain the move can't happen.
        #expect(moves(try recommend(db, .init(top: nil), layerInputs(nil))).isEmpty)
        let brain = try await writeBrain()
        // A hand-installed skill counts only when its copy is global; a layer other than core never.
        var inputs = layerInputs(brain, owners: ["tdd": .handInstalled("~/Projects/x/.agents/skills/tdd/SKILL.md")])
        #expect(moves(try recommend(db, .init(top: nil), inputs)).isEmpty)
        inputs.stats.globalSkills = ["tdd"]
        let item = try #require(moves(try recommend(db, .init(top: nil), inputs)).first)
        #expect(item.owner.kind == "handInstalled")
        #expect(moves(try recommend(db, .init(top: nil), layerInputs(brain, owners: ["tdd": .layer(["task"])]))).isEmpty)
        #expect(moves(try recommend(db, .init(top: nil), layerInputs(brain, owners: ["tdd": .plugin("p")]))).isEmpty)
    }

    @Test func aDismissedMoveStaysHiddenUntilItsSpaceDoubles() async throws {
        let brain = try await writeBrain()
        let db = try database()
        try onlyInProject(in: db)
        var inputs = layerInputs(brain)
        let id = Recommender.moveID(owner: .init(kind: "layer", name: "core"), skill: "tdd", project: Self.project)
        inputs.dismissed[id] = .init(id: id, at: "2026-10-01T00:00:00Z", approxContextSpace: 150)
        let report = try recommend(db, .init(top: nil), inputs)
        #expect(moves(report).isEmpty && report.hiddenByDismissal == 1)
    }
}
