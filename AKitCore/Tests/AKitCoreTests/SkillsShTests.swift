import Foundation
import Testing
@testable import AKitCore

/// skills.sh search parsing, finding a skill in a repository and installing it.
/// Offline: a fake repository and a fake home in a temporary folder.
struct SkillsShTests {
    let home: URL
    let repo: URL
    let fm = FileManager.default

    init() throws {
        let base = fm.temporaryDirectory.appending(path: "akit-skillssh-\(UUID().uuidString)")
        home = base.appending(path: "home")
        repo = base.appending(path: "repo-HEAD")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
    }

    var env: HarnessEnvironment { HarnessEnvironment(homeDirectory: home) }

    func write(_ url: URL, _ text: String) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func skill(_ name: String) -> String { "---\nname: \(name)\ndescription: Does \(name)\n---\n\n# \(name)\n" }

    func remote(_ skillId: String, name: String? = nil) -> RemoteSkill {
        RemoteSkill(id: "me/repo/\(skillId)", source: "me/repo", skillId: skillId, name: name ?? skillId, installs: 1)
    }

    func fetched(_ skillId: String) throws -> FetchedSkill {
        try RemoteSkillFetcher.locate(remote(skillId), in: repo)
    }

    // MARK: - Search

    @Test func decodesSearchResultsMostInstalledFirst() throws {
        let json = """
        {"query":"tdd","skills":[
          {"id":"a/b/small","source":"a/b","skillId":"small","name":"small","installs":5},
          {"id":"mattpocock/skills/tdd","source":"mattpocock/skills","skillId":"tdd","name":"tdd","installs":964882},
          {"id":"open.feishu.cn/lark-event","source":"open.feishu.cn","skillId":"lark-event","name":"lark-event","installs":10}
        ],"count":3}
        """
        let skills = try SkillsShClient.decode(Data(json.utf8))
        #expect(skills.map(\.skillId) == ["tdd", "lark-event", "small"])
        #expect(skills[0].gitHubRepo?.owner == "mattpocock")
        #expect(skills[0].pageURL.absoluteString == "https://skills.sh/mattpocock/skills/tdd")
        #expect(skills[1].gitHubRepo == nil) // a website, not GitHub
    }

    @Test func searchErrorIsReported() {
        let json = #"{"error":"Query must be at least 2 characters"}"#
        #expect(throws: SkillsShClient.Failure.self) { try SkillsShClient.decode(Data(json.utf8)) }
    }

    @Test func searchURLEncodesTheQuery() {
        let url = SkillsShClient.searchURL(query: "react testing", limit: 10)
        #expect(url.absoluteString == "https://skills.sh/api/search?q=react%20testing&limit=10")
    }

    // MARK: - Finding the skill in a repository

    @Test func slugMatchesSkillsShIds() {
        #expect(SkillLocator.slug("Test-Driven Development (TDD)") == "test-driven-development-tdd")
        #expect(SkillLocator.slug("symfony:tdd-with-phpunit") == "symfonytdd-with-phpunit")
        #expect(SkillLocator.slug("tdd") == "tdd")
    }

    @Test func findsNestedSkillByNameAndSkipsOthers() throws {
        try write(repo.appending(path: "skills/engineering/tdd/SKILL.md"), skill("tdd"))
        try write(repo.appending(path: "skills/engineering/tdd/refs/mocking.md"), "mock")
        try write(repo.appending(path: "skills/misc/other/SKILL.md"), skill("other"))
        try write(repo.appending(path: "node_modules/x/tdd/SKILL.md"), skill("tdd"))

        let found = try fetched("tdd")
        #expect(found.pathInRepo == "skills/engineering/tdd")
        #expect(found.files == ["SKILL.md", "refs/mocking.md"])
        #expect(found.name == "tdd")
        #expect(found.description == "Does tdd")
    }

    @Test func findsSkillWhoseNameIsNotASlug() throws {
        try write(repo.appending(path: "tdd/SKILL.md"), skill("\"Test-Driven Development (TDD)\""))
        try write(repo.appending(path: "other/SKILL.md"), skill("other"))
        let found = try fetched("test-driven-development-tdd")
        #expect(found.pathInRepo == "tdd")
    }

    @Test func singleSkillRepositoryAtTheRoot() throws {
        try write(repo.appending(path: "SKILL.md"), skill("whatever"))
        let found = try fetched("something-else")
        #expect(found.pathInRepo == "")
    }

    @Test func missingSkillIsAnError() throws {
        try write(repo.appending(path: "a/SKILL.md"), skill("a"))
        try write(repo.appending(path: "b/SKILL.md"), skill("b"))
        #expect(throws: RemoteSkillFetcher.Failure.self) { try fetched("c") }
    }

    // MARK: - Where it goes

    func detect() -> [HarnessID] { HarnessCatalog.detectAll(in: env).map(\.id) }

    @Test func globalTargetsShareTheAgentsFolder() throws {
        try fm.createDirectory(at: home.appending(path: ".claude"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appending(path: ".pi/agent"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appending(path: ".codex"), withIntermediateDirectories: true)

        let targets = SkillInstaller.targets(for: [.claudeCode, .pi, .codex], scope: .global,
                                             adapters: HarnessCatalog.adapters, installed: detect(), in: env)
        #expect(targets.map(\.root.path) == [home.appending(path: ".claude/skills").path,
                                             home.appending(path: ".agents/skills").path])
        #expect(targets[1].harnesses == [.pi, .codex])
        #expect(targets[1].seenBy == [.codex, .pi])
    }

    @Test func symlinkedClaudeFolderNeedsOneCopy() throws {
        try fm.createDirectory(at: home.appending(path: ".agents/skills"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appending(path: ".claude"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appending(path: ".pi/agent"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: home.appending(path: ".claude/skills"),
                                  withDestinationURL: home.appending(path: ".agents/skills"))

        let targets = SkillInstaller.targets(for: [.claudeCode, .pi], scope: .global,
                                             adapters: HarnessCatalog.adapters, installed: detect(), in: env)
        #expect(targets.count == 1)
        #expect(targets[0].harnesses == [.claudeCode, .pi])
    }

    @Test func projectTargets() throws {
        let project = home.appending(path: "Projects/app")
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appending(path: ".claude"), withIntermediateDirectories: true)
        let targets = SkillInstaller.targets(for: [.claudeCode, .pi], scope: .project(project),
                                             adapters: HarnessCatalog.adapters, installed: detect(), in: env)
        #expect(targets.map(\.root.path) == [project.appending(path: ".claude/skills").path,
                                             project.appending(path: ".agents/skills").path])
    }

    // MARK: - Installing

    func claudeGlobal() -> [InstallTarget] {
        try? fm.createDirectory(at: home.appending(path: ".claude"), withIntermediateDirectories: true)
        return SkillInstaller.targets(for: [.claudeCode], scope: .global,
                                      adapters: HarnessCatalog.adapters, installed: detect(), in: env)
    }

    @Test func installCopiesFilesAndRecordsTheSource() throws {
        try write(repo.appending(path: "skills/tdd/SKILL.md"), skill("tdd"))
        try write(repo.appending(path: "skills/tdd/refs/a.md"), "a")
        try fm.createSymbolicLink(at: repo.appending(path: "skills/tdd/escape"), withDestinationURL: home)
        let found = try fetched("tdd")

        let request = InstallRequest(skill: found, name: "tdd", skillText: found.skillText, keepSource: true)
        let folders = try SkillInstaller.install(request, into: claudeGlobal(), replace: false, in: env)
        let folder = try #require(folders.first)
        #expect(folder.path == home.appending(path: ".claude/skills/tdd").path)
        #expect(try String(contentsOf: folder.appending(path: "refs/a.md"), encoding: .utf8) == "a")
        #expect(!fm.fileExists(atPath: folder.appending(path: "escape").path)) // symlinks are not copied

        let lock = try InstalledSkillLock.load(in: env)
        #expect(lock.entries.count == 1)
        #expect(lock.entries[0].source == "me/repo")
        #expect(lock.entries[0].pathInRepo == "skills/tdd")
        #expect(lock.entries[0].modified == false)

        // The Skills screen shows where it came from.
        let skills = SkillScanner.scan(installations: HarnessCatalog.detectAll(in: env), in: env)
        #expect(skills.first { $0.name == "tdd" }?.origin == "skills.sh · me/repo")
    }

    @Test func renamedAndEditedCopyAsYourOwn() throws {
        try write(repo.appending(path: "tdd/SKILL.md"), skill("tdd"))
        let found = try fetched("tdd")
        let edited = found.skillText + "\nMy rule.\n"

        let request = InstallRequest(skill: found, name: "my-tdd", skillText: edited, keepSource: false)
        #expect(request.isModified)
        let folder = try #require(try SkillInstaller.install(request, into: claudeGlobal(), replace: false, in: env).first)
        let text = try String(contentsOf: folder.appending(path: "SKILL.md"), encoding: .utf8)
        #expect(Frontmatter.parse(text)["name"] == "my-tdd")
        #expect(text.hasSuffix("My rule.\n"))
        #expect(try InstalledSkillLock.load(in: env).entries.isEmpty) // your own: no link back
    }

    @Test func existingSkillBlocksUnlessReplacedThroughTheTrash() throws {
        try write(repo.appending(path: "tdd/SKILL.md"), skill("tdd"))
        try write(home.appending(path: ".claude/skills/tdd/SKILL.md"), skill("old"))
        let found = try fetched("tdd")
        let targets = claudeGlobal()
        let request = InstallRequest(skill: found, name: "tdd", skillText: found.skillText, keepSource: true)

        #expect(SkillInstaller.conflicts(name: "tdd", targets: targets).count == 1)
        #expect(throws: SkillInstaller.Failure.self) {
            try SkillInstaller.install(request, into: targets, replace: false, in: env)
        }

        var trashed: [URL] = []
        let trashFolder = home.appending(path: "Trash")
        try fm.createDirectory(at: trashFolder, withIntermediateDirectories: true)
        try SkillInstaller.install(request, into: targets, replace: true, in: env) { url in
            let moved = trashFolder.appending(path: url.lastPathComponent)
            try fm.moveItem(at: url, to: moved)
            trashed.append(url)
            return moved
        }
        #expect(trashed.map(\.lastPathComponent) == ["tdd"])
        let text = try String(contentsOf: home.appending(path: ".claude/skills/tdd/SKILL.md"), encoding: .utf8)
        #expect(Frontmatter.parse(text)["name"] == "tdd")
    }

    @Test func brokenLockStopsTheInstall() throws {
        try write(repo.appending(path: "tdd/SKILL.md"), skill("tdd"))
        try write(InstalledSkillLock.url(in: env), "{ not json")
        let found = try fetched("tdd")
        let request = InstallRequest(skill: found, name: "tdd", skillText: found.skillText, keepSource: true)
        #expect(throws: InstalledSkillLock.Failure.self) {
            try SkillInstaller.install(request, into: claudeGlobal(), replace: false, in: env)
        }
        #expect(!fm.fileExists(atPath: home.appending(path: ".claude/skills/tdd").path))
    }

    @Test func invalidNamesAreRejected() {
        #expect(!SkillInstaller.nameProblems("").isEmpty)
        #expect(!SkillInstaller.nameProblems("../x").isEmpty)
        #expect(!SkillInstaller.nameProblems(".hidden").isEmpty)
        #expect(SkillInstaller.nameProblems("my-tdd").isEmpty)
    }

    // MARK: - SKILL.md name

    @Test func settingNameReplacesOrAddsIt() {
        #expect(SkillText.settingName("b", in: "---\nname: a\ndescription: x\n---\nbody") == "---\nname: b\ndescription: x\n---\nbody")
        #expect(SkillText.settingName("b", in: "---\ndescription: x\n---\nbody") == "---\nname: b\ndescription: x\n---\nbody")
        #expect(SkillText.settingName("b", in: "body") == "---\nname: b\n---\n\nbody")
        let quoted = "---\nname: \"a\"\n---\n"
        #expect(SkillText.settingName("a", in: quoted) == quoted) // same name: untouched
    }
}
