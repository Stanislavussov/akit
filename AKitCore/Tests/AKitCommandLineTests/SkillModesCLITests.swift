import AKitCommandLine
import AKitFoundation
import Foundation
import Testing

/// `akit skills mode`, `akit skills resolve` and `akit skills extension` in a temporary fake home
/// with a fake repository (a `.git` folder with an origin). Never touches the real home.
struct SkillModesCLITests {
    let home: URL
    let repo: URL
    let fm = FileManager.default
    let project = "gitlab.example.com/team/app"

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-modes-cli-\(UUID().uuidString)")
        repo = home.appending(path: "Projects/app")
        try fm.createDirectory(at: home.appending(path: ".pi/agent"), withIntermediateDirectories: true)
        try fm.createDirectory(at: repo.appending(path: ".git"), withIntermediateDirectories: true)
        try Data("[remote \"origin\"]\n\turl = git@gitlab.example.com:team/app.git\n".utf8).write(to: repo.appending(path: ".git/config"))
        try skill(".agents/skills/tdd", "tdd", manual: true)
        try skill(".agents/skills/review", "review", manual: true)
        try skill("Projects/app/.agents/skills/review", "review", manual: false)
    }

    func skill(_ folder: String, _ name: String, manual: Bool) throws {
        let url = home.appending(path: folder)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("---\nname: \(name)\ndescription: Does \(name)\n\(manual ? "disable-model-invocation: true\n" : "")---\nbody\n".utf8)
            .write(to: url.appending(path: "SKILL.md"))
    }

    func akit(_ arguments: String..., cwd: URL? = nil, stdin: String = "") async -> (code: Int32, out: String, err: String) {
        var out: [String] = []
        var err: [String] = []
        let code = await AKitCLI.run(arguments, env: HarnessEnvironment(homeDirectory: home), cwd: cwd ?? repo,
                                     projectsRoot: home.appending(path: "Projects"),
                                     out: { out.append($0) }, err: { err.append($0) }, input: { Data(stdin.utf8) })
        return (code, out.joined(separator: "\n"), err.joined(separator: "\n"))
    }

    var modesFile: URL { home.appending(path: ".akit/local/skill-modes.json") }

    @Test func setPreviewsThenWritesWithYesAndResetsTakeItOut() async throws {
        let preview = await akit("skills", "mode", "tdd", "auto")
        #expect(preview.code == 0)
        #expect(preview.out.contains("tdd in \(project): Auto (was: its SKILL.md)"))
        #expect(preview.out.contains("Creates ~/.akit/local/skill-modes.json"))
        #expect(preview.out.contains("not installed: akit skills extension install"))
        #expect(preview.out.contains("Run again with --yes"))
        #expect(!fm.fileExists(atPath: modesFile.path))

        let done = await akit("skills", "mode", "tdd", "auto", "--yes")
        #expect(done.code == 0 && done.out.contains("Done."))
        #expect(projects() == [project: ["tdd": "auto"]])

        let list = await akit("skills", "mode", "--json")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(list.out.utf8)) as? [String: Any])
        #expect(json["project"] as? String == project)
        let rows = try #require(json["skills"] as? [[String: Any]])
        let tdd = try #require(rows.first { $0["name"] as? String == "tdd" })
        #expect(tdd["mode"] as? String == "auto" && tdd["from"] as? String == "project" && tdd["source"] as? String == "yours")
        let mine = try #require(rows.first { $0["name"] as? String == "my-review" })
        #expect(mine["mode"] as? String == "manual" && mine["renamedFrom"] as? String == "review")
        let team = try #require(rows.first { $0["name"] as? String == "review" })
        #expect(team["source"] as? String == "project" && team["mode"] as? String == "auto")

        _ = await akit("skills", "mode", "review", "off", "--yes")
        let text = await akit("skills", "mode")
        #expect(text.out.contains("Skill modes in \(project)"))
        #expect(text.out.contains("(yours; the project's review has the name)"))

        #expect(await akit("skills", "mode", "tdd", "--reset", "--yes").code == 0)
        #expect(projects() == [project: ["review": "off"]])
        #expect(await akit("skills", "mode", "--reset-project", "--yes").code == 0)
        #expect(projects() == [:])
    }

    /// The file's projects as plain strings.
    func projects() -> [String: [String: String]] {
        guard let data = try? Data(contentsOf: modesFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return (json["projects"] as? [String: [String: String]]) ?? [:]
    }

    @Test func aWorktreeOfTheRepositoryGetsTheSameEntries() async throws {
        let tree = home.appending(path: "trees/app-fix")
        let gitdir = repo.appending(path: ".git/worktrees/app-fix")
        try fm.createDirectory(at: gitdir, withIntermediateDirectories: true)
        try fm.createDirectory(at: tree, withIntermediateDirectories: true)
        try Data("../..\n".utf8).write(to: gitdir.appending(path: "commondir"))
        try Data("gitdir: \(gitdir.path)\n".utf8).write(to: tree.appending(path: ".git"))
        _ = await akit("skills", "mode", "tdd", "auto", "--yes", cwd: tree)
        #expect(projects() == [project: ["tdd": "auto"]])
    }

    @Test func outsideGitAWriteIsRefused() async throws {
        let plain = home.appending(path: "plain")
        try fm.createDirectory(at: plain, withIntermediateDirectories: true)
        let result = await akit("skills", "mode", "tdd", "auto", "--yes", cwd: plain)
        #expect(result.code == 2 && result.err.contains("not in a git repository"))
        #expect(await akit("skills", "mode", cwd: plain).out.contains("Not in a git repository"))
    }

    @Test func globalOffIsRefusedWithThePointer() async throws {
        let result = await akit("skills", "mode", "tdd", "off", "--global")
        #expect(result.code == 2 && result.err.contains("akit skills set tdd --harness pi --state off"))
    }

    @Test func globalAutoChangesTheSkillMd() async throws {
        let preview = await akit("skills", "mode", "tdd", "auto", "--global")
        #expect(preview.code == 0 && preview.out.contains("- disable-model-invocation: true"), "\(preview)")
        #expect(await akit("skills", "mode", "tdd", "auto", "--global", "--yes").code == 0)
        let text = try String(contentsOf: home.appending(path: ".agents/skills/tdd/SKILL.md"), encoding: .utf8)
        #expect(!text.contains("disable-model-invocation"))
    }

    @Test func resolveAnswersWithTheProjectsModesAndRenames() async throws {
        _ = await akit("skills", "mode", "tdd", "auto", "--yes")
        let skills = """
            {"skills":[{"name":"tdd","scope":"user","origin":"top-level","path":"\(home.path)/.agents/skills/tdd/SKILL.md"},
            {"name":"review","scope":"project","origin":"top-level","path":"\(repo.path)/.agents/skills/review/SKILL.md"}]}
            """
        let result = await akit("skills", "resolve", "--harness", "pi", "--cwd", repo.path, "--json", cwd: home, stdin: skills)
        #expect(result.code == 0)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(result.out.utf8)) as? [String: Any])
        #expect(json["version"] as? Int == 1 && json["project"] as? String == project)
        #expect(json["modes"] as? [String: String] == ["tdd": "auto"])
        let renames = try #require(json["renames"] as? [String: [String: String]])
        #expect(renames["my-review"]?["file"] == home.appending(path: ".agents/skills/review/SKILL.md").path)
        #expect(renames["my-review"]?["mode"] == "manual")
    }

    @Test func resolveExitCodes() async throws {
        let bad = await akit("skills", "resolve", "--harness", "pi", "--cwd", repo.path, stdin: "nope")
        #expect(bad.code == 0 && bad.out.contains(#""kind":"input""#))
        #expect(await akit("skills", "resolve", "--harness", "claude", "--cwd", repo.path).code == 2)
        #expect(await akit("skills", "resolve", "--harness", "pi").code == 2)
        #expect(await akit("skills", "resolve", "--harness", "pi", "--cwd", repo.path, "--what").code == 2)
        let outside = await akit("skills", "resolve", "--harness", "pi", "--cwd", home.path, stdin: #"{"skills":[]}"#)
        #expect(outside.out == #"{"modes":{},"problems":[],"project":null,"renames":{},"version":1}"#)
    }

    @Test func theExtensionInstallsWithAPreviewAndGoesToTheTrash() async throws {
        let file = home.appending(path: ".pi/agent/extensions/akit-skill-modes.ts")
        let preview = await akit("skills", "extension", "install")
        #expect(preview.code == 0 && preview.out.contains("NEW ~/.pi/agent/extensions/akit-skill-modes.ts"))
        #expect(!fm.fileExists(atPath: file.path))
        #expect(await akit("skills", "extension", "install", "--yes").code == 0)
        #expect(try String(contentsOf: file, encoding: .utf8).hasPrefix("// akit-skill-modes: written by AKit"))
        #expect(await akit("skills", "extension", "status").out.contains("installed, current"))
        #expect(await akit("skills", "extension", "install").out.contains("current"))

        var trashed: [URL] = []
        var out: [String] = []
        let code = await AKitCLI.run(["skills", "extension", "uninstall", "--yes"], env: HarnessEnvironment(homeDirectory: home), cwd: repo,
                                     out: { out.append($0) }, err: { _ in }, trash: { trashed.append($0); try FileManager.default.removeItem(at: $0); return nil })
        #expect(code == 0 && trashed == [file])
        #expect(await akit("skills", "extension", "status", "--json").out.contains(#""state" : "missing""#))
    }

    @Test func aFileThatIsNotAKitsIsBackedUpBeforeItIsReplacedAndNeverTrashed() async throws {
        let file = home.appending(path: ".pi/agent/extensions/akit-skill-modes.ts")
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("// mine\n".utf8).write(to: file)
        #expect(await akit("skills", "extension", "uninstall", "--yes").out.contains("was not written by AKit; left alone"))
        let preview = await akit("skills", "extension", "install")
        #expect(preview.out.contains("BACK UP") && preview.out.contains("CHANGED"))
        let done = await akit("skills", "extension", "install", "--yes")
        #expect(done.out.contains("The old file is in ~/.akit/backups/"))
    }
}
