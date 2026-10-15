import AKitBrain
import AKitFoundation
@testable import AKitReview
import Foundation
import Testing

struct ConfigEditorTests {
    func brain(_ home: TempHome) -> URL {
        let brain = home.url.appending(path: "brain")
        home.write("brain/README.md", "brain\n")
        home.git(brain, "init", "-q", "-b", "main")
        home.git(brain, "add", "README.md")
        home.git(brain, "commit", "-q", "-m", "Start")
        return brain
    }

    @Test func builtInsGoToTheBrainOnceAndAreNotALayer() async throws {
        let home = TempHome()
        let root = brain(home)
        let written = try await ReviewConfigEditor.addBuiltIns(brain: root, env: home.env)
        #expect(written.contains("layers/review/skills/review-security/SKILL.md"))
        #expect(written.contains("layers/review/scenarios/bugfix.yaml") && written.contains("layers/review/review.yaml"))
        #expect(home.git(root, "log", "--oneline", "-1").contains("Review: add the first roles and scenarios"))
        #expect(home.git(root, "status", "--porcelain").isEmpty)
        #expect(try await ReviewConfigEditor.addBuiltIns(brain: root, env: home.env).isEmpty)
        let catalog = ReviewCatalog.load(home: home.url, brain: root)
        #expect(catalog.problems.isEmpty, "\(catalog.problems)")
        #expect(catalog.roles.allSatisfy { $0.source == .brain })
        // The brain doesn't take layers/review for a project layer, and the name is reserved.
        let loaded = try #require(Brain.load(from: root))
        #expect(!loaded.layers.contains { $0.name == "review" })
        #expect(!loaded.problems.contains { $0.message.contains("layers/review") })
        #expect(LayerWriter.nameProblem("review", in: loaded) != nil)
    }

    @Test func editsShowADiffAndAreCommitted() async throws {
        let home = TempHome()
        let root = brain(home)
        try await ReviewConfigEditor.addBuiltIns(brain: root, env: home.env)
        let old = try #require(ReviewBuiltIns.roleFiles["security"])
        let new = old.replacingOccurrences(of: "max_findings: 3", with: "max_findings: 2")
        let save = try ReviewConfigEditor.plan(.role, id: "security", text: new, level: .brain, home: home.url, brain: root)
        #expect(save.diff.contains("-   max_findings: 3") && save.diff.contains("+   max_findings: 2"))
        #expect(save.workWords.isEmpty, "a personal Mac has no work words to check")
        try await ReviewConfigEditor.apply(save, brain: root, env: home.env)
        #expect(home.git(root, "log", "--oneline", "-1").contains("Review: edit role security"))
        #expect(ReviewCatalog.load(home: home.url, brain: root).roles.first { $0.id == "security" }?.maxFindings == 2)

        #expect(throws: ReviewRole.Failure.self) {
            try ReviewConfigEditor.plan(.role, id: "security", text: "---\nname: review-security\nakit-review:\n  max_findings: 99\n---\n",
                                        level: .brain, home: home.url, brain: root)
        }
        #expect(throws: ReviewConfigEditor.Failure.self) {
            try ReviewConfigEditor.plan(.role, id: "tests", text: new, level: .brain, home: home.url, brain: root)
        }
    }

    @Test func projectCopiesAndResetToBrain() async throws {
        let home = TempHome()
        let root = brain(home)
        home.write(".akit/local/review/projects/orders.yaml", "gitlab: { host: https://gitlab.corp.example, project_path: team/orders-service }\n")
        let catalog = ReviewCatalog.load(home: home.url, brain: root)
        var save = try ReviewConfigEditor.duplicate(.role, id: "tests", toProject: "orders", catalog: catalog, home: home.url, brain: root)
        save.new = save.new.replacingOccurrences(of: "max_findings: 3", with: "max_findings: 1")
        try await ReviewConfigEditor.apply(save, brain: root, env: home.env)
        let profile = try #require(ReviewCatalog.load(home: home.url, brain: root).profiles.first)
        let roles = ReviewCatalog.load(home: home.url, brain: root).roles(for: profile)
        #expect(roles.first { $0.id == "tests" }?.source == .project)
        #expect(roles.first { $0.id == "tests" }?.maxFindings == 1)

        var trashed: [URL] = []
        try ReviewConfigEditor.resetToBrain(.role, id: "tests", project: "orders", home: home.url, brain: root, trash: { url in
            trashed.append(url)
            try FileManager.default.removeItem(at: url)
            return nil
        })
        #expect(trashed.first?.lastPathComponent == "review-tests")
        #expect(ReviewCatalog.load(home: home.url, brain: root).roles(for: profile).first { $0.id == "tests" }?.source == .builtIn)
    }

    @Test func aWorkMacSeesItsWorkWords() throws {
        let home = TempHome()
        home.write(".akit/machine.json", #"{"kind":"work"}"#)
        home.write(".akit/local/review/projects/orders.yaml", """
        project: orders-service
        gitlab: { host: https://gitlab.corp.example, project_path: team/orders-service }
        tracker: { org: corpx, project: Orders }
        """)
        let text = (ReviewBuiltIns.roleFiles["domain"] ?? "") + "\nCheck queues of orders-service at gitlab.corp.example; ask jane@corp.example.\n"
        let save = try ReviewConfigEditor.plan(.role, id: "domain", text: text, level: .brain, home: home.url, brain: home.url.appending(path: "brain"))
        #expect(save.workWords.contains("gitlab.corp.example") && save.workWords.contains("orders-service"))
        #expect(save.workWords.contains("jane@corp.example"))
        // A project copy stays on this Mac: no warning.
        let local = try ReviewConfigEditor.plan(.role, id: "domain", text: text, level: .project("orders"), home: home.url,
                                                brain: home.url.appending(path: "brain"))
        #expect(local.workWords.isEmpty)
    }
}
