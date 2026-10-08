import Darwin
import Foundation
import Testing
import AKitFoundation
@testable import AKitHarnesses
@testable import AKitSkills
import AKitModel

/// Skills of Pi packages, in the same fake home as the other scanner tests.
extension SkillScannerTests {
    func piPackage(_ folder: String, name: String, version: String = "1.0.0", skills: [String]) throws {
        try write("\(folder)/package.json", #"{"name": "\#(name)", "version": "\#(version)"}"#)
        for skill in skills { try write("\(folder)/skills/\(skill)/SKILL.md", self.skill(skill)) }
    }

    @Test func piPackageSkillsAreListedWithTheirPackage() throws {
        try write(".pi/agent/settings.json", #"{"packages": ["npm:tools", {"source": "npm:quiet", "skills": []}]}"#)
        try piPackage(".pi/agent/npm/node_modules/tools", name: "tools", skills: ["review", "Bad_Name"])
        try piPackage(".pi/agent/npm/node_modules/quiet", name: "quiet", skills: ["hidden"])
        try write(".agents/skills/review/SKILL.md", skill("review"))

        let skills = scan()
        let byFile = Dictionary(uniqueKeysWithValues: skills.map { ($0.file.path, $0) })
        let packaged = try #require(byFile[home.appending(path: ".pi/agent/npm/node_modules/tools/skills/review/SKILL.md").path])
        #expect(packaged.scope == .package(name: "tools", project: nil))
        #expect(packaged.isReadOnly)
        #expect(packaged.origin == "npm:tools 1.0.0")
        #expect(packaged.visibleTo == [.pi])
        #expect(packaged.warnings.contains { $0.contains("collides") })
        let own = try #require(byFile[home.appending(path: ".agents/skills/review/SKILL.md").path])
        #expect(own.warnings.contains { $0.contains("collides") })
        let bad = try #require(skills.first { $0.name == "Bad_Name" })
        #expect(bad.warnings.contains { $0.contains("a-z, 0-9") })
        #expect(!skills.contains { $0.name == "hidden" }) // filtered out in the settings
    }

    @Test func projectPackageReplacesTheGlobalOneWithoutACollision() throws {
        let project = home.appending(path: "Projects/app")
        try write(".pi/agent/settings.json", #"{"packages": ["npm:tools"]}"#)
        try piPackage(".pi/agent/npm/node_modules/tools", name: "tools", skills: ["review"])
        try write("Projects/app/.pi/settings.json", #"{"packages": ["npm:tools@2"]}"#)
        try piPackage("Projects/app/.pi/npm/node_modules/tools", name: "tools", version: "2.0.0", skills: ["review"])

        let skills = scan(extraProjects: [project])
        #expect(skills.count == 2)
        #expect(Set(skills.map(\.scope)) == [.package(name: "tools", project: nil), .package(name: "tools", project: project)])
        #expect(skills.allSatisfy { $0.warnings.isEmpty })
    }

    @Test func autoloadDeltaHidesTheGlobalSkillInItsProject() throws {
        // The project turns the package's `review` off and has its own `review`: no collision there.
        let project = home.appending(path: "Projects/app")
        try write(".pi/agent/settings.json", #"{"packages": ["npm:tools"]}"#)
        try piPackage(".pi/agent/npm/node_modules/tools", name: "tools", skills: ["review", "lint"])
        try write("Projects/app/.pi/settings.json",
                  #"{"packages": [{"source": "npm:tools", "autoload": false, "skills": ["-skills/review"]}]}"#)
        try write("Projects/app/.pi/skills/review/SKILL.md", skill("review"))

        let skills = scan(extraProjects: [project])
        #expect(skills.allSatisfy { $0.warnings.isEmpty })
        // The package's files are listed once, under the global package.
        #expect(skills.filter { $0.scope == .package(name: "tools", project: nil) }.map(\.name).sorted() == ["lint", "review"])
    }

    @Test func secretsAndPipesNeverBecomeSkills() throws {
        let project = home.appending(path: "Projects/cloned")
        try write(".pi/agent/auth.json", #"{"token": "fake"}"#)
        try write("Projects/cloned/.pi/settings.json", #"{"packages": ["./kit"]}"#)
        try write("Projects/cloned/.pi/kit/package.json",
                  #"{"pi": {"skills": ["\#(home.path)/.pi/agent/auth.json", "../../../../.pi/agent/auth.json"]}}"#)
        // A FIFO named SKILL.md would block a reader forever.
        try fm.createDirectory(at: home.appending(path: ".agents/skills/pipe"), withIntermediateDirectories: true)
        #expect(mkfifo(home.appending(path: ".agents/skills/pipe/SKILL.md").path, 0o600) == 0)

        let skills = scan(extraProjects: [project])
        #expect(skills.isEmpty)
        // A listed root re-checks its files: one outside its folder is dropped.
        let outside = SkillRoot(url: home.appending(path: "Projects/cloned/.pi/kit"), harness: .pi,
                                scope: .package(name: "kit", project: project),
                                layout: .listed([home.appending(path: ".pi/agent/auth.json")]), isReadOnly: true)
        #expect(SkillScanner.found(in: outside).isEmpty)
    }

    @Test func projectPackageSkillCollidesInItsProjectOnly() throws {
        let project = home.appending(path: "Projects/app")
        let other = home.appending(path: "Projects/other")
        try fm.createDirectory(at: home.appending(path: ".pi/agent"), withIntermediateDirectories: true)
        try write("Projects/app/.pi/settings.json", #"{"packages": ["npm:tools"]}"#)
        try piPackage("Projects/app/.pi/npm/node_modules/tools", name: "tools", skills: ["review"])
        try write("Projects/other/.pi/skills/review/SKILL.md", skill("review"))
        try write("Projects/app/.pi/skills/review/SKILL.md", skill("review"))

        let skills = scan(extraProjects: [project, other])
        let packaged = try #require(skills.first { $0.scope == .package(name: "tools", project: project) })
        #expect(packaged.warnings.count == 1)
        #expect(packaged.warnings.first?.contains("Projects/app/.pi/skills/review") == true)
    }
}
