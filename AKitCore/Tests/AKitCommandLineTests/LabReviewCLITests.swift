import Foundation
import Testing
import AKitFoundation
@testable import AKitCommandLine

/// `akit lab new review` of a Pi session: found by its id, reviewed by Pi unless --harness
/// says otherwise. Queued with --no-start; nothing runs.
extension AKitCLITests {
    @Test func aPiSessionIsReviewedByPiByDefault() async throws {
        try write(".pi/agent/sessions/--work--/2026-10-07T07-00-00-000Z_pi-s1.jsonl",
                  #"{"type":"session","version":3,"id":"pi-s1","cwd":"/work"}"# + "\n")

        let queued = await akit("lab", "new", "review", "pi-s1", "--env", "background", "--no-start")
        #expect(queued.code == 0 && queued.out.contains("by Pi"), "\(queued)")
        let claude = await akit("lab", "new", "review", "pi-s1", "--harness", "claude-code", "--model", "sonnet",
                                "--env", "background", "--no-start")
        #expect(claude.code == 0 && claude.out.contains("by Claude Code"), "\(claude)")
        let runs = await akit("lab", "list", "--json")
        let specs = try #require(try JSONSerialization.jsonObject(with: Data(runs.out.utf8)) as? [[String: Any]])
            .compactMap { $0["spec"] as? [String: Any] }
        #expect(specs.count == 2 && specs.allSatisfy { $0["reviewedHarnessName"] as? String == "pi" }, "\(specs)")

        // AKit measures only Claude Code sessions, and an unknown id names both places.
        #expect(await akit("lab", "analyze", "pi-s1").err.contains("measures only Claude Code sessions"))
        #expect(await akit("lab", "new", "review", "nope", "--no-start").err.contains("No Claude Code or Pi session nope"))
    }
}
