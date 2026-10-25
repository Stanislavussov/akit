import Foundation
import Testing
import AKitFoundation
import AKitKnowledge
@testable import AKitCommandLine

/// `akit notebook` in a temporary fake home; git reads no config of the real user.
struct NotebookCLITests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = URL(filePath: FileWalk.realPath(fm.temporaryDirectory) ?? fm.temporaryDirectory.path)
            .appending(path: "akit-cli-notebook-\(UUID().uuidString)")
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

    @Test func agentsReadTabsAddATaskUnderTodayAndTickIt() async throws {
        defer { try? fm.removeItem(at: home) }
        #expect(await akit("kb", "init", "--world", "work").code == 0)
        // A new notebook shows Inbox, written by the first add.
        #expect(await akit("notebook", "tabs").out == "Inbox  notebook/Inbox.md  0 open tasks")
        let added = await akit("notebook", "add", "inbox", "call the bank", "--task", "--today", "--json")
        #expect(added.code == 0, "\(added.err)")
        #expect(added.out.contains(#""line" : "- [ ] call the bank""#) && added.out.contains(#""tab" : "Inbox""#))
        let today = AKitCLI.dayFormatter.string(from: .now)
        #expect(try String(contentsOf: base.appending(path: "notebook/Inbox.md"), encoding: .utf8) == "## \(today)\n\n- [ ] call the bank\n")
        #expect(await akit("notebook", "show", "Inbox", "--open").out == "- [ ] call the bank")
        #expect(await akit("notebook", "done", "Inbox", "BANK").out == "Ticked in Inbox: - [x] call the bank, committed.")
        #expect(await akit("notebook", "show", "Inbox", "--open").out == "No open tasks in Inbox.")
        let log = try await FakeGit.log(base, env: env)
        #expect(log.hasPrefix("Notebook: done in Inbox\nNotebook: add to Inbox"))
        // A missing tab and a missing task are errors, with the tabs named.
        let missing = await akit("notebook", "show", "Plans")
        #expect(missing.code != 0 && missing.err.contains("Tabs: Inbox"))
        #expect(await akit("notebook", "done", "Inbox", "nothing").code != 0)
        #expect(await akit("notebook", "--help").out.contains("akit notebook add TAB TEXT"))
    }

    @Test func withoutABaseTheReadsSaySo() async throws {
        defer { try? fm.removeItem(at: home) }
        #expect(await akit("notebook", "tabs", "--json").out.contains(#""base" : null"#))
        #expect(await akit("notebook", "add", "Inbox", "x").code != 0)
    }
}

/// The last commit subjects of a base.
enum FakeGit {
    static func log(_ folder: URL, env: HarnessEnvironment) async throws -> String {
        let result = try #require(await ProcessRunner.run(URL(filePath: "/usr/bin/git"), arguments: ["log", "--format=%s"], directory: folder,
                                                           environment: env.variables, timeout: 20))
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
