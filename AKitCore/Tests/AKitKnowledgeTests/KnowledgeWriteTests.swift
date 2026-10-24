import Foundation
import Testing
import AKitFoundation
@testable import AKitKnowledge

/// Checked map saves (step 2.2b) on a base in a temporary fake home.
struct KnowledgeWriteTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = URL(filePath: FileWalk.realPath(fm.temporaryDirectory) ?? fm.temporaryDirectory.path)
            .appending(path: "akit-kbw-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    func env() -> HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home,
                           variables: ["HOME": home.path, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"],
                           executableSearchPaths: [URL(filePath: "/usr/bin")])
    }

    func makeMap() async throws -> (KnowledgeBase, String) {
        let base = try await KnowledgeBase.create(world: "work", env: env())
        try base.newArea("payments")
        _ = try await base.newMap(area: "payments", name: "overview", env: env())
        return (base, "payments/maps/overview")
    }

    /// What the canvas posts: serializeAsJSON's text, with its own spacing and key order.
    let posted = ##"{"type":"excalidraw","version":2,"source":"akit-web://app","elements":[{"id":"r1","type":"rectangle","x":1.5,"link":"[[billing]]"}],"appState":{"gridSize":null,"viewBackgroundColor":"#ffffff"},"files":{}}"## + "\n"

    @Test func theSavedFileIsThePostedBytesExactly() async throws {
        let (base, id) = try await makeMap()
        let loaded = try #require(KnowledgeWrite.hash(of: base.mapFile(id)))
        let bytes = Data(posted.utf8)
        let saved = try base.saveMap(id, bytes: bytes, expectedHash: loaded)
        #expect(saved.path == "areas/payments/maps/overview.excalidraw")
        #expect(saved.outcome == .saved(hash: KnowledgeWrite.hash(bytes)))
        #expect(try Data(contentsOf: base.mapFile(id)) == bytes)
        // The next save expects the hash of its own last write.
        let again = Data(posted.replacingOccurrences(of: "1.5", with: "2").utf8)
        #expect(try base.saveMap(id, bytes: again, expectedHash: KnowledgeWrite.hash(bytes)).outcome == .saved(hash: KnowledgeWrite.hash(again)))
        #expect(try Data(contentsOf: base.mapFile(id)) == again)
    }

    @Test func aChangeOnDiskIsAConflictAndNothingIsWritten() async throws {
        let (base, id) = try await makeMap()
        let loaded = try #require(KnowledgeWrite.hash(of: base.mapFile(id)))
        // Someone else (Obsidian, another editor) appends a space.
        let handle = try FileHandle(forWritingTo: base.mapFile(id))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(" ".utf8))
        try handle.close()
        let disk = try Data(contentsOf: base.mapFile(id))
        let result = try base.saveMap(id, bytes: Data(posted.utf8), expectedHash: loaded)
        #expect(result.outcome == .conflict(diskHash: KnowledgeWrite.hash(disk)))
        #expect(try Data(contentsOf: base.mapFile(id)) == disk)
        // Keep Mine: the disk copy's hash is the expected one, so the write goes through.
        #expect(try base.saveMap(id, bytes: Data(posted.utf8), expectedHash: KnowledgeWrite.hash(disk)).outcome
            == .saved(hash: KnowledgeWrite.hash(Data(posted.utf8))))
    }

    @Test func onlyAnExistingMapUnderAreasIsSaved() async throws {
        let (base, _) = try await makeMap()
        #expect(throws: KnowledgeBase.Failure.self) { try base.saveMap("payments/maps/missing", bytes: Data(), expectedHash: "") }
        #expect(throws: KnowledgeBase.Failure.self) { try base.saveMap("../outside", bytes: Data(), expectedHash: "") }
    }

    @Test func mapEditsCommitAsEditMaps() {
        #expect(KnowledgeCommitQueue.message(for: ["areas/payments/maps/overview.excalidraw"]) == "Edit maps: payments/maps/overview")
        #expect(KnowledgeCommitQueue.message(for: ["areas/a/maps/x.excalidraw", "areas/a/maps/y.excalidraw"]) == "Edit maps: a/maps/x, a/maps/y")
        #expect(KnowledgeCommitQueue.message(for: ["areas/a/maps/x.excalidraw", "areas/a/n.md"]) == "Edit notes and maps: a/maps/x, a/n")
        #expect(KnowledgeCommitQueue.message(for: ["areas/a/n.md"]) == "Edit a/n")
    }
}
