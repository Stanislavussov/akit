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
}
