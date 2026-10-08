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

    /// `remember`: as the app, which keeps the folder of the last render when none is set.
    func plan(_ brain: Brain, targets: [String] = ["claude"], pi: String? = nil, remember: Bool = false) -> ProjectSetup.Plan {
        ProjectSetup.plan(project: home, id: id, answers: ProjectAnswers(layers: ["core"], targets: targets),
                          brain: brain, store: store, forHome: true, piAgentDirSetting: pi, rememberPiAgentDir: remember)
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
        // Pi's file AKit created holds nothing else: an empty one would still be the file Pi
        // reads, so it goes to the Trash.
        #expect(change(empty, ".pi/agent/AGENTS.md")?.kind == .remove && change(empty, ".pi/agent/AGENTS.md")?.blockAction == .trash)
        #expect(!fm.fileExists(atPath: home.appending(path: ".pi/agent/AGENTS.md").path))
        #expect(ProjectRecords.savedLock(id: id, in: store)?.blocks == nil)
        #expect(plan(try await core(nil), targets: ["claude", "pi"]).changes.isEmpty)
    }

    @Test func aTargetNoLongerChosenLosesItsBlock() async throws {
        let brain = try await core("Be brief.\n")
        try await apply(plan(brain, targets: ["claude", "pi"]))
        let claudeOnly = plan(brain, targets: ["claude"])
        #expect(change(claudeOnly, ".pi/agent/AGENTS.md")?.kind == .remove)
        try await apply(claudeOnly)
        #expect(read(".pi/agent/AGENTS.md") == nil)
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

    @Test func takingTheBlockOutNeverJoinsTheUsersLinesOrDropsTheirText() async throws {
        let block = Self.block
        // (original file, the file as the user left it around AKit's block, the file without the block)
        let cases: [(String, (String) -> String, String)] = [
            // No final newline; text added after the block.
            ("A", { $0 + "B\n" }, "A\nB\n"),
            // The blank line before the block deleted, text added after it.
            ("A\n", { _ in "A\n" + block + "B\n" }, "A\nB\n"),
            ("A", { _ in "A\n" + block + "B" }, "A\nB"),
            // Text added before the block (after AKit's blank line), and both before and after.
            ("A\n", { _ in "A\n\nX\n" + block }, "A\n\nX\n"),
            ("A\n", { _ in "A\n\nX\n" + block + "Y\n" }, "A\n\nX\nY\n"),
            // Blank lines added around the block.
            ("A\n", { _ in "A\n\n\n" + block + "\nB\n" }, "A\n\n\nB\n"),
            // The block moved to the top.
            ("A\n", { _ in block + "A\n" }, "A\n"),
            // CRLF, text added after.
            ("A\r\n", { $0 + "B\r\n" }, "A\r\nB\r\n"),
        ]
        for (original, edit, expected) in cases {
            try write(".claude/CLAUDE.md", original)
            try await apply(plan(try await core("Be brief.\n")))
            let written = try #require(read(".claude/CLAUDE.md"))
            try write(".claude/CLAUDE.md", edit(written))
            let out = plan(try await core(nil))
            #expect(out.canApply, "\(out.blockers)")
            try await apply(out)
            #expect(read(".claude/CLAUDE.md") == expected, "\(original.debugDescription): got \(read(".claude/CLAUDE.md")?.debugDescription ?? "nil")")
        }
    }

    @Test func aBlockAfterACodeFenceThatNeverClosesIsStillFound() async throws {
        let original = "Notes\n```\ncode without an end\n"
        try write(".claude/CLAUDE.md", original)
        try await apply(plan(try await core("Be brief.\n")))
        // Found again: nothing appended twice.
        #expect(change(plan(try await core("Be brief.\n")))?.kind == .same)
        try await apply(plan(try await core("Be brief.\nTwo.\n")))
        #expect(read(".claude/CLAUDE.md") == original + "\n<!-- akit:core:start -->\nBe brief.\nTwo.\n<!-- akit:core:end -->\n")
        let forget = try #require(ProjectForget.preview(id: id, folder: home, forHome: true, brain: try await core(nil), store: store))
        #expect(forget.blocksTakenOut == [".claude/CLAUDE.md"])
        try await apply(plan(try await core(nil)))
        #expect(read(".claude/CLAUDE.md") == original)
    }

    @Test func aTrashedPiFileLeavesItsFolderEvenALinkedEmptyOne() async throws {
        let brain = try await core("Be brief.\n")
        try fm.createDirectory(at: home.appending(path: "dotfiles/pi"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appending(path: ".pi"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: home.appending(path: ".pi/agent").path, withDestinationPath: "../dotfiles/pi")
        try await apply(plan(brain, targets: ["pi"]))
        #expect(read("dotfiles/pi/AGENTS.md") == Self.block)
        // Spaces and newlines left by hand count as empty: the file AKit created still goes.
        try write("dotfiles/pi/AGENTS.md", " \n" + Self.block + "\r\n\t\n")
        let empty = plan(try await core(nil), targets: ["pi"])
        #expect(change(empty, ".pi/agent/AGENTS.md")?.blockAction == .trash)
        try await apply(empty)
        #expect(read("dotfiles/pi/AGENTS.md") == nil)
        #expect(try fm.destinationOfSymbolicLink(atPath: home.appending(path: ".pi/agent").path) == "../dotfiles/pi")
        #expect(fm.fileExists(atPath: home.appending(path: "dotfiles/pi").path))
    }

    @Test func anEditedBlockInAFilePiNoLongerReadsIsKept() async throws {
        let brain = try await core("Be brief.\n")
        try await apply(plan(brain, targets: ["pi"]))
        try write(".pi/agent/AGENTS.md", "<!-- akit:core:start -->\nMine.\n<!-- akit:core:end -->\n")
        try write(".pi/agent/AGENTS.override.md", "override\n")
        let moved = plan(brain, targets: ["pi"])
        let old = try #require(change(moved, ".pi/agent/AGENTS.md"))
        #expect(old.kind == .keepEdited && old.blockAction == nil && old.blockNote == "edited by hand · Pi no longer reads this file")
        try await apply(moved, accepting: [".pi/agent/AGENTS.md"])
        #expect(read(".pi/agent/AGENTS.md") == "<!-- akit:core:start -->\nMine.\n<!-- akit:core:end -->\n")
    }

    @Test func aSeparatorRecordedBeforeTheFileTurnedCRLFComesOutWhole() async throws {
        try write(".claude/CLAUDE.md", "A\n")
        try await apply(plan(try await core("Be brief.\n")))
        // The user converts the file to CRLF; the block then counts as edited and is taken again.
        try write(".claude/CLAUDE.md", read(".claude/CLAUDE.md")!.replacingOccurrences(of: "\n", with: "\r\n"))
        try await apply(plan(try await core("Be brief!\n")), accepting: [".claude/CLAUDE.md"])
        try await apply(plan(try await core(nil)))
        #expect(bytes(".claude/CLAUDE.md") == Data("A\r\n".utf8))
    }

    @Test func manyFencesThatNeverCloseAreReadInOnePass() {
        let padding = String(repeating: "x", count: 500)
        let text = String(repeating: "```\(padding)\n", count: 2_000) + Self.block
        let clock = ContinuousClock()
        var found = InstructionsBlock.Found.none
        let elapsed = clock.measure { found = InstructionsBlock.find(in: Array(text.utf8)) }
        if case .block = found {} else { Issue.record("the block after unclosed fences is not found: \(found)") }
        #expect(elapsed < .seconds(5), "\(elapsed)")
        // Four spaces before a marker make it an indented code line, not a marker.
        #expect(InstructionsBlock.find(in: Array("    <!-- akit:core:start -->\n".utf8)) == .none)
    }

    @Test func indentedMarkersCountAndOtherEncodingsAreSkipped() async throws {
        let brain = try await core("Be brief.\n")
        try write(".claude/CLAUDE.md", "A\n  <!-- akit:core:start -->\nold\n\t<!-- akit:core:end -->\nB\n")
        let indented = plan(brain)
        #expect(indented.canApply && change(indented)?.kind == .suggest)  // found, no record
        try await apply(indented, accepting: [".claude/CLAUDE.md"])
        #expect(read(".claude/CLAUDE.md") == "A\n" + Self.block + "B\n")

        // UTF-16 text (a BOM and NUL bytes): skipped with a warning, never written.
        let utf16 = Data([0xFF, 0xFE]) + "A\n".data(using: .utf16LittleEndian)!
        try utf16.write(to: home.appending(path: ".claude/CLAUDE.md"))
        let skipped = plan(brain)
        #expect(skipped.canApply && skipped.changes.isEmpty)
        #expect(skipped.render.warnings.contains { $0.hasPrefix(".claude/CLAUDE.md is not UTF-8 text") })
        try await apply(skipped)
        #expect(bytes(".claude/CLAUDE.md") == utf16)
    }

    @Test func permissionsAndExtendedAttributesSurviveTheWrite() async throws {
        try write(".claude/CLAUDE.md", Self.mine)
        let url = home.appending(path: ".claude/CLAUDE.md")
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let value = Array("kept".utf8)
        #expect(setxattr(url.path, "dev.akit.test", value, value.count, 0, 0) == 0)
        try await apply(plan(try await core("Be brief.\n")))
        #expect(read(".claude/CLAUDE.md") == Self.mine + "\n" + Self.block)
        #expect((try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) == 0o600)
        var back = [UInt8](repeating: 0, count: 16)
        let length = getxattr(url.path, "dev.akit.test", &back, back.count, 0, 0)
        #expect(length == value.count && Array(back.prefix(max(length, 0))) == value)
    }

    @Test func anErrorOnlyOneTargetsRenderHasStopsApply() async throws {
        // A section for every harness but Claude, whose template is missing: the render for all
        // targets together doesn't include it, Pi's own render does.
        _ = try await core("Be brief.\n")
        try write(".akit/registry/layers/core/layer.yaml",
                  "name: core\nfiles:\n  - template: AGENTS.md\n    to: AGENTS.md\n  - template: missing.md\n    to: AGENTS.md\n    when: target != claude\n")
        let brain = try #require(Brain.load(from: brainRoot))
        let plan = plan(brain, targets: ["claude", "pi"])
        #expect(!plan.canApply)
        #expect(plan.render.errors.contains { $0.contains("missing.md") }, "\(plan.render.errors)")
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
        // The files next to it that Pi doesn't read are named.
        #expect(plan(brain, targets: ["pi"]).render.warnings.contains(
            "Pi reads .pi/agent/AGENTS.override.md and gets AKit's block there; CLAUDE.md next to it is not read by Pi."))
    }

    @Test func piAgentDirIsHonouredAndRememberedForAnEnvironmentWithoutIt() async throws {
        let brain = try await core("Be brief.\n")
        let first = plan(brain, targets: ["pi"], pi: "~/custom/pi")
        #expect(first.changes.map(\.path) == ["custom/pi/AGENTS.md"])
        try await apply(first)
        #expect(read("custom/pi/AGENTS.md") == Self.block)
        #expect(!fm.fileExists(atPath: home.appending(path: ".pi").path))
        #expect(ProjectRecords.savedLock(id: id, in: store)?.piAgentDir == home.appending(path: "custom/pi").standardizedFileURL.path)
        // The app started from the Finder has no PI_CODING_AGENT_DIR: the recorded folder holds,
        // and the preview says where it comes from.
        let remembered = plan(brain, targets: ["pi"], remember: true)
        #expect(change(remembered, "custom/pi/AGENTS.md")?.kind == .same)
        #expect(remembered.render.warnings.contains { $0.hasPrefix("Pi's folder: \(home.appending(path: "custom/pi").standardizedFileURL.path) (remembered") })
        // A shell without it (akit on the command line) means Pi's default folder.
        let shell = plan(brain, targets: ["pi"])
        #expect(change(shell, ".pi/agent/AGENTS.md")?.kind == .create)
        #expect(change(shell, "custom/pi/AGENTS.md")?.kind == .suggest && change(shell, "custom/pi/AGENTS.md")?.blockAction == .trash)

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
        #expect(change(plan(brain, targets: ["pi"], remember: true), path)?.kind == .same)
        // A remembered folder that is gone: Pi's default again.
        try fm.removeItem(at: outside)
        #expect(change(plan(brain, targets: ["pi"], remember: true), ".pi/agent/AGENTS.md")?.kind == .create)

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
        #expect(preview.blocksTakenOut == [".claude/CLAUDE.md"])
        // Pi's file AKit created goes with its block.
        #expect(preview.removals == [".pi/agent/AGENTS.md"] && preview.blocksLeft.isEmpty)
        try await ProjectForget.run(preview, keepFiles: false, brain: brain, home: home, env: env, trash: trash)
        #expect(read(".claude/CLAUDE.md") == Self.mine)
        #expect(read(".pi/agent/AGENTS.md") == nil)
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
        #expect(plan.render.warnings.contains("The lock names Documents/notes.md as an instructions file AKit wrote; it is not one, so AKit forgets it and leaves the file alone."))
        try await apply(plan)
        #expect(read("Documents/notes.md") == "<!-- akit:core:start -->\nx\n<!-- akit:core:end -->\n")
        #expect(ProjectRecords.savedLock(id: id, in: store)?.blocks?["Documents/notes.md"] == nil)
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
