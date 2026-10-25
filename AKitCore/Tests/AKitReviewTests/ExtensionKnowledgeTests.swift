import AKitFoundation
@testable import AKitReview
import Foundation
import Testing

extension ReviewProcessTests {
    /// The knowledge base's tools in the review extension (v8, K18): `akit_kb_search` and
    /// `akit_kb_show`, only with `AKIT_REVIEW_AKIT` and `AKIT_REVIEW_KB_BASE`. Without them, the
    /// tools Pi declares to the model are exactly those of v7, so the requests stay the same.
    struct ExtensionKnowledgeTests {
        /// SHA-256 of what v7 registered (name, label, description, parameters of every tool, then
        /// the events), as `harness.mjs` prints it, per mode. Taken from v7's source on 2026-10-25.
        static let v7 = ["review": "0c55bf9e3db507e7", "fetch": "6ad5502c16dc0dd6", "send": "62e5f656af48d547"]

        static let harness = """
        import { pathToFileURL } from "node:url";
        const mod = await import(pathToFileURL(process.argv[2]).href);
        const tools = []; const events = [];
        const pi = { registerTool: (t) => tools.push(t), on: (e) => events.push(e), appendEntry() {}, getAllTools: () => [] };
        mod.default(pi);
        if (process.argv[3]) {
          const tool = tools.find((t) => t.name === process.argv[3]);
          const result = await tool.execute("id", JSON.parse(process.argv[4] ?? "{}"));
          console.log(JSON.stringify(result));
        } else {
          console.log(JSON.stringify({ tools: tools.map((t) => ({ name: t.name, label: t.label, description: t.description, parameters: t.parameters })), events }));
        }
        """

        /// Node, which Pi runs on: a real binary (a version manager's shim fails in a test's environment).
        static var node: URL? {
            let home = URL(filePath: NSHomeDirectory())
            let installs = home.appending(path: ".local/share/mise/installs/node")
            let versions = FileWalk.children(of: installs).filter { FileManager.default.isExecutableFile(atPath: $0.appending(path: "bin/node").path) }
                .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
            let candidates = versions.map { $0.appending(path: "bin/node") }
                + ["/opt/homebrew/bin/node", "/usr/local/bin/node"].map { URL(filePath: $0) }
                + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { URL(filePath: String($0)).appending(path: "node") }
            return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) && !$0.path.contains("/shims/") }
        }

        /// Runs the extension in node with a fake `pi`: what it registers, or one tool's answer.
        func load(_ home: TempHome, mode: String, extra: [String: String] = [:], tool: String? = nil, params: String = "{}") throws -> String {
            let node = try #require(Self.node, "node is needed: Pi runs on it")
            let ext = home.write("ext/akit-review.ts", ReviewExtension.source)
            let harness = home.write("ext/harness.mjs", Self.harness)
            var environment = ["PATH": "/usr/bin:/bin", "HOME": home.url.path, "AKIT_REVIEW_RUN": home.url.appending(path: "run").path,
                               "AKIT_REVIEW_MODE": mode, "AKIT_REVIEW_PASS": "role-x", "AKIT_REVIEW_LINKS": #"["https://x"]"#]
            environment.merge(extra) { $1 }
            let result = ProcessRunner.runAndWait(node, arguments: [harness.path, ext.path] + (tool.map { [$0, params] } ?? []),
                                                  environment: environment, timeout: 60)
            let output = try #require(result, "node didn't start")
            #expect(output.succeeded, "\(output.output)")
            return output.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func hash(_ text: String) -> String { String(Checksum.sha256(Data((text + "\n").utf8)).prefix(16)) }

        func names(_ json: String) throws -> [String] {
            let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            return (object["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        }

        /// A fake akit that prints each argument on its own line, in brackets.
        func fakeAkit(_ home: TempHome) -> URL {
            home.write("bin/akit", "#!/bin/sh\nfor a in \"$@\"; do echo \"[$a]\"; done\n", executable: true)
        }

        @Test func versionEight() {
            #expect(ReviewExtension.version == 8)
            #expect(ReviewExtension.source.hasPrefix("// akit-review.ts v8:"))
            #expect(ReviewExtension.source.contains("const kbTimeout = 20000;") && ReviewExtension.source.contains("const kbOutputCap = 65536;"))
            #expect(ReviewExtension.source.contains("execFile(akit, argv, { shell: false, timeout: kbTimeout, maxBuffer: kbOutputCap"))
            #expect(!ReviewExtension.source.contains("execSync") && !ReviewExtension.source.contains("spawn("), "no shell")
        }

        /// Without the two variables (and in the fetch and send passes even with them), the
        /// extension registers exactly what v7 did.
        @Test func withoutTheBaseTheToolsAreThoseOfV7() throws {
            let home = TempHome()
            let akit = fakeAkit(home)
            let kb = ["AKIT_REVIEW_AKIT": akit.path, "AKIT_REVIEW_KB_BASE": home.url.path]
            for (mode, expected) in Self.v7 {
                #expect(hash(try load(home, mode: mode)) == expected, "\(mode)")
                if mode != "review" { #expect(hash(try load(home, mode: mode, extra: kb)) == expected, "\(mode) with a base") }
            }
            #expect(hash(try load(home, mode: "review", extra: ["AKIT_REVIEW_AKIT": akit.path])) == Self.v7["review"], "akit alone")
            #expect(hash(try load(home, mode: "review", extra: ["AKIT_REVIEW_KB_BASE": home.url.path])) == Self.v7["review"], "a base alone")
            #expect(hash(try load(home, mode: "review", extra: ["AKIT_REVIEW_AKIT": "akit", "AKIT_REVIEW_KB_BASE": home.url.path]))
                    == Self.v7["review"], "a relative akit")
        }

        @Test func withTheBaseTheReviewPassesGetTwoTools() throws {
            let home = TempHome()
            let kb = ["AKIT_REVIEW_AKIT": fakeAkit(home).path, "AKIT_REVIEW_KB_BASE": "/kb/work"]
            let registered = try load(home, mode: "review", extra: kb)
            #expect(try names(registered) == ["akit_submit_findings", "akit_report_context_gap", "akit_kb_search", "akit_kb_show"])
            #expect(registered.contains("untrusted"))
        }

        /// Fixed arguments, one per value, no shell; a limit over 10 is 10; a value that looks
        /// like an option is refused; the call is saved like an MCP answer.
        @Test func theToolsRunAkitWithFixedArguments() throws {
            let home = TempHome()
            let kb = ["AKIT_REVIEW_AKIT": fakeAkit(home).path, "AKIT_REVIEW_KB_BASE": "/kb/work"]
            let search = try load(home, mode: "review", extra: kb, tool: "akit_kb_search",
                                  params: #"{"query":"order created; rm -rf / $(id)","area":"payments","limit":50}"#)
            #expect(search.contains(#"[kb]\n[search]\n[order created; rm -rf / $(id)]\n[--area]\n[payments]\n[--limit]\n[10]\n[--json]\n[--scrub]\n[--max-tokens]\n[4000]\n[--base]\n[/kb/work]\n"#),
                    "\(search)")
            let show = try load(home, mode: "review", extra: kb, tool: "akit_kb_show", params: #"{"note":"payments/orders-api","section":"Events"}"#)
            #expect(show.contains(#"[kb]\n[show]\n[payments/orders-api]\n[--section]\n[Events]\n[--json]\n[--scrub]"#), "\(show)")
            let option = try load(home, mode: "review", extra: kb, tool: "akit_kb_show", params: #"{"note":"--base"}"#)
            #expect(option.contains("Not run") && option.contains(#""isError":true"#))
            let saved = FileWalk.children(of: home.url.appending(path: "run/mcp/calls"))
            #expect(saved.count == 2)
            let call = try #require(saved.first.flatMap { try? String(contentsOf: $0, encoding: .utf8) })
            #expect(call.contains(#""server":"akit-kb""#) && call.contains(#""pass":"role-x""#))
        }

        /// Swift sets the variables only with a base folder and an absolute, executable akit.
        @Test func theEnvironmentNeedsABaseAndAnAkit() throws {
            let home = TempHome()
            let akit = fakeAkit(home)
            let plain = home.write("bin/not-executable", "x")
            try FileManager.default.createDirectory(at: home.url.appending(path: "kb/areas"), withIntermediateDirectories: true)
            var spec = try ReviewResolver.resolve(catalog: ReviewCatalog.load(home: home.url, brain: nil), profile: nil,
                                                  choices: ReviewRunFixture.choices, mergeRequest: FakeMergeRequest.ref, id: "r1").spec
            #expect(ReviewPasses.knowledgeEnvironment(spec: spec, env: home.env, akit: akit).isEmpty, "no base")
            spec.knowledgeBasePath = home.url.appending(path: "kb").path
            #expect(ReviewPasses.knowledgeEnvironment(spec: spec, env: home.env, akit: akit)
                    == ["AKIT_REVIEW_AKIT": akit.path, "AKIT_REVIEW_KB_BASE": home.url.appending(path: "kb").path])
            #expect(ReviewPasses.knowledgeEnvironment(spec: spec, env: home.env, akit: plain).isEmpty, "not executable")
            #expect(ReviewPasses.knowledgeEnvironment(spec: spec, env: home.env, akit: URL(filePath: "/nope/akit")).isEmpty, "missing")
            // Without one given: the akit on the search paths (the test process isn't akit).
            #expect(ReviewPasses.knowledgeEnvironment(spec: spec, env: home.env)["AKIT_REVIEW_AKIT"] == akit.resolvingSymlinksInPath().path)
            spec.knowledgeBasePath = "kb"
            #expect(ReviewPasses.knowledgeEnvironment(spec: spec, env: home.env, akit: akit).isEmpty, "a relative base")
        }
    }
}
