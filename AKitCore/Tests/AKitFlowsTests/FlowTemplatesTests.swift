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

struct FlowPresetTests {
    @Test(arguments: FlowTemplates.all.map(\.name))
    func everyPresetPassesTheCheck(_ name: String) throws {
        let flow = try #require(FlowTemplates.template(named: name)).make("m/a", "m/b", ["make test"])
        #expect(flow.name == name)
        let issues = FlowCheck.check(flow, knownModels: ["m/a", "m/b"], knownSkills: [], pi: nil).filter { $0.severity == .error }
        #expect(issues.isEmpty, "\(issues)")
        #expect(flow.steps.allSatisfy { $0.prompt?.isEmpty == false && FlowTemplates.agents.contains($0.agent) })
        #expect(try Flow.decode(yaml: flow.yaml()) == flow)
    }

    @Test func judgesNeedAnotherModelThanMakers() {
        let flow = FlowTemplates.ralplan(model: "m/a", reviewModel: "m/a")
        let same = FlowCheck.check(flow, knownModels: ["m/a"], knownSkills: [], pi: nil).filter { $0.code == .reviewerSameModel }
        #expect(same.map(\.step) == ["architect", "critique"])
    }

    @Test func readOnlyPresetsCannotWrite() throws {
        for name in ["ralplan", "review", "research", "deep-interview", "plan", "security-review", "interrogate", "blast-radius", "sharpen", "how", "why"] {
            let flow = try #require(FlowTemplates.template(named: name)).make("m/a", "m/b", [])
            #expect(!flow.tools.contains("edit") && !flow.tools.contains("write"), "\(name)")
        }
    }
}

struct FlowJudgeRuleTests {
    @Test func reviewerMayShareThePlannersModel() {
        var flow = FlowTemplates.feature(model: "m/a", reviewModel: "m/b")
        flow.steps[1].model = "m/b" // plan on the reviewer's model
        #expect(!FlowCheck.check(flow, knownModels: ["m/a", "m/b"], knownSkills: [], pi: nil).contains { $0.code == .reviewerSameModel })
    }
}
