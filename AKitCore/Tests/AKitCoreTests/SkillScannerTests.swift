import Foundation
import Testing
@testable import AKitCore

/// Skill discovery in a temporary fake home. Never touches the real one.
struct SkillScannerTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-skills-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var env: HarnessEnvironment { HarnessEnvironment(homeDirectory: home) }

    func write(_ path: String, _ text: String) throws {
        let url = home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func skill(_ name: String, description: String = "Does things") -> String {
        "---\nname: \(name)\ndescription: \(description)\n---\n\n# \(name)\n"
    }

    func link(_ path: String, to target: String) throws {
        try fm.createDirectory(at: home.appending(path: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: home.appending(path: path), withDestinationURL: home.appending(path: target))
    }

    func scan(extraProjects: [URL] = []) -> [Skill] {
        SkillScanner.scan(installations: HarnessCatalog.detectAll(in: env), extraProjects: extraProjects, in: env)
    }

    @Test func sharedFolderIsListedOnceForBothHarnesses() throws {
        try write(".agents/skills/tdd/SKILL.md", skill("tdd"))
        try link(".claude/skills", to: ".agents/skills")
        try link(".pi/agent/skills", to: ".agents/skills")

        let skills = scan()
        #expect(skills.count == 1)
        let tdd = try #require(skills.first)
        #expect(tdd.name == "tdd")
        #expect(tdd.scope == .global)
        #expect(tdd.visibleTo == [.claudeCode, .pi])
        #expect(tdd.warnings.isEmpty)
    }

    @Test func claudeOnlySeesTopLevelButPiRecurses() throws {
        try fm.createDirectory(at: home.appending(path: ".claude"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appending(path: ".pi/agent"), withIntermediateDirectories: true)
        try write(".claude/skills/group/nested/SKILL.md", skill("nested"))
        try write(".agents/skills/group/deep/SKILL.md", skill("deep"))

        let names = Dictionary(uniqueKeysWithValues: scan().map { ($0.name, $0.visibleTo) })
        #expect(names["nested"] == nil)       // Claude: only <root>/<name>/SKILL.md
        #expect(names["deep"] == [.pi])       // Pi: any depth
    }

    @Test func syncedSkillsAreReadOnlyAndFromClaudeAI() throws {
        try write(".agents/skills/synced/bucket-1/pdf/SKILL.md", skill("pdf"))
        try link(".claude/skills", to: ".agents/skills")
        try fm.createDirectory(at: home.appending(path: ".pi/agent"), withIntermediateDirectories: true)

        let pdf = try #require(scan().first)
        #expect(pdf.scope == .synced)
        #expect(pdf.isReadOnly)
        #expect(pdf.origin == "claude.ai")
        #expect(pdf.visibleTo == [.claudeCode, .pi])
    }

    @Test func projectSkillsFromBothHarnessesAndProjectRoots() throws {
        try fm.createDirectory(at: home.appending(path: ".claude"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appending(path: ".pi/agent"), withIntermediateDirectories: true)
        try write("Projects/app/.claude/skills/deploy/SKILL.md", skill("deploy"))
        try write("Projects/app/.agents/skills/lint/SKILL.md", skill("lint"))
        try fm.createDirectory(at: home.appending(path: "Projects/app/.git"), withIntermediateDirectories: true)

        let projects = ProjectFinder.projects(inRoots: [home.appending(path: "Projects")])
        #expect(projects.map(\.lastPathComponent) == ["app"])

        let byName = Dictionary(uniqueKeysWithValues: scan(extraProjects: projects).map { ($0.name, $0) })
        #expect(byName["deploy"]?.visibleTo == [.claudeCode])
        #expect(byName["lint"]?.visibleTo == [.pi])
        #expect(byName["deploy"]?.scope == .project(projects[0]))
    }

    @Test func projectsFromClaudeHistoryExcludeHome() throws {
        try fm.createDirectory(at: home.appending(path: ".claude"), withIntermediateDirectories: true)
        try write("work/api/.claude/skills/db/SKILL.md", skill("db"))
        try write(".claude.json", """
            {"projects": {"\(home.path)": {}, "\(home.appending(path: "work/api").path)": {}, "/does/not/exist": {}}}
            """)
        try write(".claude/skills/own/SKILL.md", skill("own"))

        let skills = scan()
        #expect(Set(skills.map(\.name)) == ["db", "own"])
        #expect(skills.first { $0.name == "own" }?.scope == .global)
    }

    @Test func enabledPluginSkillsOnlyInstalledVersion() throws {
        let plugin = home.appending(path: ".claude/plugins/cache/mp/tool/2.0")
        try write(".claude/plugins/cache/mp/tool/2.0/skills/ask/SKILL.md", skill("ask"))
        try write(".claude/plugins/cache/mp/tool/1.0/skills/old/SKILL.md", skill("old"))
        try write(".claude/plugins/cache/mp/other/1.0/skills/off/SKILL.md", skill("off"))
        try write(".claude/plugins/installed_plugins.json", """
            {"version": 2, "plugins": {
              "tool@mp": [{"scope": "user", "installPath": "\(plugin.path)", "version": "2.0"}],
              "other@mp": [{"scope": "user", "installPath": "\(home.appending(path: ".claude/plugins/cache/mp/other/1.0").path)"}]
            }}
            """)
        try write(".claude/settings.json", #"{"enabledPlugins": {"tool@mp": true, "other@mp": false}}"#)

        let skills = scan()
        #expect(skills.map(\.name) == ["ask"])
        #expect(skills.first?.scope == .plugin(name: "tool"))
        #expect(skills.first?.origin == "tool 2.0")
        #expect(skills.first?.isReadOnly == true)
    }

    @Test func piWarnings() throws {
        try fm.createDirectory(at: home.appending(path: ".pi/agent"), withIntermediateDirectories: true)
        try write(".agents/skills/Bad_Name/SKILL.md", skill("Bad_Name"))
        try write(".agents/skills/nodesc/SKILL.md", "---\nname: nodesc\n---\nbody\n")

        let byName = Dictionary(uniqueKeysWithValues: scan().map { ($0.name, $0) })
        #expect(byName["Bad_Name"]?.warnings.contains { $0.contains("a-z, 0-9") } == true)
        #expect(byName["nodesc"]?.visibleTo == [])
        #expect(byName["nodesc"]?.warnings.first?.contains("description is missing") == true)
    }

    @Test func nameCollisionIsReported() throws {
        try fm.createDirectory(at: home.appending(path: ".pi/agent"), withIntermediateDirectories: true)
        try write(".pi/agent/skills/review/SKILL.md", skill("review"))
        try write(".agents/skills/review/SKILL.md", skill("review"))

        let skills = scan()
        #expect(skills.count == 2)
        #expect(skills.allSatisfy { $0.warnings.contains { $0.contains("collides") } })
    }

    @Test func lockFileGivesOrigin() throws {
        try fm.createDirectory(at: home.appending(path: ".pi/agent"), withIntermediateDirectories: true)
        try write(".agents/skills/find-skills/SKILL.md", skill("find-skills"))
        try write(".agents/.skill-lock.json", #"{"version": 3, "skills": {"find-skills": {"source": "vercel-labs/skills"}}}"#)

        #expect(scan().first?.origin == "vercel-labs/skills")
    }

    @Test func symlinkLoopDoesNotHang() throws {
        try fm.createDirectory(at: home.appending(path: ".pi/agent"), withIntermediateDirectories: true)
        try write(".agents/skills/a/readme.txt", "x")
        try link(".agents/skills/a/loop", to: ".agents/skills")
        #expect(scan().isEmpty)
    }
}


extension SkillScannerTests {
    @Test func sameNameInTwoProjectsIsNotACollision() throws {
        try fm.createDirectory(at: home.appending(path: ".claude"), withIntermediateDirectories: true)
        try write("Projects/a/.claude/skills/deploy/SKILL.md", skill("deploy"))
        try write("Projects/b/.claude/skills/deploy/SKILL.md", skill("deploy"))
        try write(".claude/skills/deploy/SKILL.md", skill("deploy"))

        let skills = scan(extraProjects: ProjectFinder.projects(inRoots: [home.appending(path: "Projects")]))
        #expect(skills.count == 3)
        let global = try #require(skills.first { $0.scope == .global })
        let projectA = try #require(skills.first { $0.file.path.contains("Projects/a/") })
        #expect(global.warnings.count == 2)      // clashes with each project, separately
        #expect(projectA.warnings.count == 1)    // only with the global one, never with project b
        #expect(!projectA.warnings[0].contains("Projects/b"))
    }

    @Test func pluginSkillDoesNotCollideForClaude() throws {
        let plugin = home.appending(path: ".claude/plugins/cache/mp/tool/1.0")
        try write(".claude/plugins/cache/mp/tool/1.0/skills/review/SKILL.md", skill("review"))
        try write(".claude/plugins/installed_plugins.json", """
            {"plugins": {"tool@mp": [{"scope": "user", "installPath": "\(plugin.path)"}],
                         "proj@mp": [{"scope": "project", "installPath": "/nowhere"}]}}
            """)
        try write(".claude/settings.json", #"{"enabledPlugins": {"tool@mp": true, "proj@mp": true}}"#)
        try write(".claude/skills/review/SKILL.md", skill("review"))

        let skills = scan()
        #expect(skills.count == 2)
        #expect(skills.allSatisfy { $0.warnings.isEmpty })
    }

    @Test func onlyClaudesSyncedFolderIsClaudeAI() throws {
        try fm.createDirectory(at: home.appending(path: ".claude"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appending(path: ".pi/agent"), withIntermediateDirectories: true)
        try write(".agents/skills/synced/bucket/x/SKILL.md", skill("x")) // Pi's folder, not Claude's

        let x = try #require(scan().first)
        #expect(x.scope == .global)
        #expect(!x.isReadOnly)
    }

    @Test func lowercaseSkillFileIsIgnoredAndRootSkillFileDoesNotHideOthers() throws {
        try fm.createDirectory(at: home.appending(path: ".claude"), withIntermediateDirectories: true)
        try write(".claude/skills/lower/skill.md", skill("lower"))
        try write(".claude/skills/SKILL.md", skill("stray"))
        try write(".claude/skills/real/SKILL.md", skill("real"))

        #expect(scan().map(\.name) == ["real"])
    }
}

struct FrontmatterTests {
    @Test func simpleAndQuoted() {
        let meta = Frontmatter.parse("---\nname: tdd\ndescription: \"Test: first\"\nother: 'it''s'\n---\nbody")
        #expect(meta == ["name": "tdd", "description": "Test: first", "other": "it's"])
    }

    @Test func blockAndFoldedAndPlainContinuation() {
        let text = """
        ---
        name: x
        description: >
          one
          two
        notes: |
          line1
          line2
        long: first
          second
        tags:
          - a
        ---
        """
        let meta = Frontmatter.parse(text)
        #expect(meta["description"] == "one two")
        #expect(meta["notes"] == "line1\nline2")
        #expect(meta["long"] == "first second")
        #expect(meta["tags"] == nil)
    }

    @Test func noHeader() {
        #expect(Frontmatter.parse("# Title\nname: x").isEmpty)
        #expect(Frontmatter.parse("---\nname: x\n").isEmpty)
    }
}

struct SkillRemoverTests {
    let home: URL
    let trashDir: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-remove-\(UUID().uuidString)")
        trashDir = home.appending(path: "Trash")
        try fm.createDirectory(at: trashDir, withIntermediateDirectories: true)
    }

    var env: HarnessEnvironment { HarnessEnvironment(homeDirectory: home) }

    func write(_ path: String, _ text: String) throws {
        let url = home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// Fake Trash: move into a temp folder.
    func fakeTrash(_ url: URL) throws -> URL? {
        let dest = trashDir.appending(path: UUID().uuidString + "-" + url.lastPathComponent)
        try fm.moveItem(at: url, to: dest)
        return dest
    }

    func scan() -> [Skill] {
        SkillScanner.scan(installations: HarnessCatalog.detectAll(in: env), in: env)
    }

    @Test func sharedSkillFolderGoesToTrashWithAllFiles() throws {
        try write(".agents/skills/tdd/SKILL.md", "---\nname: tdd\ndescription: d\n---\n")
        try write(".agents/skills/tdd/ref.md", "x")
        try write(".agents/skills/keep/SKILL.md", "---\nname: keep\ndescription: d\n---\n")
        try fm.createSymbolicLink(at: home.appending(path: ".claude"), withDestinationURL: home.appending(path: "claude-real"))
        try fm.createDirectory(at: home.appending(path: "claude-real"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: home.appending(path: ".claude/skills"), withDestinationURL: home.appending(path: ".agents/skills"))

        let tdd = try #require(scan().first { $0.name == "tdd" })
        let moved = try SkillRemover.moveToTrash(tdd, trash: fakeTrash)

        #expect(moved.count == 1) // the shared parent symlink is NOT touched
        #expect(!fm.fileExists(atPath: home.appending(path: ".agents/skills/tdd").path))
        #expect(fm.fileExists(atPath: moved[0].appending(path: "ref.md").path))
        #expect(scan().map(\.name) == ["keep"])
    }

    @Test func perSkillSymlinkIsRemovedToo() throws {
        try fm.createDirectory(at: home.appending(path: ".claude/skills"), withIntermediateDirectories: true)
        try write("library/lint/SKILL.md", "---\nname: lint\ndescription: d\n---\n")
        try fm.createSymbolicLink(at: home.appending(path: ".claude/skills/lint"), withDestinationURL: home.appending(path: "library/lint"))

        let lint = try #require(scan().first)
        #expect(try SkillRemover.items(for: lint).count == 2)
        try SkillRemover.moveToTrash(lint, trash: fakeTrash)
        #expect((try? fm.destinationOfSymbolicLink(atPath: home.appending(path: ".claude/skills/lint").path)) == nil)
        #expect(scan().isEmpty)
    }

    @Test func readOnlySkillsAreRefused() throws {
        try write(".claude/skills/synced/b/pdf/SKILL.md", "---\nname: pdf\ndescription: d\n---\n")
        let pdf = try #require(scan().first)
        #expect(throws: SkillRemover.Failure.self) { try SkillRemover.moveToTrash(pdf, trash: fakeTrash) }
        #expect(fm.fileExists(atPath: pdf.realFile.path))
    }
}

struct MoreHarnessTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-more-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var env: HarnessEnvironment { HarnessEnvironment(homeDirectory: home) }

    func write(_ path: String, _ text: String = "---\nname: x\ndescription: d\n---\n") throws {
        let url = home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func skill(_ name: String) -> String { "---\nname: \(name)\ndescription: d\n---\n" }

    @Test func openCodeAndCodexShareTheAgentsFolder() throws {
        try fm.createDirectory(at: home.appending(path: ".config/opencode"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appending(path: ".codex"), withIntermediateDirectories: true)
        try write(".agents/skills/tdd/SKILL.md", skill("tdd"))
        try write(".config/opencode/skill/oc-only/SKILL.md", skill("oc-only"))
        try write(".codex/skills/.system/imagegen/SKILL.md", skill("imagegen"))

        let found = HarnessCatalog.detectAll(in: env)
        #expect(Set(found.map(\.id)) == [.openCode, .codex])
        let byName = Dictionary(uniqueKeysWithValues: SkillScanner.scan(installations: found, in: env).map { ($0.name, $0) })
        #expect(byName["tdd"]?.visibleTo == [.codex, .openCode])
        #expect(byName["oc-only"]?.visibleTo == [.openCode])
        #expect(byName["imagegen"]?.scope == .bundled(.codex))
        #expect(byName["imagegen"]?.isReadOnly == true)
    }

    @Test func codexHomeOverride() throws {
        try fm.createDirectory(at: home.appending(path: "ch"), withIntermediateDirectories: true)
        var e = env
        e.variables["CODEX_HOME"] = "~/ch"
        #expect(CodexAdapter().detect(in: e)?.configRoot.lastPathComponent == "ch")
    }
}
