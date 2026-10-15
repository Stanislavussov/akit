import AKitFoundation
import AKitReview
import Foundation
import Testing
@testable import AKitCommandLine

extension AKitCLITests {
    /// `akit review` with an in-memory Keychain and a fake GitLab.
    func review(_ arguments: [String], secrets: MemorySecretStore, stdin: String = "",
                fetch: @escaping ReviewFetch = { _ in throw URLError(.notConnectedToInternet) }) async -> (code: Int32, out: String, err: String) {
        var out: [String] = [], err: [String] = []
        let code = await AKitCLI.run(["review"] + arguments, env: env, cwd: home, out: { out.append($0) }, err: { err.append($0) },
                                     input: { Data(stdin.utf8) }, review: ReviewServices(secrets: secrets, fetch: fetch))
        return (code, out.joined(separator: "\n"), err.joined(separator: "\n"))
    }

    @Test func reviewTokensGoToTheKeychainOnly() async throws {
        let secrets = MemorySecretStore()
        let saved = await review(["token", "gitlab", "https://gitlab.test"], secrets: secrets, stdin: "glpat-123\n")
        #expect(saved.code == 0 && !saved.out.contains("glpat-123"), "\(saved)")
        #expect(secrets.value("gitlab_gitlab_test") == "glpat-123")
        #expect(await review(["token", "gitlab", "https://gitlab.test"], secrets: secrets).err.contains("Pipe the token"))
        #expect(await review(["token", "jira", "x"], secrets: secrets).code == 2)
        _ = await review(["token", "gitlab", "https://gitlab.test", "--delete"], secrets: secrets)
        #expect(secrets.value("gitlab_gitlab_test") == nil)
    }

    @Test func reviewConfigShowNamesSources() async throws {
        try write(".akit/local/review/projects/app.yaml", "gitlab: { host: https://gitlab.test, project_path: team/app }\nreview: { max_inline: 4 }\n")
        let shown = await review(["config", "show", "--project", "app", "--scenario", "bugfix", "--brain", home.appending(path: "none").path],
                                 secrets: MemorySecretStore())
        #expect(shown.code == 0, "\(shown)")
        #expect(shown.out.contains("scenario: bugfix  [run]"))
        #expect(shown.out.contains("max_inline: 4  [project]"))
        #expect(shown.out.contains("bug-hunter [built-in] required by bugfix"))
        #expect(await review(["config", "show", "--project", "nope"], secrets: MemorySecretStore()).err.contains("no project profile nope"))
    }

    @Test func reviewNeedsAMergeRequestAndAToken() async throws {
        #expect(await review(["https://gitlab.test/a/-/issues/1"], secrets: MemorySecretStore()).err.contains("not a merge request address"))
        let noToken = await review(["https://gitlab.test/team/app/-/merge_requests/7", "--brain", home.path], secrets: MemorySecretStore())
        #expect(noToken.code == 2 && noToken.err.contains("no GitLab token"), "\(noToken)")
        #expect(await review(["--help"], secrets: MemorySecretStore()).out.contains("akit review token gitlab HOST"))
    }
}
