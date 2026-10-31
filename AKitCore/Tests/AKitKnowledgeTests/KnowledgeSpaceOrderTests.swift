import Foundation
import Testing
import AKitFoundation
@testable import AKitKnowledge

/// The order of the spaces (K31): `.spaces.json` in the base, committed; listed spaces first, the
/// rest by name; Move Up / Move Down; a deleted space leaves the file in the same commit.
final class KnowledgeSpaceOrderTests {
    deinit { try? FileManager.default.removeItem(at: home) }

    let home: URL
    init() throws { home = try FakeHome.make("akit-kb-spaces") }
    var env: HarnessEnvironment { FakeHome.env(home) }

    func base(_ spaces: [String]) async throws -> KnowledgeBase {
        let base = try await TemplateBase.base(home: home)
        for space in spaces { try base.newArea(space) }
        return base
    }

    func last(_ base: KnowledgeBase) async throws -> String {
        try await FakeHome.git(["log", "--format=%s", "--name-status", "-1"], in: base.root, env: env)
    }

    func saved(_ base: KnowledgeBase) throws -> String {
        try String(contentsOf: base.root.appending(path: ".spaces.json"), encoding: .utf8)
    }

    @Test func listedSpacesComeFirstAndTheRestByName() {
        #expect(KnowledgeBase.ordered(["a", "b", "c", "d"], saved: []) == ["a", "b", "c", "d"])
        #expect(KnowledgeBase.ordered(["d", "a", "c", "b"], saved: ["c", "gone", "a"]) == ["c", "a", "b", "d"], "a name that is no space is ignored")
    }

    @Test func aReorderIsWrittenAndCommittedAndUnknownNamesAreDropped() async throws {
        let base = try await base(["logistics", "payments", "support"])
        #expect(base.areas().map(\.name) == ["logistics", "payments", "support"])

        try await base.reorder(spaces: ["support", "nowhere", "payments", "support"], env: env)
        #expect(base.areas().map(\.name) == ["support", "payments", "logistics"])
        #expect(try saved(base) == "{\n  \"spaces\" : [\n    \"support\",\n    \"payments\",\n    \"logistics\"\n  ]\n}\n")
        #expect(try await last(base) == "Reorder spaces\n\nA\t.spaces.json")

        // A stale name in the file is ignored now and dropped at the next write; a new space comes after.
        try Data(#"{"spaces":["gone","payments"]}"#.utf8).write(to: base.root.appending(path: ".spaces.json"))
        try base.newArea("billing")
        #expect(base.areas().map(\.name) == ["payments", "billing", "logistics", "support"])
        try await base.move(space: "support", by: -1, env: env)
        #expect(base.areas().map(\.name) == ["payments", "billing", "support", "logistics"])
        #expect(!(try saved(base)).contains("gone"))
        #expect(try await last(base) == "Reorder spaces\n\nM\t.spaces.json")

        // At the top, Move Up does nothing; an unknown space is refused.
        try await base.move(space: "payments", by: -1, env: env)
        #expect(try await last(base) == "Reorder spaces\n\nM\t.spaces.json")
        await #expect(throws: KnowledgeBase.Failure.self) { try await base.move(space: "nowhere", by: 1, env: self.env) }
    }

    /// Review finding 8: dragged down a space goes after the one it is dropped on, so the last
    /// place can be reached; dragged up, before it.
    @Test func aDroppedSpaceGoesAfterWhenMovedDownAndBeforeWhenMovedUp() async throws {
        let base = try await base(["a", "b", "c"])
        try await base.move(space: "a", onto: "c", env: env)
        #expect(base.areas().map(\.name) == ["b", "c", "a"])
        try await base.move(space: "a", onto: "b", env: env)
        #expect(base.areas().map(\.name) == ["a", "b", "c"])
        try await base.move(space: "a", onto: "b", env: env)
        #expect(base.areas().map(\.name) == ["b", "a", "c"])
        try await base.move(space: "a", onto: "a", env: env)
        #expect(base.areas().map(\.name) == ["b", "a", "c"])
    }

    /// Review finding 15: a broken `.spaces.json` is read as none, and the next move writes it again.
    @Test func aBrokenOrderFileIsIgnoredAndRewritten() async throws {
        let base = try await base(["b", "a"])
        try Data("{ not json".utf8).write(to: base.root.appending(path: ".spaces.json"))
        #expect(base.areas().map(\.name) == ["a", "b"])
        try await base.move(space: "b", by: -1, env: env)
        #expect(base.areas().map(\.name) == ["b", "a"])
        #expect(try saved(base).contains("\"b\",\n    \"a\""))
    }

    @Test func aDeletedSpaceLeavesTheOrderInTheSameCommit() async throws {
        let base = try await base(["logistics", "payments"])
        try await base.newNote(area: "logistics", name: "warehouse", kind: nil, env: env)
        try await base.reorder(spaces: ["payments", "logistics"], env: env)
        let trashed = home.appending(path: "trash")
        try FileManager.default.createDirectory(at: trashed, withIntermediateDirectories: true)
        try await base.moveToTrash(area: "logistics", env: env, trash: { url in
            let target = trashed.appending(path: UUID().uuidString)
            try FileManager.default.moveItem(at: url, to: target)
            return target
        })
        let log = try await last(base)
        #expect(log.hasPrefix("Delete area logistics") && log.contains("M\t.spaces.json") && log.contains("D\tareas/logistics/warehouse.md"))
        #expect(!(try saved(base)).contains("logistics"))
        #expect(try await FakeHome.git(["status", "--porcelain"], in: base.root, env: env) == "")
    }

    @Test func theFileIsNoSpaceNoteOrWatchedChange() async throws {
        let base = try await base(["payments"])
        try await base.reorder(spaces: ["payments"], env: env)
        #expect(base.areas().map(\.name) == ["payments"])
        #expect(try base.notes().isEmpty)
        #expect(WatchFilter.classify(".spaces.json") == .ignore)
        #expect(KnowledgeLint.run(base, projects: .init(), home: home).allSatisfy { !$0.file.contains("spaces") })
    }
}
