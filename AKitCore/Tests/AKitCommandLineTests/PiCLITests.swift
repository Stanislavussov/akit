import Foundation
import Testing
import AKitFoundation
@testable import AKitCommandLine

/// `akit pi packages`, `akit mcp login --harness pi` and `akit mcp set --exposure`, in a temporary
/// fake home whose `pi` is a script that records its arguments and folder.
struct PiCLITests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-cli-pi-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try write("bin/pi", "#!/bin/sh\necho \"$PWD $*\" >> \"$HOME/pi-calls.txt\"\necho \"pi did $1\"\n")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.appending(path: "bin/pi").path)
        try write(".pi/agent/settings.json", #"{"lastChangelogVersion": "1.0.4", "packages": ["npm:pi-here", "npm:pi-missing"]}"#)
        try write(".pi/agent/npm/node_modules/pi-here/package.json", #"{"name": "pi-here", "version": "2.0.0"}"#)
        try write(".pi/agent/mcp.json", "{\n  \"mcpServers\": {\n    \"docs\": {\"url\": \"https://example.com/mcp\", \"exposure\": \"direct\"}\n  }\n}\n")
    }

    var env: HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home, variables: ["HOME": home.path], executableSearchPaths: [home.appending(path: "bin")])
    }

    func write(_ path: String, _ text: String) throws {
        let url = home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    var calls: [String] {
        ((try? String(contentsOf: home.appending(path: "pi-calls.txt"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    func akit(_ arguments: String...) async -> (code: Int32, out: String, err: String) {
        var out: [String] = [], err: [String] = []
        let code = await AKitCLI.run(arguments, env: env, cwd: home, projectsRoot: home.appending(path: "Projects"),
                                     hostName: "TestMac.local", out: { out.append($0) }, err: { err.append($0) })
        return (code, out.joined(separator: "\n"), err.joined(separator: "\n"))
    }

    @Test func packagesListShowsTheMissingOne() async throws {
        let list = await akit("pi", "packages")
        #expect(list.code == 0, "\(list.err)")
        #expect(list.out.contains("  npm:pi-here  pi-here 2.0.0"))
        #expect(list.out.contains("! npm:pi-missing  not installed"))
        #expect(await akit("pi", "packages", "--json").out.contains(#""installed" : false"#))
    }

    @Test func installAndRemoveRunPiOnlyWithYes() async throws {
        let plan = await akit("pi", "packages", "install")
        #expect(plan.code == 0 && plan.out == "Runs: pi update --extensions\nRun again with --yes to do it.", "\(plan.out)")
        let one = await akit("pi", "packages", "install", "npm:pi-missing")
        #expect(one.out.hasPrefix("Runs: pi install npm:pi-missing\n"))
        #expect(calls.isEmpty)

        let done = await akit("pi", "packages", "install", "npm:pi-missing", "--yes")
        #expect(done.code == 0, "\(done.err)")
        #expect(done.out.contains("pi did install") && done.out.hasSuffix("Done."))
        let project = home.appending(path: "Projects/app")
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        #expect(await akit("pi", "packages", "remove", "npm:pi-here", "--project", project.path, "--yes").code == 0)
        let real = FileWalk.realPath(home) ?? home.path
        #expect(calls == ["\(real) install npm:pi-missing", "\(FileWalk.realPath(project) ?? project.path) remove npm:pi-here -l"])
        #expect(await akit("pi", "packages", "remove").code == 2)
    }

    @Test func mcpLoginRunsPiMCPLoginWithYes() async throws {
        let plan = await akit("mcp", "login", "docs", "--harness", "pi")
        #expect(plan.out == "Runs: pi mcp login docs --timeout 300\nRun again with --yes to do it.", "\(plan.out) \(plan.err)")
        #expect(calls.isEmpty)
        #expect(await akit("mcp", "login", "docs", "--harness", "pi", "--yes").code == 0)
        #expect(calls.count == 1 && calls[0].hasSuffix(" mcp login docs --timeout 300"))
        #expect(await akit("mcp", "login", "nope", "--harness", "pi").code == 2)
        #expect(await akit("mcp", "login", "docs", "--harness", "claude").code == 2)
    }

    @Test func exposureShowsTheChangeAndWritesWithABackup() async throws {
        let file = home.appending(path: ".pi/agent/mcp.json")
        let before = try String(contentsOf: file, encoding: .utf8)
        let plan = await akit("mcp", "set", "docs", "--harness", "pi", "--exposure", "deferred")
        #expect(plan.code == 0, "\(plan.err)")
        #expect(plan.out.contains("Set docs's Exposure to deferred in Pi.") && plan.out.contains("deferred"))
        #expect(plan.out.hasSuffix("Run again with --yes to do it."))
        #expect(try String(contentsOf: file, encoding: .utf8) == before)

        let done = await akit("mcp", "set", "docs", "--harness", "pi", "--exposure", "deferred", "--yes")
        #expect(done.code == 0, "\(done.err)")
        #expect(done.out.contains("Done. Backups: ~/"))
        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        #expect(((after?["mcpServers"] as? [String: Any])?["docs"] as? [String: Any])?["exposure"] as? String == "deferred")
        // Codemode is Pi's default: the key goes.
        #expect(await akit("mcp", "set", "docs", "--harness", "pi", "--exposure", "codemode", "--yes").code == 0)
        let back = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        #expect(((back?["mcpServers"] as? [String: Any])?["docs"] as? [String: Any])?["exposure"] == nil)
        #expect(await akit("mcp", "set", "docs", "--harness", "pi", "--exposure", "loud").code == 2)
    }
}
