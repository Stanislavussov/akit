import Foundation
import Testing
import AKitBrain
import AKitFoundation
import AKitLab
import AKitSessions
@testable import AKitErrorAnalysis

/// A brain layer as an eval's setups: render, overlays and their hashes, refusals, answers,
/// Continue. The brain is only read.
struct LayerSetupsTests {
    let fixture: LayerFixture
    var env: HarnessEnvironment { fixture.env }
    let claude = LabAgent(harness: .claudeCode, model: "opus", effort: "high")

    init() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "akit-layersetups-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        fixture = LayerFixture(home: home)
    }

    func task(_ base: String, id: String = "make-value-2-abcd", repo: URL? = nil) -> ControlTask {
        ControlTask(id: id, title: "Make value 2", repo: (repo ?? fixture.repo).path, base: base, prompt: "Make value 2",
                    source: .reproduction, oracle: .tests(command: #"test "$(cat value.txt)" = 2"#))
    }

    func prepare(_ layer: String = "swiftui", tasks: [ControlTask], answers: [String: FieldValue] = [:], agent: LabAgent? = nil,
                 sanity: Bool = false, continuing: String? = nil, homeSkills: Set<String> = [],
                 store: ProjectStore? = nil) async throws -> LayerSetups.Prepared {
        try await LayerSetups.prepare(layer: layer, tasks: tasks, answers: answers, agent: agent ?? claude, sanity: sanity,
                                      continuing: continuing, homeSkills: homeSkills, brain: fixture.brain,
                                      store: store ?? .local(home: fixture.home), projectsRoot: fixture.home, env: env)
    }

    func message(_ body: () async throws -> Void) async -> String? {
        do {
            try await body()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    @Test func layerAndItsRequiredLayersBecomeTwoOverlays() async throws {
        try await fixture.makeBrain()
        let base = try await fixture.makeRepo()
        let headBefore = await fixture.git("rev-parse", "HEAD", in: fixture.brain)
        let prepared = try await prepare(tasks: [task(base)], sanity: true)

        #expect(prepared.setups.map(\.name) == ["without swiftui", "layer swiftui"])
        let baseline = try #require(prepared.setups[0].layer)
        let variant = try #require(prepared.setups[1].layer)
        #expect(baseline.role == .requiredOnly && variant.role == .layer && baseline.evalID == variant.evalID)
        #expect(variant.evalID.hasPrefix("swiftui-") && variant.brainCommit == headBefore)
        let layerHash = try #require(variant.overlayHash)
        let baseHash = try #require(baseline.overlayHash)
        let layerOverlay = try #require(prepared.overlays[layerHash])
        let baseOverlay = try #require(prepared.overlays[baseHash])
        // The required layers alone: only base's section. The shim CLAUDE.md is dropped.
        #expect(baseOverlay.entries.map(\.path) == ["AGENTS.md"])
        #expect(String(decoding: baseOverlay.contents["AGENTS.md"] ?? Data(), as: UTF8.self) == "- BASE-RULE\n")
        #expect(layerOverlay.entries.map(\.path) == [".agents/skills/swiftui-expert/SKILL.md", ".agents/skills/swiftui-expert/refs.json",
                                                     ".claude/skills", "AGENTS.md"])
        #expect(layerOverlay.entries.map(\.kind) == [.skillFile, .skillFile, .claudeSkillsLink, .agentsSection])
        #expect(String(decoding: layerOverlay.contents["AGENTS.md"] ?? Data(), as: UTF8.self).contains("LAYER-MARKER: check with make snapshot"))
        // project_name is the task repository's folder, not the clone's.
        #expect(String(decoding: layerOverlay.contents[".agents/skills/swiftui-expert/SKILL.md"] ?? Data(), as: UTF8.self).contains("Use repo."))
        // The project has its own CLAUDE.md: noted.
        #expect(prepared.runnable.map(\.id) == ["make-value-2-abcd"] && prepared.blocked.isEmpty)
        #expect(prepared.notes["make-value-2-abcd"]?.first?.contains("project's own CLAUDE.md") == true)
        #expect(prepared.ownFiles == ["make-value-2-abcd": "CLAUDE.md"])
        // Sanity: read-only, the required layers alone, on the first tasks.
        #expect(prepared.sanitySetup?.readOnly == true && prepared.sanitySetup?.layer == baseline && prepared.sanityTasks.count == 1)
        // The brain is only read.
        #expect(await fixture.git("rev-parse", "HEAD", in: fixture.brain) == headBefore)
        #expect(await fixture.git("status", "--porcelain", in: fixture.brain) == "")
    }

    @Test func skillScriptsStayExecutableAndAgentsOnlyProjectsAreBlocked() async throws {
        try await fixture.makeBrain()
        try fixture.write("skills/swiftui-expert/run.sh", "#!/bin/sh\n", in: fixture.brain, executable: true)
        await fixture.commitAll(fixture.brain)
        let plain = try await fixture.makeRepo()
        // A later commit where the project keeps AGENTS.md and no CLAUDE.md.
        await fixture.git("mv", "CLAUDE.md", "AGENTS.md", in: fixture.repo)
        await fixture.commitAll(fixture.repo)
        let agentsOnly = try #require(await fixture.git("rev-parse", "HEAD", in: fixture.repo))
        let prepared = try await prepare(tasks: [task(plain), task(agentsOnly, id: "agents-only-abcd")])
        let hash = try #require(prepared.setups[1].layer?.overlayHash)
        let entries = try #require(prepared.overlays[hash]?.entries)
        #expect(entries.first { $0.path.hasSuffix("run.sh") }?.executable == true)
        #expect(entries.first { $0.path.hasSuffix("SKILL.md") }?.executable == nil)
        #expect(prepared.runnable.map(\.id) == ["make-value-2-abcd"])
        #expect(prepared.blocked["agents-only-abcd"]?.contains("has AGENTS.md but no CLAUDE.md") == true)
    }

    @Test func hashFollowsTheRenderedContentOnly() async throws {
        try await fixture.makeBrain()
        let base = try await fixture.makeRepo()
        let first = try await prepare(tasks: [task(base)])
        let again = try await prepare(tasks: [task(base)])
        #expect(first.setups[1].layer?.overlayHash == again.setups[1].layer?.overlayHash)
        #expect(first.evalID != again.evalID)

        // A brain commit that doesn't change the layer's output: same hash, new commit recorded.
        try fixture.write("README.md", "brain\n", in: fixture.brain)
        await fixture.commitAll(fixture.brain)
        let unrelated = try await prepare(tasks: [task(base)])
        #expect(unrelated.setups[1].layer?.overlayHash == first.setups[1].layer?.overlayHash)
        #expect(unrelated.brainCommit != first.brainCommit)

        // A changed template: a new hash; the baseline's stays.
        try fixture.write("layers/swiftui/templates/swiftui.md", "- LAYER-MARKER, changed\n", in: fixture.brain)
        await fixture.commitAll(fixture.brain)
        let changed = try await prepare(tasks: [task(base)])
        #expect(changed.setups[1].layer?.overlayHash != first.setups[1].layer?.overlayHash)
        #expect(changed.setups[0].layer?.overlayHash == first.setups[0].layer?.overlayHash)
    }

    @Test func dirtyBrainRefusesOnlyInTheLayersItUses() async throws {
        try await fixture.makeBrain()
        let base = try await fixture.makeRepo()
        try fixture.write("layers/solo/templates/solo.md", "- changed\n", in: fixture.brain)
        _ = try await prepare(tasks: [task(base)])
        try fixture.write("layers/base/templates/base.md", "- changed\n", in: fixture.brain)
        let dirty = await message { _ = try await prepare(tasks: [task(base)]) }
        #expect(dirty?.contains("uncommitted changes in layers/base/templates/base.md") == true)
        try fixture.write("skills/swiftui-expert/new.md", "x\n", in: fixture.brain)
        await fixture.git("checkout", "--", "layers/base", in: fixture.brain)
        let skill = await message { _ = try await prepare(tasks: [task(base)]) }
        #expect(skill?.contains("skills/swiftui-expert") == true)
    }

    @Test func answersPrecedenceAndRequiredFields() async throws {
        try await fixture.makeBrain(swiftuiYAML: """
            requires: [base]
            fields:
              - id: ui_check
                default: make snapshot
              - id: company
                required: true
            files:
              - template: swiftui.md
                to: AGENTS.md

            """)
        try fixture.write("layers/swiftui/templates/swiftui.md", "- LAYER-MARKER {{ui_check}} for {{company}}\n", in: fixture.brain)
        await fixture.commitAll(fixture.brain)
        let base = try await fixture.makeRepo()
        func section(_ prepared: LayerSetups.Prepared) -> String {
            let hash = prepared.setups[1].layer?.overlayHash ?? ""
            return String(decoding: prepared.overlays[hash]?.contents["AGENTS.md"] ?? Data(), as: UTF8.self)
        }

        let missing = await message { _ = try await prepare(tasks: [task(base)]) }
        #expect(missing?.contains("(company) is required by swiftui") == true)
        #expect(missing?.hasSuffix("Set it with --answer, or answer it for the project in Brain → Set Up Project….") == true)
        // An empty explicit answer keeps the default.
        let defaults = try await prepare(tasks: [task(base)], answers: ["company": .text("Acme"), "ui_check": .text("")])
        #expect(section(defaults).contains("make snapshot for Acme"))

        // The project's saved answers (it was set up through AKit) beat the defaults; explicit ones beat both.
        let store = ProjectStore.local(home: fixture.home)
        let id = await ProjectRecords.projectID(for: fixture.repo, projectsRoot: fixture.home, env: env)
        try ProjectRecords.save(ProjectRecords.Lock(brainCommit: nil, brainDirty: false, files: [:]),
                                answers: ProjectAnswers(layers: ["swiftui"], values: ["ui_check": .text("make check"), "company": .text("Saved")]),
                                id: id, in: store)
        let saved = try await prepare(tasks: [task(base)], store: store)
        #expect(section(saved).contains("make check for Saved"))
        let explicit = try await prepare(tasks: [task(base)], answers: ["company": .text("Given")], store: store)
        #expect(section(explicit).contains("make check for Given"))
    }

    @Test func refusedLayersAgentsAndTaskSets() async throws {
        try await fixture.makeBrain()
        let base = try await fixture.makeRepo()
        // Pi, the core layer, tasks of two repositories.
        let pi = await message { _ = try await prepare(tasks: [task(base)], agent: LabAgent(harness: .pi, model: "m", effort: "low")) }
        #expect(pi?.contains("Claude Code only") == true)
        #expect(await message { _ = try await prepare("core", tasks: [task(base)]) }?.contains("core layer") == true)
        let other = task(base, id: "other-abcd", repo: fixture.home.appending(path: "other"))
        #expect(await message { _ = try await prepare(tasks: [task(base), other]) }?.contains("one repository") == true)

        // A layer that merges keys into .mcp.json is refused in v1; a .json inside a skill isn't.
        try fixture.write("layers/mcp/layer.yaml", "files:\n  - template: m.json\n    to: .mcp.json\n", in: fixture.brain)
        try fixture.write("layers/mcp/templates/m.json", #"{"mcpServers": {"x": {"command": "x"}}}"#, in: fixture.brain)
        try fixture.write("layers/tsconfig/layer.yaml", "files:\n  - template: t.json\n    to: tsconfig.json\n", in: fixture.brain)
        try fixture.write("layers/tsconfig/templates/t.json", "{}", in: fixture.brain)
        await fixture.commitAll(fixture.brain)
        #expect(await message { _ = try await prepare("mcp", tasks: [task(base)]) }?.contains("merges keys into .mcp.json") == true)
        let whole = try await prepare("tsconfig", tasks: [task(base)])
        let hash = try #require(whole.setups[1].layer?.overlayHash)
        #expect(whole.overlays[hash]?.entries.map(\.kind) == [.file])
        // No requires: nothing written on the baseline side.
        #expect(whole.setups[0].layer?.overlayHash == nil && whole.overlays.count == 1)
    }

    @Test func blockedTasksAndOverlap() async throws {
        try await fixture.makeBrain()
        let plain = try await fixture.makeRepo()
        // A later commit that tracks its own .claude/skills/swiftui-expert: overlap, and the
        // project's own .claude/skills folder blocks the task.
        try fixture.write(".claude/skills/swiftui-expert/SKILL.md", "own\n", in: fixture.repo)
        await fixture.commitAll(fixture.repo)
        let withSkills = try #require(await fixture.git("rev-parse", "HEAD", in: fixture.repo))
        let prepared = try await prepare(tasks: [task(plain), task(withSkills, id: "own-skills-abcd")], sanity: true,
                                         homeSkills: ["swiftui-expert", "unrelated"])
        #expect(prepared.runnable.map(\.id) == ["make-value-2-abcd"])
        #expect(prepared.blocked["own-skills-abcd"]?.contains("own .claude/skills folder") == true)
        #expect(prepared.overlap.count == 2)
        #expect(prepared.overlap.contains { $0.hasPrefix("swiftui-expert is already installed in the home folder") })
        #expect(prepared.overlap.contains { $0.contains("already in the project (at \(withSkills.prefix(7)))") })
        #expect(prepared.sanityTasks.map(\.id) == ["make-value-2-abcd"])
    }

    @Test func continueReusesTheSetupsUntilTheLayerChanges() async throws {
        try await fixture.makeBrain()
        let base = try await fixture.makeRepo()
        let first = task(base)
        try ControlTasks.save(first, env: env)
        let prepared = try await prepare(tasks: [first], sanity: true)
        let manifest = try LayerEvalStore.create(prepared, repeats: 3, now: Date(timeIntervalSince1970: 1_800_000_000), env: env)
        #expect(LayerEvalStore.manifest(prepared.evalID, env: env) == manifest)
        #expect(LayerEvalStore.latest(of: "swiftui", agent: claude, env: env)?.id == prepared.evalID)
        let stored = try LayerEvalStore.overlay(hash: try #require(prepared.setups[1].layer?.overlayHash), eval: prepared.evalID, env: env)
        #expect(stored == prepared.overlays[stored.hash])

        // A brain commit elsewhere: Continue keeps the setups verbatim (first brain commit) and the eval's tasks only.
        try fixture.write("README.md", "brain\n", in: fixture.brain)
        await fixture.commitAll(fixture.brain)
        let added = task(base, id: "added-later-abcd")
        try ControlTasks.save(added, env: env)
        let continued = try await prepare(tasks: [first, added], continuing: prepared.evalID)
        #expect(continued.continuing && continued.evalID == prepared.evalID && continued.setups == prepared.setups)
        #expect(continued.sanitySetup == prepared.sanitySetup && continued.runnable.map(\.id) == [first.id])
        #expect(try LayerEvalStore.create(continued, repeats: 3, env: env) == manifest)

        // The layer changed: refused.
        try fixture.write("layers/swiftui/templates/swiftui.md", "- LAYER-MARKER, changed\n", in: fixture.brain)
        await fixture.commitAll(fixture.brain)
        let refused = await message { _ = try await prepare(tasks: [first], continuing: prepared.evalID) }
        #expect(refused?.contains("start a new eval") == true)

        // A newer AKit's eval is skipped with the install advice.
        let file = EvalPaths(env: env).layerEval(prepared.evalID).appending(path: "manifest.json")
        try Data(#"{"schema": 2}"#.utf8).write(to: file)
        #expect(LayerEvalStore.manifest(prepared.evalID, env: env) == nil)
        #expect(LayerEvalStore.problem(prepared.evalID, env: env)?.contains("newer AKit") == true)
    }
}
