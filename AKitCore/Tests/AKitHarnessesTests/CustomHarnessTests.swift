import Foundation
import Testing
import AKitFoundation
import AKitModel
import AKitSkills
@testable import AKitHarnesses

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
        let folder = CustomHarnessStore.backupFolder(in: env)
        let backups = try fm.contentsOfDirectory(atPath: folder.path)
        #expect(backups.count == 1)
        #expect(try String(contentsOf: folder.appending(path: backups[0]), encoding: .utf8).contains("\"Goose\""))
    }

    @Test func updateRereadsTheFileAndRefusesBrokenOnes() throws {
        try CustomHarnessStore.save([goose], in: env)
        // Someone adds an entry by hand while AKit is open.
        try write(".akit/harnesses.json", #"{"harnesses": [{"name": "Goose", "command": "goose"}, {"name": "Hand", "command": "hand"}]}"#)
        let saved = try CustomHarnessStore.update(in: env) { $0 + [CustomHarness(id: "new-one", name: "New One", command: "n")] }
        #expect(saved.map(\.id) == ["goose", "hand", "new-one"])

        try write(".akit/harnesses.json", "{ broken")
        #expect(throws: (any Error).self) { try CustomHarnessStore.update(in: env) { $0 } }
        #expect(try String(contentsOf: CustomHarnessStore.url(in: env), encoding: .utf8) == "{ broken")
    }

    @Test func wrongTypesAndDuplicateIDsAreErrors() throws {
        try write(".akit/harnesses.json", #"{"harnesses": [{"name": "A", "skillFolders": "~/x"}]}"#)
        #expect(throws: (any Error).self) { try CustomHarnessStore.load(in: env) }
        try write(".akit/harnesses.json", #"{"harnesses": [{"name": "A b"}, {"name": "a-B"}]}"#)
        #expect(throws: CustomHarnessStore.Failure.self) { try CustomHarnessStore.load(in: env) }
    }

    @Test func symlinkedFileStaysASymlink() throws {
        try write("dotfiles/harnesses.json", #"{"harnesses": []}"#)
        try fm.createDirectory(at: home.appending(path: ".akit"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: CustomHarnessStore.url(in: env), withDestinationURL: home.appending(path: "dotfiles/harnesses.json"))
        try CustomHarnessStore.update(in: env) { $0 + [goose] }
        #expect((try? fm.destinationOfSymbolicLink(atPath: CustomHarnessStore.url(in: env).path)) != nil)
        #expect(try String(contentsOf: home.appending(path: "dotfiles/harnesses.json"), encoding: .utf8).contains("goose"))
    }

    @Test func relativeConfigFolderDoesNotLoopOrDetect() throws {
        let bad = CustomHarness(id: "bad", name: "Bad", configRoot: ".config/bad", skillFolders: ["skills"])
        #expect(CustomHarnessAdapter(bad).detect(in: env) == nil)
        #expect(CustomHarnessAdapter(bad).skillRoots(in: env, projects: []).isEmpty)
        #expect(bad.validate(against: [], reservedNames: [], isNew: true).contains("Config folder must start with / or ~/."))
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
        func problems(_ h: CustomHarness, _ others: [CustomHarness] = [], isNew: Bool = true) -> [String] {
            h.validate(against: others, reservedNames: ["Claude Code", "Pi"], isNew: isNew)
        }
        #expect(problems(CustomHarness(name: "", command: "x")).contains("Name is required."))
        #expect(problems(CustomHarness(name: "X")).count == 1) // no command/folder
        #expect(!problems(CustomHarness(name: "claude code", command: "c")).isEmpty)
        #expect(!problems(CustomHarness(name: "A", command: "a", projectSkillFolder: "~/x")).isEmpty)
        #expect(!problems(CustomHarness(name: "A", command: "a", projectSkillFolder: ".")).isEmpty)
        #expect(!problems(CustomHarness(name: "A", command: "a", skillFolders: ["skills"])).isEmpty) // relative, no root
        #expect(!problems(CustomHarness(name: "A", configRoot: "~/a", skillFolders: ["../x"])).isEmpty)
        #expect(problems(goose, [goose], isNew: false).isEmpty)       // editing itself is fine
        #expect(!problems(goose, [goose], isNew: true).isEmpty)       // adding a second Goose is not
        var renamed = goose
        renamed.name = "Other"
        #expect(!problems(CustomHarness(name: "Goose", command: "g"), [renamed]).isEmpty) // id "goose" is taken
        #expect(CustomHarness.slug("My Agent 2!") == "my-agent-2")
    }
}
