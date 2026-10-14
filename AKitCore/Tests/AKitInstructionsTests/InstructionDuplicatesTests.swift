import Foundation
import Testing
import AKitFoundation
import AKitModel
@testable import AKitInstructions

/// Duplicate sections among the files one harness loads for one session.
struct InstructionDuplicatesTests {
    let files: InstructionScannerTests

    init() throws { files = try InstructionScannerTests() }

    @Test func sameTextAcrossFilesInsideTheAKitBlockAndOnlyInLoadedFiles() throws {
        try files.write(".claude/CLAUDE.md", "# Mine\n\n## Commits\nImperative summary.\n\n<!-- akit:core:start -->\n## Tests\nRun them before done.\n<!-- akit:core:end -->\n")
        try files.write("Projects/app/CLAUDE.md", "## Commits  \n\nImperative summary.\n\n### Tests\nRun them before done.\n## Commits\nImperative summary.\n")
        // Not loaded by Claude Code here (a CLAUDE.md exists): never part of a group.
        try files.write("Projects/app/AGENTS.md", "## Commits\nImperative summary.\n")
        let groups = files.view(.claudeCode).duplicates
        // "### Tests" belongs to the first "## Commits" of the project file (D11), so that one
        // differs; the second has the same text as the global one.
        #expect(groups.map(\.kind) == [.same, .differs], "\(groups)")
        let same = try #require(groups.first)
        #expect(same.heading == "Commits" && same.places.map(\.section.line) == [3, 7])
        #expect(same.places.map(\.file.path) == [files.home.appending(path: ".claude/CLAUDE.md").path, files.project.appending(path: "CLAUDE.md").path])
        #expect(groups.last?.places.map(\.section.line) == [3, 1, 7])
        #expect(!groups.contains { $0.heading == "Tests" })
    }

    @Test func theCoreBlocksPartsCountAndKeepTheirLines() throws {
        try files.write(".claude/CLAUDE.md", "<!-- akit:core:start -->\n## Tests\nRun them before done.\n<!-- akit:core:end -->\n")
        try files.write("Projects/app/CLAUDE.md", "## Tests\nRun them before done.\n")
        let group = try #require(files.view(.claudeCode).duplicates.first)
        #expect(group.places.map(\.section.isAKitBlock) == [true, false])
        #expect(group.places.map(\.section.line) == [2, 1])
    }

    @Test func sameHeadingOtherTextDiffersAndAHeadingAloneIsNothing() throws {
        try files.write(".pi/agent/AGENTS.md", "## Style\nShort sentences.\n## Empty\n")
        try files.write("Projects/app/AGENTS.md", "## style\nLong sentences are fine.\n## Empty\n")
        let groups = files.view(.pi).duplicates
        #expect(groups.map(\.kind) == [.differs])
        #expect(groups.first?.places.map(\.section.heading) == ["Style", "style"])
    }

    // MARK: - Review round (2026-10-14)

    @Test func headingCaseAndLevelDontCountAndTheTitleComesFromAHeading() throws {
        try files.write(".pi/agent/AGENTS.md", "# Style\nShort.\n")
        try files.write("Projects/app/AGENTS.md", "## style\nShort.\n")
        let groups = files.view(.pi).duplicates
        #expect(groups.map(\.kind) == [.same] && groups.first?.heading == "style")
    }

    @Test func crlfAndTheCoreBlockMatchLfFiles() throws {
        try files.write(".claude/CLAUDE.md", "<!-- akit:core:start -->\r\n## Tests\r\nRun them.\r\n<!-- akit:core:end -->\r\n")
        try files.write("Projects/app/CLAUDE.md", "## Tests\nRun them.\n")
        #expect(files.view(.claudeCode).duplicates.map(\.kind) == [.same])
    }

    @Test func aMarkerQuotedInsideTheBlockStaysAndLinesKeepTheirPlace() {
        let text = "<!-- akit:core:start -->\n## Markers\n```\n<!-- akit:core:start -->\n```\n## Tests\nRun.\n<!-- akit:core:end -->\n"
        let units = InstructionText.units(text)
        #expect(units.map(\.heading) == ["Markers", "Tests"] && units.map(\.line) == [2, 6])
        #expect(units.first?.text.contains("<!-- akit:core:start -->") == true)
    }

    @Test func codexComparesOnlyWhatItReads() throws {
        try files.write(".codex/AGENTS.md", "## Tests\nRun.\n")
        try files.write("Projects/app/AGENTS.md", String(repeating: "x", count: 40_000) + "\n## Tests\nRun.\n")
        #expect(files.view(.codex).duplicates.isEmpty)
    }

    @Test func fencedHashLinesAreText() {
        let a = InstructionSection(heading: "Setup", text: "## Setup\n```sh\n# install\nnpm i\n```", isAKitBlock: false, line: 1)
        let b = InstructionSection(heading: "Setup", text: "## Setup\n```sh\ninstall\nnpm i\n```", isAKitBlock: false, line: 1)
        #expect(InstructionText.normalized(a) != InstructionText.normalized(b))
    }
}
