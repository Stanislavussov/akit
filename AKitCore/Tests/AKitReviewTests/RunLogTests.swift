import AKitFoundation
@testable import AKitReview
import Foundation
import Testing

/// What a run did, for the user to read after it and while it runs (`ReviewRunLog`, the live log).
struct ReviewLiveLogTests {
    @Test func piEventsBecomeLinesWithoutArguments() {
        func line(_ json: String) -> String? { ReviewPasses.liveLine(json) }
        #expect(line(#"{"type":"tool_execution_start","toolName":"read","args":{"path":"src/A.swift"}}"#) == "read src/A.swift")
        #expect(line(#"{"type":"tool_execution_start","toolName":"mcp__gitlab__get_merge_request","args":{"iid":7}}"#)
                == "MCP gitlab: get_merge_request", "MCP arguments stay out of the title")
        #expect(line(#"{"type":"tool_execution_start","toolName":"akit_submit_findings","args":{"findings":[{},{}]}}"#) == "submits 2 findings")
        #expect(line(#"{"type":"tool_execution_end","toolName":"mcp__gitlab__get_merge_request","isError":true}"#)
                == "mcp__gitlab__get_merge_request failed")
        #expect(line(#"{"type":"tool_execution_end","toolName":"read","isError":false}"#) == nil, "without details only failures")
        #expect(ReviewPasses.liveEvent(#"{"type":"tool_execution_end","toolName":"read","isError":false}"#)?.title == "\u{21B3} read answered")
        #expect(line(#"{"type":"message_end","message":{"role":"assistant","model":"m1","usage":{"input":1200,"output":30}}}"#)?
            .hasPrefix("model answered (m1) · 1.2k in") == true)
        #expect(line(#"{"type":"message_end","message":{"role":"assistant","stopReason":"error","errorMessage":"401 Unauthorized"}}"#)
                == "model error: 401 Unauthorized")
        #expect(line("plain text") == nil)
    }

    @Test func eachLineCarriesItsDetails() throws {
        func event(_ json: String) -> (title: String, detail: String?)? { ReviewPasses.liveEvent(json) }
        let call = try #require(event(#"{"type":"tool_execution_start","toolName":"mcp__gitlab__get_merge_request","args":{"iid":7}}"#))
        #expect(call.detail?.contains("\"iid\" : 7") == true, "the arguments open under the line")
        let findings = try #require(event(#"{"type":"tool_execution_start","toolName":"akit_submit_findings","args":{"findings":[{"title":"Name says get, it saves","severity":"medium","file":"A.swift","line":4,"confidence":0.5,"why":"Callers don't expect a write."}]}}"#))
        #expect(findings.title == "submits 1 finding")
        #expect(findings.detail == "[MEDIUM] Name says get, it saves\n  A.swift:4 · confidence 0.50\n  Callers don't expect a write.")
        let result = try #require(event(#"{"type":"tool_execution_end","toolName":"read","isError":false,"result":{"content":[{"type":"text","text":"let a = 1"}]}}"#))
        #expect(result.title == "\u{21B3} read answered · 9 chars" && result.detail == "let a = 1")
        let answer = try #require(event(#"{"type":"message_end","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Check the caller."},{"type":"text","text":"done"}]}}"#))
        #expect(answer.detail == "Thinking:\nCheck the caller.\n\nAnswer:\ndone")
        let secret = try #require(event(#"{"type":"tool_execution_end","toolName":"read","result":{"content":[{"type":"text","text":"token=ghp_abcdefghijklmnopqrstuvwxyz0123456789"}]}}"#))
        #expect(secret.detail?.contains("ghp_abcdefghijklmnopqrstuvwxyz0123456789") == false, "details are masked")

        // Through `Options.progress` as one string; the terminal keeps the title.
        let joined = ReviewLive.line("  role · read A.swift", detail: "body")
        #expect(ReviewLive.split(joined).title == "  role · read A.swift" && ReviewLive.split(joined).detail == "body")
        #expect(ReviewLive.split("plain").detail == nil && ReviewLive.line("t", detail: "") == "t")
    }

    @Test func savedStreamGivesTheSteps() throws {
        let home = TempHome()
        let stream = home.url.appending(path: "passes/contracts.jsonl")
        try FileManager.default.createDirectory(at: stream.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ([#"{"type":"tool_execution_start","toolName":"read","args":{"path":"A.swift"}}"#,
              #"{"type":"message_update","message":{"role":"assistant"}}"#,
              #"{"type":"tool_execution_end","toolName":"read","result":{"content":[{"type":"text","text":"x"}]}}"#].joined(separator: "\n"))
            .write(to: stream, atomically: true, encoding: .utf8)
        let steps = ReviewLive.events(stream: stream)
        #expect(steps.map(\.title) == ["read A.swift", "\u{21B3} read answered · 1 chars"])
    }

    @Test func anEmptyFetchSaysWhatPiDid() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "akit-fetch-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder.appending(path: "passes"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appending(path: "mcp/calls"), withIntermediateDirectories: true)
        try Data("""
        {"type":"tool_execution_start","toolName":"codemode","args":{}}
        {"type":"tool_execution_start","toolName":"mcp__git_cez__get_merge_request","args":{}}

        """.utf8).write(to: folder.appending(path: "passes/fetch.jsonl"))
        try Data(#"{"tool":"mcp__git_cez__get_merge_request","pass":"fetch","reason":"not a server of this run"}"#.utf8 + Data("\n".utf8))
            .write(to: folder.appending(path: "mcp/blocked.jsonl"))
        try Data(#"{"pass":"fetch","tool":"mcp__notes__get_page","server":"notes","input":"{}","text":["{}"],"isError":false}"#.utf8)
            .write(to: folder.appending(path: "mcp/calls/fetch-1-0001.json"))
        let text = ReviewPasses.fetchDiagnosis(folder: folder, access: ReviewMCPAccess())
        #expect(text.contains("codemode ×1") && text.contains("mcp__git_cez__get_merge_request ×1"))
        #expect(text.contains("Blocked by AKit: mcp__git_cez__get_merge_request (not a server of this run)"))
        #expect(text.contains("servers this run doesn't use as GitLab or the tracker: notes"))
        #expect(text.contains("mcp__*gitlab*__*"))
    }
}

extension ReviewProcessTests {
    struct RunLogTests {
        @Test func theLogNamesEachPassAndWhatTheRolesFound() async throws {
            let run = try await ReviewRunFixture.make()
            run.playTypicalRun()
            try await ReviewPasses.run(folder: run.folder, env: run.home.env)
            let log = try ReviewRunLog.load(run.folder)
            #expect(log.passes.map(\.name).contains("verifier") && log.passes.contains { $0.name.hasPrefix("role-") })
            #expect(log.passes.first { $0.name == "verifier" }?.thinking == log.verifierThinking)
            #expect(log.roles.first { $0.role == "bug-hunter" }?.found ?? 0 > 0)
            let text = log.markdown
            #expect(text.hasPrefix("# AKit review run \(log.run)"))
            #expect(text.contains("| Pass | Model | Thinking | Time |") && text.contains("## Findings by role"))
        }
    }
}
