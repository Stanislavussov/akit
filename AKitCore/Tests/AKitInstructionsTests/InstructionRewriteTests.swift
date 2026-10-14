import Foundation
import Testing
@testable import AKitInstructions

/// Rewrite with Skill…: what is sent, and what an answer may change.
struct InstructionRewriteTests {
    let file = "# Rules\r\n\r\n## Commits\r\nWrite short lines please.\r\n\r\n<!-- akit:core:start -->\r\n## Core\r\nRun the tests.\r\n<!-- akit:core:end -->\r\n"

    @Test func theCoreBlockNeverGoesOutAndComesBackInPlace() throws {
        let prepared = InstructionRewrite.prepare(file: file, skillName: "writing", skill: "Be brief.", request: "")
        #expect(!prepared.input.contains("Run the tests.") && prepared.input.contains(InstructionRewrite.marker))
        #expect(prepared.system.contains("# Skill: writing") && prepared.system.contains("Be brief."))
        #expect(prepared.input.hasPrefix("Request: Make it clearer and shorter"))
        let answer = ##"Here: {"text": "# Rules\n\n## Commits\nShort lines.\n\n\##(InstructionRewrite.marker)\n"}"##
        let result = try InstructionRewrite.result(answer, prepared: prepared)
        #expect(result == "# Rules\r\n\r\n## Commits\r\nShort lines.\r\n\r\n<!-- akit:core:start -->\r\n## Core\r\nRun the tests.\r\n<!-- akit:core:end -->\r\n")
    }

    @Test func anAnswerThatLosesTheBlockOrIsNoJSONIsRefused() {
        let prepared = InstructionRewrite.prepare(file: file, skillName: "w", skill: "", request: "x")
        #expect(throws: InstructionRewrite.Failure.self) { try InstructionRewrite.result(###"{"text": "## Commits\nShort.\n"}"###, prepared: prepared) }
        #expect(throws: InstructionRewrite.Failure.self) { try InstructionRewrite.result("Sure, here is the file.", prepared: prepared) }
    }
}
