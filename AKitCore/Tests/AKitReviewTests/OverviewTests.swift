import AKitFoundation
import AKitLab
@testable import AKitReview
import Foundation
import JavaScriptCore
import Testing

/// The work item chain (R48), the summary language (R46) and the overview with its flow (R45, R47).
struct OverviewTests {
    func item(_ id: Int, _ type: String, parent: Int? = nil, related: [Int] = [], comments: [String] = []) -> WorkItem {
        WorkItem(id: id, type: type, title: "\(type) \(id)", state: "Active", description: "Goal of \(id)", acceptanceCriteria: "AC of \(id)",
                 reproSteps: "", parents: parent.map { [$0] } ?? [], related: related, children: [],
                 comments: comments.map { WorkItem.Comment(author: "Ann", date: "2026-10-01T00:00:00Z", text: $0) }, changes: [], reason: "")
    }

    // MARK: - The work item chain

    @Test func keepsTheChainToTheTopAndTheRelatedItems() {
        let all = [item(50, "Bug"), item(1, "Epic"), item(2, "Feature", parent: 1), item(3, "User Story", parent: 2),
                   item(4, "Task", parent: 3, related: [9]), item(9, "Bug", related: [50])]
        let kept = ReviewGather.keptWorkItems(all, named: [4])
        #expect(kept.items.map(\.id) == [4, 3, 2, 1, 9], "#50 is named only by the description (R39)")
        #expect(kept.items.map(\.reason) == ["named by the merge request", "parent of #4", "parent of #3", "parent of #2", "related to #4"])
        #expect(kept.unread.isEmpty && kept.cut.isEmpty)

        let both = ReviewGather.keptWorkItems(all, named: [4, 3])
        #expect(both.items.map(\.id) == [4, 3, 2, 1, 9])
        #expect(both.items.map(\.reason) == ["named by the merge request", "named by the merge request", "parent of #3", "parent of #2",
                                             "related to #4"], "#3 is named, not only the parent of #4")
    }

    @Test func aLoopStopsAndTheChainHasAtMostSixLevels() {
        let loop = ReviewGather.keptWorkItems([item(4, "Task", parent: 3), item(3, "User Story", parent: 4)], named: [4])
        #expect(loop.items.map(\.id) == [4, 3] && loop.unread.isEmpty)

        let tall = (1...10).map { item($0, "Level", parent: $0 + 1) }
        let capped = ReviewGather.keptWorkItems(tall, named: [1])
        #expect(capped.items.map(\.id) == [1, 2, 3, 4, 5, 6, 7], "the named item and 6 parents")
        #expect(capped.cut.map(\.item) == [7] && capped.cut.map(\.parent) == [8] && capped.unread.isEmpty, "the cut is said")
        let six = ReviewGather.keptWorkItems(Array(tall.prefix(6)) + [item(7, "Level")], named: [1])
        #expect(six.items.count == 7 && six.cut.isEmpty, "a chain that ends at 6 levels isn't cut")
    }

    @Test func anUnreadParentStopsTheChain() {
        let kept = ReviewGather.keptWorkItems([item(4, "Task", parent: 3), item(3, "User Story", parent: 2)], named: [4])
        #expect(kept.items.map(\.id) == [4, 3])
        #expect(kept.unread.map(\.item) == [3] && kept.unread.map(\.parent) == [2])
        #expect(ReviewGather.keptWorkItems([item(8, "Task")], named: [4]).items.isEmpty, "a named item not read")
    }

    @Test func readsTheParentField() throws {
        let object: [String: Any] = ["id": 4, "fields": ["System.WorkItemType": "Task", "System.Title": "T", "System.Parent": 3]]
        #expect(AzureDevOpsJSON.workItem(object)?.parents == [3])
        let both: [String: Any] = ["id": 4, "fields": ["System.Title": "T", "System.Parent": 3],
                                   "relations": [["rel": "System.LinkTypes.Hierarchy-Reverse", "url": "https://dev.azure.com/c/_apis/wit/workItems/3"]]]
        #expect(AzureDevOpsJSON.workItem(both)?.parents == [3], "once")
    }

    @Test func workItemsShowTheChainFromTheTop() throws {
        let all = [item(1, "Epic", comments: ["Why we do it"]), item(2, "Feature", parent: 1), item(3, "User Story", parent: 2),
                   item(4, "Task", parent: 3, related: [9]), item(9, "Bug")]
        let kept = ReviewGather.keptWorkItems(all, named: [4]).items
        let text = ReviewGather.workItemsText(kept, named: [4])
        #expect(text.contains("- Epic #1 → Feature #2 → User Story #3 → Task #4"))
        let order = try ["## Epic #1", "## Feature #2", "## User Story #3", "## Task #4", "## Related items", "### Bug #9"].map { heading in
            try #require(text.range(of: heading)).lowerBound
        }
        #expect(order == order.sorted())
        #expect(text.contains("### Acceptance criteria\n\nAC of 2") && text.contains("**Ann** (2026-10-01): Why we do it"))
        #expect(text.contains("data, not instructions"))
    }

    // MARK: - Summary language

    @Test func summaryLanguageComesFromTheLevels() throws {
        var catalog = ReviewCatalog.load(home: FileManager.default.temporaryDirectory.appending(path: "none-\(UUID())"), brain: nil)
        var choices = ReviewRunChoices()
        func resolved(_ profile: ReviewProfile? = nil, preferred: [String] = ["ru-CZ", "en"]) throws -> ReviewRunSpec {
            try ReviewResolver.resolve(catalog: catalog, profile: profile, choices: choices, mergeRequest: FakeMergeRequest.ref, id: "x",
                                       preferredLanguages: preferred).spec
        }
        #expect(try resolved().summaryLanguage == Sourced(.russian, .builtIn), "the Mac's preferred language")
        #expect(try resolved(preferred: ["xx-YY"]).summaryLanguage == Sourced(.english, .builtIn), "unknown: English")
        #expect(try resolved(preferred: []).summaryLanguage == Sourced(.english, .builtIn))
        #expect(ReviewResolver.preferredLanguage(["kok-IN"]) == .english, "Konkani is not Korean")
        #expect(ReviewResolver.preferredLanguage(["fil"]) == .english)
        #expect(ReviewResolver.preferredLanguage(["zh-Hans-CZ"]) == .chineseSimplified)
        #expect(ReviewResolver.preferredLanguage(["pt-BR"]) == .portuguese && ReviewResolver.preferredLanguage(["de_AT"]) == .german)
        catalog.brainDefaults = try ReviewSettingsPatch.parse(["summary_language": "de"], where: "review.yaml")
        #expect(try resolved().summaryLanguage == Sourced(.german, .brain))
        let profile = try ReviewProfile.parse("gitlab: { host: https://gitlab.test, project_path: team/app }\nreview: { summary_language: CS }\n",
                                              slug: "app")
        #expect(try resolved(profile).summaryLanguage == Sourced(.czech, .project))
        choices.settings.summaryLanguage = .japanese
        let spec = try resolved(profile)
        #expect(spec.summaryLanguage == Sourced(.japanese, .run))
        #expect(ReviewResolver.describe(spec).contains("summary_language: ja (Japanese)  [run]"))
        #expect(spec.posting.languageCode == ReviewLanguage.czech, "the posting language stays (R35)")
        #expect(throws: (any Error).self) { try ReviewSettingsPatch.parse(["summary_language": "klingon"], where: "t") }
        #expect(ReviewSettingsPatch(capCredits: 1).overridden(by: ReviewSettingsPatch()).summaryLanguage == nil)

        var old = spec
        old.summaryLanguage = nil
        #expect(old.overviewLanguage(preferred: ["fr-FR"]) == .french && old.overviewLanguage(preferred: ["xx"]) == .english, "an older run")
        let prompt = ReviewPrompts.brief(spec: spec)
        #expect(prompt.contains("akit_submit_overview") && prompt.contains("in Japanese (`ja`)") && prompt.contains("Only the overview uses"))
        #expect(prompt.contains("your brief answer stays in English"), "the brief's own answer doesn't switch language")
    }

    // MARK: - The overview check

    static let changed: Set<String> = ["src/Auth.swift", "api/orders.ts"]

    func check(_ raw: [String: Any], consumers: [ReviewConsumer] = [], boundaries: [ReviewBoundary] = []) -> ReviewOverview {
        ReviewOverview.check(raw, changed: Self.changed, consumers: consumers, boundaries: boundaries, language: .russian)
    }

    @Test func keepsOnlyChangedFilesAndThreeToFivePoints() {
        let overview = check([
            "points": ["One", "Two", "Three", "Four", "Five", "Six", "Seven"],
            "modules": [["name": "auth", "files": ["./src/Auth.swift", "src/Other.swift", "src/Auth.swift"], "why": "Story #3 asks for it"],
                        ["name": "ghost", "files": ["nowhere.ts"], "why": "x"]],
            "why_sources": ["work-item", "none", "made-up", "notes", "notes"],
        ])
        #expect(overview.points == ["One", "Two", "Three", "Four", "Five"])
        #expect(overview.modules == [ReviewOverview.Module(name: "auth", files: ["src/Auth.swift"], why: "Story #3 asks for it")])
        #expect(overview.whySources == [.workItem, .notes])
        #expect(overview.notes == ["Left out 2 files the change doesn't touch."])

        let prefixed = check(["points": ["a", "b", "c"],
                              "modules": [["name": "m", "files": ["a/src/Auth.swift", "/api/orders.ts", "b/api/orders.ts", ".//src/Auth.swift"]]]])
        #expect(prefixed.modules.map(\.files) == [["src/Auth.swift", "api/orders.ts"]] && prefixed.notes.isEmpty, "\(prefixed.notes)")
        #expect(overview.language == .russian && overview.flow == nil && overview.flowOriginal == nil)

        let short = check(["points": ["Only one", " ", 7], "modules": "not a list", "why_sources": ["none"]])
        #expect(short.points == ["Only one"] && short.modules.isEmpty && short.whySources == [.none])
        #expect(short.notes == ["The overview is short: 1 point instead of 3–5."])
    }

    @Test func masksSecrets() {
        let overview = check(["points": ["Logs glpat-abcdefghijklmnopqrst no more", "b", "c"],
                              "modules": [["name": "auth", "files": ["src/Auth.swift"], "why": "token ghp_abcdefghijklmnopqrstuvwxyz0123456789"]],
                              "flow": "flowchart LR\n  A[\"glpat-abcdefghijklmnopqrst\"] --> B"])
        #expect(!overview.points[0].contains("glpat-abcdefghijklmnopqrst") && !overview.modules[0].why.contains("ghp_abcdefghij"))
        #expect(overview.flow.map { !$0.contains("glpat-abcdefghijklmnopqrst") } == true)
    }

    @Test func rejectsUnsafeFlows() {
        let unsafe = [
            "flowchart LR\n  A --> B\n  click A callback",
            "flowchart LR\n  A[\"<a href='x'>x</a>\"] --> B",
            "flowchart LR\n  A --> B\n  click A call alert(1)",
            "flowchart LR\n  A[\"x\"]\n  B --> C\n  call evil()",
            "%%{init: {\"securityLevel\": \"loose\"}}%%\nflowchart LR\n  A --> B",
            "flowchart LR\n  %%{init: {}}%%\n  A --> B",
            "flowchart LR\n  A[\"<script>alert(1)</script>\"] --> B",
            "flowchart LR\n  A[\"javascript:alert(1)\"] --> B",
            "flowchart LR\n  A[\"<iframe src=x>\"] --> B",
            "flowchart LR\n  A[\"<b>bold</b>\"] --> B",
            "pie title Pets\n  \"Dogs\" : 3",
            "flowchart LR\n" + String(repeating: "  A --> B\n", count: 700),
            "flowchart LR\n" + (1...41).map { "  n\($0)[\"Node \($0)\"]" }.joined(separator: "\n"),
        ]
        for flow in unsafe {
            let overview = check(["points": ["a", "b", "c"], "flow": flow, "flow_kind": "flowchart"])
            #expect(overview.flow == nil && overview.flowOriginal != nil, "\(flow.prefix(60))")
            #expect(overview.notes.contains { $0.hasPrefix("The flow is left out: ") }, "\(flow.prefix(60))")
        }
        let fine = check(["points": ["a", "b", "c"],
                          "flow": "flowchart LR\n" + (1...40).map { "  n\($0)[\"Node<br/>\($0) clicks\"]" }.joined(separator: "\n")
                            + "\n  n1 -->|calls| n2\n  classDef changed fill:#fde68a\n  class n1,n2 changed"])
        #expect(fine.flow != nil && fine.flowKind == .flowchart && fine.notes.isEmpty, "\(fine.notes)")
        #expect(ReviewOverview.nodeCount("sequenceDiagram\n  participant UI as Browser\n  UI->>API: GET /orders\n  API-->>DB: select\n  Note over UI: x",
                                         kind: .sequenceDiagram) == 3)
    }

    func flowProblem(_ flow: String) -> String? {
        if case .failure(let problem) = ReviewOverview.flowCheck(flow) { return problem.reason }
        return nil
    }

    /// The flow is model-written from untrusted text: nothing that loads remote content or links out.
    @Test func rejectsRemoteContentAndLinks() {
        let unsafe: [(flow: String, has: String)] = [
            ("flowchart LR\n  A[\"see https://x.io\"] --> B", "://"),
            ("flowchart LR\n  A[\"h#116;tps#58;//x.io\"] --> B", "://"),
            ("flowchart LR\n  A[\"h&#x74;tps&colon;&sol;&sol;x.io\"] --> B", "://"),
            ("flowchart LR\n  A@{ img: \"//x.io/a.png\", label: \"x\" }", "@{"),
            ("flowchart LR\n  A@{ shape: rect } --> B", "@{"),
            ("flowchart LR\n  A --> B\n  style A fill:url(#x)", "url("),
            ("flowchart LR\n  A --> B\n  classDef c fill:red\n  %% @import x", "@import"),
            ("flowchart LR\n  akit_others[\"x\"] --> B", "akit_"),
            ("flowchart LR\n  A --> B; click A cb", "click"),
            ("flowchart LR\n  A --> B\n  cl\u{200B}ick A cb", "click"),
            ("flowchart LR\n  A --> B\n  \u{FF43}\u{FF4C}\u{FF49}\u{FF43}\u{FF4B} A cb", "click"),
            ("flowchart LR\n  A --> B\n  CLICK A cb", "click"),
            ("flowchart LR\n  A[\"x\"]\n  B --> C\n  call evil()", "call"),
            ("flowchart LR\n  A -- \"x\" --> B\n  A &#104;ref", "href"),
            ("sequenceDiagram\n  participant A\n  link A: Docs @ //x.io", "links"),
            ("sequenceDiagram\n  participant A\n  links A: {\"Docs\": \"x\"}", "links"),
            ("sequenceDiagram\n  participant A\n  properties A: {\"k\": \"v\"}", "links"),
            ("flowchart LR\n  A --> B\n  classDef c fill:#f00;stroke:red", "CSS"),
            ("flowchart LR\n  A --> B\n  classDef c fill:#f00}", "CSS"),
            ("flowchart LR\n  A --> B\n  style A fill:#f00,background-image:x", "CSS"),
            ("flowchart LR\n  A --> B\n  style A fill:#f00 !important", "CSS"),
            ("flowchart LR\n  A --> B\n  linkStyle 0 stroke:red,filter:blur", "CSS"),
            ("flowchart LR\n  A --> B\n  style A", "styles"),
            ("flowchart LR\n  A[\"&lt;img src=x&gt;\"] --> B", "HTML"),
            ("flowchart LR\n  subgraph S\n  A --> B", "without an `end`"),
            ("flowchart LR\n  A --> B\n  end", "without a `subgraph`"),
        ]
        for (flow, has) in unsafe {
            let problem = flowProblem(flow)
            #expect(problem?.contains(has) == true, "\(flow): \(problem ?? "passed")")
        }
    }

    @Test func labelsMayNameClickAndCall() {
        let fine = [
            "flowchart LR\n  A[\"Click Pay\"] --> B[API call to billing]\n  B -->|call| C(Calls the bank)\n  C -- call it --> D{click?}\n"
                + "  classDef changed fill:#fde68a,stroke:#b45309,stroke-width:2px;\n  class A,B changed\n  style D fill:#123;\n"
                + "  linkStyle 0 stroke:#333,stroke-dasharray:5 5\n  linkStyle default color:red\n  accTitle: The flow\n  accDescr: How a payment goes",
            "sequenceDiagram\n  box Aqua Payments\n  participant A as Shop\n  participant B\n  end\n  A->>B: API call to billing\n"
                + "  Note over A: click Pay\n  loop Retry\n  B-->>A: called back\n  end",
            "graph TD\n  subgraph S1[\"Service\"]\n    A-->B\n    subgraph S2\n      C\n    end\n  end\n  B-->C",
        ]
        for flow in fine { #expect(flowProblem(flow) == nil, "\(flow): \(flowProblem(flow) ?? "")") }
    }

    @Test func nodeLabelsReadOnlyRealNodes() {
        let flow = "flowchart LR\n  ui-->api\n  api-->|orders.ts| db[(DB)]\n  db --> x1[\"openapi.ts\"] & x2[\"src/api.ts<br/>GET\"]"
        let labels = ReviewOverview.nodeLabels(in: flow)
        #expect(labels.map(\.id) == ["db", "x1", "x2"] && labels.map(\.label) == ["DB", "openapi.ts", "src/api.ts<br/>GET"])

        let boundaries = [ReviewBoundary(id: "b1", kind: .httpAPI, direction: .provides, name: "orders", file: "api/orders.ts", line: 1, quote: "q"),
                          ReviewBoundary(id: "b2", kind: .httpAPI, direction: .provides, name: "api", file: "src/api.ts", line: 1, quote: "q")]
        let consumers = [ReviewConsumer(boundary: "b1", project: "team/web", file: "a.ts", quote: "q", usage: "u"),
                         ReviewConsumer(boundary: "b2", project: "team/shop", file: "b.ts", quote: "q", usage: "u")]
        let final = ReviewOverview.withOtherRepositories(flow, consumers: consumers, boundaries: boundaries)
        let edges = final.split(separator: "\n").filter { $0.contains("-.->") }
        #expect(edges == ["  akit_others -.-> x2"], "orders.ts is only an edge text; api.ts is not in openapi.ts: \(edges)")
        #expect(ReviewOverview.subgraphProblem(final) == nil)
        let ids = ReviewOverview.nodeLabels(in: final).map(\.id)
        #expect(ids.allSatisfy { $0.range(of: #"^[A-Za-z_]\w*$"#, options: .regularExpression) != nil } && ids.contains("akit_c2"), "\(ids)")
    }

    @Test func aGraphWithSubgraphsGetsTheOtherRepositories() throws {
        let boundary = ReviewBoundary(id: "b1", kind: .httpAPI, direction: .provides, name: "GET /orders", file: "api/orders.ts", line: 3, quote: "q")
        let consumer = ReviewConsumer(boundary: "b1", project: "team/web", file: "a.ts", quote: "q", usage: "u")
        let flow = "graph TD\n  subgraph backend[\"Backend\"]\n    api[\"api/orders.ts\"] --> db[(Orders DB)]\n  end\n  ui[\"Page\"] --> api"
        let overview = check(["points": ["a", "b", "c"], "flow": flow], consumers: [consumer], boundaries: [boundary])
        let final = try #require(overview.flow, "\(overview.notes)")
        #expect(overview.flowKind == .flowchart && final.contains("akit_others -.-> api"))
        #expect(ReviewOverview.subgraphProblem(final) == nil)
        #expect(final.components(separatedBy: "subgraph ").count == 3)
    }

    @Test func addsTheOtherRepositoriesToAFlowchart() throws {
        let boundary = ReviewBoundary(id: "b1", kind: .httpAPI, direction: .provides, name: "GET /api/orders", file: "api/orders.ts", line: 3,
                                      quote: "get('/api/orders')")
        let consumers = [ReviewConsumer(boundary: "b1", project: "team/web\"]-->X", file: "a.ts", quote: "q", usage: "u", breaks: true, why: "w"),
                         ReviewConsumer(boundary: "b1", project: "team/web\"]-->X", file: "b.ts", quote: "q", usage: "u"),
                         ReviewConsumer(boundary: "b1", project: "team/shop", file: "c.ts", quote: "q", usage: "u")]
        let flow = "flowchart LR\n  ui[\"Orders page\"] --> api[\"api/orders.ts GET\"]\n  class api changed"
        let overview = check(["points": ["a", "b", "c"], "flow": flow], consumers: consumers, boundaries: [boundary])
        let final = try #require(overview.flow)
        #expect(final.hasPrefix(flow) && overview.flowOriginal == flow)
        #expect(final.contains("  subgraph akit_others[\"Other repositories\"]"))
        #expect(final.contains("    akit_c1[\"team/web#quot;#93;--#gt;X · 2 uses · breaks\"]"), "\(final)")
        #expect(final.contains("    akit_c2[\"team/shop · 1 use\"]"))
        #expect(final.contains("  akit_others -.-> api"))

        let sequence = "sequenceDiagram\n  UI->>API: GET"
        #expect(check(["points": ["a", "b", "c"], "flow": sequence], consumers: consumers, boundaries: [boundary]).flow == sequence,
                "only a flowchart gets the subgraph")
        let noMatch = check(["points": ["a", "b", "c"], "flow": "flowchart LR\n  A --> B"], consumers: consumers, boundaries: [boundary])
        #expect(noMatch.flow?.contains("akit_c2") == true && noMatch.flow?.contains("-.->") == false)
    }

    @Test func renamedFilesCountByTheirOldPathToo() {
        let changed = ReviewOverview.changedFiles([GitLabFileDiff(oldPath: "src/Old.swift", newPath: "src/New.swift", diff: "", renamedFile: true),
                                                   GitLabFileDiff(oldPath: "gone.ts", newPath: "gone.ts", diff: "", deletedFile: true),
                                                   GitLabFileDiff(oldPath: "a.ts", newPath: "a.ts", diff: "")])
        #expect(changed == ["src/Old.swift", "src/New.swift", "gone.ts", "a.ts"])
    }

    @Test func overviewTextAndTranslationKeys() async throws {
        let overview = ReviewOverview(points: ["Logs less"], modules: [.init(name: "auth", files: ["src/Auth.swift"], why: "The task asks")],
                                      whySources: [.workItem], flow: "flowchart LR\n  A --> B", flowKind: .flowchart, language: .czech, notes: ["n"])
        #expect(overview.text.contains("Overview (Czech)\n  • Logs less\nModules\n  auth: The task asks\n    src/Auth.swift\nWhy from: work-item"))
        #expect(overview.text.contains("Flow (flowchart)\nflowchart LR"))
        #expect(ReviewWorkflow.Run.TranslationKey.overviewPoint(0) == "overview:point:0")
        #expect(ReviewWorkflow.Run.TranslationKey.overviewModule(2) == "overview:module:2")

        let run = try await ReviewRunFixture.make()
        let saved = ReviewOverview(points: ["One", "Two", "Three"], modules: [.init(name: "a", files: ["a.ts"], why: ""),
                                                                              .init(name: "b", files: ["b.ts"], why: "Feature #2")],
                                   whySources: [.workItem], language: .czech)
        try saved.save(in: run.folder)
        let parts = try ReviewWorkflow.load(run.folder).translationSource.parts
        let overviewParts = parts.filter { $0.key.hasPrefix("overview:") }
        #expect(overviewParts.map(\.key) == ["overview:point:0", "overview:point:1", "overview:point:2", "overview:module:1"],
                "a module without a why has nothing to translate")
        #expect(overviewParts.map(\.text) == ["One", "Two", "Three", "Feature #2"])
    }

    // MARK: - The extension's rule

    @Test func theOverviewRuleRunsInJavaScript() throws {
        #expect(ReviewExtension.source.contains(ReviewExtension.rules))
        #expect(ReviewExtension.source.contains("name: \"akit_submit_overview\"") && ReviewExtension.source.contains("const wrong = overviewProblems(params);"))
        let context = try #require(JSContext())
        context.exceptionHandler = { _, error in Issue.record("JavaScript: \(error?.toString() ?? "?")") }
        context.evaluateScript(ReviewExtension.rules)
        func problems(_ json: String) -> [String] { context.evaluateScript("overviewProblems(\(json))")?.toArray() as? [String] ?? ["?"] }

        #expect(problems(#"{"points":["a","b","c"],"modules":[{"name":"auth","files":["a.ts"],"why":"x"}],"why_sources":["work-item"],"flow":"flowchart LR","flow_kind":"flowchart"}"#).isEmpty)
        #expect(problems("{}").isEmpty)
        #expect(problems(#"{"points":"a","modules":{},"why_sources":"notes"}"#) == ["points must be a list", "modules must be a list", "why_sources must be a list"])
        let nine = (1...9).map { "\"p\($0)\"" }.joined(separator: ",")
        #expect(problems("{\"points\":[\(nine)]}") == ["at most 8 points (AKit keeps 3–5)"])
        #expect(problems("{\"points\":[\"\(String(repeating: "x", count: 401))\", 3]}") == ["points[0] must be text of 1–400 characters",
                                                                                          "points[1] must be text of 1–400 characters"])
        let modules = (1...21).map { _ in #"{"name":"m","files":["a"]}"# }.joined(separator: ",")
        #expect(problems("{\"modules\":[\(modules)]}") == ["at most 20 modules"])
        let files = (1...51).map { "\"f\($0)\"" }.joined(separator: ",")
        #expect(problems("{\"modules\":[{\"name\":\"\",\"files\":[\(files)],\"why\":5}, 3, {\"name\":\"m\",\"files\":[]}]}")
                == ["modules[0].name must be 1–120 characters", "modules[0].files: at most 50", "modules[0].why must be text of at most 400 characters",
                    "modules[1] is not an object", "modules[2].files must list the module's changed files"])
        #expect(problems(#"{"why_sources":["work-item","jira"]}"#) == ["why_sources[1] must be one of work-item, description, notes, none"])
        #expect(problems("{\"flow\":\"\(String(repeating: "x", count: 6001))\"}") == ["flow must have at most 6000 characters"])
        #expect(problems(#"{"flow":5,"flow_kind":"pie"}"#) == ["flow must be Mermaid text", "flow_kind must be flowchart or sequenceDiagram"])
    }
}

extension ReviewProcessTests {
    struct OverviewPassTests {
        /// The brief submits the overview; AKit checks it after the impact pass and adds the uses.
        @Test func theBriefsOverviewIsCheckedAfterTheImpactPass() async throws {
            var choices = ReviewRunFixture.choices
            choices.settings.summaryLanguage = .german
            let run = try await ReviewRunFixture.make(choices: choices)
            ImpactTests.playImpact(run)
            run.home.write("fake/overview-brief.json", """
            {"pass":"brief","points":["Logs less","Keeps the header out","Adds no test"],
             "modules":[{"name":"auth","files":["src/Auth.swift","src/Nope.swift"],"why":"Bug #41"}],
             "why_sources":["work-item"],
             "flow":"flowchart LR\\n  req[\\"Request\\"] --> auth[\\"Auth.swift log\\"]\\n  class auth changed","flow_kind":"flowchart"}
            """)
            let lines = LockedBox<[String]>([])
            _ = try await ReviewPasses.run(folder: run.folder, env: run.home.env, options: .init(progress: { line in lines.update { $0.append(line) } }))

            #expect(run.args("brief").contains { $0.contains("akit_submit_boundaries,akit_submit_overview") })
            #expect(!run.args("role-tests").contains { $0.contains("akit_submit_overview") })
            let prompt = try String(contentsOf: run.folder.appending(path: "prompts/brief.md"), encoding: .utf8)
            #expect(prompt.contains("in German (`de`)") && prompt.contains("work-items.md"))
            let overview = try #require(ReviewOverview.load(folder: run.folder))
            #expect(overview.language == .german && overview.modules.map(\.files) == [["src/Auth.swift"]])
            let flow = try #require(overview.flow)
            #expect(flow.contains("akit_c1[\"team/web · 1 use · breaks\"]") && flow.contains("akit_c2[\"team/shop · 1 use\"]"))
            #expect(flow.contains("akit_others -.-> auth"))
            #expect(lines.value.contains("Overview: 3 points, 1 modules, a flow."))

            let source = try ReviewWorkflow.load(run.folder).translationSource
            #expect(source.parts.map(\.key).contains("overview:point:2") && source.parts.contains { $0.key == "overview:module:0" && $0.text == "Bug #41" })
        }

        @Test func noOverviewLeavesNoFile() async throws {
            let run = try await ReviewRunFixture.make()
            run.playTypicalRun()
            run.home.write("fake/overview-brief.json", "not json")
            _ = try await ReviewPasses.run(folder: run.folder, env: run.home.env)
            #expect(ReviewOverview.load(folder: run.folder) == nil)
        }

        /// The fetch pass didn't read the parent #41 names: a gap, not an error.
        @Test func anUnreadParentIsAGap() async throws {
            let (home, _) = try ReviewProcessTests.GatherTests().setUp()
            try FileManager.default.removeItem(at: home.url.appending(path: "fake/calls/fetch-1007.json"))
            let result = try await ReviewRuns.start(mr: FakeMergeRequest.ref, project: nil, choices: ReviewRunFixture.choices, env: home.env, brain: nil)
            #expect(result.workItems.map(\.id) == [41])
            #expect(result.gaps.contains { $0.needed == "Work item #40, the parent of #41" && $0.why.contains("chain stops at #41") })
            let prompt = try String(contentsOf: ReviewPaths(home: home.url).run(result.spec.id).appending(path: "prompts/fetch.md"), encoding: .utf8)
            #expect(prompt.contains("System.LinkTypes.Hierarchy-Reverse") && prompt.contains("`System.Parent`") && prompt.contains("at most 6 levels"))
            #expect(prompt.contains("ALL its comments") && prompt.contains("`tool_search`"))
        }
    }
}
