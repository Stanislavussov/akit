import Foundation
import Testing
import AKitBrain
import AKitFoundation
import AKitKnowledge
@testable import AKitLab

/// Ask Pi about a note (K30) with a fake `pi`: each call saves its arguments and its working
/// folder, writes a session file into `--session-dir` and prints a json stream. No model, no
/// network; a temporary home only.
@Suite(.serialized)
final class KnowledgeAskTests {
    let home: URL
    let fm = FileManager.default
    static let agent = LabAgent(harness: .pi, model: "opencode-go/gpt-6-luna", effort: "low")
    static let note = KnowledgeAsk.Note(base: "work", baseRoot: "/tmp/kb/work", id: "payments/orders-api",
                                        path: "areas/payments/orders-api.md", title: "orders-api")

    init() throws {
        home = URL(filePath: FileWalk.realPath(fm.temporaryDirectory) ?? fm.temporaryDirectory.path)
            .appending(path: "akit-kb-ask-\(UUID().uuidString)")
        try fm.createDirectory(at: home.appending(path: "bin"), withIntermediateDirectories: true)
        try fakePi()
    }

    deinit { try? FileManager.default.removeItem(at: home) }

    /// The fake pi. `$HOME/mode` picks the answer: empty answers "Answer N", `fail` ends with a
    /// model error, `slow` waits (for Stop).
    func fakePi() throws {
        let file = home.appending(path: "bin/pi")
        try Data(#"""
            #!/bin/sh
            if [ "$1 $2" = "auth check" ]; then echo '{"status":"ready"}'; exit 0; fi
            n=$(( $(cat "$HOME/count" 2>/dev/null || echo 0) + 1 )); echo $n > "$HOME/count"
            for a in "$@"; do printf '%s\n' "$a"; done > "$HOME/args-$n.txt"
            pwd > "$HOME/cwd-$n.txt"
            dir=""; prev=""
            for a in "$@"; do [ "$prev" = "--session-dir" ] && dir="$a"; prev="$a"; done
            echo '{"type":"session","id":"s'$n'"}' > "$dir/2026-10-31T10-00-0${n}-000Z_s$n.jsonl"
            echo '{"type":"session","id":"s'$n'"}'
            echo '{"type":"tool_execution_start","toolName":"bash","args":{"command":"akit kb search orders"}}'
            mode=$(cat "$HOME/mode" 2>/dev/null)
            if [ "$mode" = "slow" ]; then sleep 30; fi
            if [ "$mode" = "propose" ]; then
              root=$(cat "$HOME/base-root")
              cp "$HOME/other.md" "$root/inbox/2020-01-02-payments-billing.md"
              cp "$HOME/mine.md" "$root/inbox/2020-01-02-payments-billing-2.md"
              echo '{"type":"tool_execution_start","toolName":"bash","toolCallId":"c1","args":{"command":"akit kb propose --base x --note payments/billing --stdin"}}'
              echo '{"type":"tool_execution_end","toolName":"bash","toolCallId":"c1","result":{"content":[{"type":"text","text":"2020-01-02-payments-billing-2 Proposed in inbox/2020-01-02-payments-billing-2.md, for the person to accept or reject (not committed)."}]}}'
              echo '{"type":"tool_execution_start","toolName":"bash","toolCallId":"c2","args":{"command":"akit kb inbox"}}'
              echo '{"type":"tool_execution_end","toolName":"bash","toolCallId":"c2","result":{"content":[{"type":"text","text":"2020-01-02-payments-billing  note payments/billing (inbox/2020-01-02-payments-billing.md)"}]}}'
            fi
            if [ "$mode" = "fail" ]; then
              echo '{"type":"message_end","message":{"role":"assistant","stopReason":"error","errorMessage":"rate limited"}}'
              exit 1
            fi
            echo '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"Answer '$n' token=ghp_abcdefghijklmnopqrstuvwxyz0123456789"}],"usage":{"input":40,"output":9,"cacheRead":0,"cacheWrite":0,"cost":{"total":0.01}}}}'

            """#.utf8).write(to: file)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }

    func env() -> HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home, variables: ["HOME": home.path, "SHELL": "/bin/sh"],
                           executableSearchPaths: [home.appending(path: "bin"), URL(filePath: "/usr/bin"), URL(filePath: "/bin")])
    }

    func args(_ n: Int) throws -> [String] {
        try String(contentsOf: home.appending(path: "args-\(n).txt"), encoding: .utf8).split(separator: "\n").map(String.init)
    }

    func mode(_ text: String) throws { try Data(text.utf8).write(to: home.appending(path: "mode")) }

    @Test func theFirstPromptCarriesTheNoteAndAFollowUpOnlyTheQuestion() {
        let first = KnowledgeAsk.prompt(question: " Who owns it? ", passage: nil, note: Self.note, noteText: "# orders-api\nSends events.", first: true)
        #expect(first.contains("The knowledge base \"work\" is at /tmp/kb/work."))
        #expect(first.contains("The note: payments/orders-api, file areas/payments/orders-api.md, title \"orders-api\"."))
        #expect(first.contains("<note>\n# orders-api\nSends events.\n</note>") && first.hasSuffix("My question: Who owns it?"))

        let passage = KnowledgeAsk.prompt(question: "Why?", passage: "## Events\norder created", note: Self.note, noteText: "SECRET-BODY", first: true)
        #expect(passage.contains("> ## Events\n> order created") && passage.contains("areas/payments/orders-api.md"))
        #expect(!passage.contains("SECRET-BODY"), "a passage question carries the passage, not the whole note")

        #expect(KnowledgeAsk.prompt(question: "And billing?", passage: nil, note: Self.note, noteText: "x", first: false) == "And billing?")
        let next = KnowledgeAsk.prompt(question: "And this?", passage: "retry", note: Self.note, noteText: "x", first: false)
        #expect(next == "About this passage of the note payments/orders-api:\n\n> retry\n\nAnd this?")
    }

    @Test func piKeepsTheUsersSetupButMayNotEditOrWrite() throws {
        let chat = try KnowledgeAsk.newChat(note: Self.note, cwd: home, env: env())
        let options = KnowledgeAsk.options(chat: chat, fork: nil, agent: Self.agent)
        #expect(options == ["--session-dir", chat.folder.appending(path: "sessions").path, "--model", "opencode-go/gpt-6-luna",
                            "--thinking", "low", "--exclude-tools", "edit,write",
                            "--append-system-prompt", chat.folder.appending(path: "system.md").path])
        #expect(!options.contains { $0.hasPrefix("--no-") } && !options.contains("--tools"))
        let forked = KnowledgeAsk.options(chat: chat, fork: URL(filePath: "/s/a_s1.jsonl"), agent: LabAgent(harness: .pi, model: "", effort: ""))
        #expect(Array(forked.prefix(2)) == ["--fork", "/s/a_s1.jsonl"] && !forked.contains("--model") && !forked.contains("--thinking"))
        let system = KnowledgeAsk.systemPrompt(Self.note)
        #expect(system.contains("/tmp/kb/work") && system.contains("payments/orders-api") && system.contains("Never edit, write"))
        #expect(system.contains("language of the question"))
    }

    @Test func theSystemPromptLetsPiOnlyPropose() {
        let system = KnowledgeAsk.systemPrompt(Self.note)
        #expect(system.contains("Never edit, write, move or delete files yourself"))
        #expect(system.contains("akit kb propose --base '/tmp/kb/work' --author pi --note AREA/NAME --stdin --reason"))
        #expect(system.contains("Keep the quotes around the base folder"))
        var spaced = Self.note
        spaced.baseRoot = "/Users/me/My Notes/it's"
        #expect(KnowledgeAsk.systemPrompt(spaced).contains("--base '/Users/me/My Notes/it'\\''s' --author pi"))
        #expect(system.contains("whole `## Heading` blocks") && system.contains("--arrow \"A -kind-> B\""))
        #expect(!system.contains("Do not change files"))
    }

    /// K32, review round 2: the cards of an answer are only the ids its own `kb propose` printed,
    /// and new since the question: not another session's `X` while Pi made `X-2`, and not what an
    /// `akit kb inbox` in the same answer lists.
    @Test func anAnswersProposalsAreOnlyItsOwnAndComeBackWithTheChat() async throws {
        let base = try await KnowledgeBase.create(world: "work", env: env())
        try await base.newNote(area: "payments", name: "orders-api", kind: nil, env: env())
        try await base.newNote(area: "payments", name: "billing", kind: nil, env: env())
        let earlier = try base.propose(.init(.note("payments/billing", body: "## Owners\nTeam B.\n", set: []), reason: "earlier", author: "claude"),
                                       now: Date(timeIntervalSince1970: 1_577_836_800)).proposal
        func proposal(_ id: String, _ created: String) -> String {
            KnowledgeProposal(id: id, kind: .note, target: "payments/billing", reason: "owner", created: created, author: "pi",
                              set: [], arrow: nil, body: "## Owners\nTeam C.\n").text
        }
        try Data(proposal("2020-01-02-payments-billing-2", "2020-01-02T10:00:01Z").utf8).write(to: home.appending(path: "mine.md"))
        try Data(proposal("2020-01-02-payments-billing", "2020-01-02T10:00:00Z").utf8).write(to: home.appending(path: "other.md"))
        try Data(base.root.path.utf8).write(to: home.appending(path: "base-root"))
        try mode("propose")
        var note = Self.note
        note.baseRoot = base.root.path
        let chat = try KnowledgeAsk.newChat(note: note, cwd: home, env: env())
        let entry = try await KnowledgeAsk.ask("Fix the owner, please", noteText: "# orders-api", in: chat, agent: Self.agent, env: env())
        let mine = KnowledgeAsk.ProposalRef(id: "2020-01-02-payments-billing-2", created: "2020-01-02T10:00:01Z")
        #expect(entry.proposals == [mine], "not \(earlier.id) (before), nor the other session's 2020-01-02-payments-billing")
        #expect(KnowledgeAsk.entries(chat).first?.proposals == [mine])
        #expect(await base.state(ofProposal: mine.id, created: mine.created, env: env()) == .pending)
        #expect(await base.state(ofProposal: "no-such-proposal", env: env()) == .closed)

        try mode("")
        let plain = try await KnowledgeAsk.ask("Thanks", noteText: "", in: chat, agent: Self.agent, env: env())
        #expect(plain.proposals == nil)
        let line = try String(contentsOf: chat.folder.appending(path: "chat.jsonl"), encoding: .utf8).split(separator: "\n").last ?? ""
        #expect(!line.contains("proposals"), "an answer without proposals stores none")
    }

    /// A chat saved before proposals had a time reads its plain ids.
    @Test func oldEntriesWithPlainProposalIdsStillRead() throws {
        let line = #"{"asked":"2026-10-31T10:00:00Z","id":"q1","proposals":["2026-10-31-payments-billing"],"question":"Q"}"#
        let entry = try KnowledgeAsk.decoder.decode(KnowledgeAsk.Entry.self, from: Data(line.utf8))
        #expect(entry.proposals == [KnowledgeAsk.ProposalRef(id: "2026-10-31-payments-billing", created: nil)])
        let again = try KnowledgeAsk.decoder.decode(KnowledgeAsk.Entry.self, from: KnowledgeAsk.encoder.encode(entry))
        #expect(again == entry)
    }

    /// Without call ids, a propose's result is the next bash result; a failed propose names nothing.
    @Test func proposeOutputWithoutCallIds() {
        let stream = [
            #"{"type":"tool_execution_start","toolName":"bash","args":{"command":"akit kb propose --json --note a/b --stdin"}}"#,
            #"{"type":"tool_execution_end","toolName":"bash","result":{"content":[{"type":"text","text":"{\"id\":\"x-1\",\"path\":\"inbox/x-1.md\"}"}]}}"#,
            #"{"type":"tool_execution_start","toolName":"bash","args":{"command":"akit kb propose --note a/c --stdin"}}"#,
            #"{"type":"tool_execution_end","toolName":"bash","isError":true,"result":{"content":[{"type":"text","text":"inbox/x-2.md exists"}]}}"#,
            #"{"type":"tool_execution_start","toolName":"bash","args":{"command":"cat inbox/x-3.md"}}"#,
            #"{"type":"tool_execution_end","toolName":"bash","result":{"content":[{"type":"text","text":"inbox/x-3.md"}]}}"#,
        ]
        #expect(KnowledgeAsk.proposeOutputIDs(stream) == ["x-1"])
    }

    @Test func piRunsInTheSpacesProjectFolderElseTheBase() throws {
        let base = home.appending(path: "base")
        let project = home.appending(path: "Projects/orders-api")
        let clone = home.appending(path: "work/billing")
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        try fm.createDirectory(at: clone, withIntermediateDirectories: true)
        func folder(_ projects: [String], copies: [String: URL] = [:]) -> URL {
            KnowledgeAsk.workingFolder(area: KnowledgeArea(projects: projects), baseRoot: base, home: home, copies: copies)
        }
        #expect(folder([]) == base)
        #expect(folder(["~/Projects/missing", "~/Projects/orders-*", "~/Projects/orders-api"]) == project, "globs and missing folders are skipped")
        #expect(folder(["git@example.com:shop/billing.git"], copies: ["example.com/shop/billing": clone]) == clone)
        #expect(folder(["git@example.com:shop/billing.git"]) == base, "a remote without a local copy")
    }

    @Test func chatsAreStoredMaskedOutsideTheBaseAndTheLatestComesBack() async throws {
        let older = try KnowledgeAsk.newChat(note: Self.note, cwd: home, env: env(), now: Date(timeIntervalSince1970: 1_000))
        let chat = try KnowledgeAsk.newChat(note: Self.note, cwd: home, env: env(), now: Date(timeIntervalSince1970: 2_000))
        var other = Self.note
        other.id = "payments/billing"
        _ = try KnowledgeAsk.newChat(note: other, cwd: home, env: env(), now: Date(timeIntervalSince1970: 3_000))
        #expect(chat.folder.path.hasPrefix(home.appending(path: ".akit/local/knowledge-ask/work").path))
        #expect(KnowledgeAsk.latestChat(note: Self.note.id, base: "work", env: env())?.id == chat.id)
        #expect(KnowledgeAsk.latestChat(note: Self.note.id, base: "work", env: env())?.id != older.id)
        #expect(KnowledgeAsk.latestChat(note: "payments/none", base: "work", env: env()) == nil)

        let entry = try await KnowledgeAsk.ask("What does it send? password=hunter2secret", noteText: "# orders-api", in: chat,
                                               agent: Self.agent, env: env())
        let saved = KnowledgeAsk.entries(chat)
        #expect(saved.map(\.id) == [entry.id] && saved.first?.answer == entry.answer && entry.id == "q1" && entry.session == "s1" && entry.error == nil)
        #expect(!entry.question.contains("hunter2secret") && entry.answer?.contains("Answer 1") == true)
        #expect(entry.answer?.contains("ghp_abcdefghijklmnopqrstuvwxyz0123456789") == false, "the saved answer is masked")
        let stream = try String(contentsOf: chat.folder.appending(path: "streams/q1.jsonl"), encoding: .utf8)
        #expect(stream.contains("akit kb search orders") && !stream.contains("ghp_abcdefghijklmnopqrstuvwxyz0123456789"))
    }

    @Test func eachQuestionForksTheLastGoodAnswerAndUsageIsLogged() async throws {
        let cwd = home.appending(path: "Projects/orders-api")
        try fm.createDirectory(at: cwd, withIntermediateDirectories: true)
        let chat = try KnowledgeAsk.newChat(note: Self.note, cwd: cwd, env: env())
        let steps = StepLog()
        let first = try await KnowledgeAsk.ask("Who owns it?", noteText: "# orders-api\nTeam A.", in: chat, agent: Self.agent, env: env(),
                                               progress: { steps.add($0) })
        #expect(first.answer?.hasPrefix("Answer 1") == true)
        #expect(steps.all.contains("Runs bash akit kb search orders"))
        let one = try args(1)
        #expect(Array(one.prefix(4)) == ["-p", "--mode", "json", "--offline"] && !one.contains("--fork"))
        // The call record of the Log… sheet (K34): as run, masked, with the session file and the thinking.
        let call = try #require(KnowledgeAskLog.load(first, in: chat).call)
        #expect(call.arguments.first == "-p" && call.arguments.contains("--exclude-tools") && call.prompt?.contains("Team A.") == true)
        #expect(call.thinking == "low" && call.model == "opencode-go/gpt-6-luna" && call.fork == nil && call.exitStatus == 0)
        #expect(call.session?.hasSuffix("_s1.jsonl") == true && call.cwd == cwd.path && call.usage.output == 9)
        #expect(first.model == "opencode-go/gpt-6-luna" && first.thinking == "low")
        #expect(KnowledgeAskLog.load(first, in: chat).steps.first?.summary == "akit kb search orders")
        #expect(one.contains("--exclude-tools") && one.joined(separator: "\n").contains("<note>\n# orders-api\nTeam A.\n</note>"))
        #expect(try String(contentsOf: home.appending(path: "cwd-1.txt"), encoding: .utf8).trimmingCharacters(in: .newlines) == cwd.path)
        #expect(fm.fileExists(atPath: chat.folder.appending(path: "system.md").path))

        try mode("fail")
        let failed = try await KnowledgeAsk.ask("And billing?", noteText: "# orders-api", in: chat, agent: Self.agent, env: env())
        #expect(failed.error == "rate limited" && failed.answer == nil)
        let two = try args(2)
        #expect(two[two.firstIndex(of: "--fork")! + 1].hasSuffix("_s1.jsonl") && two.last == "And billing?", "a follow-up is the question alone")

        try mode("")
        _ = try await KnowledgeAsk.ask("Again?", noteText: "# orders-api", in: chat, agent: Self.agent, env: env())
        let three = try args(3)
        #expect(three[three.firstIndex(of: "--fork")! + 1].hasSuffix("_s1.jsonl"), "the failed answer s2 is never forked")
        #expect(KnowledgeAsk.entries(chat).map(\.id) == ["q1", "q2", "q3"])

        let records = SendLog.records(env: env())
        #expect(records.map(\.purpose) == ["knowledge-ask", "knowledge-ask", "knowledge-ask"], "the failed answer was sent too")
        #expect(records.first?.usage.output == 9 && records.first?.runID == chat.id && records.first?.session == "s1")
        let system = KnowledgeAsk.systemPrompt(chat.note).count
        #expect(records.first?.systemCharacters == system && (records.first?.inputCharacters ?? 0) > system)

        let script = try KnowledgeAsk.openScript(chat, agent: Self.agent, env: env())
        let text = try String(contentsOf: script, encoding: .utf8)
        #expect(text.contains("cd '\(cwd.path)'") && text.contains("'--fork' '\(chat.folder.path)/sessions/2026-10-31T10-00-03-000Z_s3.jsonl'"))
        #expect(!text.contains("'-p'") && text.contains("'--exclude-tools' 'edit,write'"))
    }

    @Test func nothingIsSentWithoutAQuestionPiOrConsent() async throws {
        let chat = try KnowledgeAsk.newChat(note: Self.note, cwd: home, env: env())
        await #expect(throws: KnowledgeAsk.Failure.self) {
            try await KnowledgeAsk.ask("  ", noteText: "", in: chat, agent: Self.agent, env: self.env())
        }
        await #expect(throws: KnowledgeAsk.Failure.self) {
            try await KnowledgeAsk.ask("Q?", noteText: "", in: chat, agent: Self.agent, env: self.env(), confirm: { _ in false })
        }
        var noPi = env()
        noPi.executableSearchPaths = [URL(filePath: "/usr/bin")]
        await #expect(throws: KnowledgeAsk.Failure.self) {
            try await KnowledgeAsk.ask("Q?", noteText: "", in: chat, agent: Self.agent, env: noPi)
        }
        #expect(throws: KnowledgeAsk.Failure.self) { try KnowledgeAsk.openScript(chat, agent: Self.agent, env: self.env()) }
        #expect(KnowledgeAsk.entries(chat).isEmpty && !fm.fileExists(atPath: home.appending(path: "count").path))
    }

    /// Review finding 1: a hostile note id can't break out of Open in Pi's script.
    @Test func openInPiQuotesTheNoteId() async throws {
        var note = Self.note
        note.id = "a$(touch pwned)b`touch pwned2`\"\necho broken; touch pwned3"
        let chat = try KnowledgeAsk.newChat(note: note, cwd: home, env: env())
        _ = try await KnowledgeAsk.ask("Q?", noteText: "", in: chat, agent: Self.agent, env: env())
        let script = try KnowledgeAsk.openScript(chat, agent: Self.agent, env: env())
        let text = try String(contentsOf: script, encoding: .utf8)
        #expect(!text.contains("\necho broken") && text.contains("printf '%s\\n' 'AKit: Pi goes on"))
        let run = try #require(await ProcessRunner.run(URL(filePath: "/bin/sh"), arguments: [script.path], directory: home,
                                                        environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"], timeout: 20))
        #expect(run.succeeded && run.output.contains("AKit: Pi goes on with your questions about a$(touch pwned)b"))
        for name in ["pwned", "pwned2", "pwned3"] { #expect(!fm.fileExists(atPath: home.appending(path: name).path), "\(name)") }
        #expect(try args(2).contains("--fork"), "the script ran the fake pi, forking the answer")
    }

    /// Review finding 4: on a work Mac Pi in a project folder sends that project's code: only to an
    /// allowed destination. In the base folder it is knowledge base data, as everywhere.
    @Test func aWorkMacSendsAProjectFolderOnlyToAnAllowedDestination() async throws {
        try MachineProfile(kind: .work, name: "work").save(home: home)
        let project = home.appending(path: "Projects/orders-api")
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        let inProject = try KnowledgeAsk.newChat(note: Self.note, cwd: project, env: env())
        await #expect(throws: KnowledgeAsk.Failure.self) {
            try await KnowledgeAsk.ask("Q?", noteText: "", in: inProject, agent: Self.agent, env: self.env())
        }
        #expect(!fm.fileExists(atPath: home.appending(path: "count").path), "Pi never started")

        var note = Self.note
        note.baseRoot = home.appending(path: "kb").path
        let inBase = try KnowledgeAsk.newChat(note: note, cwd: home.appending(path: "kb"), env: env())
        #expect(try await KnowledgeAsk.ask("Q?", noteText: "", in: inBase, agent: Self.agent, env: env()).error == nil)

        let account = SendDestination(harness: .pi, provider: "opencode-go", account: "me", org: "acme")
        try LabSettings(allowedDestinations: [account], piAccounts: [PiAccount(provider: "opencode-go", account: "me", org: "acme")]).save(env: env())
        #expect(try await KnowledgeAsk.ask("Q?", noteText: "", in: inProject, agent: Self.agent, env: env()).error == nil)
    }

    /// Review finding 15: Lab settings that can't be read stop the send before Pi starts.
    @Test func unreadableLabSettingsSendNothing() async throws {
        let file = LabSettings.file(env: env())
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ broken".utf8).write(to: file)
        let chat = try KnowledgeAsk.newChat(note: Self.note, cwd: home, env: env())
        do {
            _ = try await KnowledgeAsk.ask("Q?", noteText: "", in: chat, agent: Self.agent, env: env())
            Issue.record("sent")
        } catch {
            #expect((error as? KnowledgeAsk.Failure)?.message.hasPrefix("Not sent:") == true)
        }
        #expect(KnowledgeAsk.entries(chat).isEmpty && !fm.fileExists(atPath: home.appending(path: "count").path))
    }

    @Test func stopEndsPiAndTheAnswerIsNeverForked() async throws {
        try mode("slow")
        let chat = try KnowledgeAsk.newChat(note: Self.note, cwd: home, env: env())
        let scope = Cancellation.Scope()
        let started = Date()
        let marker = home.appending(path: "args-1.txt").path
        Task {
            // Once Pi has started (it counts its calls first).
            for _ in 0..<200 where !FileManager.default.fileExists(atPath: marker) {
                try? await Task.sleep(for: .milliseconds(50))
            }
            scope.cancel()
        }
        let entry = try await Cancellation.$scope.withValue(scope) {
            try await KnowledgeAsk.ask("Slow?", noteText: "", in: chat, agent: Self.agent, env: self.env())
        }
        #expect(entry.error == "Stopped." && !entry.isGood)
        #expect(SendLog.records(env: env()).count == 1, "the stopped question went out: it is logged")
        #expect(Date().timeIntervalSince(started) < 25, "Pi was stopped, not waited for")
        try mode("")
        _ = try await KnowledgeAsk.ask("Again?", noteText: "", in: chat, agent: Self.agent, env: env())
        #expect(!(try args(2)).contains("--fork"), "the stopped answer isn't forked")
    }

    private final class StepLog: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ line: String) { lock.withLock { lines.append(line) } }
        var all: [String] { lock.withLock { lines } }
    }
}
