import Foundation
import Testing
import AKitBrain
import AKitFoundation
import AKitHarnesses
import AKitSkills
@testable import AKitProjectSetup

/// Model invocation (Auto / Manual): your own copy's SKILL.md, or the layer's mode and the home
/// copy for a global skill AKit rendered. A fake home with Claude Code and Pi, a brain.
struct SkillInvocationTests {
    let move: SkillMoveTests
    var f: GitProjectFixture { move.f }
    let fm = FileManager.default
    let file = ".agents/skills/deploy/SKILL.md"

    init() throws { move = try SkillMoveTests() }

    func installed(projects: [URL] = []) -> [Skill] {
        SkillScanner.scan(installations: HarnessCatalog.detectAll(in: f.env), projects: projects, in: f.env)
    }

    func context(_ installed: [Skill]) -> SkillMove.Context {
        SkillMove.Context(env: f.env, store: f.store, homeID: move.homeID, installed: installed, targets: ["claude", "pi"])
    }

    /// The global skill with this folder name, its link and a plan for it.
    func plan(_ name: String = "deploy", manual: Bool, brain: Brain? = nil) throws -> SkillInvocation.Plan {
        let skills = installed()
        let skill = try #require(skills.first { $0.scope == .global && $0.folder.lastPathComponent == name })
        let links = brain.map { BrainLinks.links(for: skills, brain: $0, folders: [move.homeID: f.home], store: f.store) } ?? [:]
        return try SkillInvocation.plan(skill, link: links[skill.id], manual: manual, brain: brain, context: context(skills))
    }

    /// Every file under the harness folders of the home, by path (links not followed).
    func homeFiles() -> [String: Data] {
        var files: [String: Data] = [:]
        for folder in [".agents", ".claude", ".pi"] {
            let root = f.home.appending(path: folder)
            for case let path as String in fm.enumerator(atPath: root.path) ?? .init() {
                if let data = fm.contents(atPath: root.appending(path: path).path) { files["\(folder)/\(path)"] = data }
            }
        }
        return files
    }

    func backups(of path: String) -> [String] {
        let root = f.home.appending(path: ".akit/backups")
        return ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).compactMap { f.read("\($0)/\(path)", in: root) }
    }

    @Test func anOwnCopyGainsAndLosesTheLineWithABackup() async throws {
        try move.harnesses()
        try f.write(file, move.skill)
        try f.write(".agents/skills/deploy/run.sh", "echo\n")
        let before = homeFiles()

        let manual = try plan(manual: true)
        #expect(!manual.changesNothing && manual.layer == nil && manual.holds.isEmpty)
        #expect(manual.diffs.map(\.title) == ["~/.agents/skills/deploy/SKILL.md"])
        #expect(manual.diffs.first?.lines.contains(.added("disable-model-invocation: true")) == true)
        let backup = try await SkillInvocation.apply(manual, brain: nil, env: f.env)
        #expect(f.read(file, in: f.home) == "---\nname: deploy\ndescription: Deploys the app\ndisable-model-invocation: true\n---\n\n# Deploy\n")
        #expect(backup.flatMap { try? String(contentsOf: $0, encoding: .utf8) } == move.skill)
        #expect(homeFiles().filter { $0.key != file } == before.filter { $0.key != file })
        #expect(try plan(manual: true).changesNothing)

        // Back to Auto: the same bytes as at the start.
        let auto = try plan(manual: false)
        #expect(auto.diffs.first?.lines.contains(.removed("disable-model-invocation: true")) == true)
        try await SkillInvocation.apply(auto, brain: nil, env: f.env)
        #expect(homeFiles() == before && backups(of: file).count == 2)
        #expect(try plan(manual: false).changesNothing)
    }

    @Test func aFileChangedSinceThePreviewIsRefused() async throws {
        try move.harnesses()
        try f.write(file, move.skill)
        let plan = try plan(manual: true)
        try f.write(file, move.skill + "more\n")
        await #expect { try await SkillInvocation.apply(plan, brain: nil, env: f.env) } throws: { error in
            (error as? SkillInvocation.Failure)?.message.contains("~/.agents/skills/deploy/SKILL.md changed after the preview") == true
        }
        #expect(f.read(file, in: f.home) == move.skill + "more\n" && backups(of: file).isEmpty)
    }

    @Test func noHeaderCantBeManualAndFalseCountsAsAuto() throws {
        try move.harnesses()
        try f.write(file, "# Deploy\n")
        #expect { try plan(manual: true) } throws: { error in
            (error as? SkillInvocation.Failure)?.message == "~/.agents/skills/deploy/SKILL.md has no --- header, so it can't be made Manual. Add a header with name and description first."
        }
        try f.write(".agents/skills/off/SKILL.md", "---\nname: off\ndescription: D\ndisable-model-invocation: false\n---\n")
        #expect(try plan("off", manual: false).changesNothing)
        #expect(try plan("off", manual: true).diffs.first?.lines.contains(.removed("disable-model-invocation: false")) == true)
    }

    @Test func notesNameClaudesSwitchAndTheSource() throws {
        try move.harnesses()
        try f.write(file, "---\nname: deploy\ndescription: D\n\"disable-model-invocation\": true\n---\n")
        try f.write(".claude/settings.json", #"{"skillOverrides": {"deploy": "off"}}"#)
        try f.write(".agents/.skill-lock.json", #"{"version": 3, "skills": {"deploy": {"source": "me/skills"}}}"#)
        let notes = try plan(manual: false).notes
        #expect(notes.count == 2, "\(notes)")
        #expect(notes.first == "Claude Code's own switch for this skill is Off, so Claude Code still won't offer it to the model. Set the Claude switch to On as well.")
        #expect(notes.last == "This skill came from me/skills: updating or reinstalling it from there may write over this edit.")
    }

    @Test func pluginSyncedAndRenderedProjectCopiesAreUnavailable() async throws {
        try move.harnesses()
        let base = f.home.appending(path: ".claude/plugins/cache/tools")
        try f.write(".claude/plugins/cache/tools/skills/lint/SKILL.md", "---\nname: lint\ndescription: Lint\n---\n")
        try f.write(".claude/plugins/installed_plugins.json",
                    #"{"plugins": {"tools@market": [{"scope": "user", "installPath": "\#(base.path)", "version": "1.0"}]}}"#)
        try f.write(".claude/settings.json", #"{"enabledPlugins": {"tools@market": true}}"#)
        try f.write(".agents/skills/synced/bucket/cloud/SKILL.md", "---\nname: cloud\ndescription: From claude.ai\n---\n")
        _ = try await f.setUpBrain()
        try f.write(".akit/registry/skills/deploy/SKILL.md", move.skill)
        try await f.git("add", "-A", in: f.brainRoot)
        try await f.git("commit", "-qm", "Add deploy", in: f.brainRoot)
        var brain = try #require(Brain.load(from: f.brainRoot))
        try await f.initRepo()
        try await f.apply(ProjectAnswers(targets: ["claude", "pi"], skills: [.init(name: "deploy", mode: .manual)], localOnly: true), brain: brain)
        brain = try #require(Brain.load(from: f.brainRoot))

        let skills = installed(projects: [f.project])
        let links = BrainLinks.links(for: skills, brain: brain, folders: [f.id: f.project], store: f.store)
        func reason(_ name: String) throws -> String? {
            let skill = try #require(skills.first { $0.name == name }, "\(name) in \(skills.map(\.name))")
            let reason = SkillInvocation.unavailable(skill, link: links[skill.id])
            #expect(throws: SkillInvocation.Failure.self) {
                try SkillInvocation.plan(skill, link: links[skill.id], manual: !skill.disablesModelInvocation, brain: brain, context: context(skills))
            }
            return reason
        }
        #expect(try reason("lint") == "A plugin's skill belongs to its plugin; AKit doesn't edit plugin files.")
        #expect(try reason("cloud") == "claude.ai manages this skill and would write over the edit.")
        #expect(try reason("deploy") == "AKit rendered this copy into the project. Change its mode on the Brain screen (the layer, or the project's own skills).")
        #expect(f.read(".agents/skills/deploy/SKILL.md")?.contains("disable-model-invocation: true") == true)
    }

    @Test func aRenderedGlobalCopyChangesTheLayersModeThenTheHomeCopy() async throws {
        try move.harnesses()
        _ = try await move.renderedInCore()
        // Core also brings a skill the home folder doesn't have yet: that change is not this one's.
        try f.write(".akit/registry/skills/other/SKILL.md", "---\nname: other\ndescription: Other\n---\n")
        let core = ".akit/registry/layers/core/layer.yaml"
        try f.write(core, (f.read(core, in: f.home) ?? "") + "  - name: other\n")
        try await f.git("add", "-A", in: f.brainRoot)
        try await f.git("commit", "-qm", "Add other", in: f.brainRoot)
        var brain = try #require(Brain.load(from: f.brainRoot))
        let before = homeFiles()
        #expect(before[".agents/skills/other/SKILL.md"] == nil)
        let commits = try await f.git("rev-list", "--count", "HEAD", in: f.brainRoot)

        #expect(try plan(manual: true, brain: brain).changesNothing)
        let auto = try plan(manual: false, brain: brain)
        #expect(!auto.changesNothing && auto.layer == "core" && auto.holds == [move.homeID])
        #expect(auto.diffs.map(\.title) == ["layers/core/layer.yaml (brain)", "~/.agents/skills/deploy/SKILL.md"])
        #expect(auto.diffs.first?.lines.contains(.added("    mode: auto")) == true)
        #expect(auto.diffs.last?.lines.contains(.removed("disable-model-invocation: true")) == true)

        var held: [String] = []
        let backup = try await SkillInvocation.apply(auto, brain: brain, env: f.env, trash: f.trash) { id, work in
            held.append(id)
            return try await work()
        }
        #expect(held == [move.homeID] && backup != nil)
        #expect(Brain.load(from: f.brainRoot)?.layers.first { $0.name == "core" }?.skills.first { $0.name == "deploy" }?.mode == .auto)
        #expect(try await f.git("log", "-3", "--format=%s", in: f.brainRoot).contains("Make deploy auto in layer core"))
        #expect(try await f.git("status", "--porcelain", in: f.brainRoot).isEmpty)
        #expect(f.read(file, in: f.home) == move.skill)
        #expect(homeFiles().filter { $0.key != file } == before.filter { $0.key != file }, "only the skill's SKILL.md changed in the home folder")

        // The copy is still AKit's render, and goes back to Manual the same way.
        brain = try #require(Brain.load(from: f.brainRoot))
        let skills = installed()
        let skill = try #require(skills.first { $0.folder.lastPathComponent == "deploy" })
        #expect(BrainLinks.links(for: skills, brain: brain, folders: [move.homeID: f.home], store: f.store)[skill.id]
                == .rendered(skill: "deploy", layers: ["core"], edited: false))
        try await SkillInvocation.apply(try plan(manual: true, brain: brain), brain: brain, env: f.env, trash: f.trash)
        #expect(homeFiles() == before)
        #expect(Brain.load(from: f.brainRoot)?.layers.first { $0.name == "core" }?.skills.first { $0.name == "deploy" }?.mode == .manual)
        #expect(Int(try await f.git("rev-list", "--count", "HEAD", in: f.brainRoot).trimmingCharacters(in: .whitespacesAndNewlines))
                ?? 0 > Int(commits.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
    }

    @Test func aRenderedCopyEditedByHandIsRefusedAndNothingChanges() async throws {
        try move.harnesses()
        _ = try await move.renderedInCore()
        let brain = try #require(Brain.load(from: f.brainRoot))
        try f.write(file, (f.read(file, in: f.home) ?? "") + "mine\n")
        let before = homeFiles()
        let head = try await f.git("rev-parse", "HEAD", in: f.brainRoot)
        #expect { try plan(manual: false, brain: brain) } throws: { error in
            (error as? SkillInvocation.Failure)?.message.hasPrefix("~/.agents/skills/deploy/SKILL.md was edited by hand since AKit wrote it.") == true
        }
        #expect(homeFiles() == before)
        #expect(try await f.git("rev-parse", "HEAD", in: f.brainRoot) == head)
        #expect(try await f.git("status", "--porcelain", in: f.brainRoot).isEmpty)
    }

    @Test func aLayerChangedSinceThePreviewIsRefused() async throws {
        try move.harnesses()
        _ = try await move.renderedInCore()
        let brain = try #require(Brain.load(from: f.brainRoot))
        let plan = try plan(manual: false, brain: brain)
        let core = ".akit/registry/layers/core/layer.yaml"
        try f.write(core, (f.read(core, in: f.home) ?? "") + "# note\n")
        let before = homeFiles()
        await #expect { try await SkillInvocation.apply(plan, brain: brain, env: f.env, trash: f.trash) } throws: { error in
            (error as? SkillInvocation.Failure)?.message == "layers/core/layer.yaml changed since the preview. Look at the preview again."
        }
        #expect(homeFiles() == before)
    }

    @Test func aFlagInTheBrainsOwnFileCantBecomeAutoThroughTheLayer() async throws {
        try move.harnesses()
        _ = try await move.renderedInCore()
        try f.write(".akit/registry/skills/deploy/SKILL.md", "---\nname: deploy\ndescription: Deploys the app\ndisable-model-invocation: true\n---\n")
        try await f.git("commit", "-qam", "Manual in the file", in: f.brainRoot)
        let brain = try #require(Brain.load(from: f.brainRoot))
        #expect { try plan(manual: false, brain: brain) } throws: { error in
            (error as? SkillInvocation.Failure)?.message.hasPrefix("The brain's skills/deploy/SKILL.md sets disable-model-invocation itself") == true
        }
    }

    @Test func theScannerAndTheWriterReadTheFlagTheSameWay() async throws {
        try move.harnesses()
        let texts = [
            "quoted": "---\nname: quoted\ndescription: D\n\"disable-model-invocation\": true\n---\n",
            "comment": "---\nname: comment\ndescription: D\ndisable-model-invocation: true # only /comment\n---\n",
            // An indented --- inside a block value is not the header's end.
            "block": "---\nname: block\ndescription: |\n  one\n  ---\n  two\ndisable-model-invocation: true\n---\nbody\n",
        ]
        for (name, text) in texts { try f.write(".agents/skills/\(name)/SKILL.md", text) }
        for (name, text) in texts.sorted(by: { $0.key < $1.key }) {
            let skill = try #require(installed().first { $0.folder.lastPathComponent == name })
            #expect(skill.disablesModelInvocation, "\(name) scans as Manual")
            #expect(try plan(name, manual: true).changesNothing)
            try await SkillInvocation.apply(try plan(name, manual: false), brain: nil, env: f.env)
            let after = try #require(f.read(".agents/skills/\(name)/SKILL.md", in: f.home))
            #expect(after == text.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.contains("disable-model-invocation") }.joined(separator: "\n"))
            #expect(installed().first { $0.folder.lastPathComponent == name }?.disablesModelInvocation == false)
        }
        // Mixed line ends: an LF header, a CRLF in the body.
        try f.write(".agents/skills/mixed/SKILL.md", "---\nname: mixed\ndescription: D\n---\nbody\r\nmore\n")
        try await SkillInvocation.apply(try plan("mixed", manual: true), brain: nil, env: f.env)
        #expect(f.read(".agents/skills/mixed/SKILL.md", in: f.home) == "---\nname: mixed\ndescription: D\ndisable-model-invocation: true\n---\nbody\r\nmore\n")
    }

    @Test func aLinkedSkillFileIsWrittenThroughTheLink() async throws {
        try move.harnesses()
        try f.write("shared/deploy.md", move.skill)
        try fm.createDirectory(at: f.home.appending(path: ".agents/skills/deploy"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: f.home.appending(path: file).path, withDestinationPath: "../../../shared/deploy.md")
        let plan = try plan(manual: true)
        #expect(plan.file.path.hasSuffix("/shared/deploy.md"))
        try await SkillInvocation.apply(plan, brain: nil, env: f.env)
        #expect(try fm.destinationOfSymbolicLink(atPath: f.home.appending(path: file).path) == "../../../shared/deploy.md")
        #expect(f.read("shared/deploy.md", in: f.home)?.contains("disable-model-invocation: true") == true)
    }

    @Test func aSkillLinkedIntoTheBrainIsTheBrainsToChange() async throws {
        try move.harnesses()
        let brain = try await f.setUpBrain()
        try fm.createSymbolicLink(atPath: f.home.appending(path: ".agents/skills/tdd").path, withDestinationPath: f.brainRoot.appending(path: "skills/tdd").path)
        let skills = installed()
        let skill = try #require(skills.first { $0.folder.lastPathComponent == "tdd" })
        let links = BrainLinks.links(for: skills, brain: brain, folders: [:], store: f.store)
        #expect(SkillInvocation.unavailable(skill, link: links[skill.id], brain: brain)
                == "This skill's file is inside the brain's folder (a link into it). Change it on the Brain screen: edit the brain's skill, or set its mode in a layer.")
        #expect(throws: SkillInvocation.Failure.self) {
            try SkillInvocation.plan(skill, link: links[skill.id], manual: true, brain: brain, context: context(skills))
        }
    }

    @Test func aFailedCommitSaysTheLayerHasTheModeAndTheHomeCopyDoesNot() async throws {
        try move.harnesses()
        _ = try await move.renderedInCore()
        let brain = try #require(Brain.load(from: f.brainRoot))
        let plan = try plan(manual: false, brain: brain)
        let before = homeFiles()
        let head = try await f.git("rev-parse", "HEAD", in: f.brainRoot)
        // git can't take the index: the layer file is written, the commit fails.
        try f.write(".akit/registry/.git/index.lock")
        await #expect { try await SkillInvocation.apply(plan, brain: brain, env: f.env, trash: f.trash) } throws: { error in
            let message = (error as? SkillInvocation.Failure)?.message ?? ""
            return message.hasPrefix("layers/core/layer.yaml has the new mode (deploy is auto), but it is not committed in the brain, and the home folder's copy was not updated: ")
                && message.hasSuffix("Commit the file in the brain (Brain → Sync shows it), then Brain → core → Update Home Folder… (akit apply --home) updates the home copy.")
        }
        try fm.removeItem(at: f.brainRoot.appending(path: ".git/index.lock"))
        #expect(homeFiles() == before)
        #expect(try await f.git("rev-parse", "HEAD", in: f.brainRoot) == head)
        #expect(f.read(".akit/registry/layers/core/layer.yaml", in: f.home)?.contains("mode: auto") == true)
    }

    @Test func aFailedHomeUpdateSaysTheBrainHasTheMode() async throws {
        try move.harnesses()
        _ = try await move.renderedInCore()
        let brain = try #require(Brain.load(from: f.brainRoot))
        let plan = try plan(manual: false, brain: brain)
        let before = homeFiles()
        await #expect {
            try await SkillInvocation.apply(plan, brain: brain, env: f.env, trash: f.trash) { _, _ in throw CocoaError(.fileWriteNoPermission) }
        } throws: { error in
            let message = (error as? SkillInvocation.Failure)?.message ?? ""
            return message.hasPrefix("The brain has the new mode (deploy is auto in the core layer, committed), but the home folder's copy was not updated: ")
                && message.hasSuffix("Brain → core → Update Home Folder… (akit apply --home) finishes it.")
        }
        #expect(homeFiles() == before)
        #expect(try await f.git("log", "-1", "--format=%s", in: f.brainRoot) == "Make deploy auto in layer core\n")
        #expect(try await f.git("status", "--porcelain", in: f.brainRoot).isEmpty)
    }

    @Test func withTwoLayersTheOverridingOnesModeChanges() async throws {
        try move.harnesses()
        _ = try await move.renderedInCore(only: true)
        try f.write(".akit/registry/layers/core/layer.yaml", "name: core\nrequires: [extra]\nskills:\n  - name: deploy\n    mode: manual\n")
        try f.write(".akit/registry/layers/extra/layer.yaml", "name: extra\nskills:\n  - name: deploy\n    mode: manual\n    override: true\n")
        try await f.git("add", "-A", in: f.brainRoot)
        try await f.git("commit", "-qm", "Extra", in: f.brainRoot)
        var brain = try #require(Brain.load(from: f.brainRoot))
        let home = ProjectSetup.plan(project: f.home, id: move.homeID, answers: ProjectAnswers(layers: ["core"], targets: ["claude", "pi"]),
                                     brain: brain, store: f.store, forHome: true, env: f.env)
        #expect(home.canApply, "\(home.blockers) \(home.render.errors)")
        _ = try await ProjectSetup.apply(home, brain: brain, home: f.home, env: f.env, trash: f.trash)
        brain = try #require(Brain.load(from: f.brainRoot))

        let plan = try plan(manual: false, brain: brain)
        #expect(plan.layer == "extra" && plan.diffs.map(\.title) == ["layers/extra/layer.yaml (brain)", "~/.agents/skills/deploy/SKILL.md"])
        try await SkillInvocation.apply(plan, brain: brain, env: f.env, trash: f.trash)
        let layers = try #require(Brain.load(from: f.brainRoot)).layers
        #expect(layers.first { $0.name == "extra" }?.skills.first?.mode == .auto && layers.first { $0.name == "extra" }?.skills.first?.override == true)
        #expect(layers.first { $0.name == "core" }?.skills.first { $0.name == "deploy" }?.mode == .manual)
        #expect(f.read(file, in: f.home) == move.skill)
    }
}
