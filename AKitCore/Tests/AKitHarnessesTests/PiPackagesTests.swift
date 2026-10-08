import Foundation
import Testing
@testable import AKitFoundation
@testable import AKitHarnesses
import AKitModel

/// Pi packages and Pi's known projects, in a temporary fake home. Never touches the real one.
struct PiPackagesTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-pi-packages-\(UUID().uuidString)").standardizedFileURL
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var env: HarnessEnvironment { HarnessEnvironment(homeDirectory: home) }
    var agent: URL { home.appending(path: ".pi/agent") }

    func write(_ path: String, _ text: String = "x") throws {
        let url = home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func packages(projects: [URL] = []) -> [PiPackage] {
        PiPackages.list(configRoot: agent, projects: projects, in: env)
    }

    /// Paths relative to the package folder, for short expectations.
    func names(_ files: [URL], in package: PiPackage) -> [String] {
        let base = package.folder!.path + "/"
        return files.map { $0.path.hasPrefix(base) ? String($0.path.dropFirst(base.count)) : $0.path }.sorted()
    }

    @Test func npmPackageFollowsItsManifest() throws {
        let pkg = ".pi/agent/npm/node_modules/@acme/tools"
        try write(".pi/agent/settings.json", #"{"packages": ["npm:@acme/tools@1.2.0"]}"#)
        try write("\(pkg)/package.json", """
            {"name": "@acme/tools", "version": "1.2.0",
             "pi": {"extensions": ["./index.ts"], "skills": ["./skills"], "prompts": ["./prompts/*.md", "!prompts/old.md"]}}
            """)
        try write("\(pkg)/index.ts")
        try write("\(pkg)/extensions/unlisted.ts")
        try write("\(pkg)/skills/review/SKILL.md")
        try write("\(pkg)/skills/review/notes.md")
        try write("\(pkg)/skills/group/deep/SKILL.md")
        try write("\(pkg)/skills/loose.md")
        try write("\(pkg)/prompts/fix.md")
        try write("\(pkg)/prompts/old.md")
        try write("\(pkg)/themes/dark.json")

        let package = try #require(packages().first)
        #expect(package.kind == .npm)
        #expect(package.scope == .global)
        #expect(package.name == "@acme/tools")
        #expect(package.version == "1.2.0")
        #expect(package.identity == "npm:@acme/tools")
        #expect(names(package.extensions, in: package) == ["index.ts"])
        #expect(names(package.skills, in: package) == ["skills/group/deep/SKILL.md", "skills/loose.md", "skills/review/SKILL.md"])
        #expect(names(package.prompts, in: package) == ["prompts/fix.md"])
        #expect(package.themes.isEmpty) // the manifest lists no themes
    }

    @Test func withoutPiKeyTheConventionalFoldersLoad() throws {
        let pkg = ".pi/agent/npm/node_modules/plain"
        try write(".pi/agent/settings.json", #"{"packages": ["npm:plain"]}"#)
        try write("\(pkg)/package.json", #"{"name": "plain", "version": "0.1.0"}"#)
        try write("\(pkg)/extensions/a.ts")
        try write("\(pkg)/extensions/sub/index.ts")
        try write("\(pkg)/extensions/sub/helper.ts")
        try write("\(pkg)/extensions/node_modules/dep/index.js")
        try write("\(pkg)/skills/x/SKILL.md")
        try write("\(pkg)/prompts/nested/p.md")
        try write("\(pkg)/themes/t.json")

        let package = try #require(packages().first)
        #expect(names(package.extensions, in: package) == ["extensions/a.ts", "extensions/sub/index.ts"])
        #expect(names(package.skills, in: package) == ["skills/x/SKILL.md"])
        #expect(names(package.prompts, in: package) == ["prompts/nested/p.md"])
        #expect(names(package.themes, in: package) == ["themes/t.json"])
    }

    @Test func manifestWithoutSkillsLoadsNoneUnlessTheEntryIsAnObject() throws {
        // Like pi-caveman: a `pi` key with extensions only. A plain entry loads no skills;
        // an object entry without a skills filter falls back to the skills folder.
        let pkg = ".pi/agent/npm/node_modules/cave"
        try write("\(pkg)/package.json", #"{"name": "cave", "pi": {"extensions": ["./extensions/cave.ts"]}}"#)
        try write("\(pkg)/extensions/cave.ts")
        try write("\(pkg)/skills/grunt/SKILL.md")

        try write(".pi/agent/settings.json", #"{"packages": ["npm:cave"]}"#)
        let plain = try #require(packages().first)
        #expect(names(plain.extensions, in: plain) == ["extensions/cave.ts"])
        #expect(plain.skills.isEmpty)
        #expect(!plain.isFiltered)

        try write(".pi/agent/settings.json", #"{"packages": [{"source": "npm:cave"}]}"#)
        let object = try #require(packages().first)
        #expect(!object.isFiltered) // an object without filter keys narrows nothing
        #expect(names(object.skills, in: object) == ["skills/grunt/SKILL.md"])
    }

    @Test func settingsFiltersNarrowThePackage() throws {
        let pkg = ".pi/agent/npm/node_modules/tools"
        try write(".pi/agent/settings.json", """
            {"packages": [{"source": "npm:tools",
              "extensions": ["extensions/*.ts", "!extensions/legacy.ts"],
              "skills": ["!skills/b", "+skills/b", "-skills/c"],
              "prompts": [],
              "themes": ["themes/{dark,light}.json"]}]}
            """)
        try write("\(pkg)/package.json", #"{"name": "tools"}"#)
        try write("\(pkg)/extensions/main.ts")
        try write("\(pkg)/extensions/legacy.ts")
        try write("\(pkg)/skills/a/SKILL.md")
        try write("\(pkg)/skills/b/SKILL.md")
        try write("\(pkg)/skills/c/SKILL.md")
        try write("\(pkg)/prompts/p.md")
        try write("\(pkg)/themes/dark.json")
        try write("\(pkg)/themes/light.json")
        try write("\(pkg)/themes/neon.json")

        let package = try #require(packages().first)
        #expect(names(package.extensions, in: package) == ["extensions/main.ts"])
        // `!` drops b, `+` brings it back, `-` drops c for good.
        #expect(names(package.skills, in: package) == ["skills/a/SKILL.md", "skills/b/SKILL.md"])
        #expect(package.prompts.isEmpty)
        #expect(names(package.themes, in: package) == ["themes/dark.json", "themes/light.json"])
    }

    @Test func missingPackagesAreNotInstalled() throws {
        try write(".pi/agent/settings.json", """
            {"packages": ["npm:absent", "git:github.com/acme/repo@v1", "./nowhere", 42, {"skills": []}]}
            """)
        let list = packages()
        #expect(list.map(\.source) == ["npm:absent", "git:github.com/acme/repo@v1", "./nowhere"])
        #expect(list.map(\.kind) == [.npm, .git, .local])
        #expect(list.allSatisfy { !$0.isInstalled && $0.extensions.isEmpty && $0.skills.isEmpty })
        #expect(list.map(\.name) == ["absent", "repo", "nowhere"])
    }

    @Test func gitAndLocalSourcesResolve() throws {
        try write(".pi/agent/settings.json", """
            {"packages": ["git:github.com/acme/repo@v1", "https://gitlab.com/team/kit.git", "./mine", "~/ext.ts"]}
            """)
        try write(".pi/agent/git/github.com/acme/repo/skills/one/SKILL.md")
        try write(".pi/agent/git/gitlab.com/team/kit/prompts/p.md")
        try write(".pi/agent/mine/index.ts") // a folder with nothing conventional is one extension
        try write("ext.ts")

        let list = packages()
        #expect(list.map(\.identity) == ["git:github.com/acme/repo", "git:gitlab.com/team/kit",
                                         "local:\(agent.appending(path: "mine").path)", "local:\(home.appending(path: "ext.ts").path)"])
        #expect(list.allSatisfy { $0.isInstalled })
        #expect(names(list[0].skills, in: list[0]) == ["skills/one/SKILL.md"])
        #expect(names(list[1].prompts, in: list[1]) == ["prompts/p.md"])
        #expect(list[2].extensions.map(\.path) == [agent.appending(path: "mine").path])
        #expect(list[3].extensions.map(\.path) == [home.appending(path: "ext.ts").path])
    }

    @Test func gitSourceParsing() {
        typealias S = PiPackages.Source
        #expect(S.git("git:github.com/a/b@v1.2")! == ("github.com", "a/b"))
        #expect(S.git("git:git@github.com:a/b.git")! == ("github.com", "a/b"))
        #expect(S.git("ssh://git@GitHub.com/a/b")! == ("github.com", "a/b"))
        #expect(S.git("git:github:a/b")! == ("github.com", "a/b"))
        #expect(S.git("github.com/a/b") == nil)  // without git: only URLs with a scheme
        #expect(S.git("git:nohost/a/b") == nil)
        #expect(S.npmName("@scope/name@^1.0") == "@scope/name")
        #expect(S.npmName("plain@2") == "plain")
    }

    @Test func projectPackagesInstallUnderDotPi() throws {
        let project = home.appending(path: "Projects/app")
        try write("Projects/app/.pi/settings.json", #"{"packages": ["npm:proj", "./vendor/kit"]}"#)
        try write("Projects/app/.pi/npm/node_modules/proj/skills/s/SKILL.md")
        try write("Projects/app/.pi/vendor/kit/prompts/p.md")

        let list = packages(projects: [project, project])
        #expect(list.count == 2)
        #expect(list.allSatisfy { $0.scope == .project(project) && $0.isInstalled })
        #expect(names(list[0].skills, in: list[0]) == ["skills/s/SKILL.md"])
        #expect(names(list[1].prompts, in: list[1]) == ["prompts/p.md"])
    }

    @Test func autoloadFalseProjectEntryIsADeltaOverTheGlobalOne() throws {
        let project = home.appending(path: "Projects/app")
        try write(".pi/agent/settings.json", #"{"packages": ["npm:tools"]}"#)
        try write(".pi/agent/npm/node_modules/tools/skills/a/SKILL.md")
        try write(".pi/agent/npm/node_modules/tools/skills/b/SKILL.md")
        try write("Projects/app/.pi/settings.json", #"{"packages": [{"source": "npm:tools", "autoload": false, "skills": ["-skills/a"]}]}"#)

        let list = packages(projects: [project])
        let delta = try #require(list.last)
        #expect(delta.scope == .project(project))
        #expect(delta.folder == agent.appending(path: "npm/node_modules/tools"))
        #expect(names(delta.skills, in: delta) == ["skills/b/SKILL.md"])
    }

    @Test func packageSkillRootsRespectTheConfigDirVariable() throws {
        try write("custom-pi/settings.json", #"{"packages": ["npm:tools"]}"#)
        try write("custom-pi/npm/node_modules/tools/package.json", #"{"name": "tools", "version": "2.0"}"#)
        try write("custom-pi/npm/node_modules/tools/skills/a/SKILL.md")
        var e = env
        e.variables["PI_CODING_AGENT_DIR"] = "~/custom-pi"

        let list = PiPackages.list(configRoot: PiAdapter().configRoot(in: e), projects: [], in: e)
        let root = try #require(PiPackages.skillRoots(list).first)
        #expect(root.scope == .package(name: "tools", project: nil))
        #expect(root.origin == "npm:tools 2.0")
        #expect(root.isReadOnly)
        guard case .listed(let files) = root.layout else { Issue.record("not a listed root"); return }
        #expect(files.map(\.lastPathComponent) == ["SKILL.md"])
        // The adapter's own roots stay cheap: packages are added by the skill scan only.
        #expect(!PiAdapter().skillRoots(in: e, projects: []).contains { $0.isReadOnly })
    }

    // MARK: - Known projects

    func session(_ file: String, cwd: String, under root: String) throws {
        try write("\(root)/\(file)", """
            {"type":"session","version":3,"id":"x","timestamp":"2026-01-01T00:00:00.000Z","cwd":"\(cwd)"}
            {"type":"message","id":"1"}

            """)
    }

    @Test func knownProjectsComeFromSessionHeaders() throws {
        let app = home.appending(path: "Projects/my-app")
        let other = home.appending(path: "Projects/my/app")
        try fm.createDirectory(at: app, withIntermediateDirectories: true)
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        // `/x/my-app` and `/x/my/app` share one lossy folder name; the headers tell them apart.
        let shared = ".pi/agent/sessions/--x-Projects-my-app--"
        try session("2026-01-01T10-00-00-000Z_a.jsonl", cwd: other.path, under: shared)
        try session("2026-02-01T10-00-00-000Z_b.jsonl", cwd: app.path, under: shared)
        try session("2026-01-01T10-00-00-000Z_c.jsonl", cwd: app.path + "/", under: ".pi/agent/sessions/--dup--")
        try session("2026-01-01T10-00-00-000Z_d.jsonl", cwd: home.appending(path: "Projects/deleted").path,
                    under: ".pi/agent/sessions/--gone--")
        try write(".pi/agent/sessions/--broken--/2026-01-01T10-00-00-000Z_e.jsonl", "not json\n")

        #expect(PiAdapter().knownProjects(in: env).map(\.standardizedFileURL.path) == [app.path, other.path].sorted())
    }

    @Test func knownProjectsReadTheFlatSessionDirOfTheOverrides() throws {
        // A folder set by PI_CODING_AGENT_SESSION_DIR or `sessionDir` holds the files themselves.
        let app = home.appending(path: "Projects/app")
        let web = home.appending(path: "Projects/web")
        try fm.createDirectory(at: app, withIntermediateDirectories: true)
        try fm.createDirectory(at: web, withIntermediateDirectories: true)
        try session("2026-01-01T10-00-00-000Z_a.jsonl", cwd: app.path, under: "elsewhere")
        try session("2026-01-02T10-00-00-000Z_b.jsonl", cwd: web.path, under: "elsewhere")
        try session("2026-01-03T10-00-00-000Z_c.jsonl", cwd: app.path, under: "elsewhere")
        try session("2026-01-01T10-00-00-000Z_a.jsonl", cwd: app.path, under: "from-settings")

        var e = env
        e.variables["PI_CODING_AGENT_SESSION_DIR"] = "~/elsewhere"
        #expect(PiAdapter().knownProjects(in: e).map(\.standardizedFileURL.path) == [app.path, web.path])

        #expect(PiAdapter().knownProjects(in: env).isEmpty)
        try write(".pi/agent/settings.json", #"{"sessionDir": "~/from-settings"}"#)
        #expect(PiAdapter().knownProjects(in: env).map(\.standardizedFileURL.path) == [app.path])
    }
}
