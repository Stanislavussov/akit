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
}
