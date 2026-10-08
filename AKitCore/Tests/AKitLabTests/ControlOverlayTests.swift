import Foundation
import Testing
import AKitFoundation
@testable import AKitLab

/// A layer's overlay in a clone: the placement rules, applying and hiding, the stored form.
struct ControlOverlayTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-overlay-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var env: HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home, variables: [
            "HOME": home.path, "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "T", "GIT_AUTHOR_EMAIL": "t@example.com",
            "GIT_COMMITTER_NAME": "T", "GIT_COMMITTER_EMAIL": "t@example.com",
        ], executableSearchPaths: [URL(filePath: "/usr/bin"), URL(filePath: "/bin")])
    }

    func git(_ args: String..., in folder: URL) async -> String? { await LabGit.output(args, in: folder, env: env) }

    func write(_ path: String, _ text: String, in folder: URL) throws {
        let url = folder.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func read(_ path: String, in folder: URL) -> String? { try? String(contentsOf: folder.appending(path: path), encoding: .utf8) }

    /// The overlay of a layer with a section, a skill and the Claude link.
    var overlay: ControlOverlay {
        var overlay = ControlOverlay(layer: "swiftui", role: "layer", layers: ["swiftui"])
        overlay.add("AGENTS.md", kind: .agentsSection, data: Data("## SwiftUI\n- LAYER-MARKER\n".utf8))
        overlay.add(".agents/skills/swiftui-expert/SKILL.md", kind: .skillFile, skill: "swiftui-expert", data: Data("---\nname: x\n---\n".utf8))
        overlay.add(".agents/skills/swiftui-expert/refs.json", kind: .skillFile, skill: "swiftui-expert", data: Data("{}".utf8))
        overlay.addLink(".claude/skills", to: "../.agents/skills")
        return overlay
    }

    func files(_ files: [String], links: [String: String] = [:], texts: [String: String] = [:]) -> CloneFiles {
        CloneFiles(files: files, links: links) { texts[$0] }
    }

    func writes(_ placement: ControlOverlay.Placement) -> [String: ControlOverlay.Write.Action] {
        guard case .writes(let writes, _) = placement else { return [:] }
        return Dictionary(writes.map { ($0.path, $0.action) }, uniquingKeysWith: { first, _ in first })
    }

    func notes(_ placement: ControlOverlay.Placement) -> [String] {
        if case .writes(_, let notes) = placement { notes } else { [] }
    }

    func blocked(_ placement: ControlOverlay.Placement) -> String? {
        if case .blocked(let reason) = placement { reason } else { nil }
    }

    @Test func sectionGoesToTheFileClaudeReads() {
        // Nothing to read: a new CLAUDE.md holds the section; the skill and the link are written.
        let empty = ControlOverlay.place(overlay, in: files(["Sources/a.swift"]))
        #expect(writes(empty) == ["CLAUDE.md": .create, ".agents/skills/swiftui-expert/SKILL.md": .create,
                                  ".agents/skills/swiftui-expert/refs.json": .create, ".claude/skills": .link("../.agents/skills")])
        #expect(notes(empty).isEmpty)

        // The project's own CLAUDE.md: appended to, with a note; its AGENTS.md stays unread.
        let own = ControlOverlay.place(overlay, in: files(["CLAUDE.md", "AGENTS.md"], texts: ["CLAUDE.md": "# Rules\n"]))
        #expect(writes(own)["CLAUDE.md"] == .append && writes(own)["AGENTS.md"] == nil)
        #expect(notes(own).contains { $0.contains("project's own CLAUDE.md") })

        // Root CLAUDE.md imports AGENTS.md: the section goes to AGENTS.md (written when absent).
        let imported = ControlOverlay.place(overlay, in: files(["CLAUDE.md"], texts: ["CLAUDE.md": "Read @AGENTS.md first.\n"]))
        #expect(writes(imported)["AGENTS.md"] == .create && writes(imported)["CLAUDE.md"] == nil)
        let importedExisting = ControlOverlay.place(overlay, in: files(["CLAUDE.md", "AGENTS.md"], texts: ["CLAUDE.md": "@./AGENTS.md\n"]))
        #expect(writes(importedExisting)["AGENTS.md"] == .append)

        // In .claude/CLAUDE.md, @AGENTS.md means .claude/AGENTS.md, not the root file.
        let nested = ControlOverlay.place(overlay, in: files([".claude/CLAUDE.md", "AGENTS.md"], texts: [".claude/CLAUDE.md": "@AGENTS.md\n"]))
        #expect(writes(nested)[".claude/CLAUDE.md"] == .append && writes(nested)["AGENTS.md"] == nil)
        let up = ControlOverlay.place(overlay, in: files([".claude/CLAUDE.md", "AGENTS.md"], texts: [".claude/CLAUDE.md": "See @../AGENTS.md\n"]))
        #expect(writes(up)["AGENTS.md"] == .append && writes(up)[".claude/CLAUDE.md"] == nil)

        // CLAUDE.md is a link to AGENTS.md: append to AGENTS.md.
        let linked = ControlOverlay.place(overlay, in: files(["AGENTS.md"], links: ["CLAUDE.md": "AGENTS.md"]))
        #expect(writes(linked)["AGENTS.md"] == .append && writes(linked).count == 4)

        // An e-mail address is not an import.
        let mail = ControlOverlay.place(overlay, in: files(["CLAUDE.md", "AGENTS.md"], texts: ["CLAUDE.md": "Ask me@AGENTS.md\n"]))
        #expect(writes(mail)["CLAUDE.md"] == .append)
    }

    @Test func lettersCaseIsIgnored() {
        let lower = ControlOverlay.place(overlay, in: files(["claude.md"], texts: ["claude.md": "# Rules\n"]))
        #expect(writes(lower)["claude.md"] == .append && writes(lower)["CLAUDE.md"] == nil)
        var markdown = ControlOverlay()
        markdown.add("Docs/Guide.md", kind: .markdown, data: Data("x".utf8))
        #expect(writes(ControlOverlay.place(markdown, in: files(["docs/guide.md"])))["docs/guide.md"] == .append)
        #expect(writes(ControlOverlay.place(markdown, in: files(["docs/other.md"])))["docs/Guide.md"] == .create)
    }

    @Test func projectSkillsWinAndProjectFilesBlock() throws {
        // The project's own skill of the same name: skipped, once, with a note.
        let own = ControlOverlay.place(overlay, in: files([".agents/skills/swiftui-expert/SKILL.md"]))
        #expect(!writes(own).keys.contains { $0.hasPrefix(".agents/skills/swiftui-expert/") } && writes(own)[".claude/skills"] != nil)
        #expect(notes(own) == ["The project has its own skill swiftui-expert; the layer's copy is skipped."])
        // Also when the project's .claude/skills links to its .agents/skills.
        let linked = ControlOverlay.place(overlay, in: files([".agents/skills/swiftui-expert/SKILL.md"], links: [".claude/skills": "../.agents/skills"]))
        #expect(notes(linked).count == 1 && writes(linked)["CLAUDE.md"] == .create && writes(linked).count == 1)
        // A non-empty .claude/skills folder blocks (as Apply).
        let folder = try #require(blocked(ControlOverlay.place(overlay, in: files([".claude/skills/other/SKILL.md"]))))
        #expect(folder.contains("own .claude/skills folder"))
        // A link already pointing at .agents/skills is fine; another one blocks.
        let same = ControlOverlay.place(overlay, in: files(["x"], links: [".claude/skills": "../.agents/skills"]))
        #expect(blocked(same) == nil && writes(same)[".claude/skills"] == nil)
        #expect(blocked(ControlOverlay.place(overlay, in: files(["x"], links: [".claude/skills": "../skills"]))) != nil)

        // Another file the project has blocks.
        var file = ControlOverlay()
        file.add("tsconfig.json", kind: .file, data: Data("{}".utf8))
        #expect(blocked(ControlOverlay.place(file, in: files(["tsconfig.json"])))?.contains("already in the project") == true)
        #expect(writes(ControlOverlay.place(file, in: files(["x"]))) == ["tsconfig.json": .create])
    }

    @Test func linksAreFollowedOnlyInsideTheClone() {
        var markdown = ControlOverlay()
        markdown.add("docs/RULES.md", kind: .markdown, data: Data("x".utf8))
        // A link inside: its target is appended to.
        let inside = ControlOverlay.place(markdown, in: files(["shared/rules.md"], links: ["docs/RULES.md": "../shared/rules.md"]))
        #expect(writes(inside) == ["shared/rules.md": .append])
        // A folder link inside: followed too.
        let folder = ControlOverlay.place(markdown, in: files(["real/RULES.md"], links: ["docs": "real"]))
        #expect(writes(folder) == ["real/RULES.md": .append])
        // Out of the clone, absolute, or into .git: blocked.
        for target in ["../../outside.md", "/etc/rules.md", "../.git/config"] {
            #expect(blocked(ControlOverlay.place(markdown, in: files(["x"], links: ["docs/RULES.md": target]))) != nil, "\(target)")
        }
        #expect(blocked(ControlOverlay.place(overlay, in: files(["x"], links: ["CLAUDE.md": "/Users/me/CLAUDE.md"]))) != nil)
        // An overlay path itself must stay inside.
        var bad = ControlOverlay()
        bad.add("../x.md", kind: .markdown, data: Data())
        #expect(blocked(ControlOverlay.place(bad, in: files(["x"]))) != nil)
    }

    @Test func applyHidesEverythingAndTreeAndFolderAgree() async throws {
        let repo = home.appending(path: "repo")
        try write("CLAUDE.md", "# Rules\n", in: repo)
        try write("shared/notes.md", "notes\n", in: repo)
        try write("Sources/a.swift", "let a = 1\n", in: repo)
        try fm.createDirectory(at: repo.appending(path: "docs"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: repo.appending(path: "docs/NOTES.md").path, withDestinationPath: "../shared/notes.md")
        _ = await git("init", "-q", "-b", "master", in: repo)
        _ = await git("add", "-A", in: repo)
        _ = await git("commit", "-q", "-m", "Start", in: repo)
        let base = try #require(await git("rev-parse", "HEAD", in: repo))

        var layered = overlay
        layered.add("docs/NOTES.md", kind: .markdown, data: Data("- more notes\n".utf8))
        let work = home.appending(path: "work")
        try await IsolatedClone.make(at: work, from: repo, commit: base, env: env)
        let fromTree = try await CloneFiles.fromTree(repo: repo, base: base, env: env)
        let fromFolder = CloneFiles.fromFolder(work)
        let placement = ControlOverlay.place(layered, in: fromFolder)
        #expect(ControlOverlay.place(layered, in: fromTree) == placement)
        guard case .writes(let writes, _) = placement else {
            Issue.record("blocked: \(placement)")
            return
        }
        try await ControlOverlay.apply(writes, in: work, env: env)

        #expect(read("CLAUDE.md", in: work) == "# Rules\n\n## SwiftUI\n- LAYER-MARKER\n")
        #expect(read("shared/notes.md", in: work) == "notes\n\n- more notes\n")
        #expect(read(".claude/skills/swiftui-expert/SKILL.md", in: work)?.hasPrefix("---") == true)
        #expect(try fm.destinationOfSymbolicLink(atPath: work.appending(path: ".claude/skills").path) == "../.agents/skills")
        // The agent sees a clean checkout.
        #expect(await git("status", "--porcelain", in: work) == "")
        #expect(await git("diff", in: work) == "")
        // Tracked files are assume-unchanged ("h"), new ones are in info/exclude.
        let flags = await git("ls-files", "-v", "CLAUDE.md", "shared/notes.md", in: work)
        #expect(flags == "h CLAUDE.md\nh shared/notes.md")
        let exclude = read(".git/info/exclude", in: work) ?? ""
        #expect(exclude.contains("/.claude/skills\n") && exclude.contains("/.agents/skills/swiftui-expert/SKILL.md\n"))
        // The user's repository is untouched.
        #expect(read("CLAUDE.md", in: repo) == "# Rules\n")
        #expect(await git("status", "--porcelain", in: repo) == "")
    }

    @Test func storedOverlayRoundTripsAndRefusesChangedBytes() throws {
        let folder = home.appending(path: "overlays/x")
        let original = overlay
        try original.save(to: folder)
        let loaded = try ControlOverlay.load(from: folder)
        #expect(loaded == original && loaded.hash == original.hash)
        #expect(read("files/AGENTS.md", in: folder) == "## SwiftUI\n- LAYER-MARKER\n")
        // The JSON holds no bytes.
        #expect(read("overlay.json", in: folder)?.contains("LAYER-MARKER") == false)

        // Same content, other metadata: same hash. Other bytes: another hash.
        var renamed = original
        renamed.role = "requiredOnly"
        #expect(renamed.hash == original.hash)
        var changed = original
        changed.add("AGENTS.md", kind: .agentsSection, data: Data("## SwiftUI\n- other\n".utf8))
        #expect(changed.hash != original.hash)

        try write("files/AGENTS.md", "## SwiftUI\n- LAYER-MARKEX\n", in: folder)
        #expect(throws: ControlOverlay.Failure.self) { try ControlOverlay.load(from: folder) }

        // A newer AKit's overlay is refused with the install advice.
        try write("overlay.json", #"{"schema":2,"rulesVersion":1,"layers":[],"entries":[]}"#, in: folder)
        #expect { try ControlOverlay.load(from: folder) } throws: { ($0 as? ControlOverlay.Failure)?.message.contains("newer AKit") == true }
    }

    @Test func layerSetupLabelsAndOldRunFiles() throws {
        let agent = LabAgent(harness: .claudeCode, model: "opus", effort: "high")
        let variant = LayerVariant(layer: "swiftui", role: .layer, overlayHash: "h", evalID: "swiftui-20261012-0930-ab12",
                                   brainCommit: "a1b2c3d4e5")
        #expect(ControlSetup(name: "layer swiftui", agent: agent, layer: variant).label == "layer swiftui@a1b2c3d · Claude Code · opus · high")
        var baseline = variant
        baseline.role = .requiredOnly
        #expect(ControlSetup(name: "read-only", agent: agent, readOnly: true, layer: baseline).label
                == "read-only · without swiftui@a1b2c3d · Claude Code · opus · high")
        // Setups and outcomes written before layer evals decode, with no layer.
        let old = try LabStore.decoder.decode(ControlSetup.self, from: Data(
            #"{"name":"baseline","agent":{"harness":"claude-code","model":"opus","effort":"high"},"readOnly":false}"#.utf8))
        #expect(old.layer == nil)
        let outcome = try LabStore.decoder.decode(ControlOutcome.self, from: Data(
            #"{"key":"k","passed":true,"oracle":"x","testsDropped":false,"changedTestFiles":[],"leaks":[],"checkSteps":[]}"#.utf8))
        #expect(outcome.overlay == nil && outcome.harnessVersion == nil)
    }
}
