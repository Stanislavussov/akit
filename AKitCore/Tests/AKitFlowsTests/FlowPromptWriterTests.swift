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

/// F21: a step on Claude Code.
struct FlowClaudeStepTests {
    func flow(tools: [String], skills: [String] = []) -> Flow {
        Flow(name: "f", tools: ["read", "grep", "bash", "edit"], steps: [
            FlowStep(id: "plan", agent: "planner", model: "m/a"),
            FlowStep(id: "architect", harness: FlowStep.claudeCode, agent: "architect", model: "opus", skills: skills, tools: tools),
        ])
    }

    @Test func harnessIsWrittenOnlyWhenSetAndReadBack() throws {
        let yaml = try flow(tools: ["read"]).yaml()
        #expect(yaml.components(separatedBy: "harness: claude-code").count == 2)
        let back = try Flow.decode(yaml: yaml)
        #expect(back.steps[1].isClaudeCode && !back.steps[0].isClaudeCode && back.steps[0].harness == nil)
    }

    @Test func aClaudeStepIsReadOnlyAndItsModelIsNotPis() {
        let ok = FlowCheck.check(flow(tools: ["read", "grep", "bash"]), knownModels: ["m/a"], knownSkills: [], pi: nil)
        #expect(!ok.contains { $0.step == "architect" })
        let writes = FlowCheck.check(flow(tools: ["read", "edit"]), knownModels: ["m/a"], knownSkills: [], pi: nil)
        #expect(writes.contains { $0.code == .claudeStepWrites && $0.severity == .error && $0.message.contains("drop edit") })
        // No tools of its own: the flow's tools, which include edit.
        #expect(FlowCheck.check(flow(tools: []), knownModels: ["m/a"], knownSkills: [], pi: nil).contains { $0.code == .claudeStepWrites })
        let skills = FlowCheck.check(flow(tools: ["read"], skills: ["tdd"]), knownModels: ["m/a"], knownSkills: [], pi: nil)
        #expect(skills.contains { $0.code == .claudeStepPiOnly && $0.severity == .warning })
        #expect(!skills.contains { $0.code == .unknownSkill })
    }
}
