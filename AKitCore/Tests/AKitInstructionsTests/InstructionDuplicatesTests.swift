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
}
