import Foundation
import Testing
@testable import AKitCore

/// Which installed skills AKit rendered from the brain, in a temporary folder.
struct BrainLinksTests {
    let root: URL
    let fm = FileManager.default

    init() throws {
        root = fm.temporaryDirectory.appending(path: "akit-links-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func write(_ path: String, _ text: String = "") throws {
        let url = root.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func skill(_ path: String, scope: SkillScope = .global) -> Skill {
        let file = root.appending(path: path)
        return Skill(name: file.deletingLastPathComponent().lastPathComponent, description: "", file: file, realFile: file,
                     isSingleFile: false, scope: scope, visibleTo: [], isReadOnly: false, origin: nil, warnings: [],
                     root: file.deletingLastPathComponent().deletingLastPathComponent())
    }

    @Test func tellsRenderedCopiesFromOwnSkills() throws {
        for name in ["kept", "edited", "twin"] { try write("brain/skills/\(name)/SKILL.md", "brain") }
        try write("brain/layers/web/layer.yaml", "")
        try write("app/.agents/skills/kept/SKILL.md", "rendered")
        try write("app/.agents/skills/edited/SKILL.md", "changed by hand")
        try write("app/.agents/skills/twin/SKILL.md", "not from AKit")
        try write("app/.agents/skills/mine/SKILL.md", "own")
        let sha = Checksum.sha256(Data("rendered".utf8))
        try write("brain/projects/github.com/me/app/answers.json", #"{"layers": ["web"], "values": {}, "targets": []}"#)
        try write("brain/projects/github.com/me/app/lock.json", """
            {"brainDirty": false, "files": {
              ".agents/skills/kept/SKILL.md": {"layers": ["web"], "sha256": "\(sha)"},
              ".agents/skills/edited/SKILL.md": {"layers": ["web"], "sha256": "\(sha)"},
              ".claude/skills": {"layers": [], "link": "../.agents/skills"}}}
            """)
        let brain = try #require(Brain.load(from: root.appending(path: "brain")))
        let app = root.appending(path: "app")
        let skills = ["kept", "edited", "twin", "mine"].map { skill("app/.agents/skills/\($0)/SKILL.md", scope: .project(app)) }
            + [skill("app/.agents/skills/kept/SKILL.md", scope: .plugin(name: "p"))]

        let links = BrainLinks.links(for: skills, brain: brain, folders: ["github.com/me/app": app])
        #expect(links[skills[0].id] == .rendered(skill: "kept", layers: ["web"], edited: false))
        #expect(links[skills[1].id] == .rendered(skill: "edited", layers: ["web"], edited: true))
        #expect(links[skills[2].id] == .sameName)
        #expect(links[skills[3].id] == .notInBrain)
        #expect(links.count == 4, "a plugin skill gets no link")

        // Without the project folder on this Mac, nothing counts as rendered.
        let away = BrainLinks.links(for: skills, brain: brain, folders: [:])
        #expect(away[skills[0].id] == .sameName)
    }
}
