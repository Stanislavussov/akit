import Foundation
import Testing
import AKitBrain
import AKitFoundation
import AKitHarnesses
import AKitSkills
@testable import AKitProjectSetup

/// Duplicates: one name in places one harness loads together, and Resolve Duplicate… keeping one copy.
struct SkillDuplicatesTests {
    let removal: SkillRemovalTests
    var move: SkillMoveTests { removal.move }
    var f: GitProjectFixture { removal.f }

    init() throws { removal = try SkillRemovalTests() }

    func scan(_ projects: [URL] = []) -> [Skill] {
        SkillScanner.scan(installations: HarnessCatalog.detectAll(in: f.env), projects: projects, in: f.env)
    }

    func skill(_ name: String, _ description: String = "D") -> String {
        "---\nname: \(name)\ndescription: \(description)\n---\n"
    }

    @Test func groupsCountOnlyCopiesOneHarnessLoadsTogether() throws {
        try move.harnesses()
        let one = f.home.appending(path: "Projects/one"), two = f.home.appending(path: "Projects/two")
        // Pi loads both global copies; Claude reads ~/.agents/skills through its link.
        try f.write(".agents/skills/solo/SKILL.md", skill("solo"))
        try f.write(".pi/agent/skills/solo/SKILL.md", skill("solo", "Other"))
        // A global copy and a project's.
        try f.write(".agents/skills/tdd/SKILL.md", skill("tdd"))
        try f.write("Projects/one/.claude/skills/tdd/SKILL.md", skill("tdd"))
        // The same name in two projects only: no session sees both.
        try f.write("Projects/one/.agents/skills/lint/SKILL.md", skill("lint"))
        try f.write("Projects/two/.agents/skills/lint/SKILL.md", skill("lint"))
        // A link to the same folder is one copy.
        try FileManager.default.createDirectory(at: f.home.appending(path: "Projects/two/.agents/skills"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: f.home.appending(path: "Projects/two/.agents/skills/tdd").path,
                                                   withDestinationPath: f.home.appending(path: ".agents/skills/tdd").path)

        let groups = SkillDuplicates.groups(scan([one, two]))
        #expect(groups.map(\.name) == ["solo", "tdd"], "\(groups.map { ($0.name, $0.copies.map(\.file.path)) })")
        let solo = try #require(groups.first)
        #expect(solo.harnesses == [.pi] && solo.copies.count == 2)
        let tdd = try #require(groups.last)
        #expect(tdd.harnesses == [.claudeCode] && tdd.copies.count == 2)
        #expect(SkillDuplicates.preferred(tdd)?.scope == .global)
    }

    @Test func resolvingKeepsTheChosenCopyAndTrashesTheOther() async throws {
        try move.harnesses()
        try f.write(".agents/skills/solo/SKILL.md", skill("solo"))
        try f.write(".pi/agent/skills/solo/SKILL.md", skill("solo", "Other"))
        let group = try #require(SkillDuplicates.groups(scan()).first)
        let keep = try #require(group.copies.first { $0.file.path.contains("/.pi/") })

        let context = removal.context([:])
        let first = SkillRemoval.plan(name: "solo", brain: nil, context: context)
        let plan = SkillRemoval.plan(name: "solo", brain: nil, context: context, leaving: SkillRemoval.leaving(first, toKeep: keep))
        #expect(plan.canApply && plan.places.filter(\.selected).map(\.title) == ["~/.agents/skills/solo"])
        try await SkillRemoval.apply(plan, brain: nil, env: f.env, trash: f.trash)
        #expect(!removal.exists(".agents/skills/solo") && removal.exists(".pi/agent/skills/solo"))
        #expect(SkillDuplicates.groups(scan()).isEmpty)
    }
}
