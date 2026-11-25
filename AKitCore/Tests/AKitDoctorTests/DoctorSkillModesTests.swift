import Foundation
import Testing
import AKitFoundation
import AKitSkills
@testable import AKitDoctor

/// `akit doctor`'s Skill modes lines, in a temporary fake home with a fake repository.
struct DoctorSkillModesTests {
    let home: URL
    let repo: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-doctor-modes-\(UUID().uuidString)")
        repo = home.appending(path: "Projects/app")
        try fm.createDirectory(at: home.appending(path: ".pi/agent"), withIntermediateDirectories: true)
        try fm.createDirectory(at: repo.appending(path: ".git"), withIntermediateDirectories: true)
        try Data("[remote \"origin\"]\n\turl = https://example.com/team/app.git\n".utf8).write(to: repo.appending(path: ".git/config"))
        try fm.createDirectory(at: home.appending(path: ".agents/skills/tdd"), withIntermediateDirectories: true)
        try Data("---\nname: tdd\ndescription: Tests first\n---\n".utf8).write(to: home.appending(path: ".agents/skills/tdd/SKILL.md"))
    }

    var env: HarnessEnvironment { HarnessEnvironment(homeDirectory: home) }

    func modes(_ text: String) throws {
        try fm.createDirectory(at: home.appending(path: ".akit/local"), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: SkillModes.file(home: home))
    }

    func lines(piVersion: String? = "1.5.2") -> [String] {
        Doctor.skillModeLines(piFound: true, piVersion: piVersion, projects: [repo], projectsRoot: home.appending(path: "Projects"), env: env,
                              tilde: { FileWalk.tilde($0, home: home) })
    }

    @Test func withoutAFileThereIsNoProblem() {
        let found = lines()
        #expect(found.contains("  no skill modes set (~/.akit/local/skill-modes.json; akit skills mode)"))
        #expect(!found.contains { $0.hasPrefix("!") })
    }

    @Test func aFileThatDoesNotParseIsAProblem() throws {
        try modes("{ nope")
        #expect(lines().contains { $0.hasPrefix("! ~/.akit/local/skill-modes.json is not valid JSON") })
    }

    @Test func entriesWithoutTheExtensionAreAProblemAndUnknownNamesAndSkippedEntriesAreNotes() throws {
        try modes(#"{"version":1,"projects":{"example.com/team/app":{"tdd":"auto","gone":"off","bad":"loud"}}}"#)
        let found = lines()
        #expect(found.contains("! the Pi extension that applies skill modes is missing: akit skills extension install"))
        #expect(found.contains { $0.hasPrefix("  note: example.com/team/app bad: \"loud\" is not auto, manual or off") })
        #expect(found.contains { $0.hasPrefix("  note: example.com/team/app: no skill named gone in ~/Projects/app") })
        try SkillModesExtension(env: env).execute(try SkillModesExtension(env: env).installPlan())
        #expect(lines().contains("  Pi extension: ~/.pi/agent/extensions/akit-skill-modes.ts, current"))
    }

    @Test func anOlderPiIsAWarning() {
        #expect(lines(piVersion: "pi 1.4.9").contains("! skill modes may not apply in Pi 1.4.9 (checked on \(SkillModesExtension.minPi)); update Pi."))
        #expect(!lines(piVersion: "1.10.0").contains { $0.contains("may not apply") })
    }
}
