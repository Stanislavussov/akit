import Foundation
import Testing
import AKitFoundation
import AKitKnowledge
@testable import AKitLab

/// The knowledge check's origin, its model setting, and one call through a fake `pi` (K15).
@Suite(.serialized)
struct KnowledgeCheckModelTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-kb-check-model-\(UUID().uuidString)")
        try fm.createDirectory(at: home.appending(path: "bin"), withIntermediateDirectories: true)
        let pi = home.appending(path: "bin/pi")
        try Data("""
            #!/bin/sh
            if [ "$1 $2" = "auth check" ]; then echo '{"status":"ready"}'; exit 0; fi
            if [ "$1" = "--list-models" ]; then printf 'provider model\\nopencode-go gpt-6-luna\\nzai glm-5-air\\n'; exit 0; fi
            echo '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"{\\"marks\\":[]}"}],"usage":{"input":10,"output":3}}}'

            """.utf8).write(to: pi)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pi.path)
    }

    var env: HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home, variables: ["HOME": home.path],
                           executableSearchPaths: [home.appending(path: "bin"), URL(filePath: "/usr/bin"), URL(filePath: "/bin")])
    }

    @Test func anyPiDestinationMayGetAProposalAndNothingElseUnlisted() {
        let copilot = SendDestination(harness: .pi, provider: "github-copilot", account: "", org: "")
        let zai = SendDestination(harness: .pi, provider: "zai", account: "me", org: "acme")
        let claude = SendDestination(harness: .claudeCode, provider: "anthropic", account: "me@example.com", org: "Me")
        for work in [false, true] {
            #expect(SendPolicy.decide(origin: .knowledgeBase, destination: copilot, isWork: work, allowed: []).allowed)
            #expect(SendPolicy.decide(origin: .knowledgeBase, destination: zai, isWork: work, allowed: []).allowed)
            let refused = SendPolicy.decide(origin: .knowledgeBase, destination: claude, isWork: work, allowed: [])
            #expect(!refused.allowed && refused.reason.contains("a knowledge base proposal"))
        }
        #expect(SendPolicy.decide(origin: .knowledgeBase, destination: claude, isWork: true, allowed: [claude]).allowed)
    }

    @Test func theDefaultComesFromTheHarnessListAndNothingElseIsTaken() throws {
        let home = ["opencode-go/gpt-6-luna", "zai/glm-5-air"], work = ["github-copilot/gpt-6-luna", "zai/glm-5-air"]
        #expect(KnowledgeCheckModel.defaultModel(for: .pi, available: home) == "opencode-go/gpt-6-luna")
        #expect(KnowledgeCheckModel.defaultModel(for: .pi, available: work) == "github-copilot/gpt-6-luna")
        #expect(KnowledgeCheckModel.defaultModel(for: .pi, available: ["zai/glm-5-air"]) == "zai/glm-5-air")
        #expect(KnowledgeCheckModel.defaultModel(for: .pi, available: []) == nil)
        #expect(KnowledgeCheckModel.defaultModel(for: .claudeCode, available: ["opus", "sonnet", "haiku"]) == "haiku")
        let pi = KnowledgeCheckModel.defaultAgent
        #expect(try KnowledgeCheckModel.resolved(pi, available: work).model == "github-copilot/gpt-6-luna")
        // A model the harness doesn't list, or a harness that lists nothing, is refused.
        var made = pi
        made.model = "opencode-go/gpt-6-luna"
        #expect(throws: KnowledgeCheckModel.Failure.self) { try KnowledgeCheckModel.resolved(made, available: work) }
        #expect(throws: KnowledgeCheckModel.Failure.self) { try KnowledgeCheckModel.resolved(pi, available: []) }
        #expect(try KnowledgeCheckModel.resolved(made, available: home) == made)
    }

    @Test func eachHarnessKeepsItsOwnModel() throws {
        var settings = LabSettings()
        #expect(KnowledgeCheckModel.agent(for: .claudeCode, settings: settings) == LabAgent(harness: .claudeCode, model: "", effort: "low"))
        let pi = LabAgent(harness: .pi, model: "github-copilot/gpt-6-luna", effort: "low")
        KnowledgeCheckModel.choose(pi, in: &settings)
        let claude = LabAgent(harness: .claudeCode, model: "sonnet", effort: "medium")
        KnowledgeCheckModel.choose(claude, in: &settings)
        #expect(KnowledgeCheckModel.agent(settings: settings) == claude)
        #expect(KnowledgeCheckModel.agent(for: .pi, settings: settings) == pi)
        KnowledgeCheckModel.choose(KnowledgeCheckModel.agent(for: .pi, settings: settings), in: &settings)
        #expect(KnowledgeCheckModel.agent(for: .claudeCode, settings: settings) == claude)
        // Defaults are stored as nothing; the memory survives the file.
        KnowledgeCheckModel.choose(KnowledgeCheckModel.defaultAgent, in: &settings)
        #expect(settings.knowledgeCheckAgent == nil && settings.knowledgeCheckModels.keys.sorted() == ["claude-code"])
        try LabSettings.update(env: env) { $0 = settings }
        #expect(LabSettings.load(env: env).knowledgeCheckModels == settings.knowledgeCheckModels)
    }

    @Test func theModelSettingDefaultsToPiAndIsKept() throws {
        #expect(KnowledgeCheckModel.agent(settings: LabSettings()) == LabAgent(harness: .pi, model: "", effort: "low"))
        #expect(KnowledgeCheckModel.label(KnowledgeCheckModel.defaultAgent) == "Pi · default model · low")
        let chosen = LabAgent(harness: .pi, model: "zai/glm-5-air", effort: "minimal")
        try LabSettings.update(env: env) { $0.knowledgeCheckAgent = chosen }
        #expect(KnowledgeCheckModel.agent(settings: LabSettings.load(env: env)) == chosen)
        // The Settings form's edit applies onto what is on disk, and leaves it when unchanged.
        var disk = LabSettings(translationAgent: OutputTranslation.piAgent)
        disk.apply(from: LabSettings(), to: LabSettings(knowledgeCheckAgent: chosen))
        #expect(disk.knowledgeCheckAgent == chosen && disk.translationAgent == OutputTranslation.piAgent)
        disk.apply(from: LabSettings(), to: LabSettings())
        #expect(disk.knowledgeCheckAgent == chosen)
    }

    @Test func aCheckGoesThroughTheGateAndTheSendLogHasKbCheck() async throws {
        let agent = try await KnowledgeCheckModel.resolved(KnowledgeCheckModel.defaultAgent, env: env)
        let gate = try await SendGate.open(agent: agent, env: env)
        #expect(gate.destination.harness == .pi && gate.destination.provider == "opencode-go")
        let request = ModelCall.Request(agent: agent, purpose: KnowledgeCheckModel.purpose, system: "check", input: "{}",
                                        schema: #"{"type":"object"}"#, origin: .knowledgeBase)
        let answer = try await ModelCall.run(request, gate: gate, folder: home.appending(path: "work"), env: env)
        #expect(answer.text == #"{"marks":[]}"#)
        let records = SendLog.records(env: env)
        #expect(records.map(\.purpose) == ["kb-check"] && records.first?.model == "opencode-go/gpt-6-luna")
        // A destination the policy refuses gets nothing, and nothing is logged.
        let refusing = SendGate(destination: SendDestination(harness: .claudeCode, provider: "anthropic", account: "a@b.c", org: "B"),
                                isWork: true, settings: LabSettings())
        await #expect(throws: SendAccounts.Failure.self) {
            try await ModelCall.run(request, gate: refusing, folder: home.appending(path: "work"), env: env)
        }
        #expect(SendLog.records(env: env).count == 1)
    }

    /// The one check `akit kb check` and Inbox → Check Again share: the marks are kept beside the
    /// proposal, the send log has kb-check, and the base gets no commit.
    @Test func theSharedCheckerKeepsTheMarksAndCommitsNothing() async throws {
        var variables = env.variables
        (variables["GIT_CONFIG_GLOBAL"], variables["GIT_CONFIG_NOSYSTEM"]) = ("/dev/null", "1")
        let env = HarnessEnvironment(homeDirectory: home, variables: variables, executableSearchPaths: env.executableSearchPaths)
        let base = try await KnowledgeBase.create(world: "work", env: env)
        try await base.newNote(area: "payments", name: "billing", kind: nil, env: env)
        let proposal = try base.propose(.init(.note("payments/billing", body: "## Retries\nThree tries.\n", set: []))).proposal
        let head = try #require(await ProcessRunner.run(URL(filePath: "/usr/bin/git"), arguments: ["rev-parse", "HEAD"], directory: base.root,
                                                         environment: variables, timeout: 20)).output
        let outcome = try await KnowledgeChecker.run(proposal, in: base, env: env)
        #expect(outcome.result.marks.isEmpty && outcome.result.model == "Pi · opencode-go/gpt-6-luna · low")
        #expect(base.check(of: proposal) == outcome.result)
        #expect(SendLog.records(env: env).map(\.purpose) == ["kb-check"])
        #expect(try #require(await ProcessRunner.run(URL(filePath: "/usr/bin/git"), arguments: ["rev-parse", "HEAD"], directory: base.root,
                                                      environment: variables, timeout: 20)).output == head)
    }
}
