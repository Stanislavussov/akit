import Foundation
import Testing
import AKitCommandLine
import AKitFoundation
@testable import AKitBrain

/// AKit's own skills in a brain made before they existed or changed, in a temporary fake home.
struct BuiltInSkillsTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-builtin-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var env: HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home, variables: [
            "HOME": home.path, "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
            "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
        ], executableSearchPaths: [URL(filePath: "/usr/bin")])
    }

    var root: URL { Brain.defaultRoot(home: home) }
    var layerFile: URL { root.appending(path: "layers/core/layer.yaml") }

    func git(_ args: String...) async throws -> String {
        let result = try #require(await ProcessRunner.run(URL(filePath: "/usr/bin/git"), arguments: args,
                                                           directory: root, environment: env.variables, timeout: 10))
        return result.output
    }

    func akit(_ arguments: String...) async -> (code: Int32, out: String, err: String) {
        var out: [String] = [], err: [String] = []
        let code = await AKitCLI.run(arguments, env: env, cwd: home, projectsRoot: home.appending(path: "Projects"),
                                     hostName: "mac", installedTargets: ["pi"],
                                     out: { out.append($0) }, err: { err.append($0) }, trash: { _ in nil })
        return (code, out.joined(separator: "\n"), err.joined(separator: "\n"))
    }

    /// A brain from before /akit-context: no skill folder, no core line, and an older /akit.
    func oldBrain() async throws {
        try await BrainSetup.create(at: root, env: env)
        try fm.removeItem(at: root.appending(path: "skills/akit-context"))
        let layer = try String(contentsOf: layerFile, encoding: .utf8)
            .replacingOccurrences(of: "  - name: akit-context\n    mode: auto\n", with: "")
        try Data(layer.utf8).write(to: layerFile)
        try Data("---\nname: akit\n---\nold\n".utf8).write(to: root.appending(path: "skills/akit/SKILL.md"))
        _ = try await git("commit", "-qam", "old brain")
    }

    @Test func findsMissingAndOutdated() async throws {
        try await oldBrain()
        let plan = try BuiltInSkills.plan(brain: root)
        let akit = try #require(plan.items.first { $0.name == "akit" })
        let context = try #require(plan.items.first { $0.name == "akit-context" })
        #expect(akit.state == .outdated && akit.inCore)
        #expect(context.state == .missing && !context.inCore && context.mode == .auto)
        #expect(plan.needsWork)
    }

    @Test func addsAndUpdatesInOneCommit() async throws {
        try await oldBrain()
        let plan = try BuiltInSkills.plan(brain: root)
        let message = try await BuiltInSkills.apply(plan, names: ["akit", "akit-context"], modes: ["akit-context": .manual], env: env)
        #expect(message == "Add akit-context to core; Update akit from AKit's templates")
        let after = try BuiltInSkills.plan(brain: root)
        #expect(!after.needsWork)
        #expect(after.items.first { $0.name == "akit-context" }?.mode == .manual)
        #expect(try String(contentsOf: root.appending(path: "skills/akit/SKILL.md"), encoding: .utf8) == AKitSkill.text)
        #expect(try await git("status", "--porcelain").isEmpty)
        #expect(try await git("log", "-1", "--format=%s").contains("Add akit-context to core"))
    }

    @Test func aFinalNewlineIsTheSameCopy() async throws {
        try await BrainSetup.create(at: root, env: env)
        try Data((AKitContextSkill.text + "\n").utf8).write(to: root.appending(path: "skills/akit-context/SKILL.md"))
        #expect(try BuiltInSkills.plan(brain: root).items.first { $0.name == "akit-context" }?.state == .current)
    }

    @Test func onlyTheChosenOnes() async throws {
        try await oldBrain()
        let plan = try BuiltInSkills.plan(brain: root)
        try await BuiltInSkills.apply(plan, names: ["akit-context"], env: env)
        let after = try BuiltInSkills.plan(brain: root)
        #expect(after.items.first { $0.name == "akit" }?.state == .outdated)
        #expect(after.items.first { $0.name == "akit-context" }?.state == .current)
    }

    @Test func refusesAChangeSinceThePreview() async throws {
        try await oldBrain()
        let plan = try BuiltInSkills.plan(brain: root)
        try Data("---\nname: akit\n---\nedited\n".utf8).write(to: root.appending(path: "skills/akit/SKILL.md"))
        await #expect(throws: BuiltInSkills.Failure.self) {
            try await BuiltInSkills.apply(plan, names: ["akit"], env: env)
        }
    }

    @Test func refusesUncommittedChanges() async throws {
        try await oldBrain()
        try Data("---\nname: akit\n---\nedited\n".utf8).write(to: root.appending(path: "skills/akit/SKILL.md"))
        let plan = try BuiltInSkills.plan(brain: root)
        await #expect(throws: BuiltInSkills.Failure.self) {
            try await BuiltInSkills.apply(plan, names: ["akit"], env: env)
        }
    }

    @Test func commandShowsThenWrites() async throws {
        try await oldBrain()
        let shown = await akit("skills", "builtin")
        #expect(shown.code == 0)
        #expect(shown.out.contains("akit-context") && shown.out.contains("missing"))
        #expect(try BuiltInSkills.plan(brain: root).needsWork)

        let json = await akit("skills", "builtin", "--json")
        #expect(json.out.contains("\"state\" : \"missing\""))

        let written = await akit("skills", "builtin", "akit-context", "--mode", "manual", "--yes")
        #expect(written.code == 0, "\(written.err)")
        let after = try BuiltInSkills.plan(brain: root)
        #expect(after.items.first { $0.name == "akit-context" }?.state == .current)
        #expect(after.items.first { $0.name == "akit-context" }?.mode == .manual)
        #expect(after.items.first { $0.name == "akit" }?.state == .outdated)
        #expect(written.out.contains("akit apply --home"))
    }
}
