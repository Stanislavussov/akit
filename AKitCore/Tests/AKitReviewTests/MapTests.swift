import AKitFoundation
@testable import AKitReview
import Foundation
import Testing

/// The change map (R40) and the brief's boundaries (R41).
struct MapTests {
    @Test func readsEveryKindOfImport() {
        let text = """
        import React from "react";
        import {
          a,
          b,
        } from './multi';
        import type { T } from "../types";
        export * from './api';
        export { x } from "@shop/orders/client";
        import './side-effect.css';
        const legacy = require('../legacy');
        const lazy = () => import("./Lazy");
        """
        #expect(ReviewImports.specifiers(in: text) == ["react", "./multi", "../types", "./api", "@shop/orders/client", "./side-effect.css",
                                                         "../legacy", "./Lazy"])
        #expect(ReviewImports.specifiers(in: "let x = 1\n").isEmpty)
    }

    @Test func importsInCommentsAndStringsDontCount() {
        let text = """
        // import old from './old';
        /* import gone from './gone';
           const g = require('./gone2'); */
        const doc = "import a from './b'";
        const tpl = `export * from './tpl'`;
        const url = "http://example.test/x"; import real from './real'; // after a URL
        const s = 'it\\'s'; import { y } from "./y";
        """
        #expect(ReviewImports.specifiers(in: text) == ["./real", "./y"])
        let emoji = "const e = \"😀\"; import z from './z';\n"
        #expect(ReviewImports.specifiers(in: emoji) == ["./z"], "offsets stay right after characters outside the BMP")
    }

    @Test func resolvesRelativePathsAndWorkspacePackages() {
        let known: Set<String> = ["src/api.ts", "src/ui/index.tsx", "src/util.ts", "lib/old.js", "src/esm.mts", "src/cjs.cts",
                                  "packages/orders/src/index.ts", "packages/orders/src/client.ts", "packages/kit/index.js"]
        let packages = ["@shop/orders": ReviewImports.Package(folder: "packages/orders", entries: ["./src/index.ts"]),
                        "kit": ReviewImports.Package(folder: "packages/kit", entries: [])]
        func resolve(_ specifier: String, from importer: String = "src/app.ts") -> String? {
            ReviewImports.resolve(specifier, from: importer, known: known, packages: packages)
        }
        #expect(resolve("./api") == "src/api.ts")
        #expect(resolve("./ui") == "src/ui/index.tsx", "a folder's index")
        #expect(resolve("./util.js") == "src/util.ts", "TS imports name the emitted .js")
        #expect(resolve("./esm.mjs") == "src/esm.mts" && resolve("./cjs.cjs") == "src/cjs.cts" && resolve("./esm") == "src/esm.mts")
        #expect(resolve("../lib/old") == "lib/old.js")
        #expect(resolve("../../outside") == nil, "never past the top")
        #expect(resolve("./missing") == nil)
        #expect(resolve("@shop/orders") == "packages/orders/src/index.ts", "the package's own entry")
        #expect(resolve("@shop/orders/client") == "packages/orders/src/client.ts", "a subpath under src/")
        #expect(resolve("kit") == "packages/kit/index.js")
        #expect(resolve("react") == nil && resolve("@other/pkg") == nil)
        #expect(ReviewImports.normalized("a/./b/../c") == "a/c" && ReviewImports.normalized("a/../..") == nil)
    }

    @Test func findsEdgesAndDependentsInTheWorktree() throws {
        let home = TempHome()
        let tree = home.url.appending(path: "tree")
        home.write("tree/packages/orders/package.json", #"{"name":"@shop/orders","main":"src/index.ts"}"#)
        home.write("tree/packages/orders/src/index.ts", "export * from './api';\n")
        home.write("tree/packages/orders/src/api.ts", "export const get = () => fetch('/api/orders');\n")
        home.write("tree/apps/web/src/Cart.tsx", "import { get } from '@shop/orders';\nconst Lazy = import('./Lazy');\n")
        home.write("tree/apps/web/src/legacy.js", "const api = require('../../../packages/orders/src/api');\n")
        home.write("tree/apps/web/src/Other.ts", "import x from 'react';\n")
        home.write("tree/node_modules/dep/index.js", "require('../../packages/orders/src/api');\n")
        home.write("tree/dist/bundle.js", "require('../packages/orders/src/api');\n")
        let changed: Set<String> = ["packages/orders/src/index.ts", "packages/orders/src/api.ts", "README.md"]
        let graph = ReviewImports.scan(worktree: tree, changed: changed, limits: .init())
        #expect(graph.edges.map { "\($0.from)→\($0.to)" } == ["packages/orders/src/index.ts→packages/orders/src/api.ts"])
        #expect(graph.dependents == ["apps/web/src/Cart.tsx": ["packages/orders/src/index.ts"],
                                     "apps/web/src/legacy.js": ["packages/orders/src/api.ts"]], "node_modules and dist are skipped")
        #expect(graph.notes.isEmpty)

        // .mts files are read; two packages of one name resolve to the shorter folder, with a note.
        home.write("tree/apps/web/src/boot.mts", "import { get } from '@shop/orders';\n")
        home.write("tree/vendor/copy/orders/package.json", #"{"name":"@shop/orders","main":"index.ts"}"#)
        let twice = ReviewImports.scan(worktree: tree, changed: changed, limits: .init())
        #expect(twice.dependents["apps/web/src/boot.mts"] == ["packages/orders/src/index.ts"])
        #expect(twice.notes == ["2 workspace packages are named @shop/orders (packages/orders, vendor/copy/orders); the map resolves it to packages/orders."])
        try FileManager.default.removeItem(at: tree.appending(path: "vendor"))
        try FileManager.default.removeItem(at: tree.appending(path: "apps/web/src/boot.mts"))

        let limited = ReviewImports.scan(worktree: tree, changed: changed, limits: .init(files: 1))
        #expect(!limited.notes.isEmpty, "a scan over its limit says so")

        #expect(ReviewMap.module(of: "packages/orders/src/api.ts", worktree: tree) == "packages/orders")
        #expect(ReviewMap.module(of: "apps/web/src/Cart.tsx", worktree: tree) == "apps", "no package.json: the top folder")
        #expect(ReviewMap.module(of: "README.md", worktree: tree) == ".")
        #expect(ReviewMap.module(of: "packages/orders/src/api.ts", worktree: nil) == "packages")
        home.write("tree/package.json", #"{"name":"shop"}"#)
        #expect(ReviewMap.module(of: "apps/web/src/Cart.tsx", worktree: tree) == ".", "the root's package.json")
    }

    @Test func keepsOnlyBoundariesQuotedInAChangedFile() {
        let home = TempHome()
        let tree = home.url.appending(path: "tree")
        home.write("tree/src/routes.ts", "import x from 'y';\n\nrouter.get('/api/orders/:id', handler);\n")
        home.write("tree/src/old.ts", "export const FLAG = process.env.ORDERS_FLAG;\n")
        let raw: [[String: Any]] = [
            ["kind": "http-api", "direction": "provides", "name": "GET /api/orders/:id", "file": "./src/routes.ts", "line": 40,
             "quote": "router.get('/api/orders/:id', handler);", "note": "Token glpat-abcdefghijklmnopqrst changes"],
            ["kind": "http-api", "direction": "provides", "name": "GET /api/invented", "file": "src/routes.ts", "quote": "router.get('/api/invented')"],
            ["kind": "config", "direction": "uses", "name": "ORDERS_FLAG", "file": "src/old.ts", "quote": "process.env.ORDERS_FLAG"],
            ["kind": "telepathy", "direction": "uses", "name": "x", "file": "src/routes.ts", "quote": "router.get"],
        ]
        let diffs = [GitLabFileDiff(oldPath: "src/routes.ts", newPath: "src/routes.ts", diff: "@@ -3 +3 @@\n-x\n+router.get('/api/orders/:id', handler);\n")]
        let kept = ReviewBoundaries.check(raw, diffs: diffs, worktree: tree)
        #expect(kept.map(\.name) == ["GET /api/orders/:id"], "an invented quote, an untouched file and an unknown kind are dropped")
        #expect(kept.first?.id == "b1" && kept.first?.file == "src/routes.ts")
        #expect(kept.first?.line == 3, "the anchor moves to the quote's line")
        #expect(kept.first?.note.contains("glpat-") == false, "model text is masked")
        #expect(ReviewBoundaries.check(raw, diffs: diffs, worktree: nil).isEmpty, "nothing to check against")
    }

    @Test func removedThingsCanBeBoundaries() throws {
        let home = TempHome()
        let tree = home.url.appending(path: "tree")
        home.write("tree/src/routes.ts", "import x from 'y';\nrouter.get('/api/orders', list);\n")
        let diffs = [GitLabFileDiff(oldPath: "src/routes.ts", newPath: "src/routes.ts",
                                    diff: "@@ -1,3 +1,2 @@\n import x from 'y';\n-router.delete('/api/orders/:id', remove);\n router.get('/api/orders', list);\n"),
                     GitLabFileDiff(oldPath: "src/events.ts", newPath: "src/events.ts",
                                    diff: "@@ -1,2 +0,0 @@\n-// events\n-export const ORDER_CREATED = 'orders.created';\n", deletedFile: true)]
        let raw: [[String: Any]] = [
            ["kind": "http-api", "direction": "provides", "name": "DELETE /api/orders/:id", "file": "src/routes.ts", "side": "old", "line": 9,
             "quote": "-router.delete('/api/orders/:id', remove);"],
            ["kind": "event", "direction": "provides", "name": "ORDER_CREATED", "file": "src/events.ts",
             "quote": "export const ORDER_CREATED = 'orders.created';"],
            ["kind": "http-api", "direction": "provides", "name": "GET /api/orders", "file": "src/routes.ts", "side": "old",
             "quote": "router.get('/api/orders', list);"],
        ]
        let kept = ReviewBoundaries.check(raw, diffs: diffs, worktree: tree)
        #expect(kept.map(\.name) == ["DELETE /api/orders/:id", "ORDER_CREATED"], "an unchanged line is no removed line")
        #expect(kept.map(\.side) == [.old, .old] && kept.map(\.line) == [2, 2], "the line of the old file")
        #expect(ReviewBoundaries.check(Array(raw.prefix(2)), diffs: diffs, worktree: nil).count == 2, "removed lines need no worktree")

        let encoded = String(decoding: (try? ReviewJSON.encoder.encode(kept)) ?? Data(), as: UTF8.self)
        #expect(encoded.contains("\"side\" : \"old\""))
        let older = #"[{"id":"b1","kind":"config","direction":"uses","name":"X","file":"a.ts","line":1,"quote":"q","note":""}]"#
        #expect(try ReviewJSON.decoder.decode([ReviewBoundary].self, from: Data(older.utf8)).first?.isRemoved == false, "old files decode")

        let map = ReviewMap.make(diffs: diffs, worktree: tree, findings: [], boundaries: kept, consumers: [])
        #expect(map.text.contains("b1 removed provides http-api: DELETE /api/orders/:id  (src/routes.ts:2, old line)"))
        #expect(map.edges.contains(.init(from: "file:src/events.ts", to: "boundary:b2", kind: .declares)))
        let spec = try PlanTests.spec()
        let prompt = ReviewPrompts.impact(spec: spec, boundaries: kept, servers: ["gitlab"])
        #expect(prompt.contains("`b1` REMOVED provides http-api") && prompt.contains("every use of it you find breaks"))
        #expect(!ReviewPrompts.impact(spec: spec, boundaries: [], servers: ["gitlab"]).contains("A REMOVED boundary"))
        #expect(ReviewPrompts.brief(spec: spec).contains("`side: \"old\"`"))
    }

    @Test func aBoundaryNeedsItsNameNearAWholeQuote() {
        let home = TempHome()
        let tree = home.url.appending(path: "tree")
        home.write("tree/src/api.ts", "export const ORDERS_URL = env('ORDERS_URL');\nfoo();\n\n\n\n\n\nexport { Widget } from '@acme/ui';\n")
        let diffs = [GitLabFileDiff(oldPath: "src/api.ts", newPath: "src/api.ts", diff: "@@ -0,0 +1,8 @@\n+x\n", newFile: true)]
        func keep(_ name: String, _ quote: String) -> Bool {
            !ReviewBoundaries.check([["kind": "config", "direction": "uses", "name": name, "file": "src/api.ts", "quote": quote]],
                                    diffs: diffs, worktree: tree).isEmpty
        }
        #expect(keep("ORDERS_URL", "export const ORDERS_URL = env('ORDERS_URL');"))
        #expect(keep("@acme/ui", "export { Widget } from '@acme/ui';"), "the last segment, ui")
        #expect(!keep("GET /api/payments/:id", "export const ORDERS_URL = env('ORDERS_URL');"), "a name the quote doesn't hold")
        #expect(!keep("ORDERS_URL", "export { Widget } from '@acme/ui';"), "the name is more than 3 lines away")
        #expect(!keep("ORDERS_URL", "env("), "a short piece of a line")
        #expect(keep("foo", "foo();"), "a short quote that is the whole line")
        #expect(ReviewBoundaries.searchTerms("GET /api/orders/:id") == ["get /api/orders/:id", "orders"])
        #expect(ReviewBoundaries.searchTerms("./OrderWidget") == ["./orderwidget", "orderwidget"])
        #expect(ReviewCandidates.quoteHits("env(", in: ["x = env('a')"]) == [0], "findings keep their 4-character pieces")
        #expect(!ReviewConsumers.quoted("env(", in: ["x = env('a')"]) && ReviewConsumers.quoted("env('a')", in: ["env('a')"]),
                "a use's quote too: 12 characters or the whole line")
    }

    @Test func boundariesHaveCaps() {
        let home = TempHome()
        let tree = home.url.appending(path: "tree")
        home.write("tree/a.ts", "export const ORDERS_URL = 1;\n")
        let diffs = [GitLabFileDiff(oldPath: "a.ts", newPath: "a.ts", diff: "@@ -0,0 +1 @@\n+x\n", newFile: true)]
        let item: [String: Any] = ["kind": "config", "direction": "provides", "name": "ORDERS_URL", "file": "a.ts",
                                   "quote": "export const ORDERS_URL = 1;" + String(repeating: "\n// x", count: 200), "note": String(repeating: "n", count: 400)]
        let kept = ReviewBoundaries.check(Array(repeating: item, count: 60), diffs: diffs, worktree: tree)
        #expect(kept.count == 50 && kept[0].quote.count == 500 && kept[0].note.count == 300)
        let source = ReviewExtension.source
        #expect(source.contains("list.length > 50") && source.contains("b.quote.length > 500") && source.contains("b.note.length > 300"))
        #expect(source.contains(#"b.side !== "new" && b.side !== "old""#))
    }

    @Test func aToolArgumentThatIsNoListIsAnError() {
        let source = ReviewExtension.source
        for key in ["findings", "verdicts", "boundaries", "consumers"] {
            #expect(source.contains("listOf(params, \"\(key)\")"), "\(key)")
        }
        #expect(source.contains("must be a list") && !source.contains("Array.isArray(params?."))
    }

    @Test func countsLinesOfAGitLabDiff() {
        // GitLab's diff text has no file headers: a removed `-- comment` and an added `++i` are lines too.
        let diff = "@@ -1,2 +1,2 @@\n--- a SQL comment\n+++i;\n keep\n\\ No newline at end of file\n"
        #expect(DiffPositions.lineCounts(diff) == (1, 1))
        #expect(DiffPositions.lineCounts("diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n") == (1, 1), "a git diff's headers don't count")
        let changes = ReviewGather.changesText([GitLabFileDiff(oldPath: "q.sql", newPath: "q.sql", diff: diff)], isIgnored: { _ in false })
        #expect(changes.contains("+1 −1"))
        let map = ReviewMap.make(diffs: [GitLabFileDiff(oldPath: "q.sql", newPath: "q.sql", diff: diff)], worktree: nil, findings: [], boundaries: [], consumers: [])
        let node = map.nodes.first { $0.id == "file:q.sql" }
        #expect(node?.added == 1 && node?.removed == 1)
    }

    @Test func worstSeverityCountsOnlyWhatThePlanCouldPost() {
        func finding(_ id: String, _ severity: ReviewSeverity, verdict: ReviewFinding.Verdict.Value? = nil, raised: ReviewSeverity? = nil,
                     file: String = "a.ts") -> ReviewFinding {
            ReviewFinding(id: id, role: "bug-hunter", file: file, line: 1, title: id, evidence: "", why: "", severity: severity, confidence: 0.9,
                          verifier: verdict.map { .init(verdict: $0, note: "", severity: raised) })
        }
        var old = finding("f5", .critical, verdict: .confirmed)
        old.preExisting = true
        var question = finding("f7", .critical, verdict: .confirmed)
        question.kind = .question
        var unfounded = finding("f8", .critical, verdict: .confirmed)
        unfounded.evidenceFound = false
        let result = ReviewMap.worstSeverities([finding("f1", .critical), finding("f2", .critical, verdict: .rejected), finding("f3", .high, verdict: .merged),
                                                finding("f4", .medium, verdict: .confirmed, raised: .high), old, question, unfounded,
                                                finding("f9", .critical, verdict: .question), finding("f6", .nit, verdict: .confirmed, file: "b.ts"),
                                                finding("f10", .high, file: "c.ts")])
        #expect(result["a.ts"]?.severity == .high && result["a.ts"]?.ids == ["f4"], "unverified, questions, missing evidence and older don't count")
        #expect(result["b.ts"]?.severity == .nit && result["c.ts"] == nil)
    }

    @Test func buildsLanesAndEscapesMermaid() throws {
        let home = TempHome()
        let tree = home.url.appending(path: "tree")
        home.write("tree/orders/package.json", #"{"name":"orders"}"#)
        home.write("tree/orders/api.ts", "export const a = 1;\nrouter.get(\"/api/orders\")\n")
        home.write("tree/orders/ui.tsx", "import { a } from './api';\n")
        home.write("tree/checkout/Cart.tsx", "import { a } from '../orders/api';\n")
        home.write("tree/helm/values.yaml", "url: x\n")
        let diffs = [GitLabFileDiff(oldPath: "orders/api.ts", newPath: "orders/api.ts", diff: "@@ -1 +1,2 @@\n-x\n+a\n+b\n"),
                     GitLabFileDiff(oldPath: "orders/ui.tsx", newPath: "orders/ui.tsx", diff: "@@ -0,0 +1 @@\n+c\n", newFile: true),
                     GitLabFileDiff(oldPath: "helm/values.yaml", newPath: "helm/values.yaml", diff: "@@ -1 +1 @@\n-u\n+v\n")]
        let findings = [ReviewFinding(id: "f1", role: "contracts", file: "orders/api.ts", line: 2, title: "t", evidence: "", why: "",
                                      severity: .high, confidence: 0.9, verifier: .init(verdict: .confirmed, note: ""))]
        let boundary = ReviewBoundary(id: "b1", kind: .httpAPI, direction: .provides, name: "GET \"/api/orders\" [v2]", file: "orders/api.ts",
                                      line: 2, quote: "router.get(\"/api/orders\")")
        let uses = [ReviewConsumer(boundary: "b1", project: "shop/mfe", file: "src/Orders.tsx", line: 4, quote: "fetch('/api/orders')",
                                   usage: "reads the list", breaks: true, why: "the field is gone"),
                    ReviewConsumer(boundary: "b1", project: "shop/mfe", file: "src/Orders.tsx", line: 9, quote: "fetch('/api/orders')", usage: "again")]
        let map = ReviewMap.make(diffs: diffs, worktree: tree, findings: findings, boundaries: [boundary], consumers: uses)

        #expect(map.nodes(in: .change).map(\.id) == ["module:helm", "file:helm/values.yaml", "module:orders", "file:orders/api.ts",
                                                       "file:orders/ui.tsx", "dependent:checkout/Cart.tsx"])
        let module = map.nodes.first { $0.id == "module:orders" }
        #expect(module?.added == 3 && module?.removed == 1 && module?.severity == .high && module?.label == "orders/")
        #expect(map.nodes.first { $0.id == "file:orders/ui.tsx" }?.status == "added")
        #expect(map.edges.contains(.init(from: "file:orders/ui.tsx", to: "file:orders/api.ts", kind: .imports)))
        #expect(map.edges.contains(.init(from: "dependent:checkout/Cart.tsx", to: "file:orders/api.ts", kind: .imports)))
        #expect(map.edges.contains(.init(from: "file:orders/api.ts", to: "boundary:b1", kind: .declares)))
        #expect(map.edges.contains(.init(from: "boundary:b1", to: "consumer:shop/mfe:src/Orders.tsx", kind: .usedBy, breaks: true)))
        #expect(map.nodes(in: .others).map(\.id) == ["project:shop/mfe", "consumer:shop/mfe:src/Orders.tsx"])
        #expect(map.nodes.first { $0.id == "project:shop/mfe" }?.consumers?.count == 2)

        let mermaid = map.mermaid
        #expect(mermaid.hasPrefix("flowchart LR\n"))
        #expect(mermaid.contains("subgraph change[\"This change\"]") && mermaid.contains("subgraph boundaries[\"Boundaries\"]")
                && mermaid.contains("subgraph others[\"Other repositories\"]"))
        #expect(mermaid.contains("api.ts +2 −1 · high"))
        #expect(mermaid.contains("GET #quot;/api/orders#quot; #91;v2#93;"), "quotes and brackets never end a label")
        let faded = try #require(map.nodes.firstIndex { $0.kind == .dependent })
        #expect(mermaid.contains("== breaks ==>") && mermaid.contains("-.->") && mermaid.contains("class n\(faded + 1) dependent"))
        #expect(ReviewMap.escaped("a(b){c}<d>#e`f|g\nh") == "a#40;b#41;#123;c#125;#lt;d#gt;#35;e#96;f#124;g h")
        #expect(ReviewMap.escaped("a\rb\u{2028}c\u{2029}d\u{0}e\te\u{85}f\r\ng") == "a b c d e e f g", "control characters and separators are spaces")

        let text = map.text
        #expect(text.contains("This change\n  helm/  +1 −1\n"))
        #expect(text.contains("  orders/  +3 −1  ● high\n    api.ts  +2 −1  ● high\n    ui.tsx  +1 −0  (added)"))
        #expect(text.contains("┄ checkout/Cart.tsx → orders/api.ts"))
        #expect(text.contains("b1 provides http-api: GET \"/api/orders\" [v2]  (orders/api.ts:2)"))
        #expect(text.contains("shop/mfe  2 uses, 1 broken") && text.contains("src/Orders.tsx:4 uses b1 · breaks: the field is gone"))

        let decoded = (try? ReviewJSON.encoder.encode(map)).flatMap { try? ReviewJSON.decoder.decode(ReviewMap.self, from: $0) }
        #expect(decoded?.nodes == map.nodes && decoded?.edges == map.edges)
    }
}

extension ReviewProcessTests {
    /// The brief's boundaries are checked after it, and the map is saved at the end of the passes.
    struct MapRunTests {
        @Test func theRunKeepsBoundariesAndSavesItsMap() async throws {
            let run = try await ReviewRunFixture.make()
            run.playTypicalRun()
            run.home.write("fake/boundaries-brief.json", """
            {"pass":"brief","boundaries":[
              {"kind":"config","direction":"uses","name":"auth header log","file":"src/Auth.swift","line":3,"quote":"log(\\"Auth: \\\\(header)\\")","note":"n"},
              {"kind":"event","direction":"provides","name":"made up","file":"src/Auth.swift","quote":"publish(topic)"}
            ]}
            """)
            _ = try await ReviewPasses.run(folder: run.folder, env: run.home.env)

            #expect(run.args("brief").contains { $0.contains("akit_submit_boundaries") })
            #expect(!run.args("role-tests").contains { $0.contains("akit_submit_boundaries") }, "only the brief names boundaries")
            let boundaries = try #require(ReviewJSON.read([ReviewBoundary].self, from: run.folder.appending(path: "boundaries.json")))
            #expect(boundaries.map(\.name) == ["auth header log"])

            let saved = try #require(ReviewJSON.read(ReviewMap.self, from: run.folder.appending(path: "map.json")))
            let file = try #require(saved.nodes.first { $0.id == "file:src/Auth.swift" })
            #expect(file.severity == .high && file.added == 1 && file.parent == "module:src")
            #expect(saved.edges.contains(.init(from: "file:src/Auth.swift", to: "boundary:b1", kind: .declares)))

            // A run from before the map gets one when it is asked for.
            try FileManager.default.removeItem(at: run.folder.appending(path: "map.json"))
            #expect(ReviewMap.load(folder: run.folder)?.nodes.count == saved.nodes.count)
            #expect(FileManager.default.fileExists(atPath: run.folder.appending(path: "map.json").path))
            try FileManager.default.removeItem(at: run.folder.appending(path: "map.json"))
            try FileManager.default.removeItem(at: run.folder.appending(path: "worktree/.git"))
            #expect(ReviewMap.load(folder: run.folder) == nil, "no map and nothing to make one from")
        }

        @Test func discussChangesTheFindingsAndTheMapFollows() async throws {
            let run = try await ReviewRunFixture.make()
            run.playTypicalRun()
            _ = try await ReviewPasses.run(folder: run.folder, env: run.home.env)
            let mapFile = run.folder.appending(path: "map.json")
            let findingsFile = run.folder.appending(path: "findings.json")
            #expect(ReviewMap.load(folder: run.folder)?.nodes.first { $0.id == "file:src/Auth.swift" }?.severity == .high)

            // Discuss in Pi rejects the findings: findings.json is newer than the map.
            var findings = try #require(ReviewJSON.read(ReviewFindingsFile.self, from: findingsFile))
            for index in findings.findings.indices { findings.findings[index].verifier = .init(verdict: .rejected, note: "no") }
            try ReviewJSON.write(findings, to: findingsFile)
            try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-60)], ofItemAtPath: mapFile.path)
            #expect(ReviewMap.load(folder: run.folder)?.nodes.first { $0.id == "file:src/Auth.swift" }?.severity == nil)
            #expect(ReviewJSON.read(ReviewMap.self, from: mapFile)?.nodes.first { $0.id == "file:src/Auth.swift" }?.severity == nil, "saved again")
        }

        @Test func aFailedMapLeavesNoOldOne() async throws {
            let run = try await ReviewRunFixture.make()
            run.playTypicalRun()
            try ReviewMap(notes: ["from an earlier run"]).save(in: run.folder)
            try FileManager.default.removeItem(at: run.folder.appending(path: "gitlab/snapshot.json"))
            _ = try? await ReviewPasses.run(folder: run.folder, env: run.home.env)
            #expect(!FileManager.default.fileExists(atPath: run.folder.appending(path: "map.json").path))
        }
    }
}
