import AKitFoundation
import AKitLab
@testable import AKitReview
import Foundation
import Testing

/// Delete… for roles and scenarios, `skills:` links, and Write with AI… for scenarios.
struct DeleteAndLinksTests {
    func brain(_ home: TempHome) -> URL {
        let brain = home.url.appending(path: "brain")
        home.write("brain/README.md", "brain\n")
        home.git(brain, "init", "-q", "-b", "main")
        home.git(brain, "add", "README.md")
        home.git(brain, "commit", "-q", "-m", "Start")
        return brain
    }

    /// A fake Trash that removes the item and records it.
    final class FakeTrash: @unchecked Sendable {
        var moved: [URL] = []
        func move(_ url: URL) throws -> URL? {
            moved.append(url)
            try FileManager.default.removeItem(at: url)
            return nil
        }
    }

    @Test func linkingSetsAndTakesOutSkillsAndKeepsTheRest() throws {
        let role = try #require(ReviewBuiltIns.roleFiles["security"])
        let linked = try ReviewSkillLinks.setting(["house-style", "swift.rules"], kind: .role, in: role)
        #expect(try ReviewRole.parse(linked, source: .brain).skills == ["house-style", "swift.rules"])
        #expect(ReviewYAML.body(linked) == ReviewYAML.body(role), "the checklist stays")
        #expect(try ReviewSkillLinks.setting([], kind: .role, in: linked) == role)

        let scenario = try #require(ReviewBuiltIns.scenarioFiles["bugfix"]) + "\n"
        let withSkill = try ReviewSkillLinks.setting(["house-style"], kind: .scenario, in: scenario)
        #expect(try ReviewScenario.parse(withSkill, source: .brain).skills == ["house-style"])
        #expect(try ReviewSkillLinks.setting([], kind: .scenario, in: withSkill) == scenario)

        #expect(throws: ReviewSkillLinks.Failure.self) { try ReviewSkillLinks.setting(["../etc"], kind: .role, in: role) }
        #expect(throws: ReviewRole.Failure.self) { try ReviewScenario.parse("id: x\nskills: [review-security]\n", source: .brain) }
    }

    @Test func deletingABuiltInScenarioTakesItsOwnRolesAndHidesThem() async throws {
        let home = TempHome()
        let root = brain(home)
        home.write(".akit/local/review/projects/shop.yaml",
                   "gitlab: { host: https://g, project_path: a/shop }\ndefault_scenario: dependency-upgrade   # ours\nknowledge: []\n")
        home.write(".akit/local/review/projects/shop/scenarios/dependency-upgrade.yaml",
                   "id: dependency-upgrade\nroles: { required: [upgrade-risk] }\n")
        home.write(".akit/local/review/projects/shop/skills/review-upgrade-risk/SKILL.md",
                   (ReviewBuiltIns.roleFiles["upgrade-risk"] ?? ""))
        let catalog = ReviewCatalog.load(home: home.url, brain: root)
        let removal = try ReviewConfigEditor.planDelete(.scenario, id: "dependency-upgrade", level: .brain, catalog: catalog,
                                                        home: home.url, brain: root)
        #expect(removal.roles == ["upgrade-risk"], "tests, contracts, security and performance serve other scenarios")
        #expect(Set(removal.kept) == ["tests", "contracts", "security", "performance"])
        #expect(removal.trash.map(\.lastPathComponent).sorted() == ["dependency-upgrade.yaml", "review-upgrade-risk"])
        #expect(removal.edits.count == 2)
        #expect(ReviewConfigEditor.describe(removal).contains { $0.contains("upgrade-risk") })

        let trash = FakeTrash()
        try await ReviewConfigEditor.applyDelete(removal, brain: root, env: home.env, trash: trash.move)
        #expect(home.git(root, "log", "--oneline", "-1").contains("Review: delete scenario dependency-upgrade and roles upgrade-risk"))
        #expect(home.git(root, "status", "--porcelain").isEmpty)
        let after = ReviewCatalog.load(home: home.url, brain: root)
        #expect(after.problems.isEmpty, "\(after.problems)")
        #expect(!after.scenarios.contains { $0.id == "dependency-upgrade" } && !after.roles.contains { $0.id == "upgrade-risk" })
        #expect(after.roles.contains { $0.id == "tests" })
        let profile = try #require(after.profiles.first)
        #expect(profile.defaultScenario == nil && profile.knowledge.isEmpty)
        // Add to Brain doesn't bring them back.
        let written = try await ReviewConfigEditor.addBuiltIns(brain: root, env: home.env)
        #expect(!written.contains { $0.contains("upgrade") })
        #expect(!ReviewCatalog.load(home: home.url, brain: root).roles.contains { $0.id == "upgrade-risk" })
    }

    @Test func aDeletedRoleIsSkippedWhereItIsStillNamed() async throws {
        let home = TempHome()
        let root = brain(home)
        let catalog = ReviewCatalog.load(home: home.url, brain: root)
        for id in ["architecture", "contracts"] {
            let removal = try ReviewConfigEditor.planDelete(.role, id: id, level: .brain, catalog: ReviewCatalog.load(home: home.url, brain: root),
                                                            home: home.url, brain: root)
            #expect(removal.trash.isEmpty && removal.edits.count == 1, "a built-in role: only removed: changes")
            try await ReviewConfigEditor.applyDelete(removal, brain: root, env: home.env)
        }
        #expect(catalog.roles.contains { $0.id == "architecture" })
        let after = ReviewCatalog.load(home: home.url, brain: root)
        #expect(after.removedRoles == ["architecture", "contracts"])
        let spec = try ReviewResolver.resolve(catalog: after, profile: nil, choices: ReviewRunChoices(), mergeRequest: FakeMergeRequest.ref, id: "x").spec
        #expect(spec.scenario.value == "feature")
        #expect(!spec.roles.contains { $0.id == "architecture" || $0.id == "contracts" })
        #expect(spec.rolesOff?.contains("contracts") == true, "R44 never adds a deleted contracts role back")
        // A deleted feature scenario: the first one left is the default.
        try await ReviewConfigEditor.applyDelete(try ReviewConfigEditor.planDelete(.scenario, id: "feature", level: .brain, withRoles: false,
                                                                                   catalog: after, home: home.url, brain: root), brain: root, env: home.env)
        let fallback = try ReviewResolver.resolve(catalog: ReviewCatalog.load(home: home.url, brain: root), profile: nil, choices: ReviewRunChoices(),
                                                  mergeRequest: FakeMergeRequest.ref, id: "y").spec
        #expect(fallback.scenario.value == "bugfix")
        #expect(throws: ReviewConfigEditor.Failure.self) {
            try ReviewConfigEditor.planDelete(.role, id: "nope", level: .brain, catalog: after, home: home.url, brain: root)
        }
    }

    @Test func aProjectDeletesOnlyItsOwnItems() throws {
        let home = TempHome()
        let root = brain(home)
        home.write(".akit/local/review/projects/shop.yaml", "gitlab: { host: https://g, project_path: a/shop }\ndefault_scenario: payments\n")
        home.write(".akit/local/review/projects/shop/scenarios/payments.yaml",
                   "id: payments\nroles: { required: [money, bug-hunter], optional: [ledger] }\n")
        home.write(".akit/local/review/projects/shop/skills/review-money/SKILL.md", ReviewTemplates.role("money"))
        home.write(".akit/local/review/projects/shop/skills/review-ledger/SKILL.md", ReviewTemplates.role("ledger"))
        home.write(".akit/local/review/projects/shop/skills/review-tests/SKILL.md", ReviewBuiltIns.roleFiles["tests"] ?? "")
        let catalog = ReviewCatalog.load(home: home.url, brain: root)
        let removal = try ReviewConfigEditor.planDelete(.scenario, id: "payments", level: .project("shop"), catalog: catalog, home: home.url, brain: root)
        #expect(removal.roles.sorted() == ["ledger", "money"], "bug-hunter is the brain's")
        #expect(removal.trash.map(\.lastPathComponent).sorted() == ["payments.yaml", "review-ledger", "review-money"])
        #expect(removal.edits.map(\.file.lastPathComponent) == ["shop.yaml"])
        let kept = try ReviewConfigEditor.planDelete(.scenario, id: "payments", level: .project("shop"), withRoles: false, catalog: catalog,
                                                     home: home.url, brain: root)
        #expect(kept.roles.isEmpty && kept.trash.count == 1)
        // The project's copy of a brain role is reset, not deleted.
        #expect(throws: ReviewConfigEditor.Failure.self) {
            try ReviewConfigEditor.planDelete(.role, id: "tests", level: .project("shop"), catalog: catalog, home: home.url, brain: root)
        }
    }

    @Test func linkedSkillsReachTheRunAndItsPasses() async throws {
        let (home, _) = try ReviewProcessTests.GatherTests().setUp()
        let root = home.url.appending(path: "brain")
        home.write(".claude/skills/house-style/SKILL.md", "---\nname: house-style\ndescription: Our rules\n---\nNo force unwraps.\n")
        home.write(".claude/skills/house-style/references/more.md", "More rules.\n")
        home.write(".claude/skills/house-style/big.bin", String(repeating: "x", count: 300 * 1024))
        // The fixture's profile picks bugfix.
        let bugfix = try ReviewSkillLinks.setting(["house-style", "missing-one"], kind: .scenario, in: ReviewBuiltIns.scenarioFiles["bugfix"] ?? "")
        home.write("brain/layers/review/scenarios/bugfix.yaml", bugfix)
        let role = try ReviewSkillLinks.setting(["house-style"], kind: .role, in: ReviewBuiltIns.roleFiles["bug-hunter"] ?? "")
        home.write("brain/layers/review/skills/review-bug-hunter/SKILL.md", role)

        let result = try await ReviewRuns.start(mr: FakeMergeRequest.ref, project: nil, choices: ReviewRunFixture.choices, env: home.env, brain: root)
        let skills = try #require(result.spec.skills)
        #expect(skills.map(\.name) == ["house-style", "missing-one"])
        #expect(skills[0].linkedBy == ["scenario bugfix", "role bug-hunter"] && skills[0].file != nil && skills[1].file == nil)
        #expect(result.spec.roles.first { $0.id == "bug-hunter" }?.skills == ["house-style"])
        #expect(result.gaps.contains { $0.system == "skills" && $0.needed.contains("missing-one") })
        #expect(result.gaps.contains { $0.system == "skills" && $0.why.contains("left out") }, "the big file")
        let folder = ReviewPaths(home: home.url).run(result.spec.id)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "skills/house-style/references/more.md").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "skills/house-style/big.bin").path))

        let run = ReviewRunFixture(home: home, head: "", folder: folder)
        run.playTypicalRun()
        _ = try await ReviewPasses.run(folder: folder, env: home.env)
        let args = run.args("role-bug-hunter")
        #expect(args.contains(folder.appending(path: "skills/house-style").path))
        #expect(!args.contains { $0.contains("missing-one") })
        let prompt = args.joined(separator: "\n")
        #expect(prompt.contains("Skills linked to this check (loaded): `house-style`"), "\(prompt)")
        let env = (try? String(contentsOf: home.url.appending(path: "fake/env-role-bug-hunter.txt"), encoding: .utf8)) ?? ""
        #expect(env.contains(folder.appending(path: "skills").path), "the passes may read the copied skill")
    }

    @Test func piWritesAScenarioFromExistingRolesAndSkills() async throws {
        let answer = """
        ```yaml
        id: i18n-change
        title: Translations
        roles: { required: [domain, tests], optional: [contracts] }
        checks:
          - "Does every new UI string come from the translation files?"
        context_required: [full_files]
        skills: [house-style]
        ```
        """
        let home = try ReviewProcessTests.RoleWriterTests().home(answer: answer)
        home.write(".claude/skills/house-style/SKILL.md", "---\nname: house-style\ndescription: Our rules\n---\nRules.\n")
        let brain = home.url.appending(path: "review")
        #expect(ReviewRoleWriter.skills(brain: brain, home: home.url, for: .scenario).first == .builtInScenario)
        let request = ReviewRoleWriter.Request(kind: .scenario, id: "i18n-change", description: "Text changes must stay translated.", level: .brain)
        let result = try await ReviewRoleWriter.write(request, brain: brain, env: home.env)
        #expect(result.save.kind == .scenario && result.save.new.hasPrefix("id: i18n-change\n") && result.save.notes.isEmpty)
        #expect(result.save.file.lastPathComponent == "i18n-change.yaml")
        let folder = try #require(FileWalk.children(of: ReviewPaths(home: home.url).folder.appending(path: "role-writer")).first)
        let prompt = try String(contentsOf: folder.appending(path: "prompt.md"), encoding: .utf8)
        #expect(prompt.contains("name: review-scenario-writer") && prompt.contains("- house-style: Our rules") && prompt.contains("- bug-hunter:"))
        #expect(SendLog.records(env: home.env).contains { $0.purpose == "review-scenario-writer" })

        // A role the model made up is refused with the draft.
        let other = try ReviewProcessTests.RoleWriterTests().home(answer: answer.replacingOccurrences(of: "domain", with: "made-up"))
        await #expect {
            try await ReviewRoleWriter.write(request, brain: other.url.appending(path: "review"), env: other.env)
        } throws: { error in
            guard let failure = error as? ReviewRoleWriter.Failure else { return false }
            return failure.message.contains("made-up") && failure.draft?.contains("made-up") == true
        }
    }

    /// Guards for the user's rule: roles they made never go by surprise.
    @Test func deletesNeverTakeMoreThanShown() async throws {
        let home = TempHome()
        let root = brain(home)
        home.write(".akit/local/review/projects/shop.yaml", "gitlab: { host: https://g, project_path: a/shop }\n")
        home.write(".akit/local/review/projects/shop/scenarios/payments.yaml", "id: payments\nroles: { required: [money] }\n")
        home.write(".akit/local/review/projects/shop/skills/review-money/SKILL.md", ReviewTemplates.role("money"))
        var catalog = ReviewCatalog.load(home: home.url, brain: root)
        // A project role its scenario still names.
        #expect(throws: ReviewConfigEditor.Failure.self) {
            try ReviewConfigEditor.planDelete(.role, id: "money", level: .project("shop"), catalog: catalog, home: home.url, brain: root)
        }
        // A project-only item isn't deleted from the brain level.
        #expect(throws: ReviewConfigEditor.Failure.self) {
            try ReviewConfigEditor.planDelete(.scenario, id: "payments", level: .brain, catalog: catalog, home: home.url, brain: root)
        }
        // A file AKit can't read: no role goes with a scenario.
        home.write("brain/layers/review/scenarios/broken.yaml", "id: [not valid\n")
        catalog = ReviewCatalog.load(home: home.url, brain: root)
        let safe = try ReviewConfigEditor.planDelete(.scenario, id: "dependency-upgrade", level: .brain, catalog: catalog, home: home.url, brain: root)
        #expect(safe.roles.isEmpty && safe.notes.first?.contains("No role goes with it") == true)
        // The files change after the list was made: nothing is deleted.
        try FileManager.default.removeItem(at: root.appending(path: "layers/review/scenarios/broken.yaml"))
        let plan = try ReviewConfigEditor.planDelete(.scenario, id: "dependency-upgrade", level: .brain, catalog: ReviewCatalog.load(home: home.url, brain: root),
                                                     home: home.url, brain: root)
        #expect(plan.roles == ["upgrade-risk"])
        home.write("brain/layers/review/scenarios/upgrades.yaml", "id: upgrades\nroles: { required: [upgrade-risk] }\n")
        await #expect(throws: ReviewConfigEditor.Failure.self) {
            try await ReviewConfigEditor.applyDelete(plan, brain: root, env: home.env)
        }
        #expect(ReviewCatalog.load(home: home.url, brain: root).scenarios.contains { $0.id == "dependency-upgrade" })
    }

    @Test func aLinkedSkillFolderThatIsALinkIsCopiedWhole() throws {
        let home = TempHome()
        home.write(".agents/skills/house/SKILL.md", "---\nname: house\n---\nSee references/rules.md.\n")
        home.write(".agents/skills/house/references/rules.md", "Rules.\n")
        try FileManager.default.createDirectory(at: home.url.appending(path: ".claude/skills"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.url.appending(path: ".claude/skills/house"), withDestinationURL: home.url.appending(path: ".agents/skills/house"))
        let target = home.url.appending(path: "run/skills/house")
        #expect(ReviewSkillLinks.copy(home.url.appending(path: ".claude/skills/house"), to: target, scrub: .init()) == nil)
        #expect(FileManager.default.fileExists(atPath: target.appending(path: "references/rules.md").path))
    }
}
