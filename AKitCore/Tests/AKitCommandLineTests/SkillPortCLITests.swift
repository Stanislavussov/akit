import Foundation
import Testing
import AKitFoundation
import AKitLab
@testable import AKitCommandLine

/// `akit skills port` in a temporary fake home: `--no-model`, `--check-only`, install with
/// `--yes`, and one model round with a fake `claude`.
@Suite(.serialized)
struct SkillPortCLITests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-port-cli-\(UUID().uuidString)")
        try fm.createDirectory(at: home.appending(path: "bin"), withIntermediateDirectories: true)
        try write(".claude/skills/interview/SKILL.md", """
            ---
            name: interview
            description: Ask until clear
            allowed-tools: Read
            ---
            # Interview
            Use AskUserQuestion; stop at 0.2. Then /oh-my-claudecode:ralplan.
            """)
    }

    var env: HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home, variables: ["HOME": home.path],
                           executableSearchPaths: [home.appending(path: "bin"), URL(filePath: "/usr/bin"), URL(filePath: "/bin")])
    }

    func write(_ path: String, _ text: String) throws {
        let url = home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func akit(_ arguments: String...) async -> (code: Int32, out: String, err: String) {
        var out: [String] = [], err: [String] = []
        let code = await AKitCLI.run(arguments, env: env, cwd: home, out: { out.append($0) }, err: { err.append($0) },
                                     trash: { url in
                                         let to = home.appending(path: "Trash/\(url.lastPathComponent)")
                                         try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                                         try fm.moveItem(at: url, to: to)
                                         return to
                                     })
        return (code, out.joined(separator: "\n"), err.joined(separator: "\n"))
    }

    var installed: URL { home.appending(path: ".pi/agent/skills/interview/SKILL.md") }

    @Test func noModelShowsTheCheckAndWritesOnlyWithYes() async throws {
        let shown = await akit("skills", "port", ".claude/skills/interview", "--no-model")
        #expect(shown.code == 0, "\(shown.err)")
        #expect(shown.out.contains("Check: warnings") && shown.out.contains("[AskUserQuestion]"))
        #expect(shown.out.contains("Frontmatter: dropped allowed-tools") && shown.out.contains("Then /skill:ralplan."))

        let preview = await akit("skills", "port", "interview", "--no-model", "--to", "global")
        #expect(preview.out.contains("Creates ~/.pi/agent/skills/interview") && preview.out.contains("Run again with --yes"))
        #expect(!fm.fileExists(atPath: installed.path))

        let done = await akit("skills", "port", "interview", "--no-model", "--to", "global", "--yes")
        #expect(done.code == 0, "\(done.err)")
        #expect(try String(contentsOf: installed, encoding: .utf8).contains("/skill:ralplan"))
        let again = await akit("skills", "port", "interview", "--no-model", "--to", "global", "--yes", "--json")
        #expect(again.out.contains("\"replaces\" : true") && again.out.contains("\"installed\" : true"))
        #expect(fm.fileExists(atPath: home.appending(path: "Trash/interview/SKILL.md").path))

        let project = home.appending(path: "Projects/app")
        let local = await akit("skills", "port", "interview", "--no-model", "--to", "project", project.path, "--yes")
        #expect(local.code == 0, "\(local.err)")
        #expect(fm.fileExists(atPath: project.appending(path: ".pi/skills/interview/SKILL.md").path))
    }

    @Test func checkOnlyReportsAndFails() async throws {
        try write("pi/good/SKILL.md", "---\nname: good\ndescription: d\n---\nRead it.\n")
        let good = await akit("skills", "port", "--check-only", "pi/good")
        #expect(good.code == 0 && good.out.contains("Check: pass"))
        try write("pi/bad/SKILL.md", "---\nname: other\ndescription: d\n---\nSee references/x.md\n")
        let bad = await akit("skills", "port", "--check-only", "pi/bad", "--json")
        #expect(bad.code == 1)
        #expect(bad.out.contains("not the folder's name") && bad.out.contains("references/x.md"))
    }

    @Test func checksItsArguments() async {
        #expect(await akit("skills", "port", "--help").out.contains("--check-only PATH"))
        #expect(await akit("skills", "port", "nope", "--no-model").err.contains("No skill named nope"))
        #expect(await akit("skills", "port", "interview", "--no-model", "--yes").err.contains("--to global"))
        #expect(await akit("skills", "port", "interview", "--to", "moon").err.contains("--to is global"))
        #expect(await akit("skills", "port", "interview", "--no-model", "--model", "pi").err.contains("--no-model"))
        #expect(await akit("skills", "port", "--check-only", "x", "interview").err.contains("goes alone"))
    }

    @Test func oneModelRound() async throws {
        let answer = #"{"skill_md":"---\nname: interview\ndescription: Ask until clear\n---\n# Interview\nAsk one question as text; stop at 0.2. Then /skill:ralplan.\n","files":[],"changes":["question as text"]}"#
        let claude = home.appending(path: "bin/claude")
        try Data("""
            #!/bin/sh
            if [ "$1 $2" = "auth status" ]; then
              echo '{"loggedIn":true,"apiProvider":"firstParty","email":"me@example.com","orgName":"Me"}'; exit 0
            fi
            cat > /dev/null
            printf '%s\\n' '{"type":"result","is_error":false,"result":"","structured_output":\(answer),"usage":{"input_tokens":3,"output_tokens":2}}'

            """.utf8).write(to: claude)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        let result = await akit("skills", "port", "interview", "--model", "claude-code:haiku")
        #expect(result.code == 0, "\(result.err)")
        #expect(result.out.contains("model: Claude Code · haiku, 1 round") && result.out.contains("Check: pass"))
        #expect(result.out.contains("Model: question as text"))
        #expect(SendLog.records(env: env).map(\.purpose) == ["port-skill"])
    }
}
