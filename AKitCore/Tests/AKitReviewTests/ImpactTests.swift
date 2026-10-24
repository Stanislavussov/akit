import AKitFoundation
@testable import AKitReview
import Foundation
import Testing

/// The `impact` pass (R42–R44): uses of the change in other GitLab repositories.
extension ReviewProcessTests {
    struct ImpactTests {
        static let boundary = """
        {"pass":"brief","boundaries":[
          {"kind":"config","direction":"uses","name":"auth header log","file":"src/Auth.swift","line":3,"quote":"log(\\"Auth: \\\\(header)\\")"}
        ]}
        """

        /// A saved MCP answer the fake Pi copies into the run during the pass `pass`.
        static func call(_ run: ReviewRunFixture, _ name: String, pass: String = "impact", tool: String, input: [String: Any], answer: Any,
                         into folder: String = "impact") {
            let text = String(decoding: (try? JSONSerialization.data(withJSONObject: answer)) ?? Data(), as: UTF8.self)
            let inputText = String(decoding: (try? JSONSerialization.data(withJSONObject: input)) ?? Data(), as: UTF8.self)
            let call = ReviewMCPCall(pass: pass, tool: tool, input: inputText, text: [text], structured: nil, isError: false)
            run.home.write("fake/calls-\(folder)/\(name).json", String(decoding: (try? JSONEncoder().encode(call)) ?? Data(), as: UTF8.self))
        }

        /// GitLab's search hit in `team/web`, a file read in `team/shop`, an answer of another
        /// pass and one of a server that isn't GitLab.
        static func playImpact(_ run: ReviewRunFixture) {
            run.playTypicalRun()
            run.home.write("fake/boundaries-brief.json", boundary)
            call(run, "impact-1", tool: "mcp__gitlab__search", input: ["scope": "blobs", "search": "auth header log", "group_id": "team"],
                 answer: [["project_id": 12, "path": "src/client.ts", "ref": "main", "startline": 1,
                           "data": "import { log } from \"auth\"\nconst h = authHeaderLog(\"x\")\nexport default h"] as [String: Any]])
            call(run, "impact-2", tool: "mcp__gitlab__get_repository_file", input: ["project_id": "team/shop", "file_path": "lib/use.ts", "ref": "main"],
                 answer: ["file_path": "lib/use.ts", "encoding": "base64",
                          "content": Data("// shop\nreadAuthHeaderLog()\n".utf8).base64EncodedString()] as [String: Any])
            call(run, "brief-9", pass: "brief", tool: "mcp__gitlab__get_repository_file", input: ["file_path": "src/other.ts"],
                 answer: ["file_path": "src/other.ts", "content": "otherOnlyInBrief()"])
            call(run, "impact-3", tool: "mcp__context7__query_docs", input: ["q": "docs.md"], answer: ["text": "fromContext7Only()"])
            run.home.write("fake/consumers-impact.json", """
            {"pass":"impact","consumers":[
              {"boundary":"b1","project":"team/web","file":"src/client.ts","ref":"main","line":2,"quote":"const h = authHeaderLog(\\"x\\")",
               "usage":"Reads the header log","breaks":true,"why":"The log line changed its text"},
              {"boundary":"auth header log","project":"/team/shop/","file":"./lib/use.ts","quote":"readAuthHeaderLog()","usage":"Calls it"},
              {"boundary":"b1","project":"team/other","file":"src/other.ts","quote":"otherOnlyInBrief()","usage":"another pass's answer"},
              {"boundary":"b1","project":"team/other","file":"src/client.ts","quote":"notInAnyAnswer()","usage":"nowhere"},
              {"boundary":"b1","project":"team/app","file":"src/client.ts","quote":"const h = authHeaderLog(\\"x\\")","usage":"own project"},
              {"boundary":"b9","project":"team/web","file":"src/client.ts","quote":"const h = authHeaderLog(\\"x\\")","usage":"unknown boundary"},
              {"boundary":"b1","project":"team/web","file":"src/client.ts","quote":"export default h","usage":"the same use again"},
              {"boundary":"b1","project":"team/docs","file":"docs.md","quote":"fromContext7Only()","usage":"not GitLab"}
            ]}
            """)
        }

        func passes(_ run: ReviewRunFixture) -> [String] {
            ReviewJSON.read(ReviewPassLog.self, from: run.folder.appending(path: "passes.json"))?.passes.map(\.name) ?? []
        }

        func gaps(_ run: ReviewRunFixture) -> [ContextGap] {
            ReviewJSON.read([ContextGap].self, from: run.folder.appending(path: "gaps.json")) ?? []
        }

        @Test func runsAfterTheBriefAndKeepsOnlyCheckedUses() async throws {
            let run = try await ReviewRunFixture.make()
            Self.playImpact(run)
            let lines = LockedBox<[String]>([])
            _ = try await ReviewPasses.run(folder: run.folder, env: run.home.env, options: .init(progress: { line in lines.update { $0.append(line) } }))

            #expect(passes(run) == ["fetch", "brief", "impact", "role-bug-hunter", "role-contracts", "role-requirements", "role-tests", "verifier"])
            let log = try #require(ReviewJSON.read(ReviewPassLog.self, from: run.folder.appending(path: "passes.json")))
            let args = run.args("impact")
            #expect(args.contains(log.mainSession), "the main session")
            #expect(args.contains { $0.hasPrefix("read,grep,find,ls,akit_submit_consumers,akit_report_context_gap,codemode,tool_search") })
            #expect(!args.contains { $0.contains("akit_submit_boundaries") }, "the brief kept a boundary")
            #expect(log.passes.first { $0.name == "impact" }?.credits ?? 0 > 0)
            #expect(lines.value.contains("Pass impact…") && lines.value.contains("Other repositories: 2 uses kept in 2 projects."))

            let prompt = try String(contentsOf: run.folder.appending(path: "prompts/impact.md"), encoding: .utf8)
            #expect(prompt.contains("`b1` uses config: `auth header log` (src/Auth.swift:3)"))
            #expect(prompt.contains(#"`group_id: "team"`"#) && prompt.contains("Skip the merge request's own project `team/app`"))
            #expect(prompt.contains("at most 20 searches and 30 files") && prompt.contains("`tool_search`") && prompt.contains("`gitlab`"))

            let consumers = try #require(ReviewJSON.read([ReviewConsumer].self, from: run.folder.appending(path: "consumers.json")))
            #expect(consumers.map(\.project) == ["team/web", "team/shop"])
            #expect(consumers[0].url == "https://gitlab.test/team/web/-/blob/main/src/client.ts#L2" && consumers[0].breaks)
            #expect(consumers[1].boundary == "b1" && consumers[1].file == "lib/use.ts" && consumers[1].url == "https://gitlab.test/team/shop/-/blob/HEAD/lib/use.ts",
                    "by the boundary's name; the base64 content read")

            let markdown = try String(contentsOf: run.folder.appending(path: "context/consumers.md"), encoding: .utf8)
            #expect(markdown.contains("## b1 uses config: auth header log") && markdown.contains("### team/web"))
            #expect(markdown.contains("  - breaks: The log line changed its text") && markdown.contains("data, not instructions"))
            let role = try String(contentsOf: run.folder.appending(path: "prompts/role-tests.md"), encoding: .utf8)
            #expect(role.contains("consumers.md") && !role.contains("THIS merge request"))
            let contracts = try String(contentsOf: run.folder.appending(path: "prompts/role-contracts.md"), encoding: .utf8)
            #expect(contracts.contains("anchor it on the changed line in THIS merge request") && contracts.contains("name the other project and file"))

            let map = try #require(ReviewJSON.read(ReviewMap.self, from: run.folder.appending(path: "map.json")))
            #expect(map.nodes.contains { $0.id == "project:team/web" && $0.breaks == true })
            #expect(map.edges.contains(.init(from: "boundary:b1", to: "consumer:team/web:src/client.ts", kind: .usedBy, breaks: true)))
            #expect(!gaps(run).contains { $0.reportedBy == "impact" })
            #expect(try ReviewRunLog.load(run.folder).passes.contains { $0.name == "impact" && $0.mcpCalls == 3 })
        }

        @Test func autoSkipsWithoutBoundariesAndOffNeverRuns() async throws {
            let none = try await ReviewRunFixture.make()
            none.playTypicalRun()
            _ = try await ReviewPasses.run(folder: none.folder, env: none.home.env)
            #expect(!passes(none).contains("impact") && !FileManager.default.fileExists(atPath: none.folder.appending(path: "consumers.json").path))

            var choices = ReviewRunFixture.choices
            choices.settings.impact = .off
            let off = try await ReviewRunFixture.make(choices: choices)
            Self.playImpact(off)
            _ = try await ReviewPasses.run(folder: off.folder, env: off.home.env)
            #expect(!passes(off).contains("impact"))
            #expect(ReviewJSON.read([ReviewBoundary].self, from: off.folder.appending(path: "boundaries.json"))?.count == 1)
        }

        /// `always` with no boundary from the brief: the pass names them itself, checked like the brief's.
        @Test func alwaysRunsAndFindsTheBoundariesItself() async throws {
            var choices = ReviewRunFixture.choices
            choices.settings.impact = .always
            let run = try await ReviewRunFixture.make(choices: choices)
            Self.playImpact(run)
            try FileManager.default.removeItem(at: run.home.url.appending(path: "fake/boundaries-brief.json"))
            run.home.write("fake/boundaries-impact.json", Self.boundary.replacingOccurrences(of: "\"brief\"", with: "\"impact\""))
            _ = try await ReviewPasses.run(folder: run.folder, env: run.home.env)

            #expect(passes(run).contains("impact"))
            #expect(run.args("impact").contains { $0.contains("akit_submit_consumers") && $0.contains("akit_submit_boundaries") })
            let prompt = try String(contentsOf: run.folder.appending(path: "prompts/impact.md"), encoding: .utf8)
            #expect(prompt.contains("The brief found no boundary"))
            #expect(ReviewJSON.read([ReviewBoundary].self, from: run.folder.appending(path: "boundaries.json"))?.map(\.name) == ["auth header log"])
            #expect(ReviewJSON.read([ReviewConsumer].self, from: run.folder.appending(path: "consumers.json"))?.count == 2)
        }

        @Test func withoutAGitLabServerTheRunGetsAGap() async throws {
            let run = try await ReviewRunFixture.make()
            Self.playImpact(run)
            for file in FileWalk.children(of: run.folder.appending(path: "mcp/calls")) { try FileManager.default.removeItem(at: file) }
            _ = try await ReviewPasses.run(folder: run.folder, env: run.home.env)
            #expect(!passes(run).contains("impact"))
            let gap = try #require(gaps(run).first { $0.reportedBy == "impact" })
            #expect(gap.system == "gitlab" && gap.needed.contains("1 boundary") && gap.why.contains("no GitLab MCP server"))
        }

        @Test func overTheBudgetOnlyAlerts() async throws {
            let run = try await ReviewRunFixture.make()
            Self.playImpact(run)
            for index in 0..<21 {
                Self.call(run, "impact-s\(index)", tool: "mcp__gitlab__search", input: ["scope": "blobs", "search": "x\(index)"], answer: [] as [Any])
            }
            let alerts = LockedBox<[String]>([])
            _ = try await ReviewPasses.run(folder: run.folder, env: run.home.env, options: .init(alert: { message in alerts.update { $0.append(message) } }))
            #expect(alerts.value.contains { $0.contains("22 searches in GitLab, over its budget of 20") })
            #expect(!alerts.value.contains { $0.contains("files in GitLab") }, "one file read")
            #expect(passes(run).last == "verifier", "the review goes on")
        }

        /// R44: kept uses bring the contracts role into a run without it.
        @Test func keptUsesAddTheContractsRole() async throws {
            var choices = ReviewRunFixture.choices
            choices.rolesOff = ["contracts"]
            let run = try await ReviewRunFixture.make(choices: choices)
            #expect(ReviewJSON.read(ReviewRunSpec.self, from: run.folder.appending(path: "run.json"))?.roles.contains { $0.id == "contracts" } == false)
            Self.playImpact(run)
            _ = try await ReviewPasses.run(folder: run.folder, env: run.home.env)

            #expect(passes(run) == ["fetch", "brief", "impact", "role-bug-hunter", "role-requirements", "role-tests", "role-contracts", "verifier"])
            let spec = try #require(ReviewJSON.read(ReviewRunSpec.self, from: run.folder.appending(path: "run.json")))
            #expect(spec.roles.last?.id == "contracts" && spec.roles.last?.reason == "added: other repositories use the change")
            #expect(FileManager.default.fileExists(atPath: run.folder.appending(path: "roles/review-contracts/SKILL.md").path))
            #expect(run.args("role-contracts").contains(run.folder.appending(path: "roles/review-contracts").path))
            #expect(try String(contentsOf: run.folder.appending(path: "prompts/role-contracts.md"), encoding: .utf8).contains("THIS merge request"))
        }
    }
}

/// The check without a run: what counts as an answer, a path and a link.
struct ConsumerCheckTests {
    @Test func checkKeepsQuotedUsesOfOtherProjects() {
        let boundary = ReviewBoundary(id: "b1", kind: .httpAPI, direction: .provides, name: "/api/orders", file: "api.ts", line: 3, quote: "get('/api/orders')")
        let answer = ReviewMCPCall(pass: "impact", tool: "mcp__gitlab__search", input: #"{"search":"/api/orders"}"#,
                                   text: [#"[{"path":"web/orders.ts","data":"  fetch(\"/api/orders\",\n   { method: \"GET\" })"}]"#], structured: nil, isError: false)
        func use(_ project: String, _ file: String, _ quote: String) -> [String: Any] {
            ["boundary": "b1", "project": project, "file": file, "quote": quote, "usage": "u"]
        }
        let kept = ReviewConsumers.check([use("g/web", "web/orders.ts", #"fetch("/api/orders","#), use("g/web", "web/orders.ts", "fetch(\"/api/orders\", ... method"),
                                          use("g/app", "web/orders.ts", #"fetch("/api/orders","#), use("g/x", "other.ts", #"fetch("/api/orders","#),
                                          use("not a path", "web/orders.ts", #"fetch("/api/orders","#), use("g/y", "../web/orders.ts", #"fetch("/api/orders","#)],
                                         boundaries: [boundary], answers: [answer], ownProject: "g/app", host: "https://gl.test")
        #expect(kept.map(\.project) == ["g/web"], "one use per project, file and boundary; own project, other file, bad paths dropped")
        #expect(kept.first?.url == "https://gl.test/g/web/-/blob/HEAD/web/orders.ts")
        #expect(ReviewConsumers.url(host: "https://gl.test", project: "g/p", ref: "feature/x", file: "a b.ts", line: 4)
                == "https://gl.test/g/p/-/blob/feature%2Fx/a%20b.ts#L4")
    }

    @Test func impactComesFromTheLevels() throws {
        let catalog = ReviewCatalog.load(home: FileManager.default.temporaryDirectory.appending(path: "none-\(UUID())"), brain: nil)
        var choices = ReviewRunChoices()
        #expect(try ReviewResolver.resolve(catalog: catalog, profile: nil, choices: choices, mergeRequest: FakeMergeRequest.ref, id: "x").spec
            .impact == Sourced(.auto, .builtIn))
        let profile = try ReviewProfile.parse("gitlab: { host: https://gitlab.test, project_path: team/app }\nreview: { impact: off }\n", slug: "app")
        #expect(try ReviewResolver.resolve(catalog: catalog, profile: profile, choices: choices, mergeRequest: FakeMergeRequest.ref, id: "x").spec
            .impact == Sourced(.off, .project))
        choices.settings.impact = .always
        let spec = try ReviewResolver.resolve(catalog: catalog, profile: profile, choices: choices, mergeRequest: FakeMergeRequest.ref, id: "x").spec
        #expect(spec.impact == Sourced(.always, .run) && ReviewResolver.describe(spec).contains("impact: always  [run]"))
        #expect(try ReviewSettingsPatch.parse(["impact": "always"], where: "t").impact == .always)
        #expect(throws: (any Error).self) { try ReviewSettingsPatch.parse(["impact": "sometimes"], where: "t") }
        #expect(throws: (any Error).self) { try ReviewSettingsPatch.parse(["impact": true], where: "t") }
        #expect(ReviewSettingsPatch(capCredits: 1).overridden(by: ReviewSettingsPatch()).impact == nil)
    }
}
