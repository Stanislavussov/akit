import AKitFoundation
@testable import AKitReview
import Foundation
import Testing

/// Secrets in saved MCP answers, the send log and the pass streams.
struct MaskTests {
    static let token = "glpat-abcdefghijklmnopqrst"
    static let head = "0123456789abcdef0123456789abcdef01234567"

    @Test func masksStringsAndKeepsTheShape() throws {
        let diff = "@@ -1,2 +1,7 @@\n let a = 1\n+let token = \"\(Self.token)\"\n+-----BEGIN RSA PRIVATE KEY-----\n+MIIEowIBAAKCAQEAx1y\n+-----END RSA PRIVATE KEY-----\n+API_TOKEN=supersecretvalue123\n let b = 2"
        let answer: [String: Any] = ["iid": 7, "description": "Use \(Self.token) to test", "diff": diff, "sha": Self.head,
                                     "diff_refs": ["head_sha": Self.head], "labels": ["backend"]]
        let text = String(decoding: try JSONSerialization.data(withJSONObject: answer), as: UTF8.self)
        let call = ReviewMCPCall(pass: "fetch", tool: "mcp__gitlab__get_merge_request", input: #"{"merge_request_iid":7}"#,
                                 text: ["Merge request:\n" + text], structured: text, isError: false)
        let line = String(decoding: try JSONEncoder().encode(call), as: UTF8.self)

        let masked = ReviewMask.jsonLine(line)
        #expect(!masked.contains(Self.token) && !masked.contains("MIIEowIBAAKCAQEAx1y") && !masked.contains("supersecretvalue123"))
        #expect(!masked.contains("\n"), "one line stays one line")
        let back = try JSONDecoder().decode(ReviewMCPCall.self, from: Data(masked.utf8))
        #expect(back.text[0].hasPrefix("Merge request:\n{"))
        for value in back.values {
            let object = try #require(value as? JSONObject)
            #expect(object["sha"] as? String == Self.head && object["iid"] as? Int == 7 && object["labels"] as? [String] == ["backend"])
            let maskedDiff = try #require(object["diff"] as? String)
            #expect(maskedDiff.split(separator: "\n", omittingEmptySubsequences: false).count == diff.split(separator: "\n", omittingEmptySubsequences: false).count)
            #expect(maskedDiff.contains("+[secret hidden]") && maskedDiff.contains(" let b = 2"))
        }
        #expect(ReviewMask.jsonLine(masked) == masked, "masking masked text changes nothing")
        let clean = #"{"b":1,"a":"no secret here \/ at all"}"#
        #expect(ReviewMask.jsonLine(clean) == clean, "a line without a secret stays byte for byte")
        #expect(ReviewMask.jsonLine("not json \(Self.token)") == "not json [secret hidden]")
    }

    @Test func masksARunsSavedAnswersAndSendLog() throws {
        let home = TempHome()
        let folder = home.url.appending(path: "run")
        let mr: [String: Any] = ["iid": 7, "title": "Fix", "description": "Token: \(Self.token)", "state": "opened",
                                 "source_branch": "fix", "target_branch": "main", "web_url": "https://gitlab.test/team/app/-/merge_requests/7",
                                 "diff_refs": ["base_sha": "b0b0b0b0", "start_sha": "c0c0c0c0", "head_sha": Self.head]]
        let text = String(decoding: try JSONSerialization.data(withJSONObject: mr), as: UTF8.self)
        let call = ReviewMCPCall(pass: "fetch", tool: "mcp__gitlab__get_merge_request", input: #"{"project_id":"team/app","merge_request_iid":"7"}"#,
                                 text: [text], structured: nil, isError: false)
        home.write("run/mcp/calls/fetch-1-0001.json", String(decoding: try JSONEncoder().encode(call), as: UTF8.self))
        let first = #"{"request":"r1","tool":"mcp__gitlab__create_draft_note","isError":false,"text":"{\"id\":91}"}"#
        let second = #"{"request":"r2","tool":"mcp__gitlab__create_draft_note","isError":true,"text":"401 for PRIVATE-TOKEN \#(Self.token)"}"#
        home.write("run/send/log.jsonl", first + "\n" + second + "\n")

        ReviewMask.saved(in: folder)
        let saved = try String(contentsOf: folder.appending(path: "mcp/calls/fetch-1-0001.json"), encoding: .utf8)
        #expect(!saved.contains(Self.token) && saved.contains("Token: [secret hidden]"))
        let data = ReviewMCPData.read(ReviewMCPData.calls(in: folder), iid: 7)
        #expect(data.mergeRequest?.diffRefs?.headSHA == Self.head, "AKit still reads the masked answer")
        let log = try String(contentsOf: folder.appending(path: "send/log.jsonl"), encoding: .utf8)
        let lines = log.split(separator: "\n")
        #expect(lines.count == 2 && lines[0] == Substring(first), "a line without a secret stays as the extension wrote it")
        #expect(!log.contains(Self.token))

        // A file written after the last masking is masked the next time; an old one isn't read again.
        home.write("run/mcp/calls/fetch-1-0002.json", saved.replacingOccurrences(of: "[secret hidden]", with: Self.token))
        _ = try? ReviewWorkflow.load(folder)
        let later = try String(contentsOf: folder.appending(path: "mcp/calls/fetch-1-0002.json"), encoding: .utf8)
        #expect(!later.contains(Self.token))
    }
}
