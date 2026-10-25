import Foundation
import Testing
import AKitBrain
import AKitFoundation
import AKitKnowledge
import AKitLab
@testable import AKitCommandLine

/// `akit kb` in a temporary fake home; git reads no config of the real user.
struct KnowledgeCLITests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = URL(filePath: FileWalk.realPath(fm.temporaryDirectory) ?? fm.temporaryDirectory.path)
            .appending(path: "akit-cli-kb-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var env: HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home, variables: ["HOME": home.path, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"],
                           executableSearchPaths: [URL(filePath: "/usr/bin")])
    }

    var base: URL { home.appending(path: ".akit/local/knowledge/work") }

    func akit(_ arguments: String...) async -> (code: Int32, out: String, err: String) { await akit(arguments) }

    func akit(_ arguments: [String], stdin: String = "") async -> (code: Int32, out: String, err: String) {
        var out: [String] = [], err: [String] = []
        let code = await AKitCLI.run(arguments, env: env, cwd: home, projectsRoot: home.appending(path: "Projects"),
                                     hostName: "TestMac.local", out: { out.append($0) }, err: { err.append($0) }, trash: fakeTrash,
                                     input: { Data(stdin.utf8) })
        return (code, out.joined(separator: "\n"), err.joined(separator: "\n"))
    }

    /// A Trash in the fake home: one folder per move.
    func fakeTrash(_ url: URL) throws -> URL? {
        let folder = home.appending(path: "Trash/\(UUID().uuidString)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try fm.moveItem(at: url, to: folder.appending(path: url.lastPathComponent))
        return folder.appending(path: url.lastPathComponent)
    }

    func git(_ args: String...) async throws -> String {
        let result = try #require(await ProcessRunner.run(URL(filePath: "/usr/bin/git"), arguments: args, directory: base,
                                                           environment: env.variables, timeout: 20))
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func json(_ text: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    @Test func helpMarksThePersonOnlyCommands() async throws {
        let help = await akit("kb", "--help")
        #expect(help.code == 0)
        let lines = help.out.split(separator: "\n").map(String.init)
        for command in ["akit kb init", "akit kb new-note", "akit kb new-map", "akit kb set", "akit kb kinds add", "akit kb area AREA [--title", "akit kb path",
                        "akit kb rm", "akit kb rename", "akit kb accept", "akit kb reject", "akit kb check-model", "akit kb pi-template", "akit kb seed [", "akit kb seed --remove", "akit kb focus [FOLDER] --set"] {
            let index = try #require(lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix(command) }, "\(command)")
            #expect(lines[index...].prefix(3).contains { $0.contains("For a person only.") }, "\(command) is not marked")
        }
        for command in ["akit kb areas", "akit kb notes", "akit kb maps", "akit kb relations", "akit kb kinds [--json]", "akit kb area AREA [--json]",
                        "akit kb search", "akit kb show", "akit kb index", "akit kb neighbors", "akit kb context", "akit kb focus [FOLDER] [--json]", "akit kb lint",
                        "akit kb inbox", "akit kb propose --note", "akit kb propose --arrow", "akit kb propose --map", "akit kb check ID"] {
            let index = try #require(lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix(command) }, "\(command)")
            #expect(!lines[index...].prefix(3).contains { $0.contains("person only") }, "\(command) is a read command")
        }
        #expect(help.out.contains("Write (for a person only: an agent runs these only when the user asked for that action in\nthis session; otherwise it proposes or asks)"))
        #expect(await akit("--help").out.contains("akit kb areas | notes [AREA]"))
    }

    @Test func withoutABaseTheReadCommandsSaySoAndExitZero() async throws {
        let areas = await akit("kb", "areas", "--json")
        #expect(areas.code == 0)
        #expect(areas.out == "{\n  \"base\" : null,\n  \"reason\" : \"no base\"\n}")
        let notes = await akit("kb", "notes")
        #expect(notes.code == 0 && notes.out.contains("No knowledge base on this Mac"))
        for command in [["search", "retry"], ["show", "orders-api"], ["index"], ["neighbors", "orders-api"], ["context"], ["focus"], ["lint"], ["inbox"]] {
            let answer = await akit(["kb"] + command + ["--json"])
            #expect(answer.code == 0 && answer.out == areas.out, "\(command)")
        }
        #expect(await akit("kb", "new-note", "a", "b").code == 2)
    }

    /// The seed's files in a folder of the fake home, without git (the index needs only areas/).
    func seedFolder() throws -> String {
        let folder = home.appending(path: "kb")
        for file in KnowledgeSeed.files {
            let url = folder.appending(path: file.path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(file.text.utf8).write(to: url)
        }
        return folder.path
    }

    /// `--scrub` (AKit Review's kb tools): the answer masked as the review's context pack is.
    @Test func searchAndShowScrubOnRequest() async throws {
        let base = try seedFolder()
        let secret = "glpat-abcdefghijklmnopqrst"
        try Data("# Vault\n\n## Access\n\nThe deploy token is \(secret) for now.\n".utf8)
            .write(to: URL(filePath: base).appending(path: "areas/payments/vault.md"))
        #expect(await akit("kb", "show", "vault", "--json", "--base", base).out.contains(secret), "plain reads stay as they are")
        let shown = await akit("kb", "show", "vault", "--json", "--scrub", "--base", base)
        #expect(shown.code == 0 && !shown.out.contains(secret) && shown.out.contains("deploy token"))
        _ = try json(shown.out)
        let found = await akit("kb", "search", "deploy token", "--json", "--scrub", "--base", base)
        #expect(found.code == 0 && found.out.contains("payments/vault") && !found.out.contains(secret))
        #expect(await akit("kb", "index", "--scrub", "--base", base).code == 2, "only search and show take --scrub")
    }

    @Test func searchShowAndIndexAnswerInTheirJSONShapes() async throws {
        let base = try seedFolder()
        let search = await akit("kb", "search", "order-created: retry", "--json", "--base", base)
        #expect(search.code == 0, "\(search.err)")
        let found = try json(search.out)
        #expect(Set(found.keys) == ["results", "stale", "tokens"])
        let results = try #require(found["results"] as? [[String: Any]])
        #expect(!results.isEmpty && results.count <= 10)
        #expect(Set(results[0].keys) == ["note", "heading", "score", "snippet", "neighbors"])
        #expect(results[0]["note"] as? String == "payments/orders-api" && results[0]["heading"] as? String == "Events")
        #expect(found["stale"] as? Bool == false && (found["tokens"] as? Int ?? 0) > 0)
        #expect(await akit("kb", "search", "order", "--limit", "2", "--json", "--base", base).out.components(separatedBy: "\"note\"").count == 3)
        #expect(await akit("kb", "search", "order", "--max-tokens", "0", "--base", base).code == 2)
        #expect(await akit("kb", "search", "--base", base).code == 2)
        #expect(await akit("kb", "search", "retry", "--base", base).out.hasPrefix("payments/orders-api  ## Events  -"))

        let show = try json(await akit("kb", "show", "orders-api", "--section", "Events", "--json", "--base", base).out)
        #expect(Set(show.keys) == ["note", "title", "frontmatter", "sections", "truncated", "stale", "tokens"])
        #expect(Set((show["frontmatter"] as? [String: Any] ?? [:]).keys) == ["kind", "repo", "files"])
        let sections = try #require(show["sections"] as? [[String: Any]])
        #expect(sections.count == 1 && sections[0]["heading"] as? String == "Events" && Set(sections[0].keys) == ["heading", "text"])
        let text = await akit("kb", "show", "billing", "--base", base).out
        #expect(text.hasPrefix("# billing  (payments/billing)\nkind: service  repo: git@example.com:shop/billing.git\n\nBills each order once.\n\n## Invoices\n"))
        #expect(await akit("kb", "show", "nope", "--base", base).code == 2)

        let index = try json(await akit("kb", "index", "--rebuild", "--json", "--base", base).out)
        #expect(Set(index.keys) == ["notes", "maps", "chunks", "rebuilt", "stale", "tokens"])
        #expect(index["notes"] as? Int == 17 && index["maps"] as? Int == 4 && index["rebuilt"] as? Bool == true)
        #expect(await akit("kb", "index", "--base", base).out.hasPrefix("The index is up to date: 17 notes, 4 maps,"))
    }

    @Test func lintFindsOnlyTheSeededExamplesWhenTheReposAreCloned() async throws {
        let base = try seedFolder()
        // The made-up repos of the seed under the projects root, as tools/demo-home.sh makes them.
        for name in ["orders-api", "billing", "orders-db"] {
            let repo = home.appending(path: "Projects/\(name)")
            try fm.createDirectory(at: repo.appending(path: ".git"), withIntermediateDirectories: true)
            try Data("[remote \"origin\"]\n\turl = git@example.com:shop/\(name).git\n".utf8).write(to: repo.appending(path: ".git/config"))
        }
        try fm.createDirectory(at: home.appending(path: "Projects/orders-api/src/events"), withIntermediateDirectories: true)
        try Data("export {}\n".utf8).write(to: home.appending(path: "Projects/orders-api/src/events/order-created.ts"))

        let lint = await akit("kb", "lint", "--json", "--base", base)
        #expect(lint.code == 0, "\(lint.err)")
        let answer = try json(lint.out)
        #expect(Set(answer.keys) == ["base", "findings", "counts"])
        #expect((answer["counts"] as? [String: Int]) == ["error": 2, "warning": 6, "hint": 2])
        let findings = try #require(answer["findings"] as? [[String: Any]])
        #expect(findings.count == 10 && findings.allSatisfy { ($0["file"] as? String)?.hasPrefix("areas/lint-examples/") == true })
        #expect(Set(findings.flatMap(\.keys)) == ["rule", "severity", "file", "element", "link", "message", "fix"])
        let text = await akit("kb", "lint", "--base", base).out
        #expect(text.hasPrefix("error  broken-link  areas/lint-examples/links.md\n    The link [[no-such-note]] points to no note or map in the base."))
        #expect(text.hasSuffix("\n2 errors, 6 warnings, 2 hints."))
        #expect(await akit("kb", "lint", "extra", "--base", base).code == 2)
    }

    @Test func neighborsContextAndFocusAnswerInTheirJSONShapes() async throws {
        let base = try seedFolder()
        let neighbors = try json(await akit("kb", "neighbors", "orders-api", "--json", "--base", base).out)
        #expect(Set(neighbors.keys) == ["note", "edges", "truncated", "stale", "tokens"])
        let edges = try #require(neighbors["edges"] as? [[String: Any]])
        #expect(edges.count == 1 && Set(edges[0].keys) == ["from", "kind", "to", "flow", "map", "arrow"])
        #expect(edges[0]["kind"] as? String == "events" && edges[0]["to"] as? String == "payments/billing")
        #expect(await akit("kb", "neighbors", "orders-api", "--depth", "3", "--base", base).code == 2)
        #expect(await akit("kb", "neighbors", "--base", base).code == 2)
        #expect(await akit("kb", "neighbors", "billing", "--base", base).out == "payments/orders-api → payments/billing  \"events\"  flow payments/flows/order-to-billing  (payments/maps/overview)")

        // A clone of orders-api under ~/Projects: focus payments, by the note's repo:.
        let orders = home.appending(path: "Projects/orders-api")
        try fm.createDirectory(at: orders, withIntermediateDirectories: true)
        for args in [["init", "-q"], ["remote", "add", "origin", "git@example.com:shop/orders-api.git"]] {
            _ = await ProcessRunner.run(URL(filePath: "/usr/bin/git"), arguments: args, directory: orders, environment: env.variables, timeout: 20)
        }
        let context = await akit("kb", "context", orders.path, "--json", "--base", base)
        #expect(context.code == 0, "\(context.err)")
        let card = try json(context.out)
        #expect(Set(card.keys) == ["base", "focus", "systems", "relations", "truncated", "stale", "tokens"])
        #expect(card["focus"] as? String == "payments" && card["truncated"] as? Bool == false && (card["tokens"] as? Int ?? 9999) <= 4000)
        let systems = try #require(card["systems"] as? [[String: Any]])
        #expect(systems.count == 6 && Set(systems[0].keys) == ["note", "title", "line"])
        let relations = try #require(card["relations"] as? [[String: Any]])
        #expect(relations.count == 1 && Set(relations[0].keys) == ["from", "kind", "to"])
        let cut = try json(await akit("kb", "context", orders.path, "--max-tokens", "150", "--json", "--base", base).out)
        #expect(cut["truncated"] as? Bool == true && (cut["tokens"] as? Int ?? 9999) <= 150)
        #expect(await akit("kb", "context", orders.path, "--base", base).out.hasPrefix("Focus: payments (repo)\npayments/billing  billing: Bills each order once."))
        // A folder no area names: focus null, an empty card.
        let other = home.appending(path: "Projects/other")
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        let empty = try json(await akit("kb", "context", other.path, "--json", "--base", base).out)
        #expect(empty["focus"] is NSNull && (empty["systems"] as? [Any])?.isEmpty == true)
        #expect(await akit("kb", "context", home.appending(path: "missing").path, "--base", base).code == 2)

        // A folder that logistics' area.yaml names with ~/Projects/shipping-*.
        let labels = home.appending(path: "Projects/shipping-labels")
        try fm.createDirectory(at: labels, withIntermediateDirectories: true)
        let focus = try json(await akit("kb", "focus", labels.path, "--json", "--base", base).out)
        #expect(focus as NSDictionary == ["base": base, "project": "local/shipping-labels", "focus": "logistics", "source": "area.yaml"] as NSDictionary)

        // --set keeps the choice on this Mac (focus.json), never in the base; --clear drops it.
        let file = KnowledgeBase.focusFile(home: home)
        let set = try json(await akit("kb", "focus", orders.path, "--set", "logistics", "--json", "--base", base).out)
        #expect(set["focus"] as? String == "logistics" && set["source"] as? String == "override")
        #expect(KnowledgeBase.Focus.load(home: home).projects["example.com/shop/orders-api"]?.area == "logistics")
        #expect(try json(await akit("kb", "context", orders.path, "--json", "--base", base).out)["focus"] as? String == "logistics")
        #expect(await akit("kb", "focus", orders.path, "--set", "nowhere", "--base", base).code == 2)
        #expect(await akit("kb", "focus", orders.path, "--set", "payments", "--clear", "--base", base).code == 2)
        #expect(await akit("kb", "context", orders.path, "--set", "payments", "--base", base).code == 2)
        let cleared = await akit("kb", "focus", orders.path, "--clear", "--base", base)
        #expect(cleared.out == "example.com/shop/orders-api: focus payments (repo); your choice is cleared.")
        #expect(KnowledgeBase.Focus.load(home: home).projects.isEmpty && fm.fileExists(atPath: file.path))
        #expect(!fm.fileExists(atPath: URL(filePath: base).appending(path: "focus.json").path))
    }

    @Test func aBusyIndexLockWithNoIndexFileIsEmptyStaleAndExitsZero() async throws {
        let base = try seedFolder()
        let lock = try #require(try FileLock.acquire(URL(filePath: base).appending(path: KnowledgeIndex.lockName)))
        let busy = await akit("kb", "search", "retry", "--json", "--base", base)
        #expect(busy.code == 0)
        let answer = try json(busy.out)
        #expect((answer["results"] as? [Any])?.isEmpty == true && answer["stale"] as? Bool == true)
        lock.release()
        #expect(try json(await akit("kb", "search", "retry", "--json", "--base", base).out)["stale"] as? Bool == false)
    }

    @Test func initNewNoteAndTheJSONShapes() async throws {
        let created = await akit("kb", "init", "--world", "work")
        #expect(created.code == 0, "\(created.err)")
        #expect(created.out.hasPrefix("Created the knowledge base ~/.akit/local/knowledge/work"))
        #expect(try await git("remote").isEmpty)
        #expect(try await git("log", "-1", "--format=%an") == "AKit")

        #expect(await akit("kb", "new-note", "payments", "orders-api", "--kind", "service").code == 0)
        #expect(await akit("kb", "new-note", "payments", "billing").code == 0)
        #expect(try await git("log", "--oneline").split(separator: "\n").count == 3)
        #expect(try await git("status", "--porcelain").isEmpty)

        let areas = try json(await akit("kb", "areas", "--json").out)
        #expect(areas["base"] as? String == base.path)
        let area = try #require((areas["areas"] as? [[String: Any]])?.first)
        #expect(area["name"] as? String == "payments" && area["notes"] as? Int == 2 && area["maps"] as? Int == 0)
        #expect(Set(area.keys) == ["name", "notes", "maps", "title", "description", "projects"])
        #expect(area["title"] is NSNull && area["projects"] as? [String] == [])

        let notes = try json(await akit("kb", "notes", "payments", "--json", "--base", "work").out)
        #expect(notes["area"] as? String == "payments")
        let list = try #require(notes["notes"] as? [[String: Any]])
        #expect(list.map { $0["id"] as? String } == ["payments/billing", "payments/orders-api"])
        #expect(Set(list[0].keys) == ["id", "area", "path", "kind", "title"])
        #expect(list[0]["kind"] is NSNull && list[1]["kind"] as? String == "service")
        #expect(list[1]["path"] as? String == "areas/payments/orders-api.md" && list[1]["title"] as? String == "orders-api")
        let all = try json(await akit("kb", "notes", "--json").out)
        #expect(all["area"] is NSNull)

        #expect(await akit("kb", "areas").out == "payments  2 notes, 0 maps")
        #expect(await akit("kb", "notes").out == "payments/billing  -  billing\npayments/orders-api  service  orders-api")
        #expect(await akit("kb", "notes", "nope").code == 2)
        #expect(await akit("kb", "areas", "--base", "nope").code == 2)
    }

    /// The 0.17.6 fixture base of AKitKnowledgeTests: areas/ and no git.
    static let fixtureBase = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "AKitKnowledgeTests/Fixtures/base")

    @Test func mapsAndRelationsReadAFolderWithoutGit() async throws {
        let base = Self.fixtureBase.path
        let relations = await akit("kb", "relations", "payments/orders-api", "--json", "--base", base)
        #expect(relations.code == 0, "\(relations.err)")
        let answer = try json(relations.out)
        #expect(answer["note"] as? String == "payments/orders-api")
        let edges = try #require(answer["relations"] as? [[String: Any]])
        #expect(edges.filter { $0["to"] as? String == "payments/billing" }.count == 2)
        #expect(Set(edges[0].keys) == ["from", "kind", "to", "flow", "map", "arrow"])
        let events = try #require(edges.first { $0["kind"] as? String == "events" })
        #expect(events["flow"] as? String == "payments/flows/order-to-billing" && events["map"] as? String == "payments/maps/overview")
        #expect(edges.first { $0["kind"] as? String == "invoice requests" }?["flow"] is NSNull)
        #expect(await akit("kb", "relations", "orders-api", "--base", base).out
            == "payments/orders-api → payments/billing  \"invoice requests\"  (payments/maps/billing-detail)\npayments/orders-api → payments/billing  \"events\"  flow payments/flows/order-to-billing  (payments/maps/overview)")
        #expect(await akit("kb", "relations", "--base", base).code == 2)
        #expect(await akit("kb", "relations", "nope", "--base", base).code == 2)

        let maps = try json(await akit("kb", "maps", "payments", "--json", "--base", base).out)
        #expect(maps["area"] as? String == "payments")
        let list = try #require(maps["maps"] as? [[String: Any]])
        #expect(list.map { $0["id"] as? String } == ["payments/maps/billing-detail", "payments/maps/overview"])
        let overview = list[1]
        #expect(overview["blocks"] as? Int == 2 && overview["arrows"] as? Int == 1 && overview["unbound"] as? Int == 1)
        #expect(overview["path"] as? String == "areas/payments/maps/overview.excalidraw" && overview["area"] as? String == "payments")
        #expect((overview["jumps"] as? [[String: Any]])?.map { $0["map"] as? String } == ["payments/maps/billing-detail"])
        #expect(await akit("kb", "maps", "--base", base).out.hasPrefix("payments/maps/billing-detail  2 blocks, 1 arrow, 1 unbound, jumps to payments/maps/overview"))

        // Reads only: a change needs a base with git.
        let refused = await akit("kb", "new-map", "payments", "x", "--base", base)
        #expect(refused.code == 2 && refused.err.contains("no git"), "\(refused.err)")
        #expect(await akit("kb", "new-note", "payments", "x", "--base", base).code == 2)
        #expect(!fm.fileExists(atPath: Self.fixtureBase.appending(path: "areas/payments/maps/x.excalidraw").path))
    }

    @Test func newMapCommitsAnEmptyMapAtOnce() async throws {
        #expect(await akit("kb", "maps", "--json").out.contains("no base"))
        #expect(await akit("kb", "init", "--world", "work").code == 0)
        #expect(await akit("kb", "maps").out == "No maps yet.")
        let created = await akit("kb", "new-map", "payments", "flows-overview")
        #expect(created.code == 0 && created.out == "Created ~/.akit/local/knowledge/work/areas/payments/maps/flows-overview.excalidraw, committed.", "\(created.err)")
        #expect(try await git("log", "--format=%s") == "Add map payments/maps/flows-overview\nCreate the knowledge base")
        #expect(try await git("status", "--porcelain").isEmpty)
        let maps = try json(await akit("kb", "maps", "payments", "--json").out)
        let map = try #require((maps["maps"] as? [[String: Any]])?.first)
        #expect(map["id"] as? String == "payments/maps/flows-overview" && map["elements"] as? Int == 0 && map["error"] == nil)
        #expect(await akit("kb", "new-map", "payments", "flows-overview").code == 2)
        #expect(await akit("kb", "new-map", "payments").code == 2)
        #expect(await akit("kb", "new-map", "payments", "y", "--json").code == 2)
        #expect(await akit("kb", "areas").out == "payments  0 notes, 1 map")
    }

    @Test func renameShowsThePlanThenRenamesWithYes() async throws {
        #expect(await akit("kb", "init", "--world", "work").code == 0)
        #expect(await akit("kb", "new-note", "payments", "billing").code == 0)
        #expect(await akit("kb", "new-note", "payments", "orders-api").code == 0)
        let orders = base.appending(path: "areas/payments/orders-api.md")
        try Data("# orders-api\nSends [[billing|Billing]].\n".utf8).write(to: orders)
        #expect(await akit("kb", "set", "orders-api", "kind=service").code == 0)
        let plan = await akit("kb", "rename", "billing", "invoicing")
        #expect(plan.code == 0 && plan.out == """
            Would rename the note payments/billing to payments/invoicing and 1 link, then commit. Run again with --yes to do it:
            areas/payments/billing.md → areas/payments/invoicing.md
            areas/payments/orders-api.md
              - [[billing|Billing]]
              + [[invoicing|Billing]]
            """, "\(plan.out)\n\(plan.err)")
        #expect(fm.fileExists(atPath: base.appending(path: "areas/payments/billing.md").path))
        let answer = try json(await akit("kb", "rename", "billing", "invoicing", "--json").out)
        #expect(answer["renamed"] as? Bool == false)
        let rename = try #require(answer["rename"] as? [String: Any])
        #expect(rename["from"] as? String == "payments/billing" && rename["to"] as? String == "payments/invoicing" && rename["kind"] as? String == "note")
        #expect((rename["files"] as? [[String: Any]])?.count == 2)
        let done = await akit("kb", "rename", "billing", "invoicing", "--yes")
        #expect(done.code == 0 && done.out.hasPrefix("Renamed the note payments/billing to payments/invoicing and 1 link, committed:"), "\(done.err)")
        #expect(try await git("log", "-1", "--format=%s") == "Rename note payments/billing to payments/invoicing, 1 link in 1 file")
        #expect(try await git("status", "--porcelain").isEmpty)
        #expect(try String(contentsOf: orders, encoding: .utf8).contains("Sends [[invoicing|Billing]]."))
        // Refused: an existing name, an area, missing arguments.
        #expect(await akit("kb", "rename", "invoicing", "orders-api", "--yes").code == 2)
        #expect(await akit("kb", "rename", "payments", "pay").code == 2)
        #expect(await akit("kb", "rename", "invoicing").code == 2)
    }

    @Test func kindsSetAndAreaCommitAtOnce() async throws {
        #expect(await akit("kb", "init", "--world", "work").code == 0)
        #expect(try await git("ls-files").split(separator: "\n").contains("kb.yaml"))
        #expect(await akit("kb", "new-note", "payments", "orders-api", "--kind", "service").code == 0)

        let kinds = try json(await akit("kb", "kinds", "--json").out)
        #expect(Set(kinds.keys) == ["base", "file", "defaults", "kinds"])
        #expect(kinds["defaults"] as? Bool == false && kinds["file"] as? String == "kb.yaml")
        let list = try #require(kinds["kinds"] as? [[String: Any]])
        #expect(list.map { $0["name"] as? String } == ["service", "flow", "team", "database", "queue", "external"])
        #expect(Set(list[0].keys) == ["name", "fields", "color", "shape"])
        #expect(list[0]["fields"] as? [String] == ["repo", "files", "owner"] && list[0]["color"] is NSNull)
        #expect(await akit("kb", "kinds").out.hasPrefix("service  repo, files, owner\nflow  owner"))

        // kb set: one line added, one commit, one file.
        let set = await akit("kb", "set", "orders-api", "owner=team-a", "files=[a.ts, b.ts]", "--json")
        #expect(set.code == 0, "\(set.err)")
        let answer = try json(set.out)
        #expect(answer["note"] as? String == "payments/orders-api" && answer["changed"] as? Bool == true)
        let properties = try #require(answer["properties"] as? [String: Any])
        #expect(properties["owner"] as? String == "team-a" && properties["files"] as? [String] == ["a.ts", "b.ts"])
        #expect(try await git("show", "--name-only", "--format=%s", "HEAD") == "Set owner, files of payments/orders-api\n\nareas/payments/orders-api.md")
        #expect(try await git("diff", "HEAD~1", "--numstat") == "2\t0\tareas/payments/orders-api.md")
        #expect(await akit("kb", "set", "payments/orders-api", "owner=team-a").out.hasPrefix("Nothing changed"))
        #expect(await akit("kb", "set", "payments/orders-api", "--unset", "files").code == 0)
        #expect(await akit("kb", "set", "payments/orders-api", "owner").code == 2)
        #expect(await akit("kb", "set", "payments/orders-api").code == 2)
        #expect(await akit("kb", "set", "nope", "a=b").code == 2)

        // kb kinds add / fields / rename / remove: one commit each.
        let commits = try await git("rev-list", "--count", "HEAD")
        #expect(await akit("kb", "kinds", "add", "widget", "--fields", "size,owner").code == 0)
        #expect(await akit("kb", "kinds", "fields", "widget", "size").code == 0)
        let renamed = await akit("kb", "kinds", "rename", "service", "system")
        #expect(renamed.out == "Renamed the kind service to system in kb.yaml and 1 note, committed.", "\(renamed.err)")
        #expect(try await git("show", "--name-only", "--format=%s", "HEAD")
            == "Rename kind service to system in 1 note\n\nareas/payments/orders-api.md\nkb.yaml")
        let removed = await akit("kb", "kinds", "remove", "system")
        #expect(removed.out == "Removed the kind system (1 note still has kind: system), committed.")
        #expect(Int(try await git("rev-list", "--count", "HEAD")) == Int(commits)! + 4)
        #expect(await akit("kb", "kinds", "add", "widget").code == 2)
        #expect(await akit("kb", "kinds", "explode").code == 2)
        let names = try json(await akit("kb", "kinds", "--json").out)["kinds"] as? [[String: Any]]
        #expect(names?.map { $0["name"] as? String } == ["flow", "team", "database", "queue", "external", "widget"])
        #expect(try await git("status", "--porcelain").isEmpty)

        // kb area: read, then change and commit.
        let empty = try json(await akit("kb", "area", "payments", "--json").out)
        #expect(Set(empty.keys) == ["base", "area", "file", "title", "description", "projects"])
        #expect(empty["title"] is NSNull && empty["file"] as? String == "areas/payments/area.yaml")
        let area = try json(await akit("kb", "area", "payments", "--title", "Payments", "--project", "git@example.com:shop/orders-api.git",
                                       "--project", "~/Projects/billing", "--json").out)
        #expect(area["title"] as? String == "Payments")
        #expect(area["projects"] as? [String] == ["git@example.com:shop/orders-api.git", "~/Projects/billing"])
        #expect(try await git("show", "--name-only", "--format=%s", "HEAD") == "Edit the settings of area payments\n\nareas/payments/area.yaml")
        let removedProject = await akit("kb", "area", "payments", "--remove-project", "~/Projects/billing")
        #expect(removedProject.out.contains("projects: git@example.com:shop/orders-api.git\n"))
        #expect(await akit("kb", "areas").out == "payments  1 note, 0 maps  Payments")
        #expect(await akit("kb", "area", "nope").code == 2)
    }

    @Test func initRefusesTheBrainAndSyncedFolders() async throws {
        let brain = await akit("kb", "init", "--base", "~/.akit/registry/kb")
        #expect(brain.code == 2 && brain.err.contains("inside the brain"), "\(brain.err)")
        try MachineProfile(kind: .work, name: "work").save(home: home)
        let synced = await akit("kb", "init", "--base", "~/Library/Mobile Documents/com~apple~CloudDocs/kb")
        #expect(synced.code == 2 && synced.err.contains("synced folder"), "\(synced.err)")
        // K25: a work Mac may keep its base outside ~/.akit/local/.
        #expect(await akit("kb", "init", "--base", "~/Documents/kb").code == 0)
        // The default world is the Mac's kind.
        #expect(await akit("kb", "init").code == 0)
        #expect(KnowledgeBase.isBase(base))
        #expect(await akit("kb", "init").code == 2)
    }

    @Test func pathSetMoveAndResetTheWorldsFolder() async throws {
        let shown = try json(await akit("kb", "path", "work", "--json").out)
        #expect(shown["path"] as? String == base.path && shown["configured"] as? Bool == false && shown["isBase"] as? Bool == false)
        #expect(shown["vault"] is NSNull)

        let vault = home.appending(path: "Vault")
        try fm.createDirectory(at: vault.appending(path: ".obsidian"), withIntermediateDirectories: true)
        let set = try json(await akit("kb", "path", "work", "--set", vault.path, "--json").out)
        #expect(set["path"] as? String == vault.path && set["configured"] as? Bool == true && set["isBase"] as? Bool == true)
        #expect(set["vault"] as? String == vault.path)
        #expect(try json(await akit("kb", "areas", "--json").out)["base"] as? String == vault.path)
        #expect(try String(contentsOf: home.appending(path: ".akit/local/knowledge/bases.json"), encoding: .utf8).contains(#""work" : "~/Vault""#))
        #expect(await akit("kb", "new-note", "payments", "orders-api", "--base", "work").code == 0)
        #expect(fm.fileExists(atPath: vault.appending(path: "areas/payments/orders-api.md").path))

        let refused = await akit("kb", "path", "work", "--set", home.appending(path: "Library/Mobile Documents/x").path)
        #expect(refused.code == 2 && refused.err.contains("synced folder"), "\(refused.err)")
        #expect(await akit("kb", "path", "work", "--set", "~/a", "--reset").code == 2)

        let moved = await akit("kb", "path", "work", "--move", "~/Notes/kb")
        #expect(moved.code == 0 && moved.out == "Moved the base of work from ~/Vault to ~/Notes/kb.", "\(moved.out) \(moved.err)")
        #expect(KnowledgeBase.isBase(home.appending(path: "Notes/kb")))
        #expect(await akit("kb", "path", "work").out.hasPrefix("work: ~/Notes/kb (set on this Mac"))

        let reset = await akit("kb", "path", "work", "--reset")
        #expect(reset.out == "The base of work is the default folder again: ~/.akit/local/knowledge/work (no base there yet: akit kb init --world work). ~/Notes/kb stays as it is.")
        #expect(try json(await akit("kb", "path", "--json").out)["configured"] as? Bool == false)
    }

    @Test func seedRmAndRemoveTheSampleBase() async throws {
        let sample = home.appending(path: ".akit/local/knowledge/sample")
        let seeded = await akit("kb", "seed", "--json")
        #expect(seeded.code == 0, "\(seeded.err)")
        let answer = try json(seeded.out)
        #expect(answer["base"] as? String == sample.path)
        #expect(answer["world"] as? String == "sample")
        #expect(answer["seedVersion"] as? Int == KnowledgeSeed.version)
        #expect(answer["status"] as? String == "created")
        #expect((answer["files"] as? [String])?.contains(".akit-seed.json") == true)
        #expect(try json(await akit("kb", "seed", "--json").out)["status"] as? String == "unchanged")
        let areas = try json(await akit("kb", "areas", "--base", "sample", "--json").out)
        #expect((areas["areas"] as? [[String: Any]])?.count == 3)

        // kb rm: without --yes nothing moves; with it, one commit and the file is in the Trash.
        let note = sample.appending(path: "areas/payments/orders-db.md")
        let asked = await akit("kb", "rm", "payments/orders-db", "--base", "sample")
        #expect(asked.code == 0 && asked.out.hasSuffix("Run again with --yes to do it."))
        #expect(fm.fileExists(atPath: note.path))
        let removed = try json(await akit("kb", "rm", "payments/orders-db", "--base", "sample", "--yes", "--json").out)
        #expect(removed["base"] as? String == sample.path && removed["kind"] as? String == "note" && removed["id"] as? String == "payments/orders-db"
            && removed["path"] as? String == "areas/payments/orders-db.md" && removed["removed"] as? Bool == true)
        #expect(!fm.fileExists(atPath: note.path))
        let log = try #require(await ProcessRunner.run(URL(filePath: "/usr/bin/git"), arguments: ["log", "--format=%s"], directory: sample,
                                                        environment: env.variables, timeout: 20)).output
        #expect(log.hasPrefix("Delete note payments/orders-db\nSeed: sample base v"))
        #expect(await akit("kb", "rm", "inbox/payments/x.md", "--base", "sample", "--yes").err.contains("akit kb reject"))
        // The seeded map: listed, then removed as a map in one commit.
        let seededMaps = try json(await akit("kb", "maps", "--base", "sample", "--json").out)["maps"] as? [[String: Any]]
        #expect(seededMaps?.map { $0["id"] as? String } == ["lint-examples/maps/broken", "lint-examples/maps/examples", "logistics/maps/routes", "payments/maps/overview"])
        let map = try json(await akit("kb", "rm", "payments/maps/overview", "--base", "sample", "--yes", "--json").out)
        #expect(map["kind"] as? String == "map" && map["path"] as? String == "areas/payments/maps/overview.excalidraw")
        #expect(!fm.fileExists(atPath: sample.appending(path: "areas/payments/maps/overview.excalidraw").path))
        // Seeding again after a change of the user: refused.
        #expect(await akit("kb", "seed").err.contains("Remove it first"))

        // seed --remove: a base of the user is refused; the sample one goes to the Trash after --yes.
        #expect(await akit("kb", "init", "--world", "work").code == 0)
        #expect(await akit("kb", "new-note", "orders", "api", "--base", "work").code == 0)
        let refused = await akit("kb", "seed", "--remove", "--base", "work", "--yes")
        #expect(refused.code == 2 && refused.err.contains("not a sample base"))
        #expect(KnowledgeBase.isBase(base))
        #expect(await akit("kb", "seed", "--world", "work").err.contains("not a sample one"))
        #expect(await akit("kb", "seed", "--remove").out.hasSuffix("Run again with --yes to do it."))
        #expect(KnowledgeBase.isBase(sample))
        let gone = try json(await akit("kb", "seed", "--remove", "--yes", "--json").out)
        #expect(gone["removed"] as? Bool == true && gone["world"] as? String == "sample")
        #expect(!fm.fileExists(atPath: sample.path))
        #expect(try fm.contentsOfDirectory(atPath: home.appending(path: "Trash").path).count == 3)
    }

    /// 5.1: propose (stdin, a file, --set, an arrow) writes only inbox/; inbox lists with checks;
    /// accept shows the diff, then commits once and leaves git clean; an arrow exits 2; reject
    /// goes to the Trash.
    @Test func proposeInboxAcceptAndReject() async throws {
        #expect(await akit("kb", "init", "--world", "work").code == 0)
        #expect(await akit("kb", "new-note", "payments", "billing", "--kind", "service").code == 0)
        #expect(await akit("kb", "new-note", "payments", "orders-api").code == 0)

        let proposed = await akit(["kb", "propose", "--note", "payments/billing", "--stdin", "--reason", "from the code", "--json"],
                                  stdin: "## Retries\nThree tries with backoff.\n")
        #expect(proposed.code == 0, "\(proposed.err)")
        let answer = try json(proposed.out)
        #expect(Set(answer.keys) == ["id", "path", "kind", "target", "checks"])
        let id = try #require(answer["id"] as? String)
        #expect(answer["path"] as? String == "inbox/\(id).md" && answer["kind"] as? String == "note" && answer["target"] as? String == "payments/billing")
        #expect((answer["checks"] as? [[String: Any]])?.map { $0["name"] as? String } == ["secret", "target", "links"])
        #expect(try await git("status", "--porcelain") == "?? inbox/\(id).md")
        #expect((try json(await akit("kb", "search", "three tries", "--json").out)["results"] as? [Any])?.isEmpty == true)

        // Refused: a secret, a broken link; nothing more in inbox/.
        let secret = await akit(["kb", "propose", "--note", "payments/billing", "--stdin"], stdin: "## Keys\nghp_abcdefghijklmnopqrstuvwxyz0123456789\n")
        #expect(secret.code == 2 && secret.err.contains("secret"))
        #expect(await akit(["kb", "propose", "--note", "payments/billing", "--stdin"], stdin: "## L\n[[nowhere]]\n").err.contains("Broken link"))
        #expect(await akit(["kb", "propose", "--note", "../x", "--stdin"], stdin: "x").code == 2)
        // A new area from a file, with a property.
        let file = home.appending(path: "helpdesk.md")
        try Data("Tickets by email.\n".utf8).write(to: file)
        let area = await akit("kb", "propose", "--note", "support/helpdesk", "--file", file.path, "--set", "kind=service", "--author", "pi")
        #expect(area.code == 0 && area.out.contains("new area support"), "\(area.err)")
        let arrow = await akit("kb", "propose", "--arrow", "orders-api -events-> billing", "--json")
        #expect(arrow.code == 0, "\(arrow.err)")
        let arrowID = try #require(try json(arrow.out)["id"] as? String)

        let inbox = try json(await akit("kb", "inbox", "--json").out)
        let entries = try #require(inbox["proposals"] as? [[String: Any]])
        #expect(entries.count == 3)
        #expect(Set(entries[0].keys) == ["id", "path", "kind", "target", "reason", "created", "author", "set", "arrow", "checks", "modelCheck"])
        #expect(entries.first { $0["id"] as? String == id }?["reason"] as? String == "from the code")
        #expect(await akit("kb", "inbox").out.contains("\(arrowID)  arrow payments/orders-api -events-> payments/billing"))

        // accept: the diff without --yes, then one commit; the arrow writes nothing and exits 2.
        let asked = await akit("kb", "accept", id)
        #expect(asked.code == 0 && asked.out.contains("Run again with --yes to do it:") && asked.out.contains("+ Three tries with backoff."))
        let commits = try await git("rev-list", "--count", "HEAD")
        let accepted = try json(await akit("kb", "accept", id, "--yes", "--json").out)
        #expect(accepted["accepted"] as? Bool == true && accepted["path"] as? String == "areas/payments/billing.md")
        #expect((accepted["backup"] as? String)?.hasPrefix(home.appending(path: ".akit/local/backups/knowledge/work/").path) == true)
        #expect(Int(try await git("rev-list", "--count", "HEAD")) == Int(commits)! + 1)
        #expect(try String(contentsOf: base.appending(path: "areas/payments/billing.md"), encoding: .utf8).contains("Three tries with backoff."))
        let drawn = await akit("kb", "accept", arrowID, "--yes")
        #expect(drawn.code == 2 && drawn.out == "Add the arrow payments/orders-api -events-> payments/billing on a map of payments in the app (Knowledge → Inbox).")
        #expect(fm.fileExists(atPath: base.appending(path: "inbox/\(arrowID).md").path))

        // reject: only shown without --yes; then to the Trash, no commit.
        #expect(await akit("kb", "reject", arrowID).out.hasSuffix("Run again with --yes to do it."))
        let rejected = try json(await akit("kb", "reject", arrowID, "--yes", "--json").out)
        #expect(rejected["rejected"] as? Bool == true)
        #expect(!fm.fileExists(atPath: base.appending(path: "inbox/\(arrowID).md").path))
        #expect(Int(try await git("rev-list", "--count", "HEAD")) == Int(commits)! + 1)
        #expect(try await git("status", "--porcelain").hasPrefix("?? inbox/"))
        #expect(await akit("kb", "accept", "nope").err.contains("No proposal nope"))
    }

    /// 5.4: propose --map copies an excalidraw-cli draft into inbox/ beside its proposal (from a file
    /// or stdin); a file that isn't a scene is refused; accept of a map writes nothing and exits 2.
    @Test func proposeAMapAndAcceptItOnlyInTheApp() async throws {
        #expect(await akit("kb", "init", "--world", "work").code == 0)
        #expect(await akit("kb", "new-note", "payments", "billing").code == 0)
        #expect(await akit("kb", "new-note", "payments", "orders-api").code == 0)
        let fixture = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "AKitKnowledgeTests/Fixtures/cli-draft.excalidraw")
        let proposed = await akit("kb", "propose", "--map", "payments/flow", "--file", fixture.path, "--reason", "drawn by pi", "--json")
        #expect(proposed.code == 0, "\(proposed.err)")
        let answer = try json(proposed.out)
        let id = try #require(answer["id"] as? String)
        #expect(Set(answer.keys) == ["id", "path", "kind", "target", "checks", "draft"])
        #expect(answer["kind"] as? String == "map" && answer["target"] as? String == "payments/maps/flow"
            && answer["draft"] as? String == "inbox/\(id).excalidraw")
        #expect((answer["checks"] as? [[String: Any]])?.map { $0["name"] as? String } == ["secret", "target", "map"])
        #expect(try await git("status", "--porcelain") == "?? inbox/\(id).excalidraw\n?? inbox/\(id).md")
        #expect(await akit("kb", "inbox").out.contains("\(id)  map payments/maps/flow"))
        // From stdin too; a file that isn't a scene is refused, nothing written.
        let piped = await akit(["kb", "propose", "--map", "logistics/routes", "--stdin"], stdin: try String(contentsOf: fixture, encoding: .utf8))
        #expect(piped.code == 0 && piped.out.contains("the person accepts it in Knowledge → Inbox"), "\(piped.err)")
        let broken = await akit(["kb", "propose", "--map", "payments/flow", "--stdin"], stdin: "{\"elements\": [")
        #expect(broken.code == 2 && broken.err.contains("not valid JSON"))
        #expect(await akit(["kb", "propose", "--map", "../flow", "--file", fixture.path]).code == 2)
        #expect(await akit(["kb", "propose", "--map", "payments/flow"]).err.contains("Give the draft"))

        // Accept of a map: in the app only; nothing changes.
        let commits = try await git("rev-list", "--count", "HEAD")
        let accepted = await akit("kb", "accept", id, "--yes")
        #expect(accepted.code == 2 && accepted.out == "Open Knowledge → Inbox to accept a map.")
        let json = try json(await akit("kb", "accept", id, "--yes", "--json").out)
        #expect(json["accepted"] as? Bool == false && json["kind"] as? String == "map")
        #expect(try await git("rev-list", "--count", "HEAD") == commits)
        #expect(!fm.fileExists(atPath: base.appending(path: "areas/payments/maps/flow.excalidraw").path))
        #expect(fm.fileExists(atPath: base.appending(path: "inbox/\(id).excalidraw").path))
        // Reject takes the draft with it.
        #expect(await akit("kb", "reject", id, "--yes").code == 0)
        #expect(!fm.fileExists(atPath: base.appending(path: "inbox/\(id).excalidraw").path))
    }

    /// 5.2: kb check sends the proposal through Pi under the sending policy (purpose kb-check),
    /// keeps the marks beside it and never accepts; kb check-model sets the model.
    @Test func checkMarksAProposalThroughPiAndNeverAccepts() async throws {
        let bin = home.appending(path: "bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data(#"""
            #!/bin/sh
            if [ "$1 $2" = "auth check" ]; then echo '{"status":"ready"}'; exit 0; fi
            echo "$@" > "$HOME/pi-args.txt"
            for a in "$@"; do case "$a" in @*) cp "${a#@}" "$HOME/pi-input.json";; esac; done
            echo '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"{\"marks\":[{\"kind\":\"duplicate\",\"note\":\"payments/billing\",\"message\":\"Invoices says it.\"}],\"accept\":true}"}],"usage":{"input":10,"output":3}}}'

            """#.utf8).write(to: bin.appending(path: "pi"))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appending(path: "pi").path)
        let piEnv = HarnessEnvironment(homeDirectory: home, variables: env.variables, executableSearchPaths: [bin, URL(filePath: "/usr/bin"), URL(filePath: "/bin")])
        func run(_ arguments: String...) async -> (code: Int32, out: String, err: String) {
            var out: [String] = [], err: [String] = []
            let code = await AKitCLI.run(arguments, env: piEnv, cwd: home, projectsRoot: home.appending(path: "Projects"), hostName: "TestMac.local",
                                         out: { out.append($0) }, err: { err.append($0) }, trash: fakeTrash)
            return (code, out.joined(separator: "\n"), err.joined(separator: "\n"))
        }
        #expect(await run("kb", "seed", "--world", "work").code == 0)
        let head = try await git("rev-parse", "HEAD")
        let checked = await run("kb", "check", "2026-10-24-arrow-billing-warehouse", "--json")
        #expect(checked.code == 0, "\(checked.err)")
        let answer = try json(checked.out)
        #expect(answer["model"] as? String == "Pi · opencode-go/gpt-6-luna · low")
        #expect((answer["marks"] as? [[String: Any]])?.map { $0["kind"] as? String } == ["duplicate"])
        #expect(try String(contentsOf: home.appending(path: "pi-args.txt"), encoding: .utf8).contains("--model opencode-go/gpt-6-luna"))
        let sent = try json(String(contentsOf: home.appending(path: "pi-input.json"), encoding: .utf8))
        #expect(Set(sent.keys) == ["proposal", "candidates"])
        #expect(SendLog.records(env: piEnv).map(\.purpose) == ["kb-check"])
        // Marks only: nothing committed, the proposal is still open, kb inbox shows the mark.
        #expect(try await git("rev-parse", "HEAD") == head)
        #expect(fm.fileExists(atPath: base.appending(path: "inbox/2026-10-24-arrow-billing-warehouse.md").path))
        #expect(await run("kb", "inbox").out.contains("mark duplicate: Invoices says it."))
        // --model overrides; check-model sets and shows it.
        #expect(await run("kb", "check", "2026-10-24-arrow-billing-warehouse", "--model", "zai/glm-5-air").code == 0)
        #expect(try String(contentsOf: home.appending(path: "pi-args.txt"), encoding: .utf8).contains("--model zai/glm-5-air"))
        #expect(await run("kb", "check-model", "zai/glm-5-air", "minimal").out == "Knowledge check model: Pi · zai/glm-5-air · minimal")
        #expect(LabSettings.load(env: piEnv).knowledgeCheckAgent == LabAgent(harness: .pi, model: "zai/glm-5-air", effort: "minimal"))
        #expect(await run("kb", "check-model", "glm").code == 2)
        // Another harness keeps its own model; switching back brings Pi's back.
        #expect(await run("kb", "check-model", "--harness", "claude-code").out == "Knowledge check model: Claude Code · haiku · low")
        #expect(await run("kb", "check-model", "sonnet", "--harness", "claude-code").out == "Knowledge check model: Claude Code · sonnet · low")
        #expect(await run("kb", "check-model", "--harness", "pi").out == "Knowledge check model: Pi · zai/glm-5-air · minimal")
        #expect(await run("kb", "check-model", "--harness", "claude-code").out == "Knowledge check model: Claude Code · sonnet · low")
        #expect(await run("kb", "check-model", "--harness", "codex").code == 2)
        #expect(await run("kb", "check-model", "haiku", "minimal", "--harness", "claude-code").code == 2)
        #expect(await run("kb", "check", "nope").err.contains("No proposal nope"))
    }

    /// K16 / D0: the core layer's Pi-only section reaches Pi's AGENTS.md through apply --home and
    /// never ~/.claude/CLAUDE.md; a second run says "already set" and changes nothing.
    @Test func piTemplateReachesOnlyPiAndASecondRunIsAlreadySet() async throws {
        let brainRoot = home.appending(path: ".akit/registry")
        let created = await akit("init", "--brain", brainRoot.path, "--targets", "claude,pi", "--yes")
        #expect(created.code == 0, "\(created.err)")
        // A section for every target, so CLAUDE.md is written too.
        let brain = try #require(Brain.load(from: brainRoot))
        let before = try #require(brain.layers.first { $0.name == "core" })
        try await LayerEditor.update("core", to: LayerEditor.Details(description: before.description, requires: before.requires, agentsSection: "Be brief."),
                                     in: brain, env: env)
        #expect(await akit("kb", "init", "--world", "work").code == 0)
        // A pending edit of the base is committed before the brain changes.
        #expect(await akit("kb", "new-note", "payments", "orders-api").code == 0)
        try Data("# orders-api\n\nEdited.\n".utf8).write(to: base.appending(path: "areas/payments/orders-api.md"))
        #expect(KnowledgeCommitQueue(base: base, env: env).enqueue(["areas/payments/orders-api.md"]) == .queued(refused: []))

        let preview = await akit("kb", "pi-template")
        #expect(preview.code == 0 && preview.out.hasPrefix("Would write layers/core/templates/kb-pi.md"))
        #expect(preview.out.contains("+     when: target == pi"))
        #expect(!fm.fileExists(atPath: brainRoot.appending(path: "layers/core/templates/kb-pi.md").path))
        #expect(KnowledgeCommitQueue(base: base, env: env).pending() == ["areas/payments/orders-api.md"])

        let written = await akit("kb", "pi-template", "--yes")
        #expect(written.code == 0, "\(written.err)")
        #expect(written.out.contains("Now run `akit apply --home`"))
        #expect(KnowledgeCommitQueue(base: base, env: env).pending().isEmpty)
        #expect(try await git("status", "--porcelain").isEmpty)
        let brainLog = try #require(await ProcessRunner.run(URL(filePath: "/usr/bin/git"), arguments: ["log", "-1", "--format=%s", "--name-only"],
                                                             directory: brainRoot, environment: env.variables, timeout: 20)).output
        #expect(brainLog.hasPrefix("Add the knowledge base section for Pi to layer core"))
        #expect(brainLog.contains("layers/core/layer.yaml") && brainLog.contains("layers/core/templates/kb-pi.md"))
        let core = try #require(Brain.load(from: brainRoot)?.layers.first { $0.name == "core" })
        #expect(core.files.contains { $0.template == "kb-pi.md" && $0.to == "AGENTS.md" && $0.when == KnowledgePiTemplate.when && !$0.override })
        // The Edit Layer sheet still edits the section for every target.
        #expect(LayerEditor.details(of: core).agentsSection == "Be brief.")

        // akit init only makes the brain; the targets are the apply's (installed harnesses by default).
        let applied = await akit("apply", "--home", "--targets", "claude,pi", "--yes")
        #expect(applied.code == 0, "\(applied.err)")
        let pi = try String(contentsOf: home.appending(path: ".pi/agent/AGENTS.md"), encoding: .utf8)
        let claude = try String(contentsOf: home.appending(path: ".claude/CLAUDE.md"), encoding: .utf8)
        #expect(pi.components(separatedBy: "akit kb context").count == 2)
        #expect(pi.contains("Be brief.") && claude.contains("Be brief."))
        #expect(!claude.contains("akit kb"))

        let again = await akit("kb", "pi-template", "--yes")
        #expect(again.code == 0 && again.out.contains("already set"))
        let answer = try json(await akit("kb", "pi-template", "--json").out)
        #expect(answer["state"] as? String == "already set" && answer["diff"] as? String == "")
        #expect(try String(contentsOf: home.appending(path: ".pi/agent/AGENTS.md"), encoding: .utf8) == pi)
        let yaml = try String(contentsOf: core.manifest, encoding: .utf8)
        #expect(yaml.components(separatedBy: "kb-pi.md").count == 2)

        // A changed template text is written back; layer.yaml stays.
        try Data("Mine.\n".utf8).write(to: core.templates.appending(path: "kb-pi.md"))
        let back = try json(await akit("kb", "pi-template", "--json").out)
        #expect(back["state"] as? String == "would write")
        #expect((back["diff"] as? String)?.hasPrefix("--- layers/core/templates/kb-pi.md\n") == true)
    }
}
