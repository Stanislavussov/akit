import AKitFlows
import AKitFoundation
import Foundation
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
        let ok = FlowCheck.check(flow(tools: ["read", "grep"]), knownModels: ["m/a"], knownSkills: [], pi: nil)
        #expect(!ok.contains { $0.step == "architect" })
        // bash is allowed, with a warning that it only reads there.
        let bash = FlowCheck.check(flow(tools: ["read", "grep", "bash"]), knownModels: ["m/a"], knownSkills: [], pi: nil)
        #expect(bash.filter { $0.step == "architect" }.map(\.code) == [.claudeBashReadOnly])
        let writes = FlowCheck.check(flow(tools: ["read", "edit"]), knownModels: ["m/a"], knownSkills: [], pi: nil)
        #expect(writes.contains { $0.code == .claudeStepWrites && $0.severity == .error && $0.message.contains("drop edit") })
        // No tools of its own: the flow's tools, which include edit.
        #expect(FlowCheck.check(flow(tools: []), knownModels: ["m/a"], knownSkills: [], pi: nil).contains { $0.code == .claudeStepWrites })
        // Its skills are checked like a Pi step's: they reach Claude too.
        let skills = FlowCheck.check(flow(tools: ["read"], skills: ["tdd"]), knownModels: ["m/a"], knownSkills: ["tdd"], pi: nil)
        #expect(!skills.contains { $0.step == "architect" })
        let missing = FlowCheck.check(flow(tools: ["read"], skills: ["nope"]), knownModels: ["m/a"], knownSkills: ["tdd"], pi: nil)
        #expect(missing.contains { $0.code == .unknownSkill && $0.step == "architect" })
    }
}

/// akit flow set | route | add-step | remove-step | move-step | set-flow (F23).
struct FlowEditTests {
    let flow = FlowTemplates.feature(model: "m/a", reviewModel: "m/b", checks: ["make test"])

    @Test func setsFieldsAndRefusesBadValues() throws {
        var edited = try FlowEdit.set(flow, step: "review", field: "thinking", value: "high")
        edited = try FlowEdit.set(edited, step: "review", field: "harness", value: "claude-code")
        edited = try FlowEdit.set(edited, step: "review", field: "checks", value: "make test; make lint")
        edited = try FlowEdit.set(edited, step: "review", field: "skills", value: "a, b")
        edited = try FlowEdit.set(edited, step: "review", field: "max-rounds", value: "7")
        let review = try #require(edited.step("review"))
        #expect(review.thinking == "high" && review.isClaudeCode && review.checks == ["make test", "make lint"] && review.skills == ["a", "b"])
        #expect(review.maxLoops == 7)
        #expect(try FlowEdit.set(edited, step: "review", field: "skills", value: "none").step("review")?.skills == [])
        #expect(try FlowEdit.set(edited, step: "review", field: "thinking", value: "default").step("review")?.thinking == nil)
        #expect(throws: FlowEdit.Failure.self) { try FlowEdit.set(flow, step: "review", field: "thinking", value: "huge") }
        #expect(throws: FlowEdit.Failure.self) { try FlowEdit.set(flow, step: "review", field: "max-rounds", value: "20") }
        #expect(throws: FlowEdit.Failure.self) { try FlowEdit.set(flow, step: "nope", field: "gate", value: "yes") }
        #expect(throws: FlowEdit.Failure.self) { try FlowEdit.set(flow, step: "review", field: "colour", value: "red") }
    }

    @Test func routesAndSteps() throws {
        var edited = try FlowEdit.route(flow, step: "review", key: "blocked:disputed", target: "implement")
        #expect(edited.step("review")?.routes["blocked:disputed"] == "implement")
        edited = try FlowEdit.route(edited, step: "review", key: "blocked:disputed", target: "stop")
        #expect(edited.step("review")?.routes["blocked:disputed"] == nil)
        #expect(try FlowEdit.route(flow, step: "review", key: "failed", target: "end").step("review")?.routes["failed:*"] == "end")
        #expect(throws: FlowEdit.Failure.self) { try FlowEdit.route(flow, step: "review", key: "lost", target: "end") }

        edited = try FlowEdit.addStep(flow, id: "lint", agent: "checker", model: "m/a", after: "plan")
        #expect(edited.index(of: "lint") == (flow.index(of: "plan") ?? 0) + 1)
        edited = try FlowEdit.moveStep(edited, step: "lint", after: nil)
        #expect(edited.steps.first?.id == "lint")
        let target = flow.steps.first { step in flow.steps.contains { $0.routes.values.contains(step.id) } }?.id ?? "implement"
        edited = try FlowEdit.removeStep(edited, step: target)
        #expect(edited.step(target) == nil && !edited.steps.contains { $0.routes.values.contains(target) })
        #expect(throws: FlowEdit.Failure.self) { try FlowEdit.addStep(flow, id: "plan", agent: "planner", model: "m/a", after: nil) }
    }
}

/// The review pack: every step's context, the request for the reviewer, secrets masked (F23).
struct FlowReviewExportTests {
    let home = FileManager.default.temporaryDirectory.appending(path: "akit-review-\(UUID().uuidString)")

    @Test func everyStepWithItsPromptAndSkills() throws {
        let skill = home.appending(path: ".pi/agent/skills/house")
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try Data("---\nname: house\ndescription: House style\n---\nUse tabs. token=ghp_abcdefghijklmnopqrstuvwxyz0123456789\n".utf8)
            .write(to: skill.appending(path: "SKILL.md"))
        var flow = FlowTemplates.feature(model: "m/a", reviewModel: "m/b", checks: ["make test"])
        flow.steps[0].skills = ["house", "missing"]
        let env = HarnessEnvironment(homeDirectory: home, variables: ["HOME": home.path])
        let result = FlowReviewExport.markdown(flow: flow, source: "test", project: nil, env: env, issues: [],
                                               runner: [.init(title: "X", file: "x.ts", code: "function x() {}")])
        let text = result.text
        for (index, step) in flow.steps.enumerated() { #expect(text.contains("## Step \(index + 1): \(step.id)")) }
        #expect(text.contains("## What to review") && text.contains("Use tabs.") && text.contains("Not installed"))
        #expect(text.contains("### X (`x.ts`)") && text.contains(FlowReviewExport.precedence))
        // The secret in the skill is masked, and the pack says so.
        #expect(!text.contains("ghp_abcdefghijklmnopqrstuvwxyz0123456789") && result.masked > 0 && text.contains("AKit masked"))
        // The second step's first round has the first one's handoff as the most recent.
        #expect(text.contains("Most recent: the handoff from the step \"\(flow.steps[0].id)\" (done)"))
    }
}

/// A Claude Code step may load Claude Code's own skills; a Pi step may not (F21).
struct FlowClaudeSkillTests {
    @Test func theCheckKnowsClaudesOwnSkillsForClaudeStepsOnly() {
        var flow = FlowTemplates.feature(model: "m/a", reviewModel: "m/b", checks: ["make test"])
        let architect = 1
        flow.steps[architect].harness = FlowStep.claudeCode
        flow.steps[architect].model = "opus"
        flow.steps[architect].tools = ["read", "grep"]
        flow.steps[architect].skills = ["house"]
        flow.steps[0].skills = ["house"]
        let issues = FlowCheck.check(flow, knownModels: nil, knownSkills: [], pi: nil, claudeSkills: ["house"])
            .filter { $0.code == .unknownSkill && $0.message.contains("Skill house ") }
        #expect(issues.map(\.step) == [flow.steps[0].id], "\(issues)")
    }

    @Test func theExportSaysWhatAClaudeStepSees() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "akit-claude-skill-\(UUID().uuidString)")
        let skill = home.appending(path: ".claude/skills/house")
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try Data("---\nname: house\ndescription: x\n---\nHouse rules.\n".utf8).write(to: skill.appending(path: "SKILL.md"))
        try Data("echo hi\n".utf8).write(to: skill.appending(path: "lint.sh"))
        let flow = Flow(name: "f", tools: ["read", "grep"], steps: [
            FlowStep(id: "architect", harness: FlowStep.claudeCode, agent: "architect", model: "opus", skills: ["house"], tools: ["read", "grep"]),
        ])
        let text = FlowReviewExport.markdown(flow: flow, source: "test", project: nil,
                                             env: HarnessEnvironment(homeDirectory: home, variables: ["HOME": home.path]), issues: [], runner: []).text
        #expect(text.contains("Claude Code's own setup is off") && text.contains("House rules.") && text.contains("architect (Claude Code)"))
        #expect(text.contains("lint.sh") && text.contains("without Bash"))
    }
}

/// A Claude Code step: its bash only reads, and the sending policy decides whether it may run.
struct FlowClaudeCheckTests {
    let flow = Flow(name: "f", tools: ["read", "grep", "bash"], steps: [
        FlowStep(id: "plan", agent: "planner", model: "m/a"),
        FlowStep(id: "architect", harness: FlowStep.claudeCode, agent: "architect", model: "opus"),
    ])

    @Test func bashOnClaudeIsReadOnlyAndThePolicyCanRefuseIt() {
        let plain = FlowCheck.check(flow, knownModels: nil, knownSkills: nil, pi: nil)
        #expect(plain.contains { $0.code == .claudeBashReadOnly && $0.step == "architect" && $0.severity == .warning })
        #expect(!plain.contains { $0.code == .claudeStepNotAllowed })
        let refused = FlowCheck.check(flow, knownModels: nil, knownSkills: nil, pi: nil, claudeBlocked: "not on the allowed list")
        #expect(refused.contains { $0.code == .claudeStepNotAllowed && $0.severity == .error && $0.message.hasSuffix("not on the allowed list") })
    }
}
