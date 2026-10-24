import Foundation
import Testing
import AKitFoundation
@testable import AKitKnowledge

/// Lint (4.1): the fixture `Fixtures/lint-base` (no git, read by #filePath) has one finding of each
/// rule and two hints; bases written in a temporary fake home check the known projects, the clean
/// case and the R-SEP hint.
struct KnowledgeLintTests {
    static let fixture = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/lint-base")
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = URL(filePath: FileWalk.realPath(fm.temporaryDirectory) ?? fm.temporaryDirectory.path)
            .appending(path: "akit-kb-lint-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    func write(_ text: String, _ path: String, in root: URL) throws {
        let url = root.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test func theFixtureHasOneFindingOfEachRule() throws {
        // missing-file.md's repo is ~/Library, as on every Mac.
        try fm.createDirectory(at: home.appending(path: "Library"), withIntermediateDirectories: true)
        let findings = KnowledgeLint.run(KnowledgeBase(root: Self.fixture), projects: .init(), home: home)
        let summary = findings.map { "\($0.severity.rawValue) \($0.rule.rawValue) \($0.file) \($0.element ?? "-") \($0.link ?? "-")" }
        #expect(summary == [
            "error broken-link areas/shop/links.md - [[no-such-note]]",
            "error map-parse areas/shop/maps/broken.excalidraw - -",
            "warning missing-home-path areas/shop/home-path.md - ~/akit-lint-fixture-missing/notes.txt",
            "warning ambiguous-link areas/shop/links.md - [[status]]",
            "warning unbound-arrow areas/shop/maps/blocks.excalidraw arr-loose -",
            "warning block-without-note areas/shop/maps/blocks.excalidraw blk-draft -",
            "warning missing-file areas/shop/missing-file.md - akit-lint-fixture/no-such-file.txt",
            "warning unknown-repo areas/shop/unknown-repo.md - git@example.com:lint/no-such-repo.git",
            "hint unknown-kind areas/shop/gadget.md - gadget",
            "hint unrelated-area areas/shop/maps/blocks.excalidraw blk-thing other/thing",
        ])
        let rules = findings.filter { $0.severity != .hint }.map(\.rule)
        #expect(rules.count == 8 && Set(rules) == Set(KnowledgeLint.Rule.allCases.filter { $0.severity != .hint }))
        #expect(findings.allSatisfy { $0.fix != nil && !$0.message.isEmpty })
        #expect(KnowledgeLint.counts(findings) == .init(error: 2, warning: 6, hint: 2))
    }

    @Test func theAnswerEncodesAsTheCLIPrintsIt() throws {
        let finding = KnowledgeLint.Finding(rule: .brokenLink, file: "areas/a/b.md", link: "[[x]]", message: "m", fix: "f")
        let data = try JSONEncoder().encode(KnowledgeLint.Answer(base: "/b", findings: [finding]))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["base"] as? String == "/b")
        #expect((object["counts"] as? [String: Int]) == ["error": 1, "warning": 0, "hint": 0])
        let first = try #require((object["findings"] as? [[String: Any]])?.first)
        #expect(first["rule"] as? String == "broken-link" && first["severity"] as? String == "error" && first["link"] as? String == "[[x]]")
        #expect(first["element"] == nil)
    }

    @Test func aCleanBaseHasNoFindings() throws {
        let base = home.appending(path: "base")
        let repo = home.appending(path: "Projects/orders-api")
        try write("[core]\n\tbare = false\n[remote \"origin\"]\n\turl = git@example.com:Shop/orders-api.git\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n",
                  ".git/config", in: repo)
        try write("x\n", "src/a.ts", in: repo)
        try write("projects: [git@example.com:shop/billing.git, ~/Projects/pay-*]\n", "areas/pay/area.yaml", in: base)
        try write("---\nkind: service\nrepo: https://example.com/shop/orders-api\nfiles: [src/a.ts]\n---\n# api\n\nSee [[billing]] and [[pay/maps/m]], ![[shot.png]], https://example.com.\n",
                  "areas/pay/api.md", in: base)
        try write("---\nkind: service\nrepo: git@example.com:shop/billing.git\nfiles: [src/not/checked.ts]\n---\n# billing\n", "areas/pay/billing.md", in: base)
        try write(NewMap.scene(elements: NewMap.block(.init(id: "b1", x: 0, y: 0), label: "api", link: "[[api]]", arrows: ["a1"])
                    + NewMap.block(.init(id: "b2", x: 400, y: 0), label: "billing", link: "[[billing]]", arrows: ["a1"])
                    + NewMap.arrow("a1", from: .init(id: "b1", x: 0, y: 0), to: .init(id: "b2", x: 400, y: 0), label: "calls", link: nil)
                    + NewMap.block(.init(id: "b3", x: 0, y: 300), label: "docs", link: "https://example.com/docs")),
                  "areas/pay/maps/m.excalidraw", in: base)
        let projects = KnowledgeLint.Projects.find(home: home, projectsRoot: home.appending(path: "Projects"), brainRoot: nil)
        #expect(projects.copies == ["example.com/shop/orders-api": repo])
        #expect(KnowledgeLint.run(KnowledgeBase(root: base), projects: projects, home: home) == [])

        // The file gone from the local copy: missing-file; the repo unknown without the clone.
        try fm.removeItem(at: repo.appending(path: "src/a.ts"))
        #expect(KnowledgeLint.run(KnowledgeBase(root: base), projects: projects, home: home).map(\.rule) == [.missingFile])
        #expect(KnowledgeLint.run(KnowledgeBase(root: base), projects: .init(), home: home).map(\.rule) == [.unknownRepo])
    }

    @Test func knownProjectsComeFromTheProjectsRootAndTheProjectStores() throws {
        let root = home.appending(path: "Projects")
        try write("[remote \"origin\"]\n  url = ssh://git@example.com/group/one.git\n", ".git/config", in: root.appending(path: "one"))
        // One folder below, and a worktree's .git file pointing into the main repo.
        try write("[remote \"upstream\"]\n\turl = git@example.com:x/y.git\n[remote \"origin\"]\n\turl = https://example.com/group/two\n",
                  ".git/config", in: root.appending(path: "group/two"))
        try write("gitdir: \(root.path)/group/two/.git/worktrees/wt\n", ".git", in: root.appending(path: "wt"))
        try fm.createDirectory(at: root.appending(path: "group/two/.git/worktrees/wt"), withIntermediateDirectories: true)
        try write("{}", "github.com/me/brain-project/lock.json", in: home.appending(path: "brain/projects"))
        try write("{}", "example.com/work/app/answers.json", in: home.appending(path: ".akit/local/projects"))
        let projects = KnowledgeLint.Projects.find(home: home, projectsRoot: root, brainRoot: home.appending(path: "brain"))
        #expect(projects.copies["example.com/group/one"] == root.appending(path: "one"))
        #expect(projects.copies["example.com/group/two"] == root.appending(path: "group/two"))
        #expect(projects.known.isSuperset(of: ["example.com/group/one", "example.com/group/two", "github.com/me/brain-project", "example.com/work/app"]))
        #expect(!projects.known.contains("example.com/x/y"))
    }

    @Test func unrelatedAreasAreAHintUntilAMapJumpsBetweenThem() throws {
        let base = home.appending(path: "base")
        try write("# a\n", "areas/one/a.md", in: base)
        try write("# b\n", "areas/two/b.md", in: base)
        let map = "areas/one/maps/m.excalidraw"
        try write(NewMap.scene(elements: NewMap.block(.init(id: "blk", x: 0, y: 0), label: "b", link: "[[two/b]]")), map, in: base)
        let first = KnowledgeLint.run(KnowledgeBase(root: base), projects: .init(), home: home)
        #expect(first.map { "\($0.rule.rawValue) \($0.severity.rawValue) \($0.element ?? "")" } == ["unrelated-area hint blk"])
        // A map of two that jumps to one's map relates the areas.
        try write(NewMap.scene(elements: NewMap.block(.init(id: "jmp", x: 0, y: 0), label: "one", link: "[[one/maps/m]]")),
                  "areas/two/maps/n.excalidraw", in: base)
        #expect(KnowledgeLint.run(KnowledgeBase(root: base), projects: .init(), home: home) == [])
    }

    @Test func createNoteTargetsOfBrokenLinks() {
        func target(_ link: String, _ file: String = "areas/pay/x.md") -> String? {
            KnowledgeLint.newNote(for: .init(rule: .brokenLink, file: file, link: link, message: ""))
                .map { "\($0.area)/\($0.name)" }
        }
        #expect(target("[[refunds]]") == "pay/refunds")
        #expect(target("[[ship/carrier#API|the carrier]]") == "ship/carrier")
        #expect(target("akit:note/ship/flows/pick") == "ship/pick")
        #expect(target("[[refunds]]", "areas/ship/maps/m.excalidraw") == "ship/refunds")
        #expect(target("[[maps/nope]]") == nil)
        #expect(target("akit:map/pay/maps/nope") == nil)
        #expect(KnowledgeLint.newNote(for: .init(rule: .ambiguousLink, file: "areas/pay/x.md", link: "[[a]]", message: "")) == nil)
    }
}
