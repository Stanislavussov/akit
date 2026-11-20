import Foundation
import Testing
import AKitAttention
import AKitFoundation
import AKitMCP
@testable import AKitCommandLine

/// `akit attention` over a made-up home.
struct AttentionCLITests {
    let home = FileManager.default.temporaryDirectory.appending(path: "akit-attention-cli-\(UUID().uuidString)")

    var env: HarnessEnvironment { HarnessEnvironment(homeDirectory: home, variables: ["HOME": home.path]) }

    func akit(_ arguments: String...) async -> (code: Int32, out: String, err: String) {
        var out: [String] = [], err: [String] = []
        let code = await AKitCLI.run(arguments, env: env, cwd: home, projectsRoot: home.appending(path: "Projects"),
                                     hostName: "TestMac.local", out: { out.append($0) }, err: { err.append($0) },
                                     hardwareHash: { "test-hardware" })
        return (code, out.joined(separator: "\n"), err.joined(separator: "\n"))
    }

    @Test func nothingThenAnMCPProblemWithItsLink() async throws {
        #expect(await akit("attention").out == "Nothing needs attention.")
        try MCPCheckStore.save([MCPCheckResult(harness: .pi, name: "jira", folder: home.path, state: .timedOut, checkedAt: .now)], home: home)
        let text = await akit("attention")
        #expect(text.code == 0)
        #expect(text.out.hasPrefix("Needs a Fix (1)\n  MCP server jira: Timed Out\n    MCP Servers · "))
        #expect(text.out.hasSuffix("    akit://mcp?item=pi%7C\(home.path)%7Cjira"))

        let json = await akit("attention", "--json")
        let answer = try JSONSerialization.jsonObject(with: Data(json.out.utf8)) as? [String: Any]
        let item = try #require((answer?["items"] as? [[String: Any]])?.first)
        #expect(item["level"] as? String == "problem")
        #expect(item["source"] as? String == "mcp")
        #expect(item["dismissed"] as? Bool == false)
    }

    @Test func dismissedItemsAreHiddenUnlessAll() async throws {
        try MCPCheckStore.save([MCPCheckResult(harness: .pi, name: "jira", folder: home.path, state: .timedOut, checkedAt: .now)], home: home)
        let items = Attention.collect(env: env, brain: nil, projects: [])
        try AttentionDismissals.dismiss(items, current: items, home: home)
        #expect(await akit("attention").out == "Nothing needs attention. 1 dismissed item hidden (--all shows them).")
        #expect(await akit("attention", "--all").out.contains("· dismissed"))
    }
}
