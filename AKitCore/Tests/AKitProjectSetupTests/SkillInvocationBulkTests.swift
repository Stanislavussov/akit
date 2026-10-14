import Foundation
import Testing
import AKitBrain
import AKitFoundation
import AKitHarnesses
import AKitSkills
@testable import AKitProjectSetup

/// Model invocation of every global skill at once: own copies file by file, rendered copies
/// through their layers in one brain commit and one home folder Apply.
struct SkillInvocationBulkTests {
    let one: SkillInvocationTests
    var move: SkillMoveTests { one.move }
    var f: GitProjectFixture { one.f }

    init() throws { one = try SkillInvocationTests() }

    func bulk(manual: Bool, brain: Brain? = nil) -> SkillInvocation.BulkPlan {
        let skills = one.installed()
        let links = brain.map { BrainLinks.links(for: skills, brain: $0, folders: [move.homeID: f.home], store: f.store) } ?? [:]
        return SkillInvocation.planAll(SkillInvocation.globalCandidates(skills, manual: manual), links: links, manual: manual,
                                       brain: brain, context: one.context(skills))
    }

    func skill(_ name: String, manual: Bool = false) -> String {
        "---\nname: \(name)\ndescription: \(name)\n\(manual ? "disable-model-invocation: true\n" : "")---\n"
    }

    @Test func ownCopiesAllBecomeManualAndBack() async throws {
        try move.harnesses()
        try f.write(".agents/skills/one/SKILL.md", skill("one"))
        try f.write(".agents/skills/two/SKILL.md", skill("two"))
        try f.write(".agents/skills/done/SKILL.md", skill("done", manual: true))
        let before = one.homeFiles()

        // Claude sees the shared folder through a link: each file counts once.
        #expect(SkillInvocation.globalCandidates(one.installed(), manual: true).map(\.name) == ["one", "two"])
        let plan = bulk(manual: true)
        #expect(plan.skills == ["one", "two"] && plan.rendered.isEmpty && plan.skipped.isEmpty && plan.holds.isEmpty)
        #expect(plan.diffs.map(\.title) == ["~/.agents/skills/one/SKILL.md", "~/.agents/skills/two/SKILL.md"])
        let backups = try await SkillInvocation.applyAll(plan, brain: nil, env: f.env)
        #expect(backups.count == 2)
        #expect(f.read(".agents/skills/one/SKILL.md", in: f.home) == skill("one", manual: true))
        #expect(f.read(".agents/skills/two/SKILL.md", in: f.home) == skill("two", manual: true))
        #expect(bulk(manual: true).changesNothing)

        try await SkillInvocation.applyAll(bulk(manual: false), brain: nil, env: f.env)
        #expect(f.read(".agents/skills/done/SKILL.md", in: f.home) == skill("done"))
        try f.write(".agents/skills/done/SKILL.md", skill("done", manual: true))
        #expect(one.homeFiles() == before)
    }

    @Test func oneChangedFileFailsAloneAndTheOthersChange() async throws {
        try move.harnesses()
        try f.write(".agents/skills/one/SKILL.md", skill("one"))
        try f.write(".agents/skills/two/SKILL.md", skill("two"))
        let plan = bulk(manual: true)
        try f.write(".agents/skills/one/SKILL.md", skill("one") + "more\n")
        await #expect { try await SkillInvocation.applyAll(plan, brain: nil, env: f.env) } throws: { error in
            let message = (error as? SkillInvocation.Failure)?.message ?? ""
            return message.hasPrefix("1 of 2 own copies changed. one: ") && message.contains("changed after the preview")
        }
        #expect(f.read(".agents/skills/one/SKILL.md", in: f.home) == skill("one") + "more\n")
        #expect(f.read(".agents/skills/two/SKILL.md", in: f.home) == skill("two", manual: true))
    }

    @Test func renderedCopiesChangeInOneCommitWithOwnCopiesBeside() async throws {
        try move.harnesses()
        _ = try await move.renderedInCore(only: true)
        try f.write(".akit/registry/skills/ship/SKILL.md", skill("ship"))
        try f.write(".akit/registry/layers/core/layer.yaml", "name: core\nskills:\n  - name: deploy\n    mode: manual\n  - name: ship\n    mode: manual\n")
        try await f.git("add", "-A", in: f.brainRoot)
        try await f.git("commit", "-qm", "Add ship", in: f.brainRoot)
        var brain = try #require(Brain.load(from: f.brainRoot))
        let home = ProjectSetup.plan(project: f.home, id: move.homeID, answers: ProjectAnswers(layers: ["core"], targets: ["claude", "pi"]),
                                     brain: brain, store: f.store, forHome: true, env: f.env)
        _ = try await ProjectSetup.apply(home, brain: brain, home: f.home, env: f.env, trash: f.trash)
        try f.write(".agents/skills/mine/SKILL.md", skill("mine", manual: true))
        brain = try #require(Brain.load(from: f.brainRoot))
        let before = one.homeFiles()

        let auto = bulk(manual: false, brain: brain)
        #expect(auto.own.map(\.skill) == ["mine"] && auto.rendered == ["deploy", "ship"] && auto.layers == ["core"], "\(auto.skipped)")
        #expect(auto.skipped.isEmpty && auto.holds == [move.homeID])
        #expect(auto.diffs.map(\.title) == ["~/.agents/skills/mine/SKILL.md", "layers/core/layer.yaml (brain)",
                                            "~/.agents/skills/deploy/SKILL.md", "~/.agents/skills/ship/SKILL.md"])
        var held: [String] = []
        try await SkillInvocation.applyAll(auto, brain: brain, env: f.env, trash: f.trash) { id, work in
            held.append(id)
            return try await work()
        }
        #expect(held == [move.homeID])
        #expect(try await f.git("log", "-2", "--format=%s", in: f.brainRoot).contains("Make 2 skills auto in layer core\n"))
        #expect(try await f.git("status", "--porcelain", in: f.brainRoot).isEmpty)
        #expect(one.installed().filter { $0.scope == .global }.allSatisfy { !$0.disablesModelInvocation })

        // And back: every file as it was.
        brain = try #require(Brain.load(from: f.brainRoot))
        let manual = bulk(manual: true, brain: brain)
        #expect(manual.skills == ["mine", "deploy", "ship"])
        try await SkillInvocation.applyAll(manual, brain: brain, env: f.env, trash: f.trash)
        #expect(one.homeFiles() == before)
    }

    /// `deploy` and `ship` Manual in core, rendered into the home folder, and an own Manual copy `mine`.
    func twoInCore() async throws -> Brain {
        try move.harnesses()
        _ = try await move.renderedInCore(only: true)
        try f.write(".akit/registry/skills/ship/SKILL.md", skill("ship"))
        try f.write(".akit/registry/layers/core/layer.yaml", "name: core\nskills:\n  - name: deploy\n    mode: manual\n  - name: ship\n    mode: manual\n")
        try await f.git("add", "-A", in: f.brainRoot)
        try await f.git("commit", "-qm", "Add ship", in: f.brainRoot)
        let brain = try #require(Brain.load(from: f.brainRoot))
        let home = ProjectSetup.plan(project: f.home, id: move.homeID, answers: ProjectAnswers(layers: ["core"], targets: ["claude", "pi"]),
                                     brain: brain, store: f.store, forHome: true, env: f.env)
        _ = try await ProjectSetup.apply(home, brain: brain, home: f.home, env: f.env, trash: f.trash)
        try f.write(".agents/skills/mine/SKILL.md", skill("mine", manual: true))
        return try #require(Brain.load(from: f.brainRoot))
    }

    @Test func aBadLayerEntryDropsOnlyItsSkill() async throws {
        let brain = try await twoInCore()
        // ship left layer.yaml after the brain was read: only ship can't change.
        try f.write(".akit/registry/layers/core/layer.yaml", "name: core\nskills:\n  - name: deploy\n    mode: manual\n")
        let plan = bulk(manual: false, brain: brain)
        #expect(plan.skills == ["mine", "deploy"], "\(plan.skipped)")
        #expect(plan.skipped.map(\.skill) == ["ship"])
        #expect(plan.skipped.first?.reason == "layers/core/layer.yaml: ship is not in the layer's skills list.")
    }

    @Test func aStaleLayerChangesNoOwnCopy() async throws {
        let brain = try await twoInCore()
        let plan = bulk(manual: false, brain: brain)
        let core = ".akit/registry/layers/core/layer.yaml"
        try f.write(core, (f.read(core, in: f.home) ?? "") + "# note\n")
        let before = one.homeFiles()
        await #expect { try await SkillInvocation.applyAll(plan, brain: brain, env: f.env, trash: f.trash) } throws: { error in
            (error as? SkillInvocation.Failure)?.message == "layers/core/layer.yaml changed since the preview. Look at the preview again."
        }
        #expect(one.homeFiles() == before)
    }

    @Test func anEditedRenderedCopyIsSkippedAndTheRestChange() async throws {
        try move.harnesses()
        _ = try await move.renderedInCore()
        let brain = try #require(Brain.load(from: f.brainRoot))
        let file = ".agents/skills/deploy/SKILL.md"
        try f.write(file, (f.read(file, in: f.home) ?? "") + "mine\n")
        try f.write(".agents/skills/own/SKILL.md", skill("own", manual: true))

        // Core's own akit skill still changes; deploy stays.
        let plan = bulk(manual: false, brain: brain)
        #expect(plan.skills == ["own", "akit"] && plan.holds == [move.homeID], "\(plan.skills) \(plan.skipped)")
        #expect(!plan.diffs.contains { $0.title == "~/" + file })
        #expect(plan.skipped.map(\.skill) == ["deploy"])
        #expect(plan.skipped.first?.reason.hasPrefix("~/.agents/skills/deploy/SKILL.md was edited by hand") == true)
        try await SkillInvocation.applyAll(plan, brain: brain, env: f.env, trash: f.trash)
        #expect(f.read(".agents/skills/own/SKILL.md", in: f.home) == skill("own"))
        #expect(f.read(file, in: f.home)?.hasSuffix("mine\n") == true)
        let layers = try #require(Brain.load(from: f.brainRoot)).layers
        #expect(layers.first { $0.name == "core" }?.skills.first { $0.name == "deploy" }?.mode == .manual)
    }
}
