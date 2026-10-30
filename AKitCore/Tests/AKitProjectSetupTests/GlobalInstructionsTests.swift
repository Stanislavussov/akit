import Foundation
import Testing
import AKitBrain
import AKitFoundation
import AKitInstructions
@testable import AKitProjectSetup

/// Global Instructions in Brain: the core text, its blocks in the global files, Edit….
struct GlobalInstructionsTests {
    let move: SkillMoveTests
    var f: GitProjectFixture { move.f }

    init() throws { move = try SkillMoveTests() }

    let omc = """
        <!-- OMC:START -->
        <!-- OMC:VERSION:5.7.4 -->
        # oh-my-claudecode

        ## Setup
        Say "setup omc".
        <!-- OMC:END -->

        <!-- User customizations -->

        ## Answer style
        Short sentences.

        """

    @Test func anotherToolsBlockIsManagedElsewhereAndTheRestIsOwnText() {
        let blocks = GlobalInstructions.managedBlocks(in: omc)
        #expect(blocks.map(\.name) == ["OMC"] && blocks.first?.lines == 1...7)
        let own = GlobalInstructions.ownSections(of: omc, managed: blocks)
        #expect(own.map(\.heading) == ["Answer style"])
        #expect(own.first?.text.hasPrefix("## Answer style\nShort sentences.") == true)
    }

    @Test func textAfterABlockEndInsideASectionIsOwnText() {
        let text = "<!-- X:START -->\n## Setup\nmanaged\n<!-- X:END -->\nmine\n"
        let own = GlobalInstructions.ownSections(of: text, managed: GlobalInstructions.managedBlocks(in: text))
        #expect(own.map(\.text) == ["mine\n"] && own.first?.line == 5)
    }

    @Test func markersInACodeFenceAndAKitsOwnAreNoManagedBlock() {
        let text = "```\n<!-- X:START -->\n<!-- X:END -->\n```\n\(InstructionText.akitStart)\n## A\n\(InstructionText.akitEnd)\n"
        #expect(GlobalInstructions.managedBlocks(in: text).isEmpty)
    }

    @Test func statusListsEachGlobalFileWithItsBlockState() async throws {
        try move.harnesses()
        try f.write(".claude/CLAUDE.md", omc)
        let brain = try await f.setUpBrain()
        var status = GlobalInstructions.status(context: move.context(), brain: brain)
        #expect(status.hasCore && status.text.isEmpty)
        let claude = try #require(status.copies.first { $0.path == "~/.claude/CLAUDE.md" })
        #expect(claude.harnesses.contains(.claudeCode) && claude.managed.map(\.name) == ["OMC"])
        #expect(claude.own.map(\.heading) == ["Answer style"])
        #expect(claude.state == .current || { if case .noBlock = claude.state { true } else { false } }())

        // Edit…: core gets text; both global files are outdated until the blocks are written.
        let plan = try GlobalInstructions.editing(to: "## Commits\nShort lines.\n", brain: brain)
        #expect(plan.isChange && plan.before.isEmpty)
        try await GlobalInstructions.commit(plan, brain: brain, env: f.env)
        let fresh = try #require(Brain.load(from: f.brainRoot))
        status = GlobalInstructions.status(context: move.context(), brain: fresh)
        #expect(status.text == "## Commits\nShort lines.")
        #expect(status.outdated)
        #expect(Set(status.copies.map(\.path)).isSuperset(of: ["~/.claude/CLAUDE.md", "~/.pi/agent/AGENTS.md"]))

        let blocks = GlobalInstructions.homeBlocks(context: move.context(), brainRoot: f.brainRoot)
        #expect(blocks.canApply, "\(blocks.warnings)")
        #expect(Set(blocks.diffs.map(\.path)) == ["~/.claude/CLAUDE.md", "~/.pi/agent/AGENTS.md"])
        try await GlobalInstructions.applyHome(blocks, context: move.context(), trash: f.trash)

        let written = try #require(f.read(".claude/CLAUDE.md", in: f.home))
        #expect(written.hasPrefix(omc), "the user's bytes stay")
        #expect(written.contains("## Commits\nShort lines."))
        // No skills were rendered: only the blocks changed.
        #expect(!FileManager.default.fileExists(atPath: f.home.appending(path: ".agents/skills/akit").path))
        status = GlobalInstructions.status(context: move.context(), brain: fresh)
        #expect(!status.outdated, "\(status.copies.map { "\($0.path) \($0.state)" })")
    }

    @Test func editIsRefusedWhenCoreChangedSinceThePreviewOrTheTextHasMarkers() async throws {
        try move.harnesses()
        let brain = try await f.setUpBrain()
        #expect(throws: GlobalInstructions.Failure.self) {
            try GlobalInstructions.editing(to: "\(InstructionText.akitStart)\nx\n", brain: brain)
        }
        let plan = try GlobalInstructions.editing(to: "## A\none\n", brain: brain)
        let other = try GlobalInstructions.editing(to: "## B\ntwo\n", brain: brain)
        try await GlobalInstructions.commit(other, brain: brain, env: f.env)
        await #expect(throws: GlobalInstructions.Failure.self) {
            try await GlobalInstructions.commit(plan, brain: brain, env: f.env)
        }
    }
}

/// Take Over…: own text of the global files → core → blocks → out of the files.
struct GlobalTakeOverTests {
    let move: SkillMoveTests
    var f: GitProjectFixture { move.f }

    init() throws { move = try SkillMoveTests() }

    @Test func sameTextInTwoFilesIsOneCandidateAndAMovedSectionLeavesBoth() async throws {
        try move.harnesses()
        try f.write(".claude/CLAUDE.md", "<!-- OMC:START -->\n## Setup\nomc\n<!-- OMC:END -->\n\n## Commits\nShort lines.\n\n## Style\nTabs.\n")
        try f.write(".pi/agent/AGENTS.md", "## Commits\nShort lines.\n\n## Style\nSpaces.\n")
        let brain = try await f.setUpBrain()
        let status = GlobalInstructions.status(context: move.context(), brain: brain)
        let candidates = GlobalInstructions.candidates(status, env: f.env)
        #expect(candidates.map(\.title) == ["## Commits", "## Style", "## Style"])
        let commits = try #require(candidates.first)
        #expect(commits.places.count == 2 && commits.places.allSatisfy { $0.stays == nil })
        #expect(candidates[1].differs == [candidates[2].id])

        #expect(throws: GlobalInstructions.Failure.self) { try GlobalInstructions.takeOver(Array(candidates[1...2]), status: status) }
        let plan = try GlobalInstructions.takeOver([commits, candidates[1]], status: status)
        #expect(plan.after == "## Commits\nShort lines.\n\n## Style\nTabs.")

        try await GlobalInstructions.commit(plan, brain: brain, env: f.env)
        // Before the blocks are written, nothing leaves the files.
        #expect(GlobalInstructions.removeTakenOver(plan, env: f.env).count == 3, "Commits twice, Style (Tabs) once")
        let blocks = GlobalInstructions.homeBlocks(context: move.context(), brainRoot: f.brainRoot)
        try await GlobalInstructions.applyHome(blocks, context: move.context(), trash: f.trash)
        let kept = GlobalInstructions.removeTakenOver(plan, env: f.env)
        #expect(kept.isEmpty, "\(kept)")

        let claude = try #require(f.read(".claude/CLAUDE.md", in: f.home))
        #expect(claude.hasPrefix("<!-- OMC:START -->\n## Setup\nomc\n<!-- OMC:END -->\n"), "the other tool's block stays")
        #expect(InstructionText.units(claude).filter { !$0.isAKitBlock }.compactMap(\.heading) == ["Setup"])
        let pi = try #require(f.read(".pi/agent/AGENTS.md", in: f.home))
        #expect(InstructionText.units(pi).filter { !$0.isAKitBlock }.compactMap(\.heading) == ["Style"], "Pi's other Style stays")
        #expect(pi.contains("Spaces.") && pi.contains("Short lines."))
    }

    @Test func textWithoutAHeadingGoesOnlyIntoAnEmptyCore() async throws {
        try move.harnesses()
        try f.write(".pi/agent/AGENTS.md", "Be brief.\n\n## Rules\nOne.\n")
        let brain = try await f.setUpBrain()
        let status = GlobalInstructions.status(context: move.context(), brain: brain)
        let candidates = GlobalInstructions.candidates(status, env: f.env)
        let plan = try GlobalInstructions.takeOver(candidates.reversed(), status: status)
        #expect(plan.after == "Be brief.\n\n## Rules\nOne.")
        try await GlobalInstructions.commit(plan, brain: brain, env: f.env)
        let fresh = try #require(Brain.load(from: f.brainRoot))
        let again = GlobalInstructions.status(context: move.context(), brain: fresh)
        let lead = InstructionSection(heading: nil, text: "More.\n", isAKitBlock: false, line: 1)
        let extra = GlobalInstructions.Candidate(heading: nil, text: lead.text, places: [], differs: [], inCore: false)
        #expect(throws: GlobalInstructions.Failure.self) { try GlobalInstructions.takeOver([extra], status: again) }
    }
}

struct GlobalSuggestionTests {
    let core = "Lead.\n\n## Commits\nShort.\n\n## Style\nTabs."

    @Test func aSuggestionReplacesRemovesOrAddsASection() {
        #expect(GlobalInstructions.applying("## Commits\nImperative, 72 chars.", toSection: "## commits", in: core)
                == "Lead.\n\n## Commits\nImperative, 72 chars.\n\n## Style\nTabs.")
        #expect(GlobalInstructions.applying("", toSection: "Style", in: core) == "Lead.\n\n## Commits\nShort.")
        #expect(GlobalInstructions.applying("## Tests\nFirst.", toSection: nil, in: core) == core + "\n\n## Tests\nFirst.")
        #expect(GlobalInstructions.applying("## X\ny", toSection: "## Missing", in: core) == nil, "not in core: Take Over first")
        #expect(GlobalInstructions.applying(core + "\nMore.", toSection: nil, in: core) == nil, "a whole rewrite is not appended")
        #expect(GlobalInstructions.applying("## Style\nOther.", toSection: nil, in: core) == nil, "core has ## Style")
        #expect(GlobalInstructions.applying("Imperative.", toSection: "## Commits", in: core) == nil, "no heading")
        #expect(GlobalInstructions.applying("## Style\nTabs.", toSection: "## Style", in: core) == nil, "no change")
    }
}

/// Review round 2026-10-30: another tool's block is never taken, moved or cut.
struct GlobalManagedBlockTests {
    let move: SkillMoveTests
    var f: GitProjectFixture { move.f }

    init() throws { move = try SkillMoveTests() }

    @Test func theUsersTextRightAboveABlockIsCutAtItsStartAndStays() async throws {
        try move.harnesses()
        try f.write(".claude/CLAUDE.md", "## My notes\nx\n\n<!-- OMC:START -->\n# omc\ntext\n## Setup\nomc\n<!-- OMC:END -->\n")
        let brain = try await f.setUpBrain()
        let status = GlobalInstructions.status(context: move.context(), brain: brain)
        let claude = try #require(status.copies.first { $0.path == "~/.claude/CLAUDE.md" })
        #expect(claude.own.map(\.text) == ["## My notes\nx\n"] && claude.partial == [1])
        let candidate = try #require(GlobalInstructions.candidates(status, env: f.env).first)
        #expect(candidate.places.first?.stays != nil, "AKit can't take part of a section out")
        let plan = try GlobalInstructions.takeOver([candidate], status: status)
        #expect(!plan.after.contains("OMC"))
        try await GlobalInstructions.commit(plan, brain: brain, env: f.env)
        try await GlobalInstructions.applyHome(GlobalInstructions.homeBlocks(context: move.context(), brainRoot: f.brainRoot),
                                               context: move.context(), trash: f.trash)
        #expect(GlobalInstructions.removeTakenOver(plan, env: f.env).count == 1)
        let after = try #require(f.read(".claude/CLAUDE.md", in: f.home))
        #expect(after.hasPrefix("## My notes\nx\n\n<!-- OMC:START -->\n# omc\ntext\n## Setup\nomc\n<!-- OMC:END -->\n"))
    }

    @Test func aBOMAnUnclosedStartAndFencesAreRead() {
        #expect(GlobalInstructions.managedBlocks(in: "\u{FEFF}<!-- OMC:START -->\n## A\n<!-- OMC:END -->\n").first?.lines == 1...3)
        let open = GlobalInstructions.managedBlocks(in: "## Mine\nx\n<!-- OMC:START -->\n## A\nb\n")
        #expect(open.first?.lines == 3...5, "runs to the end of the file")
        #expect(GlobalInstructions.ownSections(of: "## Mine\nx\n<!-- OMC:START -->\n## A\nb\n", managed: open).map(\.heading) == ["Mine"])
        // ```swift doesn't close a ``` fence; the markers inside the fence don't count.
        let fenced = "````\n```swift\n<!-- X:START -->\n```\n<!-- X:END -->\n````\n"
        #expect(GlobalInstructions.managedBlocks(in: fenced).isEmpty)
    }

    @Test func theSameTextInsideABlockIsNeverTheOneRemoved() async throws {
        try move.harnesses()
        try f.write(".claude/CLAUDE.md", "<!-- OMC:START -->\n## Setup\nSay hi.\n<!-- OMC:END -->\n\n## Setup\nSay hi.\n")
        let brain = try await f.setUpBrain()
        let status = GlobalInstructions.status(context: move.context(), brain: brain)
        let candidate = try #require(GlobalInstructions.candidates(status, env: f.env).first)
        #expect(candidate.places.first?.section.line == 6 && candidate.places.first?.stays == nil)
        let plan = try GlobalInstructions.takeOver([candidate], status: status)
        try await GlobalInstructions.commit(plan, brain: brain, env: f.env)
        try await GlobalInstructions.applyHome(GlobalInstructions.homeBlocks(context: move.context(), brainRoot: f.brainRoot),
                                               context: move.context(), trash: f.trash)
        #expect(GlobalInstructions.removeTakenOver(plan, env: f.env).isEmpty)
        let after = try #require(f.read(".claude/CLAUDE.md", in: f.home))
        #expect(after.hasPrefix("<!-- OMC:START -->\n## Setup\nSay hi.\n<!-- OMC:END -->\n"))
        #expect(after.components(separatedBy: "Say hi.").count == 3, "OMC's copy and AKit's block; the own copy went")
        #expect(!after.contains("<!-- OMC:END -->\n\n## Setup"))
    }

    @Test func aFileThatGetsNoBlockKeepsItsTextAndMarkersAreRefused() async throws {
        try move.harnesses()
        try f.write(".pi/agent/AGENTS.md", "## Style\nTabs.\n")
        let brain = try await f.setUpBrain()
        // Claude only: Pi's file gets no block.
        var context = move.context()
        context.targets = ["claude"]
        let status = GlobalInstructions.status(context: context, brain: brain)
        let pi = try #require(status.copies.first { $0.path == "~/.pi/agent/AGENTS.md" })
        #expect(!pi.getsBlock)
        #expect(GlobalInstructions.candidates(status, env: f.env).first?.places.first?.stays?.contains("no core block") == true)
        #expect(throws: GlobalInstructions.Failure.self) { try GlobalInstructions.editing(to: "## A\n<!-- OMC:START -->\n", brain: brain) }
    }

    @Test func aCoreHeadingIsNotAddedTwice() async throws {
        try move.harnesses()
        try f.write(".claude/CLAUDE.md", "## Style\nSpaces.\n")
        let brain = try await f.setUpBrain()
        try await GlobalInstructions.commit(try GlobalInstructions.editing(to: "## Style\nTabs.", brain: brain), brain: brain, env: f.env)
        let fresh = try #require(Brain.load(from: f.brainRoot))
        let status = GlobalInstructions.status(context: move.context(), brain: fresh)
        #expect(throws: GlobalInstructions.Failure.self) {
            try GlobalInstructions.takeOver(GlobalInstructions.candidates(status, env: f.env), status: status)
        }
    }
}
