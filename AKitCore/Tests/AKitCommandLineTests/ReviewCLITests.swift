import AKitFoundation
import AKitReview
import Foundation
import Testing
@testable import AKitCommandLine

extension AKitCLITests {
    /// `akit review` in the fake home.
    func review(_ arguments: [String]) async -> (code: Int32, out: String, err: String) {
        var out: [String] = [], err: [String] = []
        let code = await AKitCLI.run(["review"] + arguments, env: env, cwd: home, out: { out.append($0) }, err: { err.append($0) })
        return (code, out.joined(separator: "\n"), err.joined(separator: "\n"))
    }

    @Test func reviewConfigShowNamesSources() async throws {
        try write(".akit/local/review/projects/app.yaml", """
        gitlab: { host: https://gitlab.test, project_path: team/app }
        mcp: { servers: [gitlab], write: [create_draft_note] }
        review: { max_inline: 4 }

        """)
        let shown = await review(["config", "show", "--project", "app", "--scenario", "bugfix", "--brain", home.appending(path: "none").path])
        #expect(shown.code == 0, "\(shown)")
        #expect(shown.out.contains("scenario: bugfix  [run]"))
        #expect(shown.out.contains("max_inline: 4  [project]"))
        #expect(shown.out.contains("bug-hunter [built-in] required by bugfix"))
        #expect(shown.out.contains("servers: gitlab") && shown.out.contains("write (Send Drafts only): create_draft_note"))
        #expect(await review(["config", "show", "--project", "nope"]).err.contains("no project profile nope"))
    }

    /// `--note`, `--note-file`, `--link`, `--extra-server`: the run's own context.
    @Test func reviewContextOptions() async throws {
        try write(".akit/local/review/projects/app.yaml", """
        gitlab: { host: https://gitlab.test, project_path: team/app }
        mcp: { extra_servers: [confluence] }

        """)
        try write("notes.md", "CSV is decided.\n")
        let none = home.appending(path: "none").path
        let shown = await review(["config", "show", "--project", "app", "--brain", none, "--note", "Focus on retries.", "--note-file", "notes.md",
                                  "--link", "https://www.figma.com/design/AbC/Checkout", "--extra-server", "figma,playwright"])
        #expect(shown.code == 0, "\(shown)")
        #expect(shown.out.contains("context server (read only): confluence  [project]"))
        #expect(shown.out.contains("context server (read only): figma  [run]"))
        #expect(shown.out.contains("context server (read only): playwright  [run]  ! a browser, file or web fetch server"))
        #expect(shown.out.contains("Links [run]:\n  https://www.figma.com/design/AbC/Checkout"))
        #expect(shown.out.contains("Notes [run]: 34 characters"), "both notes, joined: \(shown.out)")
        let base = await review(["config", "show", "--project", "app", "--brain", none, "--extra-server", "gitlab-corp"])
        #expect(base.out.contains("! extra server gitlab-corp is one of the run's own servers"), "\(base.out)")
        let http = await review(["config", "show", "--project", "app", "--brain", none, "--link", "http://intranet/spec"])
        #expect(http.code != 0 && http.err.contains("not an https link"))
        #expect(await review(["config", "show", "--brain", none, "--note-file", "missing.md"]).err.contains("Can't read the notes file"))
        #expect(await review(["--help"]).out.contains("--link URL"))
    }

    @Test func reviewNeedsAMergeRequest() async throws {
        #expect(await review(["https://gitlab.test/a/-/issues/1"]).err.contains("not a merge request address"))
        let help = await review(["--help"])
        #expect(help.out.contains("akit review check [--project P]") && !help.out.contains("token"))
        #expect(await review(["token", "gitlab", "https://gitlab.test"]).code != 0, "tokens are gone: Pi's MCP servers connect")
    }

    /// `akit review check`: Pi's servers and what review may do with each tool; never a command line.
    @Test func reviewCheckListsPiServers() async throws {
        try write("bin/pi", """
        #!/bin/sh
        echo '{"servers":[{"name":"gitlab","enabled":true,"state":"connected","transport":"npx mcp-gitlab --token glpat-SECRET","tools":["get_merge_request","mr_discussions","create_draft_note","bulk_publish_draft_notes"]},{"name":"jira","enabled":true,"state":"failed","tools":[]},{"name":"fetch","enabled":true,"state":"connected","tools":["fetch"]}],"errors":[]}'

        """)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.appending(path: "bin/pi").path)
        var environment = env
        environment.executableSearchPaths.insert(home.appending(path: "bin"), at: 0)
        var out: [String] = [], err: [String] = []
        let code = await AKitCLI.run(["review", "check"], env: environment, cwd: home, out: { out.append($0) }, err: { err.append($0) })
        let text = out.joined(separator: "\n")
        #expect(code == 0, "\(text) \(err)")
        #expect(text.contains("gitlab: connected · 4 tools: 2 read, 1 write drafts, 1 blocked"))
        #expect(text.contains("read: get_merge_request, mr_discussions") && text.contains("write: create_draft_note"))
        #expect(text.contains("jira: failed · not used by this project") && text.contains("fetch: connected · not used by this project"))
        #expect(!text.contains("glpat-SECRET") && !text.contains("npx"), "never a server's command line")
    }

    /// `akit review local PATH --show`: the range and the commits, nothing started.
    @Test func reviewLocalShowsTheRange() async throws {
        let repo = home.appending(path: "work/shop")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        func git(_ arguments: String...) {
            _ = ProcessRunner.runAndWait(URL(filePath: "/usr/bin/git"), arguments: ["-C", repo.path] + arguments, environment: env.gitVariables, timeout: 60)
        }
        git("init", "-q", "-b", "main")
        try write("work/shop/a.txt", "a\n")
        git("add", ".")
        git("commit", "-q", "-m", "First")
        git("checkout", "-q", "-b", "topic")
        try write("work/shop/a.txt", "b\n")
        git("commit", "-q", "-am", "Change a")
        let shown = await review(["local", repo.path, "--show"])
        #expect(shown.code == 0, "\(shown)")
        #expect(shown.out.contains("on topic") && shown.out.contains("Base: main"))
        #expect(shown.out.contains("1 commit since main (") && shown.out.contains("Change a"))
        #expect(shown.out.contains("To review: commits only."))
        #expect(await review(["local", repo.path, "--what", "uncommitted", "--show"]).err.contains("Nothing to review with --what uncommitted"))
        #expect(await review(["local", repo.path, "--what", "some"]).err.contains("--what is all, commits or uncommitted"))
        #expect(!FileManager.default.fileExists(atPath: home.appending(path: ".akit/local/review/runs").path), "--show starts nothing")
    }
}
