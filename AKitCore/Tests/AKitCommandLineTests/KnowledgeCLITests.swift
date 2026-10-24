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
        for command in ["akit kb init", "akit kb new-note"] {
            let index = try #require(lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix(command) }, "\(command)")
            #expect(lines[index...].prefix(3).contains { $0.contains("For a person only.") }, "\(command) is not marked")
        }
        for command in ["akit kb areas", "akit kb notes"] {
            let index = try #require(lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix(command) }, "\(command)")
            #expect(!lines[index...].prefix(3).contains { $0.contains("person only") }, "\(command) is a read command")
        }
        #expect(help.out.contains("Write (for a person only: an agent never runs these, it asks the user)"))
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
        #expect(Set(area.keys) == ["name", "notes", "maps"])

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

    @Test func initRefusesTheBrainAndOutsideOnAWorkMac() async throws {
        let brain = await akit("kb", "init", "--base", "~/.akit/registry/kb")
        #expect(brain.code == 2 && brain.err.contains("inside the brain"), "\(brain.err)")
        try MachineProfile(kind: .work, name: "work").save(home: home)
        let outside = await akit("kb", "init", "--base", "~/Documents/kb")
        #expect(outside.code == 2 && outside.err.contains("work Mac"), "\(outside.err)")
        // The default world is the Mac's kind.
        #expect(await akit("kb", "init").code == 0)
        #expect(KnowledgeBase.isBase(base))
        #expect(await akit("kb", "init").code == 2)
    }
}
