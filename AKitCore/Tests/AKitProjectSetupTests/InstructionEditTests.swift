import Foundation
import Testing
import AKitFoundation
import AKitInstructions
@testable import AKitProjectSetup

/// Remove This Copy…: one ## section leaves one instruction file, with a diff and a backup.
struct InstructionEditTests {
    let home: URL
    var env: HarnessEnvironment { HarnessEnvironment(homeDirectory: home) }

    init() throws {
        home = FileManager.default.temporaryDirectory.appending(path: "akit-instruction-edit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    func file(_ name: String, _ text: String) throws -> URL {
        let url = home.appending(path: name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    func section(_ heading: String, in url: URL) throws -> InstructionSection {
        try #require(InstructionText.units(String(decoding: try Data(contentsOf: url), as: UTF8.self)).first { $0.heading == heading })
    }

    @Test(arguments: [
        // The middle, the last and the first section; CRLF lines.
        ("# T\n\n## A\na\n\n## B\nb\n\n## C\nc\n", "B", "# T\n\n## A\na\n\n## C\nc\n"),
        ("# T\n\n## A\na\n\n## B\nb\n", "B", "# T\n\n## A\na\n"),
        ("## A\na\n\n## B\nb\n", "A", "## B\nb\n"),
        ("## A\r\na\r\n\r\n## B\r\nb\r\n", "A", "## B\r\nb\r\n"),
        ("# T\n\n## A\na", "A", "# T\n"),
        // Review round: trailing blank lines of the next section stay; a CRLF file without a final newline.
        ("## A\na\n\n## B\nb\n\n\n", "A", "## B\nb\n\n\n"),
        ("## A\r\na\r\n\r\n## B\r\nb", "B", "## A\r\na\r\n"),
    ])
    func removesTheLinesAndKeepsEveryOtherByte(text: String, heading: String, expected: String) throws {
        // A folder per case: the cases run at the same time.
        let url = try file("\(UUID().uuidString)/AGENTS.md", text)
        let plan = try InstructionEdit.removing(try section(heading, in: url), from: url, rendered: [], env: env)
        let backup = try InstructionEdit.apply(plan, env: env)
        #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self) == expected)
        #expect(backup.map { String(decoding: (try? Data(contentsOf: $0)) ?? Data(), as: UTF8.self) } == text)
    }

    @Test func refusesTheAKitBlockARenderedFileAndAChangedFile() throws {
        let url = try file("CLAUDE.md", "## A\na\n<!-- akit:core:start -->\n## Core\nc\n<!-- akit:core:end -->\n")
        #expect(throws: InstructionEdit.Failure.self) { try InstructionEdit.removing(try section("Core", in: url), from: url, rendered: [], env: env) }
        #expect(InstructionEdit.unavailable(try section("A", in: url), in: url, rendered: [InstructionEdit.realPath(url)])?
            .hasPrefix("AKit renders this file") == true)

        let plan = try InstructionEdit.removing(try section("A", in: url), from: url, rendered: [], env: env)
        try Data("## A\nchanged\n".utf8).write(to: url)
        #expect(throws: InstructionEdit.Failure.self) { try InstructionEdit.apply(plan, env: env) }
        #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self) == "## A\nchanged\n")
        // A section that moved since the screen read it: refused at the plan.
        let stale = InstructionSection(heading: "A", text: "## A\na\n", isAKitBlock: false, line: 3)
        #expect(throws: InstructionEdit.Failure.self) { try InstructionEdit.removing(stale, from: url, rendered: [], env: env) }
    }

    @Test func notesAGitTrackedFileAndAnEmptyResult() async throws {
        let repo = home.appending(path: "repo")
        let url = try file("repo/AGENTS.md", "## Only\nrule\n")
        for arguments in [["init", "-q"], ["add", "AGENTS.md"]] {
            _ = ProcessRunner.runAndWait(URL(filePath: "/usr/bin/git"), arguments: ["-C", repo.path] + arguments, environment: env.gitVariables, timeout: 15)
        }
        let plan = try InstructionEdit.removing(try section("Only", in: url), from: url, rendered: [], env: env)
        #expect(plan.notes.count == 2, "\(plan.notes)")
        #expect(plan.notes.first?.hasPrefix("git tracks AGENTS.md") == true)
        try InstructionEdit.apply(plan, env: env)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Review round (2026-10-14)

    @Test func aFileReadTwiceThroughALinkIsRefused() throws {
        let real = try file("w/AGENTS.md", "## Commits\nShort lines.\n\n## Style\nTabs.\n")
        let link = home.appending(path: "w/p/AGENTS.md")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../AGENTS.md")
        #expect { try InstructionEdit.removing(try section("Commits", in: link), from: link, others: [real], rendered: [], env: env) } throws: { error in
            (error as? InstructionEdit.Failure)?.message.contains("are one file (a link), read twice") == true
        }
        // A hard link is one file too.
        let hard = home.appending(path: "w/hard.md")
        try FileManager.default.linkItem(at: real, to: hard)
        let other = try file("w/other.md", "x")
        #expect(InstructionEdit.isSameFile(hard, real) && !InstructionEdit.isSameFile(hard, other))
    }

    @Test func aSectionThatGrewSinceTheScreenIsRefused() throws {
        let url = try file("AGENTS.md", "## A\na\n## B\nb\n")
        let old = try section("A", in: url)
        try Data("## A\na\nNEW RULE\n## B\nb\n".utf8).write(to: url)
        #expect { try InstructionEdit.removing(old, from: url, rendered: [], env: env) } throws: { error in
            (error as? InstructionEdit.Failure)?.message.contains("changed since the screen read it") == true
        }
    }

    @Test func anOpenFenceAndATitledLeadAreLeftToTheUser() throws {
        let fenced = try file("fenced/AGENTS.md", "## A\n```sh\nmake\n\n## B\nb\n")
        #expect { try InstructionEdit.removing(try section("A", in: fenced), from: fenced, rendered: [], env: env) } throws: { error in
            (error as? InstructionEdit.Failure)?.message.contains("never closes") == true
        }
        let titled = try file("titled/AGENTS.md", "# Title\n\nIntro text.\n\n## A\na\n")
        let lead = try #require(InstructionText.units(String(decoding: try Data(contentsOf: titled), as: UTF8.self)).first)
        #expect(lead.heading == nil)
        #expect { try InstructionEdit.removing(lead, from: titled, rendered: [], env: env) } throws: { error in
            (error as? InstructionEdit.Failure)?.message.contains("holds its header or title") == true
        }
    }

    // MARK: - Edit… (whole text)

    func bytes(_ url: URL) -> Data? { try? Data(contentsOf: url) }

    @Test func aWholeNewTextIsADiffAndTheCoreBlockMustStay() throws {
        let url = try file("edit/CLAUDE.md", "## A\na\n<!-- akit:core:start -->\n## Core\nc\n<!-- akit:core:end -->\n")
        let plan = try InstructionEdit.editing(url, original: bytes(url), to: "## A\nbetter a\n<!-- akit:core:start -->\n## Core\nc\n<!-- akit:core:end -->\n",
                                               rendered: [], env: env)
        #expect(plan.diff.contains(.added("better a")))
        try InstructionEdit.apply(plan, env: env)
        #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("better a"))
        #expect { try InstructionEdit.editing(url, original: bytes(url), to: "## A\nbetter a\n<!-- akit:core:start -->\n## Core\nchanged\n<!-- akit:core:end -->\n",
                                              rendered: [], env: env) } throws: { error in
            (error as? InstructionEdit.Failure)?.message.contains("changes AKit's core block") == true
        }
        // A marker indented 4 spaces is no longer found by Update Home Folder: refused too.
        #expect(throws: InstructionEdit.Failure.self) {
            try InstructionEdit.editing(url, original: bytes(url), to: "## A\nbetter a\n    <!-- akit:core:start -->\n## Core\nc\n<!-- akit:core:end -->\n",
                                        rendered: [], env: env)
        }
        #expect(throws: InstructionEdit.Failure.self) { try InstructionEdit.editing(url, original: bytes(url), to: "x", rendered: [InstructionEdit.realPath(url)], env: env) }
    }

    @Test func aChangeMadeMeanwhileIsNeverUndone() throws {
        let url = try file("meanwhile/CLAUDE.md", "## A\nold\n")
        let original = bytes(url)
        try Data("## A\nold\n## B\nuser added meanwhile\n".utf8).write(to: url)
        #expect { try InstructionEdit.editing(url, original: original, to: "## A\nnew\n", rendered: [], env: env) } throws: { error in
            (error as? InstructionEdit.Failure)?.message.contains("changed since its text was read") == true
        }
        #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("user added meanwhile"))
    }

    @Test func aBlockBehindAnOpenFenceCantBeEdited() throws {
        let url = try file("fence/CLAUDE.md", "## Notes\n```bash\nmake\n\n<!-- akit:core:start -->\n## Core\nRun.\n<!-- akit:core:end -->\n")
        #expect(throws: InstructionEdit.Failure.self) {
            try InstructionEdit.editing(url, original: bytes(url), to: "## Notes\n```bash\nmake\n\n<!-- akit:core:start -->\n## Core\nSkip.\n<!-- akit:core:end -->\n",
                                        rendered: [], env: env)
        }
    }
}
