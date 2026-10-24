import AKitFoundation
@testable import AKitReview
import Foundation
import JavaScriptCore
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

        /// GitLab's search hit in project 12 (`team/web`, as the project's own answer says), a
        /// file read in `team/shop`, an answer of another pass and one of a server that isn't GitLab.
        static func playImpact(_ run: ReviewRunFixture) {
            run.playTypicalRun()
            run.home.write("fake/boundaries-brief.json", boundary)
            call(run, "impact-0", tool: "mcp__gitlab__get_project", input: ["id": "12"], answer: ["id": 12, "path_with_namespace": "team/web"])
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
            #expect(try ReviewRunLog.load(run.folder).passes.contains { $0.name == "impact" && $0.mcpCalls == 4 })
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

        /// R44: kept uses bring the contracts role into a run without it; a run of the passes
        /// without uses takes it out again, with the definition AKit wrote.
        @Test func keptUsesAddTheContractsRole() async throws {
            var choices = ReviewRunFixture.choices
            choices.scenario = "security"
            let run = try await ReviewRunFixture.make(choices: choices)
            #expect(ReviewJSON.read(ReviewRunSpec.self, from: run.folder.appending(path: "run.json"))?.roles.contains { $0.id == "contracts" } == false)
            Self.playImpact(run)
            _ = try await ReviewPasses.run(folder: run.folder, env: run.home.env)

            #expect(passes(run) == ["fetch", "brief", "impact", "role-security", "role-bug-hunter", "role-contracts", "verifier"])
            let spec = try #require(ReviewJSON.read(ReviewRunSpec.self, from: run.folder.appending(path: "run.json")))
            #expect(spec.roles.last?.id == "contracts" && spec.roles.last?.reason == "added: other repositories use the change")
            let roleFolder = run.folder.appending(path: "roles/review-contracts")
            #expect(FileManager.default.fileExists(atPath: roleFolder.appending(path: "SKILL.md").path))
            #expect(run.args("role-contracts").contains(roleFolder.path))
            #expect(try String(contentsOf: run.folder.appending(path: "prompts/role-contracts.md"), encoding: .utf8).contains("THIS merge request"))

            // The passes again, and this time no use is kept: the added role doesn't stick.
            try FileManager.default.removeItem(at: run.home.url.appending(path: "fake/consumers-impact.json"))
            _ = try await ReviewPasses.run(folder: run.folder, env: run.home.env)
            #expect(passes(run) == ["fetch", "brief", "impact", "role-security", "role-bug-hunter", "verifier"])
            #expect(ReviewJSON.read(ReviewRunSpec.self, from: run.folder.appending(path: "run.json"))?.roles.contains { $0.id == "contracts" } == false)
            #expect(!FileManager.default.fileExists(atPath: roleFolder.path))
        }

        /// The user turned contracts off: the uses are found, the role stays off and the run says so.
        @Test func theUsersRemovalOfContractsWins() async throws {
            var choices = ReviewRunFixture.choices
            choices.rolesOff = ["contracts"]
            let run = try await ReviewRunFixture.make(choices: choices)
            let spec = try #require(ReviewJSON.read(ReviewRunSpec.self, from: run.folder.appending(path: "run.json")))
            #expect(spec.rolesOff == ["contracts"] && !spec.roles.contains { $0.id == "contracts" })
            Self.playImpact(run)
            let lines = LockedBox<[String]>([])
            _ = try await ReviewPasses.run(folder: run.folder, env: run.home.env, options: .init(progress: { line in lines.update { $0.append(line) } }))

            #expect(passes(run) == ["fetch", "brief", "impact", "role-bug-hunter", "role-requirements", "role-tests", "verifier"])
            #expect(lines.value.contains("Other repositories use the change, but the contracts role is off by the user's choice."))
            #expect(ReviewJSON.read([ReviewConsumer].self, from: run.folder.appending(path: "consumers.json"))?.count == 2)
            #expect(ReviewJSON.read(ReviewRunSpec.self, from: run.folder.appending(path: "run.json"))?.roles.contains { $0.id == "contracts" } == false)
        }

        /// A failed impact pass: AKit's gap comes after the pass's own, and the uses it saved before
        /// failing are still checked and kept.
        @Test func aFailedPassKeepsItsGapsAndSavedUses() async throws {
            let run = try await ReviewRunFixture.make()
            Self.playImpact(run)
            run.home.write("fake/gaps-impact.jsonl", #"{"system":"gitlab","needed":"Code search in the instance","why":"Advanced search is off","reportedBy":"impact"}"# + "\n")
            run.home.write("fake/fail-impact", "")
            _ = try await ReviewPasses.run(folder: run.folder, env: run.home.env)

            #expect(passes(run).last == "verifier", "the review goes on")
            let reported = gaps(run).filter { $0.reportedBy == "impact" }
            #expect(reported.contains { $0.why == "Advanced search is off" } && reported.contains { $0.why.hasPrefix("The impact pass failed") })
            #expect(ReviewJSON.read([ReviewConsumer].self, from: run.folder.appending(path: "consumers.json"))?.map(\.project) == ["team/web", "team/shop"])
        }

        /// The estimate counts the impact pass and the contracts role it may add.
        @Test func theEstimateCountsTheImpactPass() async throws {
            func estimate(_ impact: ReviewImpact) async throws -> Double {
                var choices = ReviewRunFixture.choices
                choices.scenario = "security"
                choices.settings.impact = impact
                let run = try await ReviewRunFixture.make(choices: choices)
                Self.playImpact(run)
                _ = try await ReviewPasses.run(folder: run.folder, env: run.home.env)
                return try #require(ReviewJSON.read(ReviewPassLog.self, from: run.folder.appending(path: "passes.json"))?.estimate)
            }
            let off = try await estimate(.off)
            let auto = try await estimate(.auto)
            #expect(auto > off)
        }
    }
}

/// The check without a run: what counts as an answer, a path and a link.
struct ConsumerCheckTests {
    static func answer(_ tool: String, input: [String: Any] = [:], _ value: Any) -> ReviewMCPCall {
        let text = String(decoding: (try? JSONSerialization.data(withJSONObject: value)) ?? Data(), as: UTF8.self)
        let inputText = String(decoding: (try? JSONSerialization.data(withJSONObject: input)) ?? Data(), as: UTF8.self)
        return ReviewMCPCall(pass: "impact", tool: tool, input: inputText, text: [text], structured: nil, isError: false)
    }

    static let boundary = ReviewBoundary(id: "b1", kind: .httpAPI, direction: .provides, name: "/api/orders", file: "api.ts", line: 3,
                                         quote: "get('/api/orders')")

    static func use(_ project: String, _ file: String, _ quote: String) -> [String: Any] {
        ["boundary": "b1", "project": project, "file": file, "quote": quote, "usage": "u"]
    }

    @Test func checkKeepsQuotedUsesOfOtherProjects() {
        let search = Self.answer("mcp__gitlab__search", input: ["search": "/api/orders"],
                                 [["project_id": 7, "path": "web/orders.ts", "data": "  fetch(\"/api/orders\",\n   { method: \"GET\" })"]])
        let project = Self.answer("mcp__gitlab__get_project", input: ["id": 7], ["id": 7, "path_with_namespace": "g/web"])
        let kept = ReviewConsumers.check([Self.use("g/web", "web/orders.ts", #"fetch("/api/orders","#),
                                          Self.use("g/web", "web/orders.ts", "fetch(\"/api/orders\", ... method"),
                                          Self.use("g/app", "web/orders.ts", #"fetch("/api/orders","#), Self.use("g/x", "other.ts", #"fetch("/api/orders","#),
                                          Self.use("not a path", "web/orders.ts", #"fetch("/api/orders","#),
                                          Self.use("g/y", "../web/orders.ts", #"fetch("/api/orders","#)],
                                         boundaries: [Self.boundary], answers: [search, project], ownProject: "g/app", host: "https://gl.test")
        #expect(kept.map(\.project) == ["g/web"], "one use per project, file and boundary; own project, other file, bad paths dropped")
        #expect(kept.first?.url == "https://gl.test/g/web/-/blob/HEAD/web/orders.ts")
        #expect(ReviewConsumers.url(host: "https://gl.test", project: "g/p", ref: "feature/x", file: "a b.ts", line: 4)
                == "https://gl.test/g/p/-/blob/feature%2Fx/a%20b.ts#L4")
    }

    /// One answer must hold the quote, the whole file path and the project; a number counts only
    /// when an answer of the pass gives its one path; the call's input is never evidence.
    @Test func aUseIsTiedToItsProjectAndFile() {
        let quote = "fetchOrders('/api/orders/' + id)"
        let hits = Self.answer("mcp__gitlab__search", [
            ["project_id": 12, "path": "src/a.ts", "data": quote],
            ["project_id": 13, "path": "src/b.ts", "data": "unrelated()"],
            ["project_id": 99, "path": "src/c.ts", "data": quote],
            ["project_id": 14, "path": "src/d.ts", "data": quote],
            ["project_id": 5, "path": "src/own.ts", "data": quote],
            ["path_with_namespace": "g/named", "path": "lib/e.ts", "data": quote],
        ] as [[String: Any]])
        let projects = Self.answer("mcp__gitlab__search", input: ["scope": "projects"], [
            ["id": 12, "path_with_namespace": "g/web"], ["id": 13, "path_with_namespace": "g/other"],
            ["id": 14, "path_with_namespace": "g/one"], ["id": 14, "path_with_namespace": "g/two"],
            ["id": 5, "path_with_namespace": "g/lied"],
        ] as [[String: Any]])
        let read = Self.answer("mcp__gitlab__get_repository_file", input: ["project_id": "g%2Fshop", "file_path": "lib/use.ts", "ref": "main"],
                               ["file_path": "lib/use.ts", "encoding": "base64", "content": Data("// shop\n\(quote)\n".utf8).base64EncodedString()])
        let echo = Self.answer("mcp__gitlab__get_repository_file", input: ["project_id": "g/echo", "file_path": "x.ts", "ref": quote],
                               ["file_path": "x.ts", "content": "nothing here"])
        let other = Self.answer("mcp__gitlab__get_repository_file", input: ["project_id": "g/swap", "file_path": "asked.ts"],
                                ["file_path": "given.ts", "content": quote])
        let kept = ReviewConsumers.check([
            Self.use("g/web", "src/a.ts", quote),            // kept: the hit's number is g/web
            Self.use("g/other", "src/b.ts", quote),          // the quote is in another hit
            Self.use("g/web", "a.ts", quote),                // only the file's name
            Self.use("g/web", "src/c.ts", quote),            // project 99 has no path in any answer
            Self.use("g/one", "src/d.ts", quote),            // project 14 has two paths
            Self.use("g/lied", "src/own.ts", quote),         // project 5 is the merge request's own
            Self.use("g/elsewhere", "src/a.ts", quote),      // the hit is in g/web
            Self.use("g/named", "lib/e.ts", quote),          // kept: the hit names its path
            Self.use("g/shop", "lib/use.ts", quote),         // kept: a file read of that project and file
            Self.use("g/echo", "x.ts", quote),               // the quote is only in the call's input
            Self.use("g/swap", "asked.ts", quote),           // the answer is another file
        ], boundaries: [Self.boundary], answers: [hits, projects, read, echo, other], ownProject: "g/app", ownProjectID: 5, host: "https://gl.test")
        #expect(kept.map(\.project) == ["g/web", "g/named", "g/shop"])
    }

    @Test func bigAnswersAndLinksAreRefused() {
        let big = String(repeating: "x", count: ReviewConsumers.maxAnswer + 1)
        #expect(ReviewConsumers.answerLines([Self.answer("mcp__gitlab__search", [["path": "a.ts", "data": big + "\nfetchOrders(id)"]])]).isEmpty)
        #expect(ReviewConsumers.decoded(String(repeating: "QUFB", count: ReviewConsumers.maxAnswer / 3 + 10)) == nil)
        #expect(ReviewConsumers.decoded(Data("fetchOrders(id)".utf8).base64EncodedString()) == "fetchOrders(id)")
        // A JSON text block is read once, through its strings.
        let lines = ReviewConsumers.answerLines([Self.answer("mcp__gitlab__search", [["path": "a.ts", "data": "fetchOrders(id)"]])])
        #expect(lines == ["a.ts", "fetchOrders(id)"] || lines == ["fetchOrders(id)", "a.ts"])
        #expect(ReviewConsumers.url(host: "https://gl.test", project: "g/p", ref: "../../evil", file: "a.ts", line: nil) == nil)
        #expect(ReviewConsumers.url(host: "https://gl.test", project: "g/p", ref: "main", file: "a/./b.ts", line: nil) == nil)
        let use = ReviewConsumer(boundary: "b1", project: "g/p", file: "a<!--b.ts", ref: "x-->y", line: nil, quote: "q", usage: "u", breaks: false,
                                 why: "", url: nil)
        let markdown = ReviewConsumers.markdown([use], boundaries: [Self.boundary])
        #expect(!markdown.contains("<!--") && !markdown.contains("-->"))
    }

    @Test func onlySearchesAndFileReadsCount() {
        var counts = (searches: 0, files: 0)
        for tool in ["mcp__gitlab__search", "mcp__gitlab__semantic_search", "mcp__gitlab__query_graph", "mcp__gitlab__get_repository_file",
                     "mcp__gitlab__get_file_contents", "mcp__gitlab__list_repository_tree", "mcp__gitlab__list_files", "mcp__gitlab__get_project",
                     "mcp__gitlab__get_repository_tree"] {
            ReviewConsumers.count(tool, into: &counts)
        }
        #expect(counts.searches == 3 && counts.files == 2)
    }

    /// The extension's pure rules, run as they are with JavaScriptCore: no Node, the same text Pi loads.
    @Test func theExtensionsRulesRun() throws {
        #expect(ReviewExtension.source.contains(ReviewExtension.rules))
        let context = try #require(JSContext())
        context.exceptionHandler = { _, error in Issue.record("JavaScript: \(error?.toString() ?? "?")") }
        context.evaluateScript(ReviewExtension.rules)
        func call(_ name: String, _ arguments: [Any]) -> JSValue? { context.objectForKeyedSubscript(name)?.call(withArguments: arguments) }
        func tooMuch(_ json: String) -> Bool { context.evaluateScript("tooMuchFor(\(json))")?.toBool() ?? false }

        #expect(context.evaluateScript("openArgumentLimit")?.toInt32() == Int32(ReviewMCPPolicy.openArgumentLimit))
        #expect(!tooMuch(#"{"scope":"blobs","search":"auth header log","group_id":"team"}"#))
        #expect(tooMuch(#"{"search":"a\nb"}"#), "a line break")
        #expect(tooMuch("{\"search\":\"\(String(repeating: "x", count: 301))\"}"), "a long text")
        #expect(tooMuch(#"{"a":{"b":{"c":{"d":{"e":{"f":"x"}}}}}}"#), "deeper than AKit looks")
        #expect(tooMuch("{\"a\":\"\(String(repeating: "x", count: 250))\",\"b\":\"\(String(repeating: "y", count: 250))\",\"c\":\"\(String(repeating: "z", count: 250))\"}"),
                "much in all")
        #expect(tooMuch(#"{"x\ny":1}"#), "a key is text too")
        #expect(tooMuch(#"{"server":"docs","uri":"docs://\#(String(repeating: "u", count: 400))"}"#), "a resource's uri")

        #expect(call("limitApplies", ["impact", true, false])?.toBool() == true, "every server in the impact pass")
        #expect(call("limitApplies", ["role-tests", true, false])?.toBool() == false)
        #expect(call("limitApplies", ["brief", false, true])?.toBool() == false, "a context server")
        #expect(call("limitApplies", ["fetch", false, false])?.toBool() == true, "an open server")
        // The resource tools pass the same check where the limit applies.
        #expect(ReviewExtension.source.contains("if (limitApplies(pass, serverBase(server), serverExtra(server)) && tooMuchFor(event.input))"))

        let good: [String: Any] = ["boundary": "b1", "project": "g/web", "file": "a.ts", "quote": "fetchOrders(id)", "usage": "Calls it", "line": 3]
        #expect(call("consumerProblems", [[good]])?.toArray()?.isEmpty == true)
        var bad = good
        bad["quote"] = " "
        bad["line"] = 0
        bad["breaks"] = true
        let problems = call("consumerProblems", [[bad, "x"]])?.toArray() as? [String] ?? []
        #expect(problems == ["consumers[0].line must be a line number from 1", "consumers[0].quote must copy the line from GitLab's answer",
                             "consumers[0].why says how this change breaks it", "consumers[1] is not an object"])
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
