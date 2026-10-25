import Foundation
import Testing
import AKitFoundation
import AKitKnowledge
@testable import AKitLab

/// Draw Map with Pi… (5.4) with a fake `pi` and a fake `akit`: the arguments and the prompt AKit
/// builds, the send log's kb-draw, and the map proposal Pi leaves in the Inbox. No model, no network.
@Suite(.serialized)
struct KnowledgeMapDrawerTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = URL(filePath: FileWalk.realPath(fm.temporaryDirectory) ?? fm.temporaryDirectory.path)
            .appending(path: "akit-kb-draw-\(UUID().uuidString)")
        try fm.createDirectory(at: home.appending(path: "bin"), withIntermediateDirectories: true)
        try script("akit", "#!/bin/sh\nexit 0\n")
    }

    func script(_ name: String, _ text: String) throws {
        let file = home.appending(path: "bin/\(name)")
        try Data(text.utf8).write(to: file)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }

    /// A fake pi: answers the account check; a run saves its arguments, copies the prepared
    /// proposal and draft into the base's inbox (as `akit kb propose --map` would) when there are
    /// some, and ends with one answer.
    func fakePi() throws {
        try script("pi", """
            #!/bin/sh
            if [ "$1 $2" = "auth check" ]; then echo '{"status":"ready"}'; exit 0; fi
            for a in "$@"; do printf '%s\\n' "$a"; done > "$HOME/pi-args.txt"
            if [ -f "$HOME/proposal.md" ]; then
              cp "$HOME/draft.excalidraw" "$FAKE_BASE/inbox/2026-10-25-payments-maps-flow.excalidraw"
              cp "$HOME/proposal.md" "$FAKE_BASE/inbox/2026-10-25-payments-maps-flow.md"
            fi
            echo '{"type":"tool_execution_start","toolName":"bash","args":{"command":"npx --yes @swiftlysingh/excalidraw-cli create --inline x -o /tmp/f.excalidraw"}}'
            echo '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"Proposed the map payments/flow."}],"usage":{"input":40,"output":9}}}'

            """)
    }

    func env(base: URL? = nil) -> HarnessEnvironment {
        var variables = ["HOME": home.path, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
        variables["FAKE_BASE"] = base?.path
        return HarnessEnvironment(homeDirectory: home, variables: variables,
                                  executableSearchPaths: [home.appending(path: "bin"), URL(filePath: "/usr/bin"), URL(filePath: "/bin")])
    }

    func request(_ prompt: String = "How an order reaches billing") -> KnowledgeMapDrawer.Request {
        .init(area: "payments", name: "flow", prompt: prompt, agent: KnowledgeCheckModel.defaultAgent)
    }

    @Test func piDrawsWithItsToolsAndTheDraftArrivesInTheInbox() async throws {
        try fakePi()
        let base = try await KnowledgeBase.create(world: "work", env: env())
        try await base.newNote(area: "payments", name: "billing", kind: nil, env: env())
        try await base.newNote(area: "payments", name: "orders-api", kind: nil, env: env())
        let fixture = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "AKitKnowledgeTests/Fixtures/cli-draft.excalidraw")
        try fm.copyItem(at: fixture, to: home.appending(path: "draft.excalidraw"))
        let proposal = KnowledgeProposal(id: "2026-10-25-payments-maps-flow", kind: .map, target: "payments/maps/flow", reason: "drawn",
                                         created: "2026-10-25T12:00:00Z", author: "pi", body: "Blocks: orders-api, billing\n")
        try Data(proposal.text.utf8).write(to: home.appending(path: "proposal.md"))

        let lines = Lines()
        let outcome = try await KnowledgeMapDrawer.run(request(), in: base, env: env(base: base.root)) { lines.add($0) }
        #expect(outcome.proposals == [proposal.id] && outcome.answer == "Proposed the map payments/flow.")
        #expect(lines.all.contains("runs npx --yes @swiftlysingh/excalidraw-cli create --inline x -o /tmp/f.excalidraw"))
        let args = try String(contentsOf: home.appending(path: "pi-args.txt"), encoding: .utf8).split(separator: "\n").map(String.init)
        let tools = try #require(args.firstIndex(of: "--tools"))
        #expect(args[tools + 1] == "bash,read,write")
        for flag in ["-p", "--no-session", "--no-skills", "--no-context-files", "--no-prompt-templates", "--no-extensions"] {
            #expect(args.contains(flag), "\(flag)")
        }
        #expect(args.contains("opencode-go/gpt-6-luna") && args.contains("--thinking"))
        let prompt = try String(contentsOf: home.appending(path: "pi-args.txt"), encoding: .utf8)
        #expect(prompt.hasPrefix("-p\n") && prompt.contains("How an order reaches billing"))
        #expect(prompt.contains("so AKit links the block to its note: billing, orders-api."))
        #expect(prompt.contains("npx --yes @swiftlysingh/excalidraw-cli create"))
        #expect(prompt.contains("\(home.appending(path: "bin/akit").path) kb propose --map payments/flow --file "))
        #expect(prompt.contains("--base \(base.root.path)"))
        let records = SendLog.records(env: env())
        #expect(records.map(\.purpose) == ["kb-draw"] && records.first?.usage.output == 9)
        // The draft is a proposal like any agent's: the person accepts it in the Inbox.
        #expect(try base.planMap(try base.proposal(proposal.id)).links.map(\.link) == ["[[orders-api]]", "[[billing]]"])
    }

    @Test func aRunWithoutAMapProposalOrWithoutPiIsAFailure() async throws {
        try fakePi()
        let base = try await KnowledgeBase.create(world: "work", env: env())
        await #expect {
            try await KnowledgeMapDrawer.run(request(), in: base, env: env(base: base.root))
        } throws: { error in
            (error as? KnowledgeMapDrawer.Failure)?.message == "Pi finished but proposed no map. Its last words: Proposed the map payments/flow."
        }
        // The call is logged even so: it cost something.
        #expect(SendLog.records(env: env()).map(\.purpose) == ["kb-draw"])
        await #expect(throws: KnowledgeMapDrawer.Failure.self) {
            try await KnowledgeMapDrawer.run(request("  "), in: base, env: env(base: base.root))
        }
        var claude = request()
        claude.agent = LabAgent(harness: .claudeCode, model: "sonnet", effort: "low")
        await #expect(throws: KnowledgeMapDrawer.Failure.self) { try await KnowledgeMapDrawer.run(claude, in: base, env: env()) }
        try fm.removeItem(at: home.appending(path: "bin/akit"))
        await #expect {
            try await KnowledgeMapDrawer.run(request(), in: base, env: env(base: base.root))
        } throws: { error in
            (error as? KnowledgeMapDrawer.Failure)?.message.hasPrefix("akit isn't on the PATH") == true
        }
    }

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func add(_ line: String) { lock.withLock { stored.append(line) } }
        var all: [String] { lock.withLock { stored } }
    }
}
