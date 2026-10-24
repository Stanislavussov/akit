import Foundation
import Testing
import AKitFoundation
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

    @Test func theModelSettingDefaultsToLunaThroughPiAndIsKept() throws {
        #expect(KnowledgeCheckModel.agent(settings: LabSettings()) == LabAgent(harness: .pi, model: "opencode-go/gpt-6-luna", effort: "low"))
        #expect(KnowledgeCheckModel.label(KnowledgeCheckModel.defaultAgent) == "Pi · opencode-go/gpt-6-luna · low")
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
        let agent = KnowledgeCheckModel.defaultAgent
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
}
