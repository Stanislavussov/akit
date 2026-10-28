import AKitFoundation
import AKitLab
@testable import AKitReview
import Foundation
import Testing

extension ReviewProcessTests {
    /// Debug… of a run (`ReviewDebug`): the full log, AKit's checks, the debug pass.
    struct DebugTests {
        static let token = "ghp_" + String(repeating: "a1B2", count: 9)

        /// A typical run with one MCP answer that holds a token and a role pass that read nothing.
        func playedRun() async throws -> ReviewRunFixture {
            let run = try await ReviewRunFixture.make()
            run.playTypicalRun()
            try await ReviewPasses.run(folder: run.folder, env: run.home.env)
            let call = ReviewMCPCall(pass: "fetch", tool: "mcp__gitlab__get_merge_request", input: #"{"iid":7,"project":"team/app"}"#,
                                     text: ["title: Log less, token \(Self.token)"], structured: nil, isError: true)
            try JSONEncoder().encode(call).write(to: run.folder.appending(path: "mcp/calls/fetch-9-0099.json"))
            return run
        }

        @Test func theFullLogHasTranscriptsArgumentsAndAnswersButNoSecret() async throws {
            let run = try await playedRun()
            let text = try ReviewDebug.fullLog(run.folder)
            #expect(text.hasPrefix("# AKit review run "))
            #expect(text.contains("## Pass transcripts") && text.contains("### role-bug-hunter"))
            #expect(text.contains(#"- Calls read: {"path":"../context/diff.patch"}"#), "tool calls keep their arguments")
            #expect(text.contains("- Model: Intent: log less."))
            #expect(text.contains("## MCP calls with arguments and answers") && text.contains(#""project":"team/app""#))
            #expect(text.contains("title: Log less, token"))
            #expect(!text.contains(Self.token), "masked")
            #expect(text.contains("### prompts/verifier.md") && text.contains("## Findings (findings.json)"))
            #expect(text.contains("## Checks without a model") && text.contains("MCP call failed: fetch · mcp__gitlab__get_merge_request"))
        }

        @Test func longItemsLoseTheirMiddle() {
            let text = String(repeating: "a", count: 5_000) + "MIDDLE" + String(repeating: "z", count: 5_000)
            let cut = ReviewDebug.middleCut(text, 1_000)
            #expect(cut.hasPrefix("aaa") && cut.hasSuffix("zzz") && !cut.contains("MIDDLE") && cut.contains("characters cut"))
            #expect(ReviewDebug.middleCut("short", 1_000) == "short")
        }

        @Test func checksFindFailedPassesAndRolesThatReadNothing() async throws {
            let run = try await playedRun()
            // The tests role read nothing; the verifier failed.
            var log = try #require(ReviewJSON.read(ReviewPassLog.self, from: run.folder.appending(path: "passes.json")))
            for index in log.passes.indices {
                if log.passes[index].name == "role-tests" { log.passes[index].paths = [] }
                if log.passes[index].name == "verifier" { log.passes[index].error = "quota exceeded" }
            }
            try ReviewJSON.write(log, to: run.folder.appending(path: "passes.json"))
            let checks = try ReviewDebug.checks(run.folder)
            #expect(checks.first?.level == .high && checks.first?.title == "Pass verifier failed")
            #expect(checks.contains { $0.title == "Pass role-tests read no file" && $0.level == .medium })
            #expect(checks.contains { $0.title.hasPrefix("MCP call failed") })
            #expect(!checks.contains { $0.title == "No diff in the context pack" }, "Gather wrote the diff")
        }

        @Test func theDebugPassReadsOnlyTheMaskedPartsWithTheVerifierModel() async throws {
            let run = try await playedRun()
            let report = try await ReviewDebug.run(run.folder, env: run.home.env)
            #expect(report.id == "d1" && report.answer == "Intent: log less." && report.error == nil)
            #expect(report.model == "fake/strong" && report.credits > 0)
            let args = run.args("debug-1")
            for flag in ["--no-mcp", "--no-skills", "--no-extensions", "fake/strong", "high", "read,grep,find,ls"] {
                #expect(args.contains(flag), "\(flag)")
            }
            #expect(!args.contains("builtin:mcp") && !args.contains("--fork"))
            let env = try String(contentsOf: run.home.url.appending(path: "fake/env-debug-1.txt"), encoding: .utf8)
            let roots = try #require(env.split(separator: "\n").first { $0.hasPrefix("AKIT_REVIEW_ROOTS=") })
            #expect(roots.contains("/debug") && !roots.contains("/gitlab") && !roots.contains("/tracker") && !roots.contains("/worktree"))
            #expect(env.contains(#""inPasses":false"#))
            let full = try String(contentsOf: run.folder.appending(path: "debug/full-log.md"), encoding: .utf8)
            #expect(full.contains("## Pass transcripts") && !full.contains(Self.token))
            #expect(ReviewDebug.reports(run.folder).map(\.id) == ["d1"])
            #expect(try String(contentsOf: run.folder.appending(path: "debug/report-1.md"), encoding: .utf8).contains("## Pi's analysis"))
            #expect(SendLog.records(env: run.home.env).contains { $0.purpose == "review-debug" && $0.runID == run.folder.lastPathComponent })
            // The run's own numbers stay those of the review.
            #expect(!(ReviewJSON.read(ReviewPassLog.self, from: run.folder.appending(path: "passes.json"))?.passes.contains { $0.name.hasPrefix("debug") } ?? true))
            #expect(try await ReviewDebug.run(run.folder, env: run.home.env).id == "d2")
        }

        /// A failed pass is no analysis; a report AKit can't read is never overwritten.
        @Test func aFailedDebugPassKeepsOnlyTheError() async throws {
            let run = try await playedRun()
            try FileManager.default.createDirectory(at: run.folder.appending(path: "debug"), withIntermediateDirectories: true)
            try Data("not json".utf8).write(to: run.folder.appending(path: "debug/report-1.json"))
            run.home.write("fake/fail-debug-2", "")
            let report = try await ReviewDebug.run(run.folder, env: run.home.env)
            #expect(report.id == "d2" && report.answer == nil && report.error == "quota exceeded")
            #expect(try String(contentsOf: run.folder.appending(path: "debug/report-1.json"), encoding: .utf8) == "not json")
        }
    }
}

extension ReviewProcessTests {
    struct DebugGuardTests {
        /// The extension lets a debug pass call only the reading tools, whatever Pi offers it.
        @Test func theDebugPassCallsNoAKitTool() throws {
            let node = try #require(ExtensionKnowledgeTests.node, "node is needed: Pi runs on it")
            let home = TempHome()
            let ext = home.write("ext/akit-review.ts", ReviewExtension.source)
            let harness = home.write("ext/harness.mjs", """
            import { pathToFileURL } from "node:url";
            const mod = await import(pathToFileURL(process.argv[2]).href);
            const handlers = {};
            const pi = { registerTool() {}, on: (e, h) => { handlers[e] = h; }, appendEntry() {}, getAllTools: () => [] };
            mod.default(pi);
            const out = {};
            for (const name of ["akit_submit_findings", "akit_report_context_gap", "mcp__gitlab__get_merge_request", "codemode", "read"]) {
              const r = await handlers.tool_call({ toolName: name, toolCallId: "1", input: { path: "debug/full-log.md" } }, { cwd: process.argv[3] });
              out[name] = r?.block === true;
            }
            console.log(JSON.stringify(out));
            """)
            let run = home.url.appending(path: "run")
            try FileManager.default.createDirectory(at: run.appending(path: "debug"), withIntermediateDirectories: true)
            try Data("log".utf8).write(to: run.appending(path: "debug/full-log.md"))
            func blocked(pass: String) throws -> [String: Bool] {
                let result = try #require(ProcessRunner.runAndWait(node, arguments: [harness.path, ext.path, run.path], environment: [
                    "PATH": "/usr/bin:/bin", "HOME": home.url.path, "AKIT_REVIEW_RUN": run.path, "AKIT_REVIEW_MODE": "review",
                    "AKIT_REVIEW_PASS": pass, "AKIT_REVIEW_ROOTS": run.appending(path: "debug").path, "AKIT_REVIEW_MCP": #"{"inPasses":false}"#,
                ], timeout: 60))
                #expect(result.succeeded, "\(result.output)")
                let line = result.output.split(separator: "\n").last.map(String.init) ?? "{}"
                return try JSONDecoder().decode([String: Bool].self, from: Data(line.utf8))
            }
            let debug = try blocked(pass: "debug-1")
            #expect(debug == ["akit_submit_findings": true, "akit_report_context_gap": true, "mcp__gitlab__get_merge_request": true,
                              "codemode": true, "read": false], "\(debug)")
            #expect(try blocked(pass: "role-x")["akit_submit_findings"] == false, "a role pass still submits")
        }
    }
}
