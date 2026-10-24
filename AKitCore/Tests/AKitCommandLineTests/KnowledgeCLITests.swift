import Foundation
import Testing
import AKitBrain
import AKitFoundation
import AKitKnowledge
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

    func akit(_ arguments: String...) async -> (code: Int32, out: String, err: String) {
        var out: [String] = [], err: [String] = []
        let code = await AKitCLI.run(arguments, env: env, cwd: home, projectsRoot: home.appending(path: "Projects"),
                                     hostName: "TestMac.local", out: { out.append($0) }, err: { err.append($0) }, trash: fakeTrash)
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
                        "akit kb rm", "akit kb seed [", "akit kb seed --remove"] {
            let index = try #require(lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix(command) }, "\(command)")
            #expect(lines[index...].prefix(3).contains { $0.contains("For a person only.") }, "\(command) is not marked")
        }
        for command in ["akit kb areas", "akit kb notes", "akit kb maps", "akit kb relations", "akit kb kinds [--json]", "akit kb area AREA [--json]"] {
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
        #expect(await akit("kb", "new-note", "a", "b").code == 2)
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
        #expect((areas["areas"] as? [[String: Any]])?.count == 2)

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
        #expect(seededMaps?.map { $0["id"] as? String } == ["logistics/maps/routes", "payments/maps/overview"])
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
}
