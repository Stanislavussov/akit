import Foundation
import Testing
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
        #expect(system.contains("/tmp/kb/work") && system.contains("payments/orders-api") && system.contains("Do not change files"))
        #expect(system.contains("language of the question"))
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
        #expect(records.map(\.purpose) == ["knowledge-ask", "knowledge-ask"], "the failed answer recorded no usage")
        #expect(records.first?.usage.output == 9 && records.first?.runID == chat.id && records.first?.session == "s1")

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
