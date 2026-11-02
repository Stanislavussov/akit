import AKitFoundation
@testable import AKitReview
import Foundation
import Testing

/// The roles of a scenario edited without YAML, and roles named by their skill name.
struct ScenarioRolesTests {
    let feature = try! ReviewScenario.parse((ReviewBuiltIns.scenarioFiles["feature"] ?? "") + "\n", source: .builtIn)

    @Test func addingMovingAndRemovingKeepTheRestOfTheFile() throws {
        let added = try ReviewScenarioRoles.adding("test", required: false, to: feature)
        let parsed = try ReviewScenario.parse(added, source: .brain)
        #expect(parsed.optional.last == "test")
        #expect(parsed.required == feature.required)
        #expect(parsed.checks == feature.checks, "checks stay")
        #expect(added.contains("detect:"), "lines the parser ignores stay")

        let required = try ReviewScenario.parse(try ReviewScenarioRoles.adding("test", required: true, to: parsed), source: .brain)
        #expect(required.required.last == "test")
        #expect(!required.optional.contains("test"), "moved, not doubled")

        let up = try ReviewScenario.parse(try ReviewScenarioRoles.moving("test", by: -1, in: required), source: .brain)
        #expect(up.required.suffix(2) == ["test", feature.required.last!])
        let top = try ReviewScenario.parse(try ReviewScenarioRoles.moving("contracts", by: -1, in: up), source: .brain)
        #expect(top.required.first == "contracts", "the first stays first")

        let removed = try ReviewScenario.parse(try ReviewScenarioRoles.removing("test", from: up), source: .brain)
        #expect(removed.required == feature.required)
        #expect(throws: ReviewScenarioRoles.Failure.self) { try ReviewScenarioRoles.removing("nope", from: removed) }
    }

    @Test func theLastRequiredRoleStays() throws {
        let one = try ReviewScenario.parse(ReviewTemplates.scenario("hotfix"), source: .brain)
        #expect(throws: ReviewScenarioRoles.Failure.self) { try ReviewScenarioRoles.removing("bug-hunter", from: one) }
        #expect(throws: ReviewScenarioRoles.Failure.self) { try ReviewScenarioRoles.setting(required: ["../x"], optional: [], in: one.text) }
    }

    @Test func aBlockWithBlankLinesIsReplacedWholeAndTheNextKeyStays() throws {
        let text = "id: x\nroles:\n  required:\n    - a\n\n  optional:\n    - b\n\n# checks next\nchecks:\n  - \"q\"\n"
        let scenario = try ReviewScenario.parse(text, source: .brain)
        let edited = try ReviewScenarioRoles.adding("c", required: true, to: scenario)
        let parsed = try ReviewScenario.parse(edited, source: .brain)
        #expect(parsed.required == ["a", "c"])
        #expect(parsed.optional == ["b"])
        #expect(parsed.checks == ["q"])
        #expect(edited.contains("# checks next"), "a comment before the next key stays")
    }

    @Test func noScenarioIsLeftWithoutARequiredRole() throws {
        let one = try ReviewScenario.parse(ReviewTemplates.scenario("hotfix"), source: .brain)
        #expect(throws: ReviewScenarioRoles.Failure.self) { try ReviewScenarioRoles.adding("bug-hunter", required: false, to: one) }
    }

    @Test func usesListTheScenariosOfARole() {
        let catalog = ReviewCatalog.load(home: TempHome().url, brain: nil)
        let uses = ReviewScenarioRoles.uses(of: "security", in: catalog.scenarios)
        #expect(uses.contains { $0.scenario.id == "security" && $0.required })
        #expect(uses.contains { $0.scenario.id == "feature" && !$0.required })
    }

    @Test func aSkillNameInAScenarioMeansTheRole() throws {
        let scenario = try ReviewScenario.parse("id: x\nroles: { required: [review-test, bug-hunter], optional: [review-security] }\n", source: .brain)
        #expect(scenario.required == ["test", "bug-hunter"])
        #expect(scenario.optional == ["security"])
    }

    @Test func aNewBrainRoleRunsWhenAScenarioNamesIt() throws {
        let home = TempHome()
        let brain = home.url.appending(path: "brain")
        home.write("brain/layers/review/skills/review-test/SKILL.md", ReviewTemplates.role("test"))
        home.write("brain/layers/review/scenarios/feature.yaml", try ReviewScenarioRoles.adding("review-test", required: true, to: feature))
        let catalog = ReviewCatalog.load(home: home.url, brain: brain)
        #expect(catalog.problems.isEmpty)
        let resolved = try ReviewResolver.resolve(catalog: catalog, profile: nil, choices: ReviewRunChoices(), mergeRequest: FakeMergeRequest.ref, id: "r1")
        #expect(resolved.roles.map(\.id).contains("test"))
    }

    @Test func turnedOnRolesRunInTheScenarioOrder() throws {
        let catalog = ReviewCatalog.load(home: TempHome().url, brain: nil)
        let choices = ReviewRunChoices(scenario: "feature", rolesOn: ["history", "tests", "security"])
        let resolved = try ReviewResolver.resolve(catalog: catalog, profile: nil, choices: choices, mergeRequest: FakeMergeRequest.ref, id: "r1")
        #expect(Array(resolved.roles.map(\.id).suffix(3)) == ["tests", "security", "history"])
    }

    @Test func aSaveSaysWhereAProjectOnlyRoleLives() throws {
        let home = TempHome()
        let brain = home.url.appending(path: "brain")
        home.write("brain/README.md", "brain\n")
        home.write(".akit/local/review/projects/shop.yaml", "gitlab: { host: https://g, project_path: a/shop }\nknowledge: []\n")
        home.write(".akit/local/review/projects/shop/skills/review-orders/SKILL.md", ReviewTemplates.role("orders"))
        let text = try ReviewScenarioRoles.adding("orders", required: false, to: feature)
        let save = try ReviewConfigEditor.plan(.scenario, id: "feature", text: text, level: .brain, home: home.url, brain: brain)
        #expect(save.notes.contains { $0.contains("project role of shop") })
        let inProject = try ReviewConfigEditor.plan(.scenario, id: "feature", text: text, level: .project("shop"), home: home.url, brain: brain)
        #expect(!inProject.notes.contains { $0.contains("orders") })
    }
}
