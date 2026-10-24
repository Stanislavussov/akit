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
                                     hostName: "TestMac.local", out: { out.append($0) }, err: { err.append($0) })
        return (code, out.joined(separator: "\n"), err.joined(separator: "\n"))
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
        for command in ["akit kb init", "akit kb new-note", "akit kb set", "akit kb kinds add", "akit kb area AREA [--title", "akit kb path"] {
            let index = try #require(lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix(command) }, "\(command)")
            #expect(lines[index...].prefix(3).contains { $0.contains("For a person only.") }, "\(command) is not marked")
        }
        for command in ["akit kb areas", "akit kb notes", "akit kb kinds [--json]", "akit kb area AREA [--json]"] {
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
}
