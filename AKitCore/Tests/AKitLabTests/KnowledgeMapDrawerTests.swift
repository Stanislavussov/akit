import Foundation
import Testing
import AKitFoundation
import AKitKnowledge
@testable import AKitLab

/// Draw Map with Pi… (5.4) with a fake `pi` (answers with a DSL), a fake `excalidraw-cli` and a
/// fake `npx` (write the fixture draft): Pi gets no tools and only the prompt, AKit draws the DSL
/// without a shell and proposes the draft itself. No model, no network, no Node.
@Suite(.serialized)
final class KnowledgeMapDrawerTests {
    let home: URL
    let fm = FileManager.default
    static let dsl = "[orders-api] -> \"events\" -> [billing]"

    init() throws {
        home = URL(filePath: FileWalk.realPath(fm.temporaryDirectory) ?? fm.temporaryDirectory.path)
            .appending(path: "akit-kb-draw-\(UUID().uuidString)")
        try fm.createDirectory(at: home.appending(path: "bin"), withIntermediateDirectories: true)
        let fixture = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "AKitKnowledgeTests/Fixtures/cli-draft.excalidraw")
        try fm.copyItem(at: fixture, to: home.appending(path: "draft.excalidraw"))
    }

    deinit { try? FileManager.default.removeItem(at: home) }

    func script(_ name: String, _ text: String) throws {
        let file = home.appending(path: "bin/\(name)")
        try Data(text.utf8).write(to: file)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }

    /// A fake pi: answers the account check; a run saves its arguments and the input file it was
    /// given (`@file`, the last argument), then prints `answer` as its one answer.
    func fakePi(answer: String) throws {
        let message: [String: Any] = ["type": "message_end", "message": [
            "role": "assistant", "content": [["type": "text", "text": answer]], "usage": ["input": 40, "output": 9],
        ] as [String: Any]]
        try JSONSerialization.data(withJSONObject: message).write(to: home.appending(path: "pi-event.json"))
        try script("pi", """
            #!/bin/sh
            if [ "$1 $2" = "auth check" ]; then echo '{"status":"ready"}'; exit 0; fi
            if [ "$1" = "--list-models" ]; then printf 'provider model\\nopencode-go gpt-6-luna\\nzai glm-5-air\\n'; exit 0; fi
            for a in "$@"; do printf '%s\\n' "$a"; last="$a"; done > "$HOME/pi-args.txt"
            cp "${last#@}" "$HOME/pi-input.txt"
            cat "$HOME/pi-event.json"; echo

            """)
    }

    /// A fake drawer (`excalidraw-cli` or `npx`): saves its arguments, writes the fixture draft to
    /// the path after `-o`.
    func fakeDrawer(_ name: String, fail: Bool = false) throws {
        try script(name, """
            #!/bin/sh
            for a in "$@"; do printf '%s\\n' "$a"; done > "$HOME/\(name)-args.txt"
            \(fail ? "echo 'Parse error on line 1' >&2; exit 3" : "")
            while [ $# -gt 0 ]; do if [ "$1" = "-o" ]; then cp "$HOME/draft.excalidraw" "$2"; fi; shift; done

            """)
    }

    func env() -> HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home, variables: ["HOME": home.path, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"],
                           executableSearchPaths: [home.appending(path: "bin"), URL(filePath: "/usr/bin"), URL(filePath: "/bin")])
    }

    func request(_ prompt: String = "How an order reaches billing") -> KnowledgeMapDrawer.Request {
        .init(area: "payments", name: "flow", prompt: prompt, agent: KnowledgeCheckModel.defaultAgent)
    }

    func lines(_ name: String) throws -> [String] {
        try String(contentsOf: home.appending(path: name), encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
            .dropLast().map(String.init)
    }

    func answer(_ dsl: String = dsl, reason: String = "How an order reaches billing") throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["dsl": dsl, "reason": reason]), as: UTF8.self)
    }

    @Test func piWritesTheDSLWithoutToolsAndAKitDrawsAndProposesIt() async throws {
        try fakePi(answer: try answer())
        try fakeDrawer("excalidraw-cli")
        try fakeDrawer("npx")
        let base = try await KnowledgeBase.create(world: "work", env: env())
        try await base.newNote(area: "payments", name: "billing", kind: nil, env: env())
        try await base.newNote(area: "payments", name: "orders-api", kind: nil, env: env())

        let log = Lines()
        let outcome = try await KnowledgeMapDrawer.run(request(), in: base, env: env()) { log.add($0) }
        let id = try #require(outcome.proposals.first)
        #expect(outcome.proposals.count == 1 && outcome.answer == "How an order reaches billing")
        let proposal = try base.proposal(id)
        #expect(proposal.kind == .map && proposal.target == "payments/maps/flow" && proposal.author == "pi")
        #expect(proposal.reason == "How an order reaches billing")

        // Pi: no tools, no session, none of the user's customizations; only the prompt as input.
        let args = try lines("pi-args.txt")
        #expect(args.contains("--no-tools") && !args.contains("--tools") && !args.contains("bash,read,write"))
        for flag in ["-p", "--no-session", "--no-skills", "--no-context-files", "--no-prompt-templates"] {
            #expect(args.contains(flag), "\(flag)")
        }
        #expect(args.contains("opencode-go/gpt-6-luna") && args.contains("--thinking"))
        let input = try String(contentsOf: home.appending(path: "pi-input.txt"), encoding: .utf8)
        #expect(input == "Area: payments. Map: flow.\nWhat the map shows: How an order reaches billing\n"
            + "The area's notes (use these names as block labels): billing, orders-api.")
        #expect(!input.contains("akit") && !input.contains(base.root.path))

        // AKit drew it: excalidraw-cli on the PATH wins over npx, the DSL is one argument.
        let drew = try lines("excalidraw-cli-args.txt")
        #expect(Array(drew.prefix(3)) == ["create", "--inline", Self.dsl] && drew.count == 5 && drew[3] == "-o")
        #expect(!fm.fileExists(atPath: home.appending(path: "npx-args.txt").path))
        #expect(log.all.contains("Proposed \(id)."))

        // The send log has the call as sent: the prompt alone.
        let records = SendLog.records(env: env())
        #expect(records.map(\.purpose) == ["kb-draw"] && records.first?.usage.output == 9)
        #expect(records.first?.inputCharacters == input.count)
        // The draft is a proposal like any agent's: the person accepts it in the Inbox.
        #expect(try base.planMap(proposal).links.map(\.link) == ["[[orders-api]]", "[[billing]]"])
    }

    @Test func withoutExcalidrawCLIItRunsThroughNpx() async throws {
        try fakePi(answer: "```\n\(Self.dsl)\n```")
        try fakeDrawer("npx")
        let base = try await KnowledgeBase.create(world: "work", env: env())
        let outcome = try await KnowledgeMapDrawer.run(request(), in: base, env: env())
        #expect(outcome.answer == nil)
        #expect(try base.proposal(try #require(outcome.proposals.first)).reason == "Drawn with Pi: How an order reaches billing")
        let drew = try lines("npx-args.txt")
        #expect(Array(drew.prefix(5)) == ["--yes", "@swiftlysingh/excalidraw-cli", "create", "--inline", Self.dsl])
        let input = try String(contentsOf: home.appending(path: "pi-input.txt"), encoding: .utf8)
        #expect(input.hasSuffix("The area has no notes yet: label each block with a short name for the system it stands for."))
    }

    @Test func failuresSayWhyAndProposeNothing() async throws {
        let base = try await KnowledgeBase.create(world: "work", env: env())
        try fakePi(answer: try answer())
        // Neither excalidraw-cli nor npx: refused before anything is sent.
        await #expect {
            try await KnowledgeMapDrawer.run(request(), in: base, env: env())
        } throws: { error in
            (error as? KnowledgeMapDrawer.Failure)?.message.hasPrefix("Draw Map needs excalidraw-cli, or Node's npx") == true
        }
        #expect(KnowledgeMapDrawer.missingDrawer(env: env()) != nil)
        #expect(SendLog.records(env: env()).isEmpty)

        // excalidraw-cli fails: its words, no proposal; the call is logged (it cost something).
        try fakeDrawer("excalidraw-cli", fail: true)
        #expect(KnowledgeMapDrawer.missingDrawer(env: env()) == nil)
        await #expect {
            try await KnowledgeMapDrawer.run(request(), in: base, env: env())
        } throws: { error in
            (error as? KnowledgeMapDrawer.Failure)?.message == "excalidraw-cli couldn't draw Pi's map (status 3): Parse error on line 1"
        }
        #expect(SendLog.records(env: env()).map(\.purpose) == ["kb-draw"])

        // Pi answers without a map.
        try fakeDrawer("excalidraw-cli")
        try fakePi(answer: "I can't draw that.")
        await #expect {
            try await KnowledgeMapDrawer.run(request(), in: base, env: env())
        } throws: { error in
            (error as? KnowledgeMapDrawer.Failure)?.message == "Pi's answer has no map: I can't draw that."
        }
        #expect(base.proposals().isEmpty)

        await #expect(throws: KnowledgeMapDrawer.Failure.self) {
            try await KnowledgeMapDrawer.run(request("  "), in: base, env: env())
        }
        var claude = request()
        claude.agent = LabAgent(harness: .claudeCode, model: "sonnet", effort: "low")
        await #expect(throws: KnowledgeMapDrawer.Failure.self) { try await KnowledgeMapDrawer.run(claude, in: base, env: env()) }
        try fm.removeItem(at: home.appending(path: "bin/pi"))
        await #expect {
            try await KnowledgeMapDrawer.run(request(), in: base, env: env())
        } throws: { error in
            (error as? KnowledgeMapDrawer.Failure)?.message == "Pi (pi) is not installed."
        }
    }

    @Test func theAnswerIsReadAsJSONOrAFencedBlock() throws {
        #expect(try KnowledgeMapDrawer.drawing(fromAnswer: #"Sure: {"dsl": "[a] -> [b]\n[c]", "reason": " A to B "}"#)
            == ("[a] -> [b]\n[c]", "A to B"))
        #expect(try KnowledgeMapDrawer.drawing(fromAnswer: "Here:\n```dsl\n[a] -> \"x\" -> [b]\n```\nDone.") == ("[a] -> \"x\" -> [b]", nil))
        // Passed as one argument: never something excalidraw-cli would read as an option.
        #expect(throws: KnowledgeMapDrawer.Failure.self) { try KnowledgeMapDrawer.drawing(fromAnswer: #"{"dsl": "--help", "reason": "x"}"#) }
        #expect(throws: KnowledgeMapDrawer.Failure.self) { try KnowledgeMapDrawer.drawing(fromAnswer: #"{"dsl": " ", "reason": "x"}"#) }
        let long = String(repeating: "[a] -> [b]\n", count: 2_000)
        #expect(throws: KnowledgeMapDrawer.Failure.self) {
            try KnowledgeMapDrawer.drawing(fromAnswer: String(decoding: try JSONSerialization.data(withJSONObject: ["dsl": long]), as: UTF8.self))
        }
    }

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func add(_ line: String) { lock.withLock { stored.append(line) } }
        var all: [String] { lock.withLock { stored } }
    }
}
