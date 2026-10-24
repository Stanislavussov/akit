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

    @Test func resolvesRelativePathsAndWorkspacePackages() {
        let known: Set<String> = ["src/api.ts", "src/ui/index.tsx", "src/util.ts", "lib/old.js",
                                  "packages/orders/src/index.ts", "packages/orders/src/client.ts", "packages/kit/index.js"]
        let packages = ["@shop/orders": ReviewImports.Package(folder: "packages/orders", entries: ["./src/index.ts"]),
                        "kit": ReviewImports.Package(folder: "packages/kit", entries: [])]
        func resolve(_ specifier: String, from importer: String = "src/app.ts") -> String? {
            ReviewImports.resolve(specifier, from: importer, known: known, packages: packages)
        }
        #expect(resolve("./api") == "src/api.ts")
        #expect(resolve("./ui") == "src/ui/index.tsx", "a folder's index")
        #expect(resolve("./util.js") == "src/util.ts", "TS imports name the emitted .js")
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
        let kept = ReviewBoundaries.check(raw, changed: ["src/routes.ts"], worktree: tree)
        #expect(kept.map(\.name) == ["GET /api/orders/:id"], "an invented quote, an untouched file and an unknown kind are dropped")
        #expect(kept.first?.id == "b1" && kept.first?.file == "src/routes.ts")
        #expect(kept.first?.line == 3, "the anchor moves to the quote's line")
        #expect(kept.first?.note.contains("glpat-") == false, "model text is masked")
        #expect(ReviewBoundaries.check(raw, changed: ["src/routes.ts"], worktree: nil).isEmpty, "nothing to check against")
    }

    @Test func worstSeverityIgnoresRejectedMergedAndOlderFindings() {
        func finding(_ id: String, _ severity: ReviewSeverity, verdict: ReviewFinding.Verdict.Value? = nil, raised: ReviewSeverity? = nil,
                     file: String = "a.ts") -> ReviewFinding {
            ReviewFinding(id: id, role: "bug-hunter", file: file, line: 1, title: id, evidence: "", why: "", severity: severity, confidence: 0.9,
                          verifier: verdict.map { .init(verdict: $0, note: "", severity: raised) })
        }
        var old = finding("f5", .critical)
        old.preExisting = true
        let result = ReviewMap.worstSeverities([finding("f1", .low), finding("f2", .critical, verdict: .rejected), finding("f3", .high, verdict: .merged),
                                                finding("f4", .medium, verdict: .confirmed, raised: .high), old, finding("f6", .nit, file: "b.ts")])
        #expect(result["a.ts"]?.severity == .high && result["a.ts"]?.ids == ["f1", "f4"])
        #expect(result["b.ts"]?.severity == .nit)
    }

    @Test func buildsLanesAndEscapesMermaid() {
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
                                      severity: .high, confidence: 0.9)]
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
        #expect(mermaid.contains("== breaks ==>") && mermaid.contains("-.->") && mermaid.contains("class n6 dependent"))
        #expect(ReviewMap.escaped("a(b){c}<d>#e`f|g\nh") == "a#40;b#41;#123;c#125;#lt;d#gt;#35;e#96;f#124;g h")

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
    }
}
