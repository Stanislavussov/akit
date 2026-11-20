import AKitFlows
import Testing

struct FlowPromptWriterTests {
    let flow = FlowTemplates.feature(model: "m/a", reviewModel: "m/b", checks: ["make test"])

    @Test func inputNamesTheOrderThisStepItsToolsAndTheRequest() throws {
        let input = try FlowPromptWriter.input(flow: flow, step: "review", request: "  focus on security  ")
        #expect(input.contains("5. review (reviewer)  ← this step"))
        #expect(input.contains("1. clarify (clarifier)\n2. plan (planner)"))
        #expect(input.contains("This step: review, agent reviewer, tools read, grep, find, ls, bash; the user approves its result at a gate"))
        #expect(input.contains("Current prompt:\nAnother model made the change."))
        #expect(input.hasSuffix("Request:\nfocus on security"))
    }

    @Test func checksAreNamedAndAnEmptyRequestTightensThePrompt() throws {
        let input = try FlowPromptWriter.input(flow: flow, step: "checks", request: "")
        #expect(input.contains("the runner runs make test at its end"))
        #expect(input.hasSuffix("Make the current prompt shorter and clearer; keep what it asks."))
    }

    @Test func nothingToWriteFromOrAnUnknownStepIsRefused() {
        var bare = flow
        bare.steps[0].prompt = nil
        #expect(throws: FlowPromptWriter.Failure.self) { try FlowPromptWriter.input(flow: bare, step: "clarify", request: " ") }
        #expect(throws: FlowPromptWriter.Failure.self) { try FlowPromptWriter.input(flow: flow, step: "nope", request: "x") }
    }

    @Test func resultTakesThePromptFromJSONEvenWithProseAround() throws {
        #expect(try FlowPromptWriter.result("Sure:\n```json\n{\"prompt\": \"  Review the diff.  \"}\n```") == "Review the diff.")
        #expect(throws: FlowPromptWriter.Failure.self) { try FlowPromptWriter.result("no json here") }
        #expect(throws: FlowPromptWriter.Failure.self) { try FlowPromptWriter.result("{\"prompt\": \"  \"}") }
    }
}
