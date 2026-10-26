@testable import AKitReview
import Foundation
import Testing

/// GitLab's own MCP server (`/api/v4/mcp`) answers in GraphQL's shape, one part per call
/// (`include`): AKit reads it as REST's. The keys are those of a real answer; the values are made up.
struct GraphQLShapeTests {
    static let head = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"
    static let input = #"{"project_id":"team/app","merge_request_iid":7}"#
    static var base: [String: Any] { ["id": "gid://gitlab/MergeRequest/901", "iid": "7", "title": "Login", "description": "Adds login",
                                      "state": "opened", "draft": false, "sourceBranch": "feature/COL-1-login", "targetBranch": "main",
                                      "webUrl": "https://gitlab.example/team/app/-/merge_requests/7",
                                      "author": ["id": "gid://gitlab/User/5", "name": "Ann", "username": "ann"],
                                      "createdAt": "2026-10-20T10:00:00Z", "updatedAt": "2026-10-21T10:00:00Z", "mergedAt": NSNull(),
                                      "conflicts": false] }

    static func call(_ extra: [String: Any]) -> ReviewMCPCall {
        let object = base.merging(extra) { $1 }
        let text = String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        return ReviewMCPCall(pass: "fetch", tool: "mcp__gitlab__get_merge_request", input: input, text: [text], structured: text, isError: false)
    }

    static var page: [String: Any] { ["hasNextPage": false, "endCursor": NSNull()] }

    @Test func readsTheMergeRequestItsPartsAndTheHead() throws {
        let diffs: [String: Any] = ["nodes": [
            ["aMode": "100644", "bMode": "100644", "collapsed": false, "deletedFile": false, "diff": "@@ -1 +1 @@\n-a\n+b\n", "newFile": false,
             "newPath": "src/login.ts", "oldPath": "src/login.ts", "renamedFile": false, "tooLarge": false],
        ], "pageInfo": Self.page]
        let stats: [String: Any] = ["nodes": [["newPath": "src/login.ts", "oldPath": "src/login.ts", "diff": NSNull(), "tooLarge": false]],
                                    "pageInfo": Self.page]
        let commits: [String: Any] = ["nodes": [
            ["id": "gid://gitlab/CommitPresenter/1", "sha": Self.head, "shortId": "a1b2c3d4", "title": "Fix", "authorName": "Ann",
             "authoredDate": "2026-10-21T09:00:00Z", "webUrl": "https://gitlab.example/c/1"],
            ["id": "gid://gitlab/CommitPresenter/2", "sha": "0000000000000000000000000000000000000001", "shortId": "00000000",
             "title": "Start", "authorName": "Ann", "authoredDate": "2026-10-20T09:00:00Z", "webUrl": "https://gitlab.example/c/2"],
        ], "pageInfo": Self.page]
        let note: [String: Any] = ["id": "gid://gitlab/DiffNote/77", "body": "Why?", "system": false, "internal": false,
                                   "author": ["id": "gid://gitlab/User/6", "name": "Bob", "username": "bob"],
                                   "createdAt": "2026-10-21T11:00:00Z", "updatedAt": "2026-10-21T11:00:00Z", "webUrl": "https://gitlab.example/n/77",
                                   "discussion": ["id": "gid://gitlab/Discussion/abc123"],
                                   "position": ["positionType": "TEXT", "newPath": "src/login.ts", "oldPath": "src/login.ts", "newLine": 1,
                                                "oldLine": NSNull(),
                                                "diffRefs": ["baseSha": "1111111111111111111111111111111111111111", "startSha": "1111111111111111111111111111111111111111",
                                                             "headSha": Self.head]]]
        let discussions: [String: Any] = ["nodes": [["id": "gid://gitlab/Discussion/abc123", "resolvable": true, "resolved": false,
                                                     "notes": ["nodes": [note], "pageInfo": Self.page]]], "pageInfo": Self.page]
        let user = ReviewMCPCall(pass: "fetch", tool: "mcp__gitlab__get_user", input: #"{"me":true}"#,
                                 text: [#"{"id":6,"username":"bob","name":"Bob","state":"active","web_url":"https://gitlab.example/bob"}"#],
                                 structured: nil, isError: false)
        let data = ReviewMCPData.read([Self.call([:]), Self.call(["diffs": stats]), Self.call(["diffs": diffs]), Self.call(["commits": commits]),
                                       Self.call(["discussions": discussions]), user], iid: 7, project: "team/app")
        let mr = try #require(data.mergeRequest)
        #expect(mr.title == "Login" && mr.sourceBranch == "feature/COL-1-login" && mr.targetBranch == "main" && mr.author == "ann")
        #expect(mr.draft == false)
        #expect(mr.diffRefs?.headSHA == Self.head, "the newest commit is the head without diff refs")
        #expect(data.diffs.count == 1 && data.diffs.first?.diff.contains("+b") == true, "the patch wins over the stats")
        let thread = try #require(data.discussions.first)
        #expect(thread.id == "abc123" && thread.notes.first?.id == 77 && thread.notes.first?.author == "bob")
        #expect(thread.notes.first?.resolvable == true && thread.notes.first?.position?.headSHA == Self.head)
        #expect(thread.notes.first?.position?.newLine == 1)
        #expect(data.user == "bob")
    }

    @Test func explicitHeadWinsOverCommitsAndOtherProjectsDontCount() {
        let explicit = "ffffffffffffffffffffffffffffffffffffffff"
        let commits: [String: Any] = ["nodes": [["id": "gid://gitlab/CommitPresenter/1", "sha": Self.head]], "pageInfo": Self.page]
        let data = ReviewMCPData.read([Self.call(["commits": commits]), Self.call(["diffHeadSha": explicit, "diffBaseSha": Self.head])],
                                      iid: 7, project: "team/app")
        #expect(data.mergeRequest?.diffRefs?.headSHA == explicit && data.mergeRequest?.diffRefs?.baseSHA == Self.head)
        let elsewhere = ReviewMCPData.read([Self.call([:])], iid: 7, project: "team/other")
        #expect(elsewhere.mergeRequest == nil)
    }

    /// Pi cuts a text answer over 20 KB in the middle for the model and keeps the whole
    /// `CallToolResult` in the structured content: AKit reads the whole one.
    @Test func readsTheWholeAnswerPiCutForTheModel() throws {
        let files = (1...60).map { index -> [String: Any] in
            ["newPath": "src/file\(index).ts", "oldPath": "src/file\(index).ts", "newFile": false, "deletedFile": false, "renamedFile": false,
             "tooLarge": false, "diff": "@@ -1 +1 @@\n-a\n+" + String(repeating: "b", count: 600) + "\n"]
        }
        let object = Self.base.merging(["diffs": ["nodes": files, "pageInfo": Self.page]]) { $1 }
        let whole = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        #expect(whole.utf8.count > 20 * 1024)
        let shown = "Warning: truncated output (original token count: 9000)\nTotal output lines: 1\n\n" + whole.prefix(10_000)
            + "…20000 chars truncated…" + whole.suffix(10_000) + "\n\n[Full output: /tmp/pi-mcp-1.txt (read it with offset/limit)]"
        let result = String(decoding: try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": whole]], "isError": false]),
                            as: UTF8.self)
        let call = ReviewMCPCall(pass: "fetch", tool: "mcp__gitlab__get_merge_request", input: Self.input, text: [shown], structured: result,
                                 isError: false)
        let data = ReviewMCPData.read([call], iid: 7, project: "team/app")
        #expect(data.mergeRequest?.title == "Login")
        #expect(data.diffs.count == 60 && data.cut == 0)

        // An older Pi saved only the cut text: AKit says so instead of "read none".
        let cut = ReviewMCPCall(pass: "fetch", tool: "mcp__gitlab__get_merge_request", input: Self.input, text: [shown], structured: nil,
                                isError: false)
        let lost = ReviewMCPData.read([cut], iid: 7, project: "team/app")
        #expect(lost.diffs.isEmpty && lost.cut == 1)
    }

    @Test func otherServersKeepTheirKeys() {
        let item: [String: Any] = ["id": 305489, "fields": ["System.Title": "Login", "System.WorkItemType": "Task"]]
        #expect(GitLabJSON.restShape(item) as? NSDictionary == item as NSDictionary)
        #expect(GitLabJSON.snakeCase("sourceBranch") == "source_branch" && GitLabJSON.snakeCase("web_url") == "web_url")
    }
}
