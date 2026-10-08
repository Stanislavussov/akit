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
    func bytes(_ path: String) -> Data? { try? Data(contentsOf: home.appending(path: path)) }

    func trash(_ url: URL) throws -> URL? {
        let target = home.appending(path: "Trash/\(UUID().uuidString)-\(url.lastPathComponent)")
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: url, to: target)
        return target
    }

    /// The core layer with `text` as its AGENTS.md section (none when nil), and more sections
    /// given as (template, when) pairs.
    func core(_ text: String?, more: [(text: String, when: String)] = []) async throws -> Brain {
        if !fm.fileExists(atPath: brainRoot.path) { try await BrainSetup.create(at: brainRoot, env: env) }
        var yaml = "name: core\n"
        if text != nil || !more.isEmpty { yaml += "files:\n" }
        if let text {
            yaml += "  - template: AGENTS.md\n    to: AGENTS.md\n"
            try write(".akit/registry/layers/core/templates/AGENTS.md", text)
        }
        for (index, section) in more.enumerated() {
            yaml += "  - template: more\(index).md\n    to: AGENTS.md\n    when: \(section.when)\n"
            try write(".akit/registry/layers/core/templates/more\(index).md", section.text)
        }
        try write(".akit/registry/layers/core/layer.yaml", yaml)
        return try #require(Brain.load(from: brainRoot))
    }

    func plan(_ brain: Brain, targets: [String] = ["claude"], pi: String? = nil) -> ProjectSetup.Plan {
        ProjectSetup.plan(project: home, id: id, answers: ProjectAnswers(layers: ["core"], targets: targets),
                          brain: brain, store: store, forHome: true, piAgentDirSetting: pi)
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
        #expect(appended.block && appended.kind == .update && !appended.replacesUnmanaged && appended.blockNote == nil)
        #expect(appended.oldText == Self.mine && appended.newText == Self.mine + "\n" + Self.block)
        // Never ~/AGENTS.md.
        #expect(change(plan, "AGENTS.md") == nil)

        let outcome = try await apply(plan)
        #expect(read(".claude/CLAUDE.md") == Self.mine + "\n" + Self.block)
        #expect(!fm.fileExists(atPath: home.appending(path: "AGENTS.md").path))
        let backup = try #require(outcome.backup)
        #expect(try String(contentsOf: backup.appending(path: ".claude/CLAUDE.md"), encoding: .utf8) == Self.mine)
        let record = try #require(ProjectRecords.savedLock(id: id, in: store)?.blocks?[".claude/CLAUDE.md"])
        #expect(record.sha256 == Checksum.sha256(Data("Be brief.\n".utf8)) && record.layers == ["core"])
        #expect(record.separator == "\n" && record.target == "claude")
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

    @Test func appendingAndTakingOutAgainLeavesTheBytesAsTheyWere() async throws {
        let cases = ["A", "A\n", "A\n\n\n", "A\r\nB\r\n", "A\r\nB", "\u{FEFF}A\n", "\u{FEFF}", ""]
        for original in cases {
            try write(".claude/CLAUDE.md", original)
            try await apply(plan(try await core("Be brief.\nTwo.\n")))
            let written = try #require(read(".claude/CLAUDE.md"))
            if original.contains("\r\n") {
                // The block takes the file's own line ending.
                #expect(written.hasSuffix("<!-- akit:core:start -->\r\nBe brief.\r\nTwo.\r\n<!-- akit:core:end -->\r\n"), "\(original.debugDescription)")
                #expect(!written.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "\(written.debugDescription)")
            }
            try await apply(plan(try await core(nil)))
            #expect(bytes(".claude/CLAUDE.md") == Data(original.utf8), "\(original.debugDescription) → \(read(".claude/CLAUDE.md")?.debugDescription ?? "nil")")
        }
        // Text the user puts after the block stays, and the separator still goes.
        try write(".claude/CLAUDE.md", "A\n")
        try await apply(plan(try await core("Be brief.\n")))
        try write(".claude/CLAUDE.md", read(".claude/CLAUDE.md")! + "More\n")
        try await apply(plan(try await core(nil)))
        #expect(read(".claude/CLAUDE.md") == "A\nMore\n")
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

    @Test func onlyWholeMarkerLinesOutsideCodeFencesCount() async throws {
        let brain = try await core("Be brief.\n")
        // Quoted and fenced markers are the user's text; the real block is found among them.
        let quoted = """
            Use `<!-- akit:core:start -->` to find it.
            ```
            <!-- akit:core:start -->
            ```
            ~~~~
            <!-- akit:core:end -->
            ~~~~
              <!-- akit:core:start -->  is indented and quoted here

            """
        try write(".claude/CLAUDE.md", quoted + "<!-- akit:core:start -->  \nold\n<!-- akit:core:end -->\t\n")
        let plan = plan(brain)
        #expect(plan.canApply, "\(plan.blockers)")
        #expect(change(plan)?.kind == .suggest)  // no record: AKit can't tell the text is its own
        try await apply(plan, accepting: [".claude/CLAUDE.md"])
        #expect(read(".claude/CLAUDE.md") == quoted + Self.block)

        // A layer's text that holds a marker would break the next render: an error.
        let marked = try await core("Write <!-- akit:core:end --> nowhere.\n")
        #expect(self.plan(marked).render.errors == ["The core layer's AGENTS.md text holds <!-- akit:core:end -->, which marks AKit's block. Take it out of the layer."])
    }

    @Test func anEditedBlockIsKeptAndTheLayersTextOfferedUnticked() async throws {
        try write(".claude/CLAUDE.md", Self.mine)
        try await apply(plan(try await core("Be brief.\n")))
        let edited = Self.mine + "\n<!-- akit:core:start -->\nBe brief, mostly.\n<!-- akit:core:end -->\n"
        try write(".claude/CLAUDE.md", edited)

        // Same layers: the edit is the user's; nothing offered.
        let same = plan(try await core("Be brief.\n"))
        #expect(change(same)?.kind == .own && change(same)?.blockNote == "edited by hand")
        try await apply(same)
        #expect(read(".claude/CLAUDE.md") == edited)

        // The layers change: offered once, unticked; Apply without it keeps the edit.
        let changed = plan(try await core("Be very brief.\n"))
        #expect(change(changed)?.kind == .suggest && change(changed)?.blockNote == "edited by hand · layers changed")
        try await apply(changed)
        #expect(read(".claude/CLAUDE.md") == edited)
        #expect(change(plan(try await core("Be very brief.\n")))?.kind == .own)

        // Taken on purpose.
        let taken = plan(try await core("Be very brief.\n"))
        try await apply(taken, accepting: [".claude/CLAUDE.md"])
        #expect(read(".claude/CLAUDE.md") == Self.mine + "\n<!-- akit:core:start -->\nBe very brief.\n<!-- akit:core:end -->\n")
        #expect(change(plan(try await core("Be very brief, please.\n")))?.kind == .update)

        // An edited block outlives an empty render, and Forget says it stays.
        try write(".claude/CLAUDE.md", edited)
        let empty = plan(try await core(nil))
        #expect(change(empty)?.kind == .keepEdited)
        try await apply(empty)
        #expect(read(".claude/CLAUDE.md") == edited)
        let forget = try #require(ProjectForget.preview(id: id, folder: home, forHome: true, brain: try await core(nil), store: store))
        #expect(forget.blocksLeft == [".claude/CLAUDE.md"] && forget.blocksTakenOut.isEmpty && forget.kept.isEmpty)
    }

    @Test func aBlockRemovedByHandIsOnlyOffered() async throws {
        try write(".claude/CLAUDE.md", Self.mine)
        let brain = try await core("Be brief.\n")
        try await apply(plan(brain))
        try write(".claude/CLAUDE.md", Self.mine)
        let plan = plan(brain)
        #expect(change(plan)?.kind == .own && change(plan)?.blockNote == "removed by hand")
        #expect(plan.render.warnings.contains { $0.hasPrefix(".claude/CLAUDE.md: AKit's block was removed by hand") })
        try await apply(plan)
        #expect(read(".claude/CLAUDE.md") == Self.mine)
    }

    @Test func piGetsTheBlockInTheFileItReads() async throws {
        let brain = try await core("Be brief.\n")
        // Only CLAUDE.md in Pi's folder: Pi reads it, so the block goes there.
        try write(".pi/agent/CLAUDE.md", "mine\n")
        let claudeOnly = plan(brain, targets: ["pi"])
        #expect(claudeOnly.changes.map(\.path) == [".pi/agent/CLAUDE.md"])
        try await apply(claudeOnly)
        #expect(read(".pi/agent/CLAUDE.md") == "mine\n\n" + Self.block)
        #expect(!fm.fileExists(atPath: home.appending(path: ".pi/agent/AGENTS.md").path))

        // An AGENTS.override.md wins over everything: the block moves there; the old one is only offered.
        try write(".pi/agent/AGENTS.override.md", "override\n")
        let moved = plan(brain, targets: ["pi"])
        #expect(change(moved, ".pi/agent/AGENTS.override.md")?.kind == .update)
        #expect(change(moved, ".pi/agent/CLAUDE.md")?.kind == .suggest)
        #expect(moved.render.warnings.contains { $0.hasPrefix(".pi/agent/CLAUDE.md has AKit's block, but Pi now reads .pi/agent/AGENTS.override.md.") })
        try await apply(moved)
        #expect(read(".pi/agent/AGENTS.override.md") == "override\n\n" + Self.block)
        #expect(read(".pi/agent/CLAUDE.md") == "mine\n\n" + Self.block)
        try await apply(plan(brain, targets: ["pi"]), accepting: [".pi/agent/CLAUDE.md"])
        #expect(read(".pi/agent/CLAUDE.md") == "mine\n")
        #expect(ProjectRecords.savedLock(id: id, in: store)?.blocks?.keys.sorted() == [".pi/agent/AGENTS.override.md"])
    }

    @Test func piAgentDirIsHonouredAndRememberedForAnEnvironmentWithoutIt() async throws {
        let brain = try await core("Be brief.\n")
        let first = plan(brain, targets: ["pi"], pi: "~/custom/pi")
        #expect(first.changes.map(\.path) == ["custom/pi/AGENTS.md"])
        try await apply(first)
        #expect(read("custom/pi/AGENTS.md") == Self.block)
        #expect(!fm.fileExists(atPath: home.appending(path: ".pi").path))
        #expect(ProjectRecords.savedLock(id: id, in: store)?.piAgentDir == home.appending(path: "custom/pi").standardizedFileURL.path)
        // The app started from the Finder has no PI_CODING_AGENT_DIR: the recorded folder holds.
        #expect(change(plan(brain, targets: ["pi"]), "custom/pi/AGENTS.md")?.kind == .same)

        // Moved outside the home folder: an absolute path; the old block is only offered for removal.
        let outside = fm.temporaryDirectory.appending(path: "akit-block-pi-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: outside) }
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("theirs\n".utf8).write(to: outside.appending(path: "AGENTS.md"))
        let moved = plan(brain, targets: ["pi"], pi: outside.path)
        let path = outside.appending(path: "AGENTS.md").standardizedFileURL.path
        #expect(change(moved, path)?.kind == .update)
        #expect(change(moved, "custom/pi/AGENTS.md")?.kind == .suggest)
        let outcome = try await apply(moved)
        #expect(try String(contentsOf: outside.appending(path: "AGENTS.md"), encoding: .utf8) == "theirs\n\n" + Self.block)
        // The file outside the home folder is backed up under its full path.
        let backup = try #require(outcome.backup)
        #expect(try String(contentsOf: backup.appending(path: path), encoding: .utf8) == "theirs\n")
        #expect(read("custom/pi/AGENTS.md") == Self.block)
        #expect(Set(ProjectRecords.savedLock(id: id, in: store)?.blocks.map { Array($0.keys) } ?? []) == [path, "custom/pi/AGENTS.md"])
        #expect(change(plan(brain, targets: ["pi"]), path)?.kind == .same)

        // A relative setting: Pi resolves it from where it starts, so AKit leaves Pi alone.
        let relative = plan(brain, targets: ["pi"], pi: "pi-config")
        #expect(relative.changes.isEmpty)
        #expect(relative.render.warnings.contains { $0.hasPrefix("PI_CODING_AGENT_DIR is a relative path (pi-config)") })
    }

    @Test func aSectionForOneTargetReachesOnlyThatHarness() async throws {
        let brain = try await core("Be brief.\n", more: [("Pi only.\n", "target == pi"), ("Claude only.\n", "target == claude")])
        try await apply(plan(brain, targets: ["claude", "pi"]))
        #expect(read(".claude/CLAUDE.md") == "<!-- akit:core:start -->\nBe brief.\n\nClaude only.\n<!-- akit:core:end -->\n")
        #expect(read(".pi/agent/AGENTS.md") == "<!-- akit:core:start -->\nBe brief.\n\nPi only.\n<!-- akit:core:end -->\n")
    }

    @Test func anAGENTSmdOfAnOlderRenderGoesToTheTrashUnlessEdited() async throws {
        let brain = try await core("Be brief.\n")
        for (text, kind) in [("Be brief.\n", ProjectSetup.Change.Kind.remove), ("Be brief. Mine.\n", .keepEdited)] {
            try write("AGENTS.md", text)
            try ProjectRecords.save(ProjectRecords.Lock(brainCommit: nil, brainDirty: false,
                                                        files: ["AGENTS.md": .init(sha256: Checksum.sha256(Data("Be brief.\n".utf8)), link: nil, layers: ["core"])]),
                                    answers: nil, id: id, in: store)
            let plan = plan(brain, targets: ["claude", "pi"])
            #expect(change(plan, "AGENTS.md")?.kind == kind)
            // Pi reads a kept ~/AGENTS.md as well as its own file: said so.
            #expect(plan.render.warnings.contains { $0.hasPrefix("AGENTS.md in the home folder is kept") } == (kind == .keepEdited))
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
        #expect(preview.removals.isEmpty && preview.blocksLeft.isEmpty)
        try await ProjectForget.run(preview, keepFiles: false, brain: brain, home: home, env: env, trash: trash)
        #expect(read(".claude/CLAUDE.md") == Self.mine)
        #expect(read(".pi/agent/AGENTS.md") == "")
    }

    @Test func aLockWithoutBlocksStillFindsAKitsOwnTextAndForgetSaysWhatStays() async throws {
        let brain = try await core("Be brief.\n")
        try write(".claude/CLAUDE.md", Self.mine)
        try await apply(plan(brain))
        // An older AKit saved the lock again, without `blocks`.
        var lock = try #require(ProjectRecords.savedLock(id: id, in: store))
        lock.blocks = nil
        try ProjectRecords.save(lock, answers: nil, id: id, in: store)
        // Forget can't tell the block is untouched: it stays, and Forget says so.
        let forget = try #require(ProjectForget.preview(id: id, folder: home, forHome: true, brain: brain, store: store))
        #expect(forget.blocksLeft == [".claude/CLAUDE.md"] && forget.blocksTakenOut.isEmpty)
        // The layers' own text: AKit's again, with a record.
        let same = plan(brain)
        #expect(change(same)?.kind == .same)
        try await apply(same)
        #expect(ProjectRecords.savedLock(id: id, in: store)?.blocks?[".claude/CLAUDE.md"] != nil)
        let again = try #require(ProjectForget.preview(id: id, folder: home, forHome: true, brain: brain, store: store))
        #expect(again.blocksTakenOut == [".claude/CLAUDE.md"])
    }

    @Test func aLockKeyThatIsNoInstructionsFileIsIgnored() async throws {
        let brain = try await core("Be brief.\n")
        try write("Documents/notes.md", "<!-- akit:core:start -->\nx\n<!-- akit:core:end -->\n")
        try ProjectRecords.save(ProjectRecords.Lock(brainCommit: nil, brainDirty: false, files: [:],
                                                    blocks: ["Documents/notes.md": .init(sha256: "00", offered: nil, layers: ["core"])]),
                                answers: nil, id: id, in: store)
        let plan = plan(brain)
        #expect(change(plan, "Documents/notes.md") == nil)
        #expect(plan.render.warnings.contains("The lock names Documents/notes.md as an instructions file AKit wrote; it is not one AKit writes now, so AKit leaves it alone."))
        try await apply(plan)
        #expect(read("Documents/notes.md") == "<!-- akit:core:start -->\nx\n<!-- akit:core:end -->\n")
    }

    @Test func anEditAfterThePreviewStopsApplyAndLinkedFilesAreSkipped() async throws {
        let brain = try await core("Be brief.\n")
        try write(".claude/CLAUDE.md", Self.mine)
        let plan = plan(brain)
        try write(".claude/CLAUDE.md", Self.mine + "new line\n")
        await #expect(throws: ProjectSetup.Failure.self) { try await apply(plan) }
        #expect(read(".claude/CLAUDE.md") == Self.mine + "new line\n")

        // A link (dotfiles) and a hard link: skipped with a warning; the rest still updates.
        try write("dotfiles/CLAUDE.md", Self.mine)
        try fm.removeItem(at: home.appending(path: ".claude/CLAUDE.md"))
        try fm.createSymbolicLink(atPath: home.appending(path: ".claude/CLAUDE.md").path, withDestinationPath: "../dotfiles/CLAUDE.md")
        try write("dotfiles/AGENTS.md", "pi\n")
        try fm.createDirectory(at: home.appending(path: ".pi/agent"), withIntermediateDirectories: true)
        try fm.linkItem(at: home.appending(path: "dotfiles/AGENTS.md"), to: home.appending(path: ".pi/agent/AGENTS.md"))
        let linked = self.plan(brain, targets: ["claude", "pi"])
        #expect(linked.canApply && linked.changes.isEmpty, "\(linked.blockers) \(linked.changes.map(\.path))")
        #expect(linked.render.warnings.contains(".claude/CLAUDE.md is a link; AKit writes its block only into a plain file. AKit's block is not written there."))
        #expect(linked.render.warnings.contains(".pi/agent/AGENTS.md has 2 hard links; AKit writes its block only into a file with one. AKit's block is not written there."))
        try await apply(linked)
        #expect(read("dotfiles/CLAUDE.md") == Self.mine && read("dotfiles/AGENTS.md") == "pi\n")
    }

    @Test func findingTheBlock() {
        #expect(InstructionsBlock.find(in: Array("plain".utf8)) == .none)
        if case .block(_, let inner) = InstructionsBlock.find(in: Array("a\n<!-- akit:core:start -->\nx\n<!-- akit:core:end -->\nb".utf8)) {
            #expect(inner == Array("x\n".utf8))
        } else {
            Issue.record("no block found")
        }
        // A BOM before a marker on the first line still counts.
        if case .block = InstructionsBlock.find(in: Array("\u{FEFF}<!-- akit:core:start -->\n<!-- akit:core:end -->\n".utf8)) {} else {
            Issue.record("no block found after a BOM")
        }
    }
}
