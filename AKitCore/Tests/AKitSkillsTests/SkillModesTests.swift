import Foundation
import Testing
import AKitFoundation
@testable import AKitSkills

/// Skill modes per project (skill-modes.md) in a temporary fake home: reading the file entry by
/// entry, resolving a run's modes and renames, and writing through `SettingsFile`.
struct SkillModesTests {
    let home: URL
    let fm = FileManager.default
    let project = "gitlab.example.com/team/app"

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-modes-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var env: HarnessEnvironment { HarnessEnvironment(homeDirectory: home) }
    var file: URL { SkillModes.file(home: home) }

    func write(_ path: String, _ text: String) throws {
        let url = home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func skill(_ name: String, manual: Bool = false, description: String? = nil) -> String {
        "---\nname: \(name)\ndescription: \(description ?? "Does \(name)")\n\(manual ? "disable-model-invocation: true\n" : "")---\n\nbody of \(name)\n"
    }

    func reading(_ text: String) -> SkillModes.Reading { SkillModes.read(data: Data(text.utf8)) }

    // MARK: Reading

    @Test func aMissingFileChangesNothing() {
        let read = SkillModes.read(file, home: home)
        #expect(!read.exists && read.usable && read.projects.isEmpty && read.problems.isEmpty)
    }

    @Test func entriesAreReadOneByOneAndBadOnesAreSkipped() {
        let read = reading(#"{"version":1,"projects":{"p":{"a":"auto","b":"loud","c":3,"d":"off"},"q":"oops"}}"#)
        #expect(read.usable)
        #expect(read.projects == ["p": ["a": .auto, "d": .off]])
        #expect(read.problems.map(\.kind) == ["entry", "entry", "entry"])
        #expect(read.problems.contains { $0.name == "b" && $0.message.contains("\"loud\"") })
        #expect(read.problems.contains { $0.project == "q" && $0.name == nil })
    }

    @Test func badJSONOrAnotherVersionMakesTheWholeFileUnused() {
        for text in ["{", "[]", #"{"version":2,"projects":{"p":{"a":"auto"}}}"#, #"{"projects":{"p":{"a":"auto"}}}"#,
                     #"{"version":1,"projects":[]}"#, #"{"version":1,"version":1}"#] {
            let read = reading(text)
            #expect(!read.usable, "\(text)")
            #expect(read.projects.isEmpty && read.problems.count == 1 && read.problems[0].kind == "file", "\(text)")
        }
    }

    // MARK: Resolving

    func loaded(_ name: String, scope: String = "user", origin: String = "top-level", path: String? = nil) -> SkillModes.LoadedSkill {
        .init(name: name, scope: scope, origin: origin, path: path ?? home.appending(path: ".agents/skills/\(name)/SKILL.md").path)
    }

    @Test func onlyTheProjectsEntriesForLoadedSkillsComeBack() {
        let read = reading(#"{"version":1,"projects":{"\#(project)":{"tdd":"auto","gone":"off","flowskill":"off"},"other":{"x":"auto"}}}"#)
        let skills = [loaded("tdd"), loaded("x"), loaded("flowskill", scope: "temporary")]
        let result = SkillModes.resolve(file: read, skills: skills, projectID: project, userFolders: SkillModes.piUserFolders(in: env))
        #expect(result.project == project)
        #expect(result.modes == ["tdd": .auto])
        #expect(result.renames.isEmpty)
        // Outside git: nothing applies.
        #expect(SkillModes.resolve(file: read, skills: skills, projectID: nil, userFolders: []).modes.isEmpty)
    }

    @Test func anUnusableFileAppliesNothingAndSaysWhy() {
        let read = reading("{nope")
        let result = SkillModes.resolve(file: read, skills: [loaded("tdd")], projectID: project, userFolders: [])
        #expect(result.modes.isEmpty)
        #expect(result.problems.first?.kind == "file")
        #expect(result.json.contains(#""problems":[{"kind":"file""#))
    }

    @Test func aPersonalSkillHiddenByTheProjectsComesBackAsMyName() throws {
        try write(".agents/skills/review/SKILL.md", skill("review", manual: true, description: "My review"))
        try write(".pi/agent/skills/lint/SKILL.md", skill("lint"))
        try write(".agents/skills/lint/SKILL.md", skill("lint", manual: true))  // Pi's agent folder comes first
        let teamReview = "/repo/.agents/skills/review/SKILL.md", teamLint = "/repo/.pi/skills/lint/SKILL.md"
        let skills = [loaded("review", scope: "project", path: teamReview), loaded("lint", scope: "project", path: teamLint), loaded("tdd")]
        let read = reading(#"{"version":1,"projects":{"\#(project)":{"review":"off","my-lint":"manual"}}}"#)
        let result = SkillModes.resolve(file: read, skills: skills, projectID: project, userFolders: SkillModes.piUserFolders(in: env))
        #expect(result.modes == ["review": .off])
        let review = try #require(result.renames["my-review"])
        #expect(review.original == "review" && review.mode == .manual && review.from == "skill" && review.description == "My review")
        #expect(review.file == home.appending(path: ".agents/skills/review/SKILL.md").path)
        #expect(review.baseDir == home.appending(path: ".agents/skills/review").path)
        let lint = try #require(result.renames["my-lint"])
        #expect(lint.file == home.appending(path: ".pi/agent/skills/lint/SKILL.md").path)
        #expect(lint.mode == .manual && lint.from == "project")
    }

    @Test func noRenameForTheSameFileTemporarySkillsOrATakenName() throws {
        try write(".agents/skills/review/SKILL.md", skill("review"))
        try write(".agents/skills/plan/SKILL.md", skill("plan"))
        try write(".agents/skills/fix/SKILL.md", skill("fix"))
        let same = home.appending(path: ".agents/skills/review/SKILL.md").path
        let skills = [loaded("review", scope: "project", path: same), loaded("plan", scope: "temporary", path: "/x/plan/SKILL.md"),
                      loaded("fix", scope: "project", path: "/repo/fix/SKILL.md"), loaded("my-fix")]
        let result = SkillModes.resolve(file: SkillModes.Reading(), skills: skills, projectID: project, userFolders: SkillModes.piUserFolders(in: env))
        #expect(result.renames.isEmpty)
        #expect(result.problems.map(\.kind) == ["rename"])
    }

    @Test func aPersonalSkillPiTurnedOffIsNotOfferedAndTheNextFolderCounts() throws {
        try write(".pi/agent/skills/review/SKILL.md", skill("review", description: "Off in Pi"))
        try write(".agents/skills/review/SKILL.md", skill("review", description: "Mine"))
        try write(".agents/skills/lint/SKILL.md", skill("lint"))
        let skills = [loaded("review", scope: "project", path: "/repo/review/SKILL.md"), loaded("lint", scope: "project", path: "/repo/lint/SKILL.md")]
        let folders = SkillModes.piUserFolders(in: env)
        // `akit skills set --state off` writes `-skills/review/SKILL.md`, relative to each folder's parent.
        let off = SkillModes.resolve(file: .init(), skills: skills, projectID: project, userFolders: folders,
                                     userEntries: ["-skills/review/SKILL.md", "!lint"])
        #expect(off.renames.isEmpty)
        // Only ~/.pi/agent's review off: ~/.agents' review is the one Pi loads, so it is offered.
        let one = SkillModes.resolve(file: .init(), skills: skills, projectID: project, userFolders: folders,
                                     userEntries: ["-\(home.appending(path: ".pi/agent/skills/review/SKILL.md").path)"])
        #expect(one.renames["my-review"]?.description == "Mine")
        #expect(one.renames["my-lint"] != nil)
        // Pi's settings unreadable: no rename, said why.
        let unknown = SkillModes.resolve(file: .init(), skills: skills, projectID: project, userFolders: folders, userEntries: nil)
        #expect(unknown.renames.isEmpty && unknown.problems.map(\.kind) == ["rename"])
    }

    @Test func onlyAProjectSkillHidesOneOfYours() throws {
        try write(".agents/skills/review/SKILL.md", skill("review"))
        let package = loaded("review", scope: "project", origin: "package", path: "/repo/node_modules/x/review/SKILL.md")
        #expect(SkillModes.resolve(file: .init(), skills: [package], projectID: project, userFolders: SkillModes.piUserFolders(in: env)).renames.isEmpty)
    }

    @Test func piUserSkillEntriesComeFromPisSettings() throws {
        #expect(SkillModes.piUserSkillEntries(in: env) == [])
        try write(".pi/agent/settings.json", #"{"skills": ["-skills/x/SKILL.md", 3, "!y"]}"#)
        #expect(SkillModes.piUserSkillEntries(in: env) == ["-skills/x/SKILL.md", "!y"])
        try write(".pi/agent/settings.json", "{ nope")
        #expect(SkillModes.piUserSkillEntries(in: env) == nil)
    }

    @Test func myNameAlwaysMeansYourOwnSkill() {
        let read = reading(#"{"version":1,"projects":{"\#(project)":{"review":"off","my-review":"auto","tdd":"manual"}}}"#)
        // No team review here (or an untrusted worktree): Pi loads yours as review; my-review sets it.
        let yours = SkillModes.resolve(file: read, skills: [loaded("review"), loaded("tdd")], projectID: project, userFolders: [])
        #expect(yours.modes == ["review": .auto, "tdd": .manual])
        // The team's review: the review entry is for it.
        let team = SkillModes.resolve(file: read, skills: [loaded("review", scope: "project", path: "/repo/review/SKILL.md")], projectID: project,
                                      userFolders: [])
        #expect(team.modes == ["review": .off])
        // Without a my- entry, the entry applies to whatever Pi loads under the name.
        let plain = reading(#"{"version":1,"projects":{"\#(project)":{"review":"off"}}}"#)
        #expect(SkillModes.resolve(file: plain, skills: [loaded("review")], projectID: project, userFolders: []).modes == ["review": .off])
    }

    @Test func theAnswerIsOneLineOfJSONWithANullProject() {
        let json = SkillModes.Resolution(project: nil).json
        #expect(json == #"{"modes":{},"problems":[],"project":null,"renames":{},"version":1}"#)
    }

    // MARK: Writing

    @Test func aFirstWriteCreatesThePrivateFolderAndTheFile() throws {
        let plan = try SkillModes.plan(set: .auto, name: "tdd", project: project, home: home)
        #expect(plan.creates && !plan.changesNothing)
        #expect(plan.summary.contains("Auto"))
        // The whole new file, not one excerpt per edit.
        #expect(TextDiff.unified(plan.diff) == ["+ {", "+   \"version\": 1,", "+   \"projects\": {", "+     \"\(project)\": {",
                                                "+       \"tdd\": \"auto\"", "+     }", "+   }", "+ }"])
        #expect(try SkillModes.apply(plan, home: home) == nil)
        let read = SkillModes.read(file, home: home)
        #expect(read.projects == [project: ["tdd": .auto]])
        let mode = try fm.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions] as? Int
        #expect(mode == 0o700)
        #expect(try fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
        try SkillModes.apply(try SkillModes.plan(set: .off, name: "lint", project: project, home: home), home: home)
        #expect(try fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
    }

    @Test func anExistingLocalFolderKeepsItsMode() throws {
        let folder = home.appending(path: ".akit/local")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try SkillModes.apply(try SkillModes.plan(set: .auto, name: "tdd", project: project, home: home), home: home)
        #expect(try fm.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int == 0o755)
    }

    @Test func aChangeKeepsTheRestAndBacksUp() throws {
        let original = """
            {
              "version": 1,
              "projects": {
                "other": { "x": "manual" },
                "\(project)": { "tdd": "manual", "bad": "loud" }
              }
            }

            """
        try write(".akit/local/skill-modes.json", original)
        let plan = try SkillModes.plan(set: .auto, name: "tdd", project: project, home: home)
        #expect(plan.summary.contains("was Manual"))
        let backup = try #require(try SkillModes.apply(plan, home: home))
        #expect(try String(contentsOf: backup, encoding: .utf8) == original)
        let now = try String(contentsOf: file, encoding: .utf8)
        #expect(now == original.replacingOccurrences(of: #""tdd": "manual""#, with: #""tdd": "auto""#))
        #expect(try SkillModes.plan(set: .auto, name: "tdd", project: project, home: home).changesNothing)
    }

    @Test func aResetTakesTheEntryOutAndAnEmptyProjectToo() throws {
        try write(".akit/local/skill-modes.json", #"{"version":1,"projects":{"\#(project)":{"a":"auto","b":"off"},"other":{"x":"auto"}}}"#)
        try SkillModes.apply(try SkillModes.plan(reset: "a", project: project, home: home), home: home)
        #expect(SkillModes.read(file, home: home).projects[project] == ["b": .off])
        try SkillModes.apply(try SkillModes.plan(reset: "b", project: project, home: home), home: home)
        let read = SkillModes.read(file, home: home)
        #expect(read.projects == ["other": ["x": .auto]])
        #expect(!(try String(contentsOf: file, encoding: .utf8)).contains(project))
        #expect(try SkillModes.plan(reset: "b", project: project, home: home).changesNothing)
    }

    @Test func aProjectResetTakesAllItsEntriesOut() throws {
        try write(".akit/local/skill-modes.json", #"{"version":1,"projects":{"\#(project)":{"a":"auto","b":"off"},"other":{"x":"auto"}}}"#)
        let plan = try SkillModes.plan(resetProject: project, home: home)
        #expect(plan.summary.contains("2 entries"))
        try SkillModes.apply(plan, home: home)
        #expect(SkillModes.read(file, home: home).projects == ["other": ["x": .auto]])
        #expect(try SkillModes.plan(resetProject: project, home: home).changesNothing)
    }

    @Test func aFileAKitCantReadIsNeverRewritten() throws {
        for text in ["{ broken", #"{"version":2,"projects":{}}"#] {
            try write(".akit/local/skill-modes.json", text)
            #expect(throws: SkillModes.Failure.self) { try SkillModes.plan(set: .off, name: "tdd", project: project, home: home) }
            #expect(try String(contentsOf: file, encoding: .utf8) == text)
        }
    }

    @Test func aChangeSinceThePreviewIsRefused() throws {
        try write(".akit/local/skill-modes.json", #"{"version":1,"projects":{"\#(project)":{"tdd":"manual"}}}"#)
        let plan = try SkillModes.plan(set: .auto, name: "tdd", project: project, home: home)
        try write(".akit/local/skill-modes.json", #"{"version":1,"projects":{"\#(project)":{"tdd":"off"}}}"#)
        #expect(throws: SkillModes.Failure.self) { try SkillModes.apply(plan, home: home) }
        #expect(SkillModes.read(file, home: home).projects[project] == ["tdd": .off])
    }

    @Test func aNameWithASlashIsRefused() {
        #expect(throws: SkillModes.Failure.self) { try SkillModes.plan(set: .auto, name: "a/b", project: project, home: home) }
    }
}
