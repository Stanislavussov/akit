import AKitFoundation
import AKitReview
import Foundation
import Testing
@testable import AKitCommandLine

/// `akit review roles|role|scenario|defaults|profile`: new roles and configuration from the
/// terminal, as Review → Roles and Scenarios does in the app.
extension AKitCLITests {
    /// A git brain of its own in the fake home.
    func reviewBrain() async throws -> URL {
        let brain = home.appending(path: "review-brain")
        try write("review-brain/README.md", "brain\n")
        for args in [["init", "-q", "-b", "main"], ["add", "README.md"], ["commit", "-q", "-m", "Start"]] {
            let result = try #require(await ProcessRunner.run(URL(filePath: "/usr/bin/git"), arguments: args, directory: brain,
                                                              environment: env.variables, timeout: 10))
            #expect(result.succeeded, "\(result.output)")
        }
        return brain
    }

    /// `akit review …` with this brain, stdin text and a fake Trash.
    func reviewConfig(_ arguments: [String], brain: URL, stdin: String = "") async -> (code: Int32, out: String, err: String) {
        var out: [String] = [], err: [String] = []
        let code = await AKitCLI.run(["review"] + arguments + ["--brain", brain.path], env: env, cwd: home,
                                     out: { out.append($0) }, err: { err.append($0) },
                                     trash: { url in
                                         let target = home.appending(path: "Trash/\(UUID().uuidString)")
                                         try fm.createDirectory(at: target, withIntermediateDirectories: true)
                                         try fm.moveItem(at: url, to: target.appending(path: url.lastPathComponent))
                                         return target
                                     }, input: { Data(stdin.utf8) })
        return (code, out.joined(separator: "\n"), err.joined(separator: "\n"))
    }

    @Test func reviewRoleNewShowsDiffThenCommitsWithYes() async throws {
        let brain = try await reviewBrain()
        let roleFile = brain.appending(path: "layers/review/skills/review-performance/SKILL.md")
        let listed = await reviewConfig(["roles"], brain: brain)
        #expect(listed.code == 0 && listed.out.contains("bug-hunter  [built-in]"), "\(listed)")

        let dry = await reviewConfig(["role", "new", "performance"], brain: brain)
        #expect(dry.code == 0, "\(dry)")
        #expect(dry.out.contains("New role performance in Brain") && dry.out.contains("+ name: review-performance"))
        #expect(dry.out.contains("Nothing written"))
        #expect(!fm.fileExists(atPath: roleFile.path))

        let saved = await reviewConfig(["role", "new", "review-performance", "--yes"], brain: brain)
        #expect(saved.code == 0 && saved.out.contains("committed in the brain"), "\(saved)")
        #expect(fm.fileExists(atPath: roleFile.path))
        let log = try #require(await ProcessRunner.run(URL(filePath: "/usr/bin/git"), arguments: ["log", "--oneline", "-1"], directory: brain,
                                                       environment: env.variables, timeout: 10))
        #expect(log.output.contains("Review: add role performance"))
        #expect(await reviewConfig(["roles"], brain: brain).out.contains("performance  [brain]"))
        #expect(await reviewConfig(["role", "new", "performance"], brain: brain).err.contains("already has role performance"))
        #expect(await reviewConfig(["role", "show", "performance"], brain: brain).out.contains("name: review-performance"))

        // An agent's own text from stdin; a broken one is refused before anything is written.
        let text = ReviewTemplates.role("performance").replacingOccurrences(of: "max_findings: 6", with: "max_findings: 2")
        let edited = await reviewConfig(["role", "save", "performance", "--file", "-", "--yes"], brain: brain, stdin: text)
        #expect(edited.code == 0 && edited.out.contains("-   max_findings: 6") && edited.out.contains("+   max_findings: 2"), "\(edited)")
        #expect(ReviewCatalog.load(home: home, brain: brain).roles.first { $0.id == "performance" }?.maxFindings == 2)
        let broken = await reviewConfig(["role", "save", "performance", "--file", "-"], brain: brain, stdin: "---\nname: other\n---\n")
        #expect(broken.code != 0 && !broken.err.isEmpty, "\(broken)")
        let wrongName = await reviewConfig(["role", "save", "performance", "--file", "-"], brain: brain,
                                           stdin: ReviewTemplates.role("speed"))
        #expect(wrongName.err.contains("The name must be review-performance."), "\(wrongName)")
    }

    @Test func reviewProjectCopiesAndScenarios() async throws {
        let brain = try await reviewBrain()
        let profile = await reviewConfig(["profile", "new", "orders", "--yes"], brain: brain)
        #expect(profile.code == 0, "\(profile)")
        #expect(await reviewConfig(["profile", "show", "orders"], brain: brain).out.contains("project: orders"))

        let copy = await reviewConfig(["role", "duplicate", "tests", "--project", "orders", "--yes"], brain: brain)
        #expect(copy.code == 0 && copy.out.contains("in Project orders"), "\(copy)")
        let json = await reviewConfig(["roles", "--project", "orders", "--json"], brain: brain)
        #expect(json.out.contains("\"id\" : \"tests\"") && json.out.contains("\"source\" : \"project\""), "\(json)")
        #expect(await reviewConfig(["role", "duplicate", "tests", "--project", "orders"], brain: brain).err.contains("already has its own"))

        let folder = home.appending(path: ".akit/local/review/projects/orders/skills/review-tests")
        let dry = await reviewConfig(["role", "reset", "tests", "--project", "orders"], brain: brain)
        #expect(dry.out.contains("Would move") && fm.fileExists(atPath: folder.path), "\(dry)")
        let reset = await reviewConfig(["role", "reset", "tests", "--project", "orders", "--yes"], brain: brain)
        #expect(reset.code == 0 && !fm.fileExists(atPath: folder.path), "\(reset)")
        #expect(fm.fileExists(atPath: home.appending(path: "Trash").path))

        let scenario = await reviewConfig(["scenario", "new", "hotfix", "--project", "orders", "--yes"], brain: brain)
        #expect(scenario.code == 0, "\(scenario)")
        #expect(await reviewConfig(["scenarios", "--project", "orders"], brain: brain).out.contains("hotfix  [project]"))
        #expect(!(await reviewConfig(["scenarios"], brain: brain).out.contains("hotfix")))
        #expect(await reviewConfig(["role", "new", "x", "--project", "nope"], brain: brain).err.contains("no project profile nope"))
        #expect(await reviewConfig(["defaults", "show"], brain: brain).out.contains("models:"))
        #expect(await reviewConfig(["defaults", "show", "--project", "orders"], brain: brain).err.contains("profile's review: block"))
        #expect(await reviewConfig(["--help"], brain: brain).out.contains("akit review role new ID"))

        // Ids name files: no way out of the review folders, no run flags dropped quietly.
        let escape = await reviewConfig(["scenario", "reset", "../../orders", "--project", "orders", "--yes"], brain: brain)
        #expect(escape.code != 0 && escape.err.contains("not a scenario id"), "\(escape)")
        #expect(fm.fileExists(atPath: home.appending(path: ".akit/local/review/projects/orders.yaml").path))
        #expect(await reviewConfig(["profile", "show", "../../../x"], brain: brain).err.contains("not a profile id"))
        #expect(await reviewConfig(["role", "new", "perf", "--scenario", "hotfix"], brain: brain).err.contains("takes only --project"))
        #expect(await reviewConfig(["profile", "show", "nope"], brain: brain).err.contains("akit review profile new nope"))
        let onlyHere = await reviewConfig(["scenario", "reset", "hotfix", "--project", "orders"], brain: brain)
        #expect(onlyHere.out.contains("orders has no scenario hotfix any more"), "\(onlyHere)")
        #expect(await reviewConfig(["role", "new", "security"], brain: brain).out.contains("built into AKit"))

        // Write with AI…: the skills to pick, and the flags it needs.
        try write(".claude/skills/house-style/SKILL.md", "---\nname: house-style\ndescription: Our rules\n---\n")
        let skills = await reviewConfig(["role", "skills"], brain: brain)
        #expect(skills.out.contains("review-role-writer  [built-in]") && skills.out.contains("house-style  [Claude Code]"), "\(skills)")
        #expect(await reviewConfig(["role", "skills", "--json"], brain: brain).out.contains("\"place\" : \"Claude Code\""))
        #expect(await reviewConfig(["role", "write", "i18n"], brain: brain).err.contains("--describe TEXT"))
        #expect(await reviewConfig(["role", "write", "i18n", "--describe", "x", "--skill", "nope"], brain: brain).err.contains("There is no skill nope"))
        #expect(await reviewConfig(["role", "new", "i18n", "--describe", "x"], brain: brain).err.contains("go with akit review role write"))
        #expect(await reviewConfig(["defaults", "write", "--describe", "y"], brain: brain).err.contains("Only a role or a scenario"))
    }

    @Test func reviewLinksSkillsAndDeletesScenarios() async throws {
        let brain = try await reviewBrain()
        try write(".claude/skills/house-style/SKILL.md", "---\nname: house-style\ndescription: Our rules\n---\nRules.\n")
        #expect(await reviewConfig(["scenario", "skills"], brain: brain).out.contains("review-scenario-writer  [built-in]"))
        let linked = await reviewConfig(["role", "link", "security", "house-style", "--yes"], brain: brain)
        #expect(linked.code == 0 && linked.out.contains("+   skills: [house-style]"), "\(linked)")
        #expect(ReviewCatalog.load(home: home, brain: brain).roles.first { $0.id == "security" }?.skills == ["house-style"])
        let unknown = await reviewConfig(["scenario", "link", "bugfix", "nope"], brain: brain)
        #expect(unknown.code == 0 && unknown.err.contains("no skill on this Mac is called nope"), "\(unknown)")
        let unlinked = await reviewConfig(["role", "unlink", "security", "house-style", "--yes"], brain: brain)
        #expect(unlinked.code == 0 && ReviewCatalog.load(home: home, brain: brain).roles.first { $0.id == "security" }?.skills == [])

        let dry = await reviewConfig(["scenario", "delete", "dependency-upgrade"], brain: brain)
        #expect(dry.code == 0 && dry.out.contains("Roles only this scenario uses, deleted too: upgrade-risk."), "\(dry)")
        #expect(dry.out.contains("Nothing changed"))
        let kept = await reviewConfig(["scenario", "delete", "dependency-upgrade", "--keep-roles", "--yes"], brain: brain)
        #expect(kept.code == 0 && kept.out.contains("committed in the brain"), "\(kept)")
        let catalog = ReviewCatalog.load(home: home, brain: brain)
        #expect(!catalog.scenarios.contains { $0.id == "dependency-upgrade" } && catalog.roles.contains { $0.id == "upgrade-risk" })
        let role = await reviewConfig(["role", "delete", "upgrade-risk", "--yes"], brain: brain)
        #expect(role.code == 0 && !ReviewCatalog.load(home: home, brain: brain).roles.contains { $0.id == "upgrade-risk" }, "\(role)")
        #expect(await reviewConfig(["role", "delete", "upgrade-risk"], brain: brain).err.contains("There is no role upgrade-risk"))
        #expect(await reviewConfig(["role", "delete", "tests", "--keep-roles"], brain: brain).err.contains("--keep-roles goes with"))
    }
}
