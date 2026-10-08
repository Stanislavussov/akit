import Foundation
import Testing
import AKitBrain
import AKitFoundation
@testable import AKitProjectSetup

/// The core layer's AGENTS.md text as a marked block in the harnesses' global instruction
/// files, all inside a temporary fake home.
struct InstructionsBlockTests {
    let home: URL
    let fm = FileManager.default
    let id = "home/mac"

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-block-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var env: HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home, variables: [
            "HOME": home.path, "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
            "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
        ], executableSearchPaths: [URL(filePath: "/usr/bin")])
    }

    var brainRoot: URL { Brain.defaultRoot(home: home) }
    var store: ProjectStore { .brain(brainRoot) }

    func write(_ path: String, _ text: String) throws {
        let url = home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func read(_ path: String) -> String? { try? String(contentsOf: home.appending(path: path), encoding: .utf8) }

    func trash(_ url: URL) throws -> URL? {
        let target = home.appending(path: "Trash/\(UUID().uuidString)-\(url.lastPathComponent)")
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: url, to: target)
        return target
    }

    /// The core layer with `text` as its AGENTS.md section (none when nil).
    func core(_ text: String?) async throws -> Brain {
        if !fm.fileExists(atPath: brainRoot.path) { try await BrainSetup.create(at: brainRoot, env: env) }
        try write(".akit/registry/layers/core/layer.yaml", text == nil ? "name: core\n" : "name: core\nfiles:\n  - template: AGENTS.md\n    to: AGENTS.md\n")
        if let text { try write(".akit/registry/layers/core/templates/AGENTS.md", text) }
        return try #require(Brain.load(from: brainRoot))
    }

    func plan(_ brain: Brain, targets: [String] = ["claude"], piAgentDir: URL? = nil) -> ProjectSetup.Plan {
        ProjectSetup.plan(project: home, id: id, answers: ProjectAnswers(layers: ["core"], targets: targets),
                          brain: brain, store: store, forHome: true, piAgentDir: piAgentDir)
    }

    @discardableResult
    func apply(_ plan: ProjectSetup.Plan, accepting: Set<String> = []) async throws -> ProjectSetup.Outcome {
        try await ProjectSetup.apply(plan, accepting: accepting, brain: try #require(Brain.load(from: brainRoot)), home: home, env: env, trash: trash)
    }

    func change(_ plan: ProjectSetup.Plan, _ path: String = ".claude/CLAUDE.md") -> ProjectSetup.Change? { plan.changes.first { $0.path == path } }

    static let block = "<!-- akit:core:start -->\nBe brief.\n<!-- akit:core:end -->\n"
    /// Another tool's block in the same file, which AKit never touches.
    static let mine = "# My rules\n\n<!-- OMC:START -->\nomc text\n<!-- OMC:END -->\n"

    @Test func theBlockIsAppendedAndTheUsersTextStays() async throws {
        let brain = try await core("Be brief.\n")
        try write(".claude/CLAUDE.md", Self.mine)
        let plan = plan(brain)
        #expect(plan.canApply, "\(plan.render.errors) \(plan.blockers)")
        let appended = try #require(change(plan))
        #expect(appended.block && appended.kind == .update && !appended.replacesUnmanaged)
        #expect(appended.oldText == Self.mine && appended.newText == Self.mine + "\n" + Self.block)
        // Never ~/AGENTS.md: no harness reads it.
        #expect(change(plan, "AGENTS.md") == nil)

        let outcome = try await apply(plan)
        #expect(read(".claude/CLAUDE.md") == Self.mine + "\n" + Self.block)
        #expect(!fm.fileExists(atPath: home.appending(path: "AGENTS.md").path))
        let backup = try #require(outcome.backup)
        #expect(try String(contentsOf: backup.appending(path: ".claude/CLAUDE.md"), encoding: .utf8) == Self.mine)
        let record = try #require(ProjectRecords.savedLock(id: id, in: store)?.blocks?[".claude/CLAUDE.md"])
        #expect(record.sha256 == Checksum.sha256(Data("Be brief.\n".utf8)) && record.layers == ["core"])
        #expect(change(self.plan(brain))?.kind == .same)
    }

    @Test func aMissingFileIsCreatedWithOnlyTheBlockForEachTarget() async throws {
        let brain = try await core("Be brief.\n")
        let plan = plan(brain, targets: ["claude", "pi"])
        #expect(change(plan)?.kind == .create)
        #expect(change(plan, ".pi/agent/AGENTS.md")?.kind == .create)
        try await apply(plan)
        #expect(read(".claude/CLAUDE.md") == Self.block)
        #expect(read(".pi/agent/AGENTS.md") == Self.block)
    }

    @Test func anUpdateReplacesOnlyTheBlock() async throws {
        try write(".claude/CLAUDE.md", Self.mine)
        try await apply(plan(try await core("Be brief.\n")))
        // The user adds text after AKit's block.
        try write(".claude/CLAUDE.md", read(".claude/CLAUDE.md")! + "\nMore of mine, no newline")
        let plan = plan(try await core("Be brief.\nAsk first.\n"))
        #expect(change(plan)?.kind == .update)
        try await apply(plan)
        #expect(read(".claude/CLAUDE.md") == Self.mine + "\n<!-- akit:core:start -->\nBe brief.\nAsk first.\n<!-- akit:core:end -->\n\nMore of mine, no newline")
    }

    @Test func anEmptyRenderRemovesOnlyTheBlockAndKeepsTheFile() async throws {
        try write(".claude/CLAUDE.md", Self.mine)
        try await apply(plan(try await core("Be brief.\n"), targets: ["claude", "pi"]))
        let empty = plan(try await core(nil), targets: ["claude", "pi"])
        #expect(change(empty)?.kind == .update && change(empty)?.newText == Self.mine)
        try await apply(empty)
        #expect(read(".claude/CLAUDE.md") == Self.mine)
        // The file AKit created holds nothing else: it stays, empty.
        #expect(read(".pi/agent/AGENTS.md") == "")
        #expect(ProjectRecords.savedLock(id: id, in: store)?.blocks == nil)
        #expect(plan(try await core(nil), targets: ["claude", "pi"]).changes.isEmpty)
    }

    @Test func aTargetNoLongerChosenLosesItsBlock() async throws {
        let brain = try await core("Be brief.\n")
        try await apply(plan(brain, targets: ["claude", "pi"]))
        let claudeOnly = plan(brain, targets: ["claude"])
        #expect(change(claudeOnly, ".pi/agent/AGENTS.md")?.kind == .update)
        try await apply(claudeOnly)
        #expect(read(".pi/agent/AGENTS.md") == "")
        #expect(read(".claude/CLAUDE.md") == Self.block)
        #expect(ProjectRecords.savedLock(id: id, in: store)?.blocks?.keys.sorted() == [".claude/CLAUDE.md"])
    }

    @Test func brokenMarkersBlockApplyAndNothingIsWritten() async throws {
        let brain = try await core("Be brief.\n")
        let broken = [
            "a\n<!-- akit:core:start -->\nno end\n",
            "<!-- akit:core:start -->\n<!-- akit:core:start -->\nx\n<!-- akit:core:end -->\n",
            "<!-- akit:core:end -->\nx\n<!-- akit:core:start -->\n",
            "x\n<!-- akit:core:end -->\n",
        ]
        for text in broken {
            try write(".claude/CLAUDE.md", text)
            let plan = plan(brain)
            #expect(!plan.canApply, "\(text)")
            #expect(plan.blockers.contains { $0.hasPrefix(".claude/CLAUDE.md: AKit's block markers are broken (") }, "\(plan.blockers)")
            await #expect(throws: ProjectSetup.Failure.self) { try await apply(plan) }
            #expect(read(".claude/CLAUDE.md") == text)
        }
    }

    @Test func anEditedBlockIsKeptAndTheLayersTextOfferedUnticked() async throws {
        try write(".claude/CLAUDE.md", Self.mine)
        try await apply(plan(try await core("Be brief.\n")))
        let edited = Self.mine + "\n<!-- akit:core:start -->\nBe brief, mostly.\n<!-- akit:core:end -->\n"
        try write(".claude/CLAUDE.md", edited)

        // Same layers: the edit is the user's; nothing offered.
        let same = plan(try await core("Be brief.\n"))
        #expect(change(same)?.kind == .own)
        try await apply(same)
        #expect(read(".claude/CLAUDE.md") == edited)

        // The layers change: offered once, unticked; Apply without it keeps the edit.
        let changed = plan(try await core("Be very brief.\n"))
        #expect(change(changed)?.kind == .suggest)
        try await apply(changed)
        #expect(read(".claude/CLAUDE.md") == edited)
        #expect(change(plan(try await core("Be very brief.\n")))?.kind == .own)

        // Taken on purpose.
        let taken = plan(try await core("Be very brief.\n"))
        try await apply(taken, accepting: [".claude/CLAUDE.md"])
        #expect(read(".claude/CLAUDE.md") == Self.mine + "\n<!-- akit:core:start -->\nBe very brief.\n<!-- akit:core:end -->\n")
        #expect(change(plan(try await core("Be very brief, please.\n")))?.kind == .update)

        // An edited block outlives an empty render.
        try write(".claude/CLAUDE.md", edited)
        let empty = plan(try await core(nil))
        #expect(change(empty)?.kind == .keepEdited)
        try await apply(empty)
        #expect(read(".claude/CLAUDE.md") == edited)
    }

    @Test func aBlockRemovedByHandIsOnlyOffered() async throws {
        try write(".claude/CLAUDE.md", Self.mine)
        let brain = try await core("Be brief.\n")
        try await apply(plan(brain))
        try write(".claude/CLAUDE.md", Self.mine)
        let plan = plan(brain)
        #expect(change(plan)?.kind == .own)
        #expect(plan.render.warnings.contains { $0.hasPrefix(".claude/CLAUDE.md: AKit's block was removed by hand") })
        try await apply(plan)
        #expect(read(".claude/CLAUDE.md") == Self.mine)
    }

    @Test func piAgentDirIsHonouredInsideAndOutsideTheHomeFolder() async throws {
        let brain = try await core("Be brief.\n")
        let inside = home.appending(path: "custom/pi")
        let first = plan(brain, targets: ["pi"], piAgentDir: inside)
        #expect(first.changes.map(\.path) == ["custom/pi/AGENTS.md"])
        try await apply(first)
        #expect(read("custom/pi/AGENTS.md") == Self.block)
        #expect(!fm.fileExists(atPath: home.appending(path: ".pi").path))

        // Moved outside the home folder: the path is absolute; the old file loses its block.
        let outside = fm.temporaryDirectory.appending(path: "akit-block-pi-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: outside) }
        let moved = plan(brain, targets: ["pi"], piAgentDir: outside)
        let path = outside.appending(path: "AGENTS.md").standardizedFileURL.path
        #expect(change(moved, path)?.kind == .create)
        #expect(change(moved, "custom/pi/AGENTS.md")?.kind == .update)
        try await apply(moved)
        #expect(try String(contentsOf: outside.appending(path: "AGENTS.md"), encoding: .utf8) == Self.block)
        #expect(read("custom/pi/AGENTS.md") == "")
        #expect(ProjectRecords.savedLock(id: id, in: store)?.blocks?.keys.sorted() == [path])
        #expect(change(plan(brain, targets: ["pi"], piAgentDir: outside), path)?.kind == .same)
    }

    @Test func anAGENTSmdOfAnOlderRenderGoesToTheTrashUnlessEdited() async throws {
        let brain = try await core("Be brief.\n")
        for (text, kind) in [("Be brief.\n", ProjectSetup.Change.Kind.remove), ("Be brief. Mine.\n", .keepEdited)] {
            try write("AGENTS.md", text)
            try ProjectRecords.save(ProjectRecords.Lock(brainCommit: nil, brainDirty: false,
                                                        files: ["AGENTS.md": .init(sha256: Checksum.sha256(Data("Be brief.\n".utf8)), link: nil, layers: ["core"])]),
                                    answers: nil, id: id, in: store)
            let plan = plan(brain)
            #expect(change(plan, "AGENTS.md")?.kind == kind)
            try await apply(plan)
            #expect(fm.fileExists(atPath: home.appending(path: "AGENTS.md").path) == (kind == .keepEdited))
        }
    }

    @Test func aFileAnOlderRenderWroteWholeIsTakenOverByTheBlockNeverTrashed() async throws {
        let brain = try await core("Be brief.\n")
        try write(".claude/CLAUDE.md", "old\n")
        try ProjectRecords.save(ProjectRecords.Lock(brainCommit: nil, brainDirty: false,
                                                    files: [".claude/CLAUDE.md": .init(sha256: Checksum.sha256(Data("old\n".utf8)), link: nil, layers: ["core"])]),
                                answers: nil, id: id, in: store)
        let plan = plan(brain)
        #expect(plan.changes.filter { $0.path == ".claude/CLAUDE.md" }.map(\.kind) == [.update])
        try await apply(plan)
        #expect(read(".claude/CLAUDE.md") == "old\n\n" + Self.block)
        #expect(ProjectRecords.savedLock(id: id, in: store)?.files[".claude/CLAUDE.md"] == nil)
    }

    @Test func forgettingTheHomeFolderTakesTheBlocksOut() async throws {
        try write(".claude/CLAUDE.md", Self.mine)
        let brain = try await core("Be brief.\n")
        try await apply(plan(brain, targets: ["claude", "pi"]))
        let preview = try #require(ProjectForget.preview(id: id, folder: home, forHome: true, brain: brain, store: store))
        #expect(preview.blocksTakenOut == [".claude/CLAUDE.md", ".pi/agent/AGENTS.md"])
        #expect(preview.removals.isEmpty)
        try await ProjectForget.run(preview, keepFiles: false, brain: brain, home: home, env: env, trash: trash)
        #expect(read(".claude/CLAUDE.md") == Self.mine)
        #expect(read(".pi/agent/AGENTS.md") == "")
    }

    @Test func anEditAfterThePreviewOrALinkStopsApply() async throws {
        let brain = try await core("Be brief.\n")
        try write(".claude/CLAUDE.md", Self.mine)
        let plan = plan(brain)
        try write(".claude/CLAUDE.md", Self.mine + "new line\n")
        await #expect(throws: ProjectSetup.Failure.self) { try await apply(plan) }
        #expect(read(".claude/CLAUDE.md") == Self.mine + "new line\n")

        try write("dotfiles/CLAUDE.md", Self.mine)
        try fm.removeItem(at: home.appending(path: ".claude/CLAUDE.md"))
        try fm.createSymbolicLink(atPath: home.appending(path: ".claude/CLAUDE.md").path, withDestinationPath: "../dotfiles/CLAUDE.md")
        let linked = self.plan(brain)
        #expect(linked.blockers == [".claude/CLAUDE.md is a link; AKit writes its block only into a plain file."])
    }

    @Test func findingTheBlock() {
        #expect(InstructionsBlock.find(in: "plain") == .none)
        if case .block(_, let inner) = InstructionsBlock.find(in: "a\n<!-- akit:core:start -->\nx\n<!-- akit:core:end -->\nb") {
            #expect(inner == "x\n")
        } else {
            Issue.record("no block found")
        }
        // Appending to a file without a final newline, and taking the block out again.
        let appended = InstructionsBlock.written("x\n", into: "a", found: .none)
        #expect(appended == "a\n\n<!-- akit:core:start -->\nx\n<!-- akit:core:end -->\n")
        #expect(InstructionsBlock.written(nil, into: appended, found: InstructionsBlock.find(in: appended)) == "a\n")
    }
}
