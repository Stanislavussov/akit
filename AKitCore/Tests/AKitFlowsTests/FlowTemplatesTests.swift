import Foundation
import Testing
@testable import AKitFlows

struct FlowTemplatesTests {
    @Test func featurePassesTheCheckWithTwoModels() throws {
        let flow = FlowTemplates.feature(model: "m/a", reviewModel: "m/b", checks: ["make test"])
        let issues = FlowCheck.check(flow, knownModels: ["m/a", "m/b"], knownSkills: [], pi: nil).filter { $0.severity == .error }
        #expect(issues.isEmpty, "\(issues)")
        #expect(flow.steps.map(\.id) == ["clarify", "plan", "implement", "checks", "review", "commit"])
        #expect(flow.steps.allSatisfy { $0.prompt?.isEmpty == false })
        #expect(flow.steps.filter(\.gate).map(\.id) == ["plan", "review"])
        // The YAML reads back as the same flow, prompts included.
        #expect(try Flow.decode(yaml: flow.yaml()) == flow)
    }

    @Test func oneModelForBothIsTheReviewerError() {
        let flow = FlowTemplates.feature(model: "m/a", reviewModel: "m/a")
        #expect(FlowCheck.check(flow, knownModels: ["m/a"], knownSkills: [], pi: nil).contains { $0.code == .reviewerSameModel })
    }
}
