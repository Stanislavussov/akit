import AKitFoundation
import AKitLab
import AKitReview
import Foundation
import Testing
@testable import AKitCommandLine

extension AKitCLITests {
    /// `akit review` in the fake home.
    func review(_ arguments: [String]) async -> (code: Int32, out: String, err: String) {
        var out: [String] = [], err: [String] = []
        let code = await AKitCLI.run(["review"] + arguments, env: env, cwd: home, out: { out.append($0) }, err: { err.append($0) })
        return (code, out.joined(separator: "\n"), err.joined(separator: "\n"))
    }

    @Test func reviewConfigShowNamesSources() async throws {
        try write(".akit/local/review/projects/app.yaml", """
        gitlab: { host: https://gitlab.test, project_path: team/app }
        mcp: { servers: [gitlab], write: [create_draft_note] }
        review: { max_inline: 4 }

        """)
        let shown = await review(["config", "show", "--project", "app", "--scenario", "bugfix", "--brain", home.appending(path: "none").path])
        #expect(shown.code == 0, "\(shown)")
        #expect(shown.out.contains("scenario: bugfix  [run]"))
        #expect(shown.out.contains("max_inline: 4  [project]"))
        #expect(shown.out.contains("bug-hunter [built-in] required by bugfix"))
        #expect(shown.out.contains("servers: gitlab") && shown.out.contains("write (Send Drafts only): create_draft_note"))
        #expect(await review(["config", "show", "--project", "nope"]).err.contains("no project profile nope"))
    }

    /// `kb-gaps RUN`: what the review missed in the knowledge base, each with its propose command.
    @Test func reviewKnowledgeGaps() async throws {
        let run = ".akit/local/review/runs/r1"
        try write("\(run)/run.json", "{}")
        try write("\(run)/mcp/calls/role-a-1-0001.json", #"{"pass":"role-a","tool":"akit_kb_search","input":"{\"query\":\"refunds\"}","text":["{\"results\":[],\"stale\":false}"],"isError":false}"#)
        try write("\(run)/gaps.json", #"[{"id":"g1","system":"knowledge","needed":"Who reads order.created","why":"A field goes","howToGet":"","effect":"","reportedBy":"role-a"}]"#)
        let shown = await review(["kb-gaps", "r1"])
        #expect(shown.code == 0, "\(shown)")
        #expect(shown.out.contains("k1  No answer for the search \"refunds\"  [role-a]"), "\(shown.out)")
        #expect(shown.out.contains("k2  Needed: Who reads order.created (A field goes)") && shown.out.contains("akit kb propose --note AREA/NAME"))
        let json = await review(["kb-gaps", "r1", "--json"])
        #expect(json.out.contains("\"kind\" : \"search\"") || json.out.contains("\"kind\":\"search\""), "\(json.out)")
        #expect(await review(["kb-gaps", "nope"]).err.contains("There is no review run nope"))
    }

    /// `--verifier-thinking`: a level alone keeps the configured verifier model; a wrong level stops.
    @Test func reviewVerifierThinking() async throws {
        try write(".akit/local/review/projects/app.yaml", """
        gitlab: { host: https://gitlab.test, project_path: team/app }
        review: { models: { verifier: fake/strong }, thinking: { verifier: high } }

        """)
        let none = home.appending(path: "none").path
        let shown = await review(["config", "show", "--project", "app", "--brain", none, "--verifier-thinking", "low"])
        #expect(shown.code == 0, "\(shown)")
        #expect(shown.out.contains("fake/strong") && shown.out.contains("low") && !shown.out.contains("thinking high"), "\(shown.out)")
        #expect(await review(["config", "show", "--project", "app", "--brain", none, "--verifier-thinking", "huge"]).err
            .contains("--verifier-thinking is one of off, minimal"))
        #expect(await review(["--help"]).out.contains("--verifier-thinking L"))
    }

    /// `--note`, `--note-file`, `--link`, `--extra-server`: the run's own context.
    @Test func reviewContextOptions() async throws {
        try write(".akit/local/review/projects/app.yaml", """
        gitlab: { host: https://gitlab.test, project_path: team/app }
        mcp: { extra_servers: [confluence] }

        """)
        try write("notes.md", "CSV is decided.\n")
        let none = home.appending(path: "none").path
        let shown = await review(["config", "show", "--project", "app", "--brain", none, "--note", "Focus on retries.", "--note-file", "notes.md",
                                  "--link", "https://www.figma.com/design/AbC/Checkout", "--extra-server", "figma,playwright"])
        #expect(shown.code == 0, "\(shown)")
        #expect(shown.out.contains("context server (read only): confluence  [project]"))
        #expect(shown.out.contains("context server (read only): figma  [run]"))
        #expect(shown.out.contains("context server (read only): playwright  [run]  ! a browser, file or web fetch server"))
        #expect(shown.out.contains("Links [run]:\n  https://www.figma.com/design/AbC/Checkout"))
        #expect(shown.out.contains("Notes [run]: 34 characters"), "both notes, joined: \(shown.out)")
        let base = await review(["config", "show", "--project", "app", "--brain", none, "--extra-server", "gitlab-corp"])
        #expect(base.out.contains("! extra server gitlab-corp is one of the run's own servers"), "\(base.out)")
        let http = await review(["config", "show", "--project", "app", "--brain", none, "--link", "http://intranet/spec"])
        #expect(http.code != 0 && http.err.contains("not an https link"))
        #expect(await review(["config", "show", "--brain", none, "--note-file", "missing.md"]).err.contains("Can't read the notes file"))
        #expect(await review(["--help"]).out.contains("--link URL"))
    }

    /// `--impact`: whether the impact pass looks in other repositories, over the profile's choice.
    @Test func reviewImpactOption() async throws {
        try write(".akit/local/review/projects/app.yaml", """
        gitlab: { host: https://gitlab.test, project_path: team/app }
        review: { impact: off }

        """)
        let none = home.appending(path: "none").path
        #expect(await review(["config", "show", "--project", "app", "--brain", none]).out.contains("impact: off  [project]"))
        let shown = await review(["config", "show", "--project", "app", "--brain", none, "--impact", "always"])
        #expect(shown.code == 0 && shown.out.contains("impact: always  [run]"), "\(shown)")
        #expect(await review(["config", "show", "--brain", none, "--impact", "maybe"]).err.contains("--impact takes auto, off or always"))
        #expect(await review(["--help"]).out.contains("--impact auto|off|always"))
    }

    /// `--knowledge-base`, `--knowledge-budget`: the knowledge card of one run (K18), over the profile's.
    @Test func reviewKnowledgeOptions() async throws {
        try write(".akit/local/review/projects/app.yaml", """
        gitlab: { host: https://gitlab.test, project_path: team/app }
        knowledge_base: work

        """)
        let none = home.appending(path: "none").path
        let profile = await review(["config", "show", "--project", "app", "--brain", none])
        #expect(profile.out.contains("knowledge_base: work  [project]") && profile.out.contains("knowledge_budget: 8000  [built-in]"), "\(profile)")
        let run = await review(["config", "show", "--project", "app", "--brain", none, "--knowledge-base", "~/kb", "--knowledge-budget", "4000"])
        #expect(run.out.contains("knowledge_base: ~/kb  [run]") && run.out.contains("knowledge_budget: 4000  [run]"), "\(run)")
        let zero = await review(["config", "show", "--project", "app", "--brain", none, "--knowledge-budget", "0"])
        #expect(zero.code != 0 && zero.err.contains("--knowledge-budget needs a whole number above 0"))
        #expect(await review(["--help"]).out.contains("--knowledge-budget N"))
    }

    @Test func reviewNeedsAMergeRequest() async throws {
        #expect(await review(["https://gitlab.test/a/-/issues/1"]).err.contains("not a merge request address"))
        let help = await review(["--help"])
        #expect(help.out.contains("akit review check [--project P]") && !help.out.contains("token"))
        #expect(await review(["token", "gitlab", "https://gitlab.test"]).code != 0, "tokens are gone: Pi's MCP servers connect")
    }

    /// `akit review map RUN`: the saved map as text, JSON or Mermaid; a clear error without one.
    @Test func reviewMapPrintsTheLanes() async throws {
        try write(".akit/local/review/runs/r1/run.json", "{}")
        let missing = await review(["map", "r1"])
        #expect(missing.code != 0 && missing.err.contains("No map for run r1"))
        var file = ReviewMap.Node(id: "file:api/orders.ts", kind: .file, lane: .change, label: "api/orders.ts", path: "api/orders.ts")
        file.added = 5
        file.removed = 2
        file.severity = .high
        let boundary = ReviewBoundary(id: "b1", kind: .httpAPI, direction: .provides, name: "GET /api/orders", file: "api/orders.ts", line: 3,
                                      quote: "get('/api/orders')")
        var node = ReviewMap.Node(id: "boundary:b1", kind: .boundary, lane: .boundaries, label: "provides http-api: GET /api/orders")
        node.boundary = boundary
        try ReviewMap(nodes: [file, node], edges: [.init(from: file.id, to: node.id, kind: .declares)])
            .save(in: ReviewPaths(home: home).run("r1"))
        let text = await review(["map", "r1"])
        #expect(text.code == 0 && text.out.contains("Boundaries\n  b1 provides http-api: GET /api/orders  (api/orders.ts:3)"), "\(text)")
        #expect(text.out.contains("Other repositories\n  none found"))
        let json = await review(["map", "r1", "--json"])
        #expect(json.code == 0 && json.out.contains("\"kind\" : \"declares\""))
        let mermaid = await review(["map", "r1", "--mermaid"])
        #expect(mermaid.out.hasPrefix("flowchart LR") && mermaid.out.contains("n1 --> n2"))
        #expect(await review(["map", "r1", "--json", "--mermaid"]).code != 0)
        #expect(await review(["map"]).err.contains("Which run?"))
    }

    /// `akit review overview RUN`: the saved overview as text, JSON or the flow only; a clear error without one.
    @Test func reviewOverviewPrintsThePoints() async throws {
        try write(".akit/local/review/runs/r1/run.json", "{}")
        let missing = await review(["overview", "r1"])
        #expect(missing.code != 0 && missing.err.contains("No overview for run r1"))
        let folder = ReviewPaths(home: home).run("r1")
        try ReviewOverview(points: ["Logs less", "Keeps the header out"], modules: [.init(name: "auth", files: ["src/Auth.swift"], why: "Bug #41")],
                           whySources: [.workItem, .description], language: .russian, notes: ["The overview is short: 2 points instead of 3–5."])
            .save(in: folder)
        let text = await review(["overview", "r1"])
        #expect(text.code == 0 && text.out.contains("Overview (Russian)\n  • Logs less"), "\(text)")
        #expect(text.out.contains("  auth: Bug #41\n    src/Auth.swift") && text.out.contains("Why from: work-item, description"))
        #expect(text.out.contains("Flow: none"))
        #expect(await review(["overview", "r1", "--mermaid"]).err.contains("has no flow"))
        try ReviewOverview(points: ["a"], modules: [], whySources: [], flow: "flowchart LR\n  A --> B", flowKind: .flowchart, language: .english)
            .save(in: folder)
        let mermaid = await review(["overview", "r1", "--mermaid"])
        #expect(mermaid.code == 0 && mermaid.out.hasPrefix("flowchart LR\n  A --> B"))
        let json = await review(["overview", "r1", "--json"])
        #expect(json.code == 0 && json.out.contains("\"flowKind\" : \"flowchart\""))
        #expect(await review(["overview", "r1", "--json", "--mermaid"]).code != 0)
        #expect(await review(["overview"]).err.contains("Which run?"))
        #expect(await review(["--help"]).out.contains("akit review overview RUN [--json | --mermaid]"))
    }

    /// `--summary-language`: the overview's language for this run, over the profile's.
    @Test func reviewSummaryLanguageOption() async throws {
        try write(".akit/local/review/projects/app.yaml", """
        gitlab: { host: https://gitlab.test, project_path: team/app }
        review: { summary_language: de }

        """)
        let none = home.appending(path: "none").path
        #expect(await review(["config", "show", "--project", "app", "--brain", none]).out.contains("summary_language: de (German)  [project]"))
        let shown = await review(["config", "show", "--project", "app", "--brain", none, "--summary-language", "RU"])
        #expect(shown.code == 0 && shown.out.contains("summary_language: ru (Russian)  [run]"), "\(shown)")
        #expect(await review(["config", "show", "--brain", none, "--summary-language", "xx"]).err.contains("--summary-language is one of en, ru"))
        #expect(await review(["--help"]).out.contains("--summary-language CODE"))
    }

    /// `akit review eval`: the set, and its errors.
    @Test func reviewEvalListsTheSet() async {
        let empty = await review(["eval"])
        #expect(empty.code == 0 && empty.out.contains("The eval set is empty"))
        #expect(await review(["eval", "add"]).code != 0)
        #expect(await review(["eval", "remove", "nope"]).code != 0)
        #expect(await review(["eval", "frobnicate"]).code != 0)
    }

    /// `akit review check`: Pi's servers and what review may do with each tool; never a command line.
    @Test func reviewCheckListsPiServers() async throws {
        try write("bin/pi", """
        #!/bin/sh
        echo '{"servers":[{"name":"gitlab","enabled":true,"state":"connected","transport":"npx mcp-gitlab --token glpat-SECRET","tools":["get_merge_request","mr_discussions","create_draft_note","bulk_publish_draft_notes"]},{"name":"jira","enabled":true,"state":"failed","tools":[]},{"name":"fetch","enabled":true,"state":"connected","tools":["fetch"]}],"errors":[]}'

        """)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.appending(path: "bin/pi").path)
        var environment = env
        environment.executableSearchPaths.insert(home.appending(path: "bin"), at: 0)
        var out: [String] = [], err: [String] = []
        let code = await AKitCLI.run(["review", "check"], env: environment, cwd: home, out: { out.append($0) }, err: { err.append($0) })
        let text = out.joined(separator: "\n")
        #expect(code == 0, "\(text) \(err)")
        #expect(text.contains("gitlab: connected · 4 tools: 2 read, 1 write drafts, 1 blocked"))
        #expect(text.contains("read: get_merge_request, mr_discussions") && text.contains("write: create_draft_note"))
        #expect(text.contains("jira: failed · read only, in the brief, roles and verifier (all_servers)"))
        #expect(text.contains("fetch: connected · not used: name it as a context server to use it"), "a risky server only when named")
        #expect(!text.contains("glpat-SECRET") && !text.contains("npx"), "never a server's command line")
    }

    /// `akit review local PATH --show`: the range and the commits, nothing started.
    @Test func reviewLocalShowsTheRange() async throws {
        let repo = home.appending(path: "work/shop")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        func git(_ arguments: String...) {
            _ = ProcessRunner.runAndWait(URL(filePath: "/usr/bin/git"), arguments: ["-C", repo.path] + arguments, environment: env.gitVariables, timeout: 60)
        }
        git("init", "-q", "-b", "main")
        try write("work/shop/a.txt", "a\n")
        git("add", ".")
        git("commit", "-q", "-m", "First")
        git("checkout", "-q", "-b", "topic")
        try write("work/shop/a.txt", "b\n")
        git("commit", "-q", "-am", "Change a")
        let shown = await review(["local", repo.path, "--show"])
        #expect(shown.code == 0, "\(shown)")
        #expect(shown.out.contains("on topic") && shown.out.contains("Base: main"))
        #expect(shown.out.contains("1 commit since main (") && shown.out.contains("Change a"))
        #expect(shown.out.contains("To review: commits only."))
        #expect(await review(["local", repo.path, "--what", "uncommitted", "--show"]).err.contains("Nothing to review with --what uncommitted"))
        #expect(await review(["local", repo.path, "--what", "some"]).err.contains("--what is all, commits or uncommitted"))
        #expect(!FileManager.default.fileExists(atPath: home.appending(path: ".akit/local/review/runs").path), "--show starts nothing")

        // Find the points, then review up to another head.
        let found = await review(["points", repo.path, "--find", "first"])
        #expect(found.code == 0 && found.out.contains("branch  main") && found.out.contains("First") && !found.out.contains("Change a"), "\(found)")
        let json = await review(["points", repo.path, "--json"])
        #expect(json.out.contains("\"kind\" : \"branch\"") && json.out.contains("\"subject\" : \"Change a\""))
        #expect(await review(["points", repo.path, "--find", "zzz"]).out.contains("No branch, tag or commit matches zzz."))
        let onlyCommits = await review(["points", repo.path, "--kind", "commits"])
        #expect(onlyCommits.code == 0 && onlyCommits.out.contains("commit  ") && !onlyCommits.out.contains("branch  "), "\(onlyCommits)")
        #expect(await review(["points", repo.path, "--kind", "files"]).err.contains("--kind is branches, tags or commits"))
        git("checkout", "-q", "main")
        let upTo = await review(["local", repo.path, "--head", "topic", "--show"])
        #expect(upTo.code == 0 && upTo.out.contains("up to topic") && upTo.out.contains("1 commit since main ("), "\(upTo)")
    }
}
