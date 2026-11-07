import Foundation
import Testing
import AKitFoundation
import AKitSkills
@testable import AKitLab

/// Port to Pi's model pass: the call through `ModelCall` with a fake `claude` that answers per
/// round, and the feedback loop on the lint's leftovers.
@Suite(.serialized)
struct SkillPortModelTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-port-model-\(UUID().uuidString)")
        try fm.createDirectory(at: home.appending(path: "bin"), withIntermediateDirectories: true)
        let skill = home.appending(path: ".claude/skills/interview/SKILL.md")
        try fm.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("---\nname: interview\ndescription: Ask until clear\nmodel: opus\n---\n# Interview\nUse AskUserQuestion; stop at 0.2.\n".utf8).write(to: skill)
    }

    var env: HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home, variables: ["HOME": home.path],
                           executableSearchPaths: [home.appending(path: "bin"), URL(filePath: "/usr/bin"), URL(filePath: "/bin")])
    }

    let gate = SendGate(destination: SendDestination(harness: .claudeCode, provider: "anthropic", account: "me@example.com", org: "Me"),
                        isWork: false, settings: LabSettings())
    let agent = LabAgent(harness: .claudeCode, model: "haiku", effort: "low", mode: .call)

    /// A fake `claude` whose n-th call answers `answers[n-1]` (the last one after that) and keeps each stdin.
    func fakeClaude(_ answers: [[String: Any]]) throws {
        var cases = ""
        for (index, answer) in answers.enumerated() {
            let json = String(decoding: try JSONSerialization.data(withJSONObject: answer), as: UTF8.self)
            let result = #"{"type":"result","is_error":false,"result":"","structured_output":\#(json),"usage":{"input_tokens":10,"output_tokens":5}}"#
            cases += "  \(index + 1)) printf '%s\\n' '\(result.replacingOccurrences(of: "'", with: "'\\''"))' ;;\n"
        }
        let url = home.appending(path: "bin/claude")
        try Data("""
            #!/bin/sh
            echo x >> "$HOME/calls.txt"
            n=$(wc -l < "$HOME/calls.txt" | tr -d ' ')
            cat > "$HOME/stdin-$n.txt"
            case "$n" in
            \(cases)  *) echo '{"type":"result","is_error":true,"result":"no more"}' ;;
            esac

            """.utf8).write(to: url)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    var calls: Int {
        ((try? String(contentsOf: home.appending(path: "calls.txt"), encoding: .utf8)) ?? "").split(separator: "\n").count
    }

    var draft: SkillPort.Draft { get throws { try SkillPort.port(folder: home.appending(path: ".claude/skills/interview"), env: env) } }

    @Test func aCleanAnswerTakesOneRound() async throws {
        try fakeClaude([[
            "skill_md": "---\nname: interview\ndescription: Ask until clear\nmodel: opus\n---\n# Interview\nAsk one question with numbered options, then stop; stop at 0.2.\n",
            "files": [["path": "references/extra.md", "text": "New"], ["path": "../escape.md", "text": "no"]],
            "changes": ["AskUserQuestion → a question as text"],
        ]])
        let outcome = try await SkillPortModel.run(try draft, agent: agent, gate: gate, env: env)
        #expect(outcome.rounds == 1 && calls == 1)
        #expect(outcome.report.verdict == .pass, "\(outcome.report.lines)")
        // The header goes through the deterministic pass again: `model` stays out.
        #expect(!outcome.draft.skillText.contains("model: opus"))
        #expect(outcome.draft.texts["references/extra.md"] == "New")
        #expect(outcome.draft.texts["../escape.md"] == nil)
        #expect(outcome.draft.changes.contains("Model: AskUserQuestion → a question as text"))
        #expect(SendLog.records(env: env).map(\.purpose) == ["port-skill"])
        let sent = try String(contentsOf: home.appending(path: "stdin-1.txt"), encoding: .utf8)
        #expect(sent.contains("AskUserQuestion") && !sent.contains("\"rule\""))
    }

    @Test func leftoversGoBackOnceThenRemain() async throws {
        let left = "---\nname: interview\ndescription: Ask until clear\n---\n# Interview\nUse AskUserQuestion; stop at 0.2.\n"
        try fakeClaude([["skill_md": left, "files": [], "changes": []], ["skill_md": left, "files": [], "changes": []]])
        let outcome = try await SkillPortModel.run(try draft, agent: agent, gate: gate, env: env)
        #expect(outcome.rounds == 2 && calls == 2)
        #expect(outcome.report.verdict == .warnings)
        #expect(outcome.report.hits.map(\.rule) == ["AskUserQuestion"])
        // The second call carries the first one's leftovers.
        let second = try String(contentsOf: home.appending(path: "stdin-2.txt"), encoding: .utf8)
        #expect(second.contains("\"rule\" : \"AskUserQuestion\""))
    }

    @Test func aLostNumberIsReported() async throws {
        try fakeClaude([["skill_md": "---\nname: interview\ndescription: Ask until clear\n---\n# Interview\nAsk as text; stop at 0.3.\n",
                         "files": [], "changes": []]])
        let outcome = try await SkillPortModel.run(try draft, agent: agent, gate: gate, env: env)
        #expect(outcome.report.missingNumbers == ["0.2"])
        #expect(outcome.report.verdict == .warnings)
    }

    @Test func aBrokenAnswerFails() async throws {
        try fakeClaude([["nothing": true]])
        await #expect(throws: SkillPort.Failure.self) { try await SkillPortModel.run(try draft, agent: agent, gate: gate, env: env) }
    }
}
