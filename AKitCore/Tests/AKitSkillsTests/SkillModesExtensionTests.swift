import Foundation
import Testing
import AKitFoundation
@testable import AKitSkills

/// The Pi skill modes extension's text and installer, in a temporary fake home.
struct SkillModesExtensionTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-modes-ext-\(UUID().uuidString)")
        try fm.createDirectory(at: home.appending(path: ".pi/agent"), withIntermediateDirectories: true)
    }

    var installer: SkillModesExtension { SkillModesExtension(env: HarnessEnvironment(homeDirectory: home)) }

    /// The text is embedded in the code; it must equal the file `make test-skill-modes` tests
    /// (tools/gen-skill-modes-extension.sh after an edit).
    @Test func theEmbeddedTextEqualsTheResource() throws {
        let file = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../../Sources/AKitSkills/Resources/akit-skill-modes.ts").standardized
        #expect(try String(contentsOf: file, encoding: .utf8) == SkillModesExtension.text)
        #expect(SkillModesExtension.text.split(separator: "\n").first?.contains(SkillModesExtension.marker) == true)
    }

    @Test func installWritesThenIsCurrentAndUninstallTrashes() throws {
        #expect(installer.status().state == .missing)
        let plan = try installer.installPlan()
        #expect(plan.text(home: home).contains("NEW ~/.pi/agent/extensions/akit-skill-modes.ts"))
        #expect(try installer.execute(plan) == nil)
        #expect(installer.status().state == .current)
        #expect(try installer.installPlan().isEmpty)

        var trashed: [URL] = []
        try installer.execute(installer.uninstallPlan()) { trashed.append($0); try FileManager.default.removeItem(at: $0); return nil }
        #expect(trashed == [installer.file])
        #expect(installer.status().state == .missing)
    }

    @Test func anOlderAKitTextIsReplacedWithoutABackup() throws {
        try fm.createDirectory(at: installer.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("// \(SkillModesExtension.marker) (old)\n".utf8).write(to: installer.file)
        #expect(installer.status().state == .outdated)
        let plan = try installer.installPlan()
        #expect(!plan.backup && plan.text(home: home).contains("CHANGED"))
        #expect(try installer.execute(plan) == nil)
        #expect(installer.status().state == .current)
    }

    @Test func aForeignFileIsBackedUpBeforeAReplaceAndNeverTrashed() throws {
        try fm.createDirectory(at: installer.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("// mine\n".utf8).write(to: installer.file)
        #expect(installer.status().state == .foreign)
        #expect(installer.uninstallPlan().isEmpty)
        let plan = try installer.installPlan()
        #expect(plan.backup)
        let backup = try #require(try installer.execute(plan))
        #expect(fm.fileExists(atPath: backup.appending(path: ".pi/agent/extensions/akit-skill-modes.ts").path))
    }

    @Test func aFileChangedSinceThePreviewIsLeftAlone() throws {
        let plan = try installer.installPlan()
        try fm.createDirectory(at: installer.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("// meanwhile\n".utf8).write(to: installer.file)
        #expect(throws: SkillModesExtension.Failure.self) { try installer.execute(plan) }
        #expect(try String(contentsOf: installer.file, encoding: .utf8) == "// meanwhile\n")
    }

    @Test func withoutPiNothingIsWritten() throws {
        try fm.removeItem(at: home.appending(path: ".pi"))
        #expect(throws: SkillModesExtension.Failure.self) { try installer.installPlan() }
    }
}
