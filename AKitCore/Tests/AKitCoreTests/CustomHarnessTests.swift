import Foundation
import Testing
@testable import AKitCore

struct CustomHarnessTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-custom-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var env: HarnessEnvironment { HarnessEnvironment(homeDirectory: home) }

    func write(_ path: String, _ text: String) throws {
        let url = home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    var goose: CustomHarness {
        CustomHarness(id: "goose", name: "Goose", command: "goose", configRoot: "~/.config/goose",
                      settingsFile: "config.yaml", skillFolders: ["skills", "~/.agents/skills"],
                      projectSkillFolder: ".goose/skills", instructionsFile: "~/.goosehints")
    }

    @Test func notInstalledIsNotDetected() {
        #expect(CustomHarnessAdapter(goose).detect(in: env) == nil)
    }

    @Test func detectedByConfigFolderWithLocations() throws {
        try write(".config/goose/config.yaml", "a: 1")
        let found = try #require(CustomHarnessAdapter(goose).detect(in: env))
        #expect(found.isCustom)
        #expect(found.displayName == "Goose")
        #expect(found.id == HarnessID("custom:goose", displayName: "Goose"))
        let byURL = Dictionary(uniqueKeysWithValues: found.locations.map { ($0.url.path, $0) })
        #expect(byURL[home.appending(path: ".config/goose/config.yaml").path]?.exists == true)
        #expect(byURL[home.appending(path: ".config/goose/skills").path]?.exists == false)
        #expect(byURL[home.appending(path: ".goosehints").path] != nil)
    }

    @Test func customHarnessSharesSkillsWithBuiltIns() throws {
        try write(".config/goose/config.yaml", "a: 1")
        try write(".agents/skills/tdd/SKILL.md", "---\nname: tdd\ndescription: d\n---\n")
        try write("Projects/app/.goose/skills/ship/SKILL.md", "---\nname: ship\ndescription: d\n---\n")
        try fm.createDirectory(at: home.appending(path: ".pi/agent"), withIntermediateDirectories: true)

        let adapters = HarnessCatalog.allAdapters(custom: [goose])
        let installed = HarnessCatalog.detectAll(in: env, adapters: adapters)
        let skills = SkillScanner.scan(installations: installed,
                                       extraProjects: [home.appending(path: "Projects/app")],
                                       adapters: adapters, in: env)
        let byName = Dictionary(uniqueKeysWithValues: skills.map { ($0.name, $0.visibleTo.map(\.rawValue)) })
        #expect(byName["tdd"] == ["custom:goose", "pi"])
        #expect(byName["ship"] == ["custom:goose"])
    }

    @Test func storeRoundTripKeepsBackup() throws {
        try CustomHarnessStore.save([goose], in: env)
        #expect(try CustomHarnessStore.load(in: env) == [goose])

        var renamed = goose
        renamed.name = "Goose CLI"
        try CustomHarnessStore.save([renamed], in: env)
        #expect(try CustomHarnessStore.load(in: env).first?.name == "Goose CLI")
        let backup = CustomHarnessStore.url(in: env).appendingPathExtension("bak")
        #expect(try String(contentsOf: backup, encoding: .utf8).contains("\"Goose\""))
    }

    @Test func handEditedFileWithMissingKeysLoads() throws {
        try write(".akit/harnesses.json", #"{"harnesses": [{"name": "My Agent", "command": "myagent"}]}"#)
        let loaded = try CustomHarnessStore.load(in: env)
        #expect(loaded.first?.id == "my-agent")
        #expect(loaded.first?.skillFolders == [])
    }

    @Test func brokenFileThrows() throws {
        try write(".akit/harnesses.json", "{ not json")
        #expect(throws: (any Error).self) { try CustomHarnessStore.load(in: env) }
    }

    @Test func validation() {
        #expect(CustomHarness(name: "", command: "x").validate(against: [], reservedNames: []).contains("Name is required."))
        #expect(CustomHarness(name: "X").validate(against: [], reservedNames: []).count == 1) // no command/folder
        #expect(!CustomHarness(name: "claude code", command: "c").validate(against: [], reservedNames: ["Claude Code"]).isEmpty)
        #expect(!CustomHarness(name: "A", command: "a", projectSkillFolder: "~/x").validate(against: [], reservedNames: []).isEmpty)
        #expect(goose.validate(against: [goose], reservedNames: ["Claude Code", "Pi"]).isEmpty)
        #expect(CustomHarness.slug("My Agent 2!") == "my-agent-2")
    }
}
