import Foundation
import Testing
import AKitFoundation
import AKitModel
@testable import AKitInstructions

/// The loading rules of each harness (docs/design/instructions.md, Facts) on a fake home:
/// `~/Projects/app` is a git repo, `~/Projects` holds a file above it.
struct InstructionScannerTests {
    let home: URL
    var env: HarnessEnvironment { HarnessEnvironment(homeDirectory: home) }
    var project: URL { home.appending(path: "Projects/app") }
    let none = URL(filePath: "/nonexistent/managed/CLAUDE.md")

    init() throws {
        home = FileManager.default.temporaryDirectory.appending(path: "akit-instructions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appending(path: "Projects/app/.git"), withIntermediateDirectories: true)
    }

    func write(_ path: String, _ text: String) throws {
        let url = home.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func view(_ harness: HarnessID, _ variables: [String: String] = [:]) -> InstructionView {
        InstructionScanner.view(harness: harness, project: project, env: HarnessEnvironment(homeDirectory: home, variables: variables),
                                top: home, managed: none)
    }

    /// `path → status` with paths relative to the home.
    func lines(_ view: InstructionView) -> [String] {
        view.entries.map { entry in
            let path = String(entry.file.path.dropFirst(home.path.count + 1))
            switch entry.status {
            case .loaded: return path
            case .imported(let by): return "\(path) <- \(by.lastPathComponent)"
            case .skipped: return "(\(path))"
            case .onDemand: return "\(path) (later)"
            }
        }
    }

    @Test func claudeJoinsEveryLevelAndSkipsAgentsWhenAClaudeFileExists() throws {
        try write(".claude/CLAUDE.md", "user\n")
        try write(".claude/rules/style.md", "rule\n")
        try write("Projects/CLAUDE.md", "above\n")
        try write("Projects/app/CLAUDE.md", "@AGENTS.md\n")
        try write("Projects/app/AGENTS.md", "## Build\nmake\n")
        try write("Projects/app/CLAUDE.local.md", "mine\n")
        try write("Projects/app/docs/AGENTS.md", "later\n")
        #expect(lines(view(.claudeCode)) == [
            ".claude/CLAUDE.md", ".claude/rules/style.md", "Projects/CLAUDE.md",
            "Projects/app/CLAUDE.md", "Projects/app/AGENTS.md <- CLAUDE.md", "Projects/app/CLAUDE.local.md",
        ])
    }

    @Test func claudeReadsAgentsOnlyWithoutAnyClaudeFileAndTheUserFileDoesNotCount() throws {
        try write(".claude/CLAUDE.md", "user\n")
        try write("Projects/app/AGENTS.md", "agents\n")
        #expect(lines(view(.claudeCode)) == [".claude/CLAUDE.md", "Projects/app/AGENTS.md"])
        try write("Projects/CLAUDE.md", "above\n")
        #expect(lines(view(.claudeCode)) == [".claude/CLAUDE.md", "Projects/CLAUDE.md", "(Projects/app/AGENTS.md)"])
        #expect(lines(view(.claudeCode, ["CLAUDE_CODE_DISABLE_CLAUDE_MDS": "1"])) == ["(.claude/CLAUDE.md)"])
    }

    @Test func piTakesOneFilePerFolderFromItsAgentFolderDown() throws {
        try write(".pi/agent/AGENTS.md", "global\n")
        try write("AGENTS.md", "home\n")
        try write("Projects/app/AGENTS.md", "agents\n")
        try write("Projects/app/CLAUDE.md", "claude\n")
        #expect(lines(view(.pi)) == [".pi/agent/AGENTS.md", "AGENTS.md", "Projects/app/AGENTS.md", "(Projects/app/CLAUDE.md)"])
        let skipped = try #require(view(.pi).entries.last)
        #expect(skipped.status == .skipped("Pi reads one file per folder: AGENTS.md comes first"))
    }

    @Test func codexStartsAtTheGitRootSkipsEmptyFilesAndCutsAt32KiB() throws {
        try write(".codex/AGENTS.override.md", "  \n")
        try write(".codex/AGENTS.md", "global\n")
        try write("Projects/AGENTS.md", "above the git root\n")
        try write("Projects/app/AGENTS.md", String(repeating: "x", count: 40_000))
        try write("Projects/app/CLAUDE.md", "claude\n")
        let view = view(.codex)
        #expect(lines(view) == ["(.codex/AGENTS.override.md)", ".codex/AGENTS.md", "Projects/app/AGENTS.md", "(Projects/app/CLAUDE.md)"])
        #expect(view.entries.first { $0.file.lastPathComponent == "AGENTS.md" && $0.level == .project }?.note?.hasPrefix("Codex reads only its first 32768 bytes") == true)
    }

    @Test func openCodeUsesOneNameForTheTreeClosestFirst() throws {
        try write(".config/opencode/AGENTS.md", "global\n")
        try write(".claude/CLAUDE.md", "claude user\n")
        // The repo root is the project: nothing above it counts. Add a nested folder as the project.
        try FileManager.default.createDirectory(at: project.appending(path: "web"), withIntermediateDirectories: true)
        try write("Projects/app/AGENTS.md", "root\n")
        try write("Projects/app/web/AGENTS.md", "web\n")
        try write("Projects/app/web/CLAUDE.md", "claude\n")
        let view = InstructionScanner.view(harness: .openCode, project: project.appending(path: "web"), env: env, top: home, managed: none)
        #expect(lines(view) == [".config/opencode/AGENTS.md", "(.claude/CLAUDE.md)", "Projects/app/web/AGENTS.md", "Projects/app/AGENTS.md", "(Projects/app/web/CLAUDE.md)"])
    }

    @Test func sectionsSplitAtLevelTwoHeadingsOutsideFencesAndKeepTheAKitBlockWhole() {
        let text = """
        # Title
        lead

        ## Build
        make
        ```sh
        ## not a heading
        ```
        <!-- akit:core:start -->
        ## Core
        rules
        <!-- akit:core:end -->
        ### Deep
        ## Test
        swift test

        """
        let sections = InstructionText.sections(text)
        // The text between AKit's block and the next ## heading is a piece of its own.
        #expect(sections.map(\.heading) == [nil, "Build", nil, nil, "Test"])
        #expect(sections.map(\.isAKitBlock) == [false, false, true, false, false])
        #expect(sections[1].text.contains("## not a heading") && sections[1].text.hasSuffix("```"))
        #expect(sections[2].text.hasSuffix("<!-- akit:core:end -->") && sections[3].text == "### Deep" && sections[4].line == 14)
        #expect(InstructionText.normalized(InstructionSection(heading: "Build", text: "### Build  \r\n\n\nmake\n", isAKitBlock: false, line: 1))
                == InstructionText.normalized(InstructionSection(heading: "Build", text: "## Build\nmake", isAKitBlock: false, line: 1)))
    }

    @Test func importsAreAtPathsOutsideCode() {
        let text = "See @AGENTS.md and @docs/rules.md.\nMention @someone here.\n`@not/this.md`\n```\n@nor/this.md\n```\n"
        // Every @word outside code; the scanner keeps the ones that exist (see the Claude test).
        #expect(InstructionText.imports(in: text) == ["AGENTS.md", "docs/rules.md", "someone"])
    }

    // MARK: - Review round (2026-10-14)

    @Test func piAndCodexFindALowercaseNameAndListOneSpelling() throws {
        try write("Projects/app/agents.md", "lower\n")
        // Pi probes AGENTS.md first; the disk is case-insensitive, so it opens agents.md.
        #expect(lines(view(.pi)).count == 1)
        #expect(view(.pi).loaded.first?.text == "lower\n")
        #expect(view(.codex).loaded.first?.text == "lower\n")
    }

    @Test func piReadsALinkedFileTwiceAndSkipsTheClaudeFileNextToIt() throws {
        try write("Projects/AGENTS.md", "shared\n")
        try FileManager.default.createSymbolicLink(atPath: project.appending(path: "AGENTS.md").path, withDestinationPath: "../AGENTS.md")
        try write("Projects/app/CLAUDE.md", "claude\n")
        #expect(lines(view(.pi)) == ["Projects/AGENTS.md", "Projects/app/AGENTS.md", "(Projects/app/CLAUDE.md)"])
        // OpenCode lists the real file once, and AGENTS.md still wins the name.
        #expect(lines(view(.openCode)) == ["Projects/app/AGENTS.md", "(Projects/app/CLAUDE.md)"])
    }

    @Test func piSkipsTheMainCheckoutsFileInANestedWorktree() throws {
        try write("Projects/app/.git/HEAD", "ref: refs/heads/main\n")
        try write("Projects/app/.git/worktrees/x/HEAD", "ref: refs/heads/x\n")
        try write("Projects/app/.git/worktrees/x/commondir", "../..\n")
        let tree = project.appending(path: ".claude/worktrees/x")
        try write("Projects/app/.claude/worktrees/x/.git", "gitdir: \(project.appending(path: ".git/worktrees/x").path)\n")
        try write("Projects/app/AGENTS.md", "main\n")
        try write("Projects/app/.claude/worktrees/x/AGENTS.md", "worktree\n")
        let view = InstructionScanner.view(harness: .pi, project: tree, env: env, top: home, managed: none)
        #expect(lines(view) == ["(Projects/app/AGENTS.md)", "Projects/app/.claude/worktrees/x/AGENTS.md"])
        // A plain repo: nothing is shadowed.
        try FileManager.default.removeItem(at: tree)
        #expect(lines(self.view(.pi)) == ["Projects/app/AGENTS.md"])
    }

    @Test func claudeImportsAnyExistingPathAndRulesWithPathsLoadLater() throws {
        try write("Projects/app/CLAUDE.md", "See @README for the overview and @package.json, ask @someone.\n")
        try write("Projects/app/README", "readme\n")
        try write("Projects/app/package.json", "{}\n")
        try write("Projects/app/.claude/rules/ts.md", "---\npaths:\n  - \"src/**/*.ts\"\n---\nTS only\n")
        try write("Projects/app/.claude/rules/all.md", "always\n")
        let view = view(.claudeCode)
        #expect(lines(view) == ["Projects/app/CLAUDE.md", "Projects/app/README <- CLAUDE.md", "Projects/app/package.json <- CLAUDE.md",
                                "Projects/app/.claude/rules/all.md", "Projects/app/.claude/rules/ts.md (later)"])
        #expect(view.entries.last?.status == .onDemand("Claude Code loads this rule only when a file matching its paths: is in play"))
        #expect(view.loadedBytes == view.loaded.reduce(0) { $0 + $1.bytes } && !view.loaded.contains { $0.file.lastPathComponent == "ts.md" })
    }

    @Test func aLinkToTheUserFileAboveCountsAsAClaudeFile() throws {
        try write(".claude/CLAUDE.md", "user\n")
        try FileManager.default.createSymbolicLink(atPath: home.appending(path: "CLAUDE.md").path, withDestinationPath: ".claude/CLAUDE.md")
        try write("Projects/app/AGENTS.md", "agents\n")
        #expect(lines(view(.claudeCode)).last == "(Projects/app/AGENTS.md)")
    }

    @Test func codexCountsOnlyTheReadPartAndSkipsFilesOverTheBudget() throws {
        try write("Projects/app/AGENTS.md", String(repeating: "x", count: 40_000))
        try FileManager.default.createDirectory(at: project.appending(path: "web"), withIntermediateDirectories: true)
        try write("Projects/app/web/AGENTS.md", "web\n")
        let view = InstructionScanner.view(harness: .codex, project: project.appending(path: "web"), env: env, top: home, managed: none)
        #expect(lines(view) == ["Projects/app/AGENTS.md", "(Projects/app/web/AGENTS.md)"])
        #expect(view.loadedBytes == 32 * 1024)
    }

    @Test func openCodeWithoutAGitRootWalksToTheTop() throws {
        try FileManager.default.removeItem(at: project.appending(path: ".git"))
        try write("AGENTS.md", "home\n")
        try write("Projects/app/AGENTS.md", "app\n")
        #expect(lines(view(.openCode)) == ["Projects/app/AGENTS.md", "AGENTS.md"])
    }

    @Test func aDeepPathIsWalkedToTheTop() {
        let deep = URL(filePath: "/" + (1...80).map { "d\($0)" }.joined(separator: "/"))
        let chain = InstructionScanner.chain(from: deep, top: nil)
        #expect(chain.count == 81 && chain.first?.path == "/" && chain.last?.path == deep.path)
    }

    @Test func titlesFencesAndHashLines() {
        #expect(InstructionText.sections("# Project rules\n\n## Build\nmake\n").map(\.heading) == ["Build"])
        // A longer fence holds a shorter one; an inline ```x``` is not a fence.
        let text = "````md\n```sh\n## inside\n```\n````\n```x``` inline\n## After\nyes\n"
        #expect(InstructionText.sections(text).map(\.heading) == [nil, "After"])
        #expect(InstructionText.imports(in: "```x``` see @AGENTS.md\n") == ["AGENTS.md"])
        let a = InstructionSection(heading: nil, text: "#include <a.h>\n## Build", isAKitBlock: false, line: 1)
        let b = InstructionSection(heading: nil, text: "include <a.h>\n## Build", isAKitBlock: false, line: 1)
        #expect(InstructionText.normalized(a) != InstructionText.normalized(b))
        #expect(InstructionText.frontMatterKeys("---\nname: x\npaths:\n  - a\n---\nbody") == ["name", "paths"])
        #expect(InstructionText.frontMatterKeys("---\npaths: a\n").isEmpty)
    }

    @Test func crlfFilesSplitIntoSectionsAndImports() throws {
        let text = "# T\r\n\r\n## Build\r\nmake\r\n## Test\r\nsee @docs/test.md\r\n"
        let sections = InstructionText.sections(text)
        #expect(sections.map(\.heading) == ["Build", "Test"] && sections.map(\.line) == [3, 5])
        #expect(InstructionText.imports(in: text) == ["docs/test.md"])
        #expect(InstructionText.lines(text).joined(separator: "\n") == text)
        #expect(InstructionText.frontMatterKeys("---\r\npaths: a\r\n---\r\nbody") == ["paths"])
    }
}
