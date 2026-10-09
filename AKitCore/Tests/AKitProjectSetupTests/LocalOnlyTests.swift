import Foundation
import Testing
import AKitBrain
import AKitFoundation
import AKitRender
@testable import AKitProjectSetup

/// A project that is a git repository, with a brain (layers `task` and `mcp`), inside a
/// temporary fake home. Shared by the local-only and worktree tests.
struct GitProjectFixture {
    let home: URL
    let fm = FileManager.default

    init(_ name: String) throws {
        home = fm.temporaryDirectory.appending(path: "akit-\(name)-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var env: HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home, variables: [
            "HOME": home.path, "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
            "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
        ], executableSearchPaths: [URL(filePath: "/usr/bin")])
    }

    var brainRoot: URL { Brain.defaultRoot(home: home) }
    var project: URL { home.appending(path: "Projects/task") }
    var store: ProjectStore { .brain(brainRoot) }
    let id = "local/task"

    func write(_ path: String, _ text: String = "") throws {
        let url = home.appending(path: path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func read(_ path: String, in folder: URL? = nil) -> String? {
        try? String(contentsOf: (folder ?? project).appending(path: path), encoding: .utf8)
    }

    func trash(_ url: URL) throws -> URL? {
        let target = home.appending(path: "Trash/\(UUID().uuidString)-\(url.lastPathComponent)")
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: url, to: target)
        return target
    }

    @discardableResult
    func git(_ args: String..., in folder: URL? = nil) async throws -> String {
        let result = try #require(await ProcessRunner.run(URL(filePath: "/usr/bin/git"), arguments: args, directory: folder ?? project,
                                                           environment: env.variables, timeout: 20))
        #expect(result.succeeded, "git \(args.joined(separator: " ")): \(result.output)")
        return result.output
    }

    /// Layer `task`: skills `tdd` and (while `review`) `review`, AGENTS.md; layer `mcp`: a server in `.mcp.json`.
    func setUpBrain() async throws -> Brain {
        try await BrainSetup.create(at: brainRoot, env: env)
        try write(".akit/registry/skills/tdd/SKILL.md", "---\nname: tdd\ndescription: Tests first\n---\n")
        try write(".akit/registry/skills/review/SKILL.md", "---\nname: review\ndescription: Review\n---\n")
        try write(".akit/registry/layers/task/layer.yaml", """
            fields:
              - id: review
                type: bool
                default: true
            skills:
              - tdd
              - name: review
                when: review
            files:
              - template: agents.md
                to: AGENTS.md
            """)
        try write(".akit/registry/layers/task/templates/agents.md", "# Task\n")
        try write(".akit/registry/layers/mcp/layer.yaml", "files:\n  - template: one.json\n    to: .mcp.json\n")
        try write(".akit/registry/layers/mcp/templates/one.json", #"{"mcpServers": {"one": {"command": "one-server"}}}"#)
        return try #require(Brain.load(from: brainRoot))
    }

    /// `git init` in the project with `files` committed (path → text).
    func initRepo(_ files: [String: String] = ["README.md": "readme\n"]) async throws {
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        try await git("init", "-q", "-b", "main")
        for (path, text) in files { try write("Projects/task/\(path)", text) }
        try await git("add", "-A")
        try await git("commit", "-qm", "Start")
    }

    var excludeFile: URL { project.appending(path: ".git/info/exclude") }
    var exclude: String { (try? String(contentsOf: excludeFile, encoding: .utf8)) ?? "" }

    func answers(_ layers: [String] = ["task"], review: Bool = true, localOnly: Bool? = true) -> ProjectAnswers {
        ProjectAnswers(layers: layers, values: ["review": .bool(review)], targets: ["claude", "pi"], localOnly: localOnly)
    }

    func plan(_ answers: ProjectAnswers, brain: Brain, store: ProjectStore? = nil, folder: URL? = nil) -> ProjectSetup.Plan {
        ProjectSetup.plan(project: folder ?? project, id: id, answers: answers, brain: brain, store: store ?? self.store, env: env)
    }

    @discardableResult
    func apply(_ answers: ProjectAnswers, brain: Brain) async throws -> ProjectSetup.Outcome {
        let plan = plan(answers, brain: brain)
        #expect(plan.canApply, "\(plan.render.errors) \(plan.blockers)")
        return try await ProjectSetup.apply(plan, brain: brain, home: home, env: env, trash: trash)
    }
}

/// Local only: AKit's block in `.git/info/exclude`.
struct LocalOnlyTests {
    let f: GitProjectFixture

    init() throws { f = try GitProjectFixture("local-only") }

    @Test func theBlockIsWrittenUpdatedAndTakenOutAndOtherLinesStay() async throws {
        let brain = try await f.setUpBrain()
        try await f.initRepo()
        try Data("# mine\n*.log".utf8).write(to: f.excludeFile)

        let plan = f.plan(f.answers(), brain: brain)
        #expect(plan.localOnly)
        #expect(plan.exclude?.units == [".agents/skills/review", ".agents/skills/tdd", ".claude/skills", "AGENTS.md", "CLAUDE.md"])
        #expect(plan.notes.contains { $0.hasPrefix("Local only: AKit's block in .git/info/exclude keeps these out of git: /.agents/skills/review,") })
        #expect(f.exclude == "# mine\n*.log", "the plan only reads")

        try await f.apply(f.answers(), brain: brain)
        #expect(f.exclude == """
            # mine
            *.log
            \(LocalOnly.startMarker)
            /.agents/skills/review
            /.agents/skills/tdd
            /.claude/skills
            /AGENTS.md
            /CLAUDE.md
            \(LocalOnly.endMarker)

            """)
        #expect(try await f.git("status", "--porcelain", "--untracked-files=all").isEmpty)

        // A dropped skill leaves the block.
        try await f.apply(f.answers(review: false), brain: brain)
        #expect(LocalOnly.blockUnits(in: f.excludeFile) == [".agents/skills/tdd", ".claude/skills", "AGENTS.md", "CLAUDE.md"])

        // Committed again: the block comes out, the files show in git status.
        let back = f.plan(f.answers(review: false, localOnly: false), brain: brain)
        #expect(back.notes.contains("Not local only: AKit's block comes out of .git/info/exclude; its files show in git status."))
        try await f.apply(f.answers(review: false, localOnly: false), brain: brain)
        #expect(f.exclude == "# mine\n*.log\n")
        #expect(try await f.git("status", "--porcelain").contains("AGENTS.md"))
    }

    @Test func trackedFilesGetNoLineAndATrackedMergedFileWarns() async throws {
        let brain = try await f.setUpBrain()
        try await f.initRepo(["AGENTS.md": "# Ours\n", ".mcp.json": "{}\n",
                              ".agents/skills/team/SKILL.md": "---\nname: team\ndescription: Team\n---\n"])
        let plan = f.plan(f.answers(["task", "mcp"]), brain: brain)
        #expect(plan.render.warnings.contains(".mcp.json is tracked in git: AKit's keys show in git diff."))
        let units = try #require(plan.exclude?.units)
        #expect(!units.contains("AGENTS.md") && !units.contains(".mcp.json") && !units.contains(".agents/skills/team"))
        #expect(units.contains(".agents/skills/tdd"))

        try await f.apply(f.answers(["task", "mcp"]), brain: brain)
        let block = try #require(LocalOnly.blockUnits(in: f.excludeFile))
        #expect(!block.contains(".agents/skills/team") && !block.contains(".mcp.json") && !block.contains("AGENTS.md"))
    }

    @Test func aMergedFileAKitCreatedGetsALine() async throws {
        let brain = try await f.setUpBrain()
        try await f.initRepo()
        try await f.apply(f.answers(["task", "mcp"]), brain: brain)
        #expect(LocalOnly.blockUnits(in: f.excludeFile)?.contains(".mcp.json") == true)
        #expect(try await f.git("status", "--porcelain", "--untracked-files=all").isEmpty)
    }

    @Test func theMacsRoleDecidesWithoutAnAnswer() async throws {
        let brain = try await f.setUpBrain()
        try await f.initRepo()
        #expect(f.plan(f.answers(localOnly: nil), brain: brain).localOnly == false)
        let work = f.plan(f.answers(localOnly: nil), brain: brain, store: .local(home: f.home))
        #expect(work.localOnly && work.exclude?.units.isEmpty == false)
        #expect(f.plan(f.answers(localOnly: false), brain: brain, store: .local(home: f.home)).exclude == nil)
    }

    @Test func answersKeepLocalOnlyOnlyWhenSet() throws {
        let old = try JSONDecoder().decode(ProjectAnswers.self, from: Data(#"{"layers":[],"values":{},"targets":["pi"]}"#.utf8))
        #expect(old.localOnly == nil)
        #expect(!String(decoding: try JSONEncoder().encode(old), as: UTF8.self).contains("localOnly"))
        let set = try JSONDecoder().decode(ProjectAnswers.self, from: JSONEncoder().encode(ProjectAnswers(localOnly: false)))
        #expect(set.localOnly == false)
    }

    @Test func forgetTakesTheBlockOut() async throws {
        let brain = try await f.setUpBrain()
        try await f.initRepo()
        try Data("*.log\n".utf8).write(to: f.excludeFile)
        try await f.apply(f.answers(), brain: brain)
        let preview = try #require(ProjectForget.preview(id: f.id, folder: f.project, forHome: false, brain: brain, store: f.store, env: f.env))
        #expect(preview.excludeTakenOut != nil)
        try await ProjectForget.run(preview, keepFiles: true, brain: brain, home: f.home, env: f.env, trash: f.trash)
        #expect(f.exclude == "*.log\n")
        #expect(f.read("AGENTS.md") == "# Task\n")
    }

    @Test func notAGitRepositoryNeedsNothing() async throws {
        let brain = try await f.setUpBrain()
        try FileManager.default.createDirectory(at: f.project, withIntermediateDirectories: true)
        let plan = f.plan(f.answers(), brain: brain)
        #expect(plan.localOnly && plan.exclude == nil && plan.notes.isEmpty)
        try await f.apply(f.answers(), brain: brain)
        #expect(!FileManager.default.fileExists(atPath: f.project.appending(path: ".git").path))
    }

    @Test func aLinkedWorktreeIsBlocked() async throws {
        let brain = try await f.setUpBrain()
        try await f.initRepo()
        let tree = f.home.appending(path: "trees/task-x")
        try await f.git("worktree", "add", "-q", "-b", "x", tree.path)
        let plan = f.plan(f.answers(), brain: brain, folder: tree)
        let main = try #require(GitCheckout.at(tree)?.mainFolder).path
        #expect(plan.blockers == ["This folder is a git worktree of \(main). Set up \(main); AKit links its files into its worktrees."])
        #expect(!plan.canApply)
    }

    @Test func linesEscapeWildcardsAndReadBack() {
        #expect(LocalOnly.line(for: ".agents/skills/a*b") == "/.agents/skills/a\\*b")
        #expect(LocalOnly.line(for: "x[1]?\\ ") == "/x\\[1]\\?\\\\\\ ")
        for unit in [".agents/skills/a*b", "x[1]?\\ ", "AGENTS.md"] {
            #expect(LocalOnly.unit(fromLine: LocalOnly.line(for: unit)) == unit)
        }
    }

    @Test func aBrokenBlockIsLeftAlone() throws {
        func updated(_ text: String, _ units: [String]) -> String? {
            LocalOnly.updated(Data(text.utf8), units: units).map { String(decoding: $0, as: UTF8.self) }
        }
        #expect(updated("a\n\(LocalOnly.startMarker)\n/x\n", ["y"]) == nil)
        #expect(updated("a", ["y"]) == "a\n\(LocalOnly.startMarker)\n/y\n\(LocalOnly.endMarker)\n")
        #expect(updated("a\n", []) == "a\n")
    }

    @Test func aBrokenBlockShowsInThePreviewWithTheFix() async throws {
        let brain = try await f.setUpBrain()
        try await f.initRepo()
        let broken = "*.log\n\(LocalOnly.startMarker)\n/x\n\(LocalOnly.startMarker)\n"
        try Data(broken.utf8).write(to: f.excludeFile)
        let plan = f.plan(f.answers(), brain: brain)
        #expect(plan.exclude == nil)
        #expect(plan.notes.contains { $0.hasPrefix("Local only: \(f.excludeFile.path) has a broken AKit block") && $0.contains("by hand") }, "\(plan.notes)")
        #expect(!plan.notes.contains { $0.contains("keeps these out of git") })
        try await f.apply(f.answers(), brain: brain)
        #expect(f.exclude == broken)
    }

    @Test func otherLinesKeepTheirBytesEvenWhenNotUTF8() async throws {
        let brain = try await f.setUpBrain()
        try await f.initRepo()
        var mine = Data([0xFF, 0xFE, 0x2F, 0x78, 0x0A])  // not UTF-8
        mine.append(Data("*.log\r\nlast".utf8))
        try mine.write(to: f.excludeFile)
        try await f.apply(f.answers(), brain: brain)
        let after = try Data(contentsOf: f.excludeFile)
        #expect(after.starts(with: mine + Data("\n\(LocalOnly.startMarker)\n".utf8)))
        #expect(LocalOnly.blockUnits(in: f.excludeFile)?.contains("AGENTS.md") == true)
        #expect(try await f.git("status", "--porcelain", "--untracked-files=all").isEmpty)

        // Committed again: only AKit's block goes.
        try await f.apply(f.answers(localOnly: false), brain: brain)
        #expect(try Data(contentsOf: f.excludeFile) == mine + Data("\n".utf8))
    }

    @Test func anUnreadableExcludeFileIsLeftAlone() async throws {
        let brain = try await f.setUpBrain()
        try await f.initRepo()
        try Data("*.log\n".utf8).write(to: f.excludeFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: f.excludeFile.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: f.excludeFile.path) }
        let plan = f.plan(f.answers(), brain: brain)
        #expect(plan.exclude == nil && plan.notes.contains { $0.hasPrefix("Local only: Couldn't read \(f.excludeFile.path)") }, "\(plan.notes)")
        let outcome = try await f.apply(f.answers(), brain: brain)
        #expect(outcome.notes.contains { $0.hasPrefix("Couldn't read \(f.excludeFile.path)") }, "\(outcome.notes)")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: f.excludeFile.path)
        #expect(f.exclude == "*.log\n")
    }

    @Test func crlfLinesStayAndCRLFMarkersAreFound() throws {
        let text = "a\r\n\(LocalOnly.startMarker)\r\n/x\r\n\(LocalOnly.endMarker)\r\nb\r\n"
        let new = try #require(LocalOnly.updated(Data(text.utf8), units: ["y"]))
        #expect(String(decoding: new, as: UTF8.self) == "a\r\n\(LocalOnly.startMarker)\n/y\n\(LocalOnly.endMarker)\nb\r\n")
        try FileManager.default.createDirectory(at: f.home, withIntermediateDirectories: true)
        let file = f.home.appending(path: "exclude")
        try Data(text.utf8).write(to: file)
        #expect(LocalOnly.blockUnits(in: file) == ["x"])
        #expect(LocalOnly.write(units: [], to: file) == nil)
        #expect(String(decoding: try Data(contentsOf: file), as: UTF8.self) == "a\r\nb\r\n")
    }

    @Test func aLinkedExcludeFileIsWrittenThrough() async throws {
        let brain = try await f.setUpBrain()
        try await f.initRepo()
        let shared = f.home.appending(path: "shared-exclude")
        try Data("*.log\n".utf8).write(to: shared)
        try FileManager.default.removeItem(at: f.excludeFile)
        try FileManager.default.createSymbolicLink(at: f.excludeFile, withDestinationURL: shared)
        try await f.apply(f.answers(), brain: brain)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: f.excludeFile.path) == shared.path)
        #expect(LocalOnly.blockUnits(in: shared)?.contains("AGENTS.md") == true)
        #expect(try await f.git("status", "--porcelain", "--untracked-files=all").isEmpty)
    }

    @Test func unitsOutsideTheCheckoutOrWithLineBreaksAreRefused() {
        for line in ["/../shared/x", "//x", "/a/./b", "/a/../b", "/.", "/..", "/a/", "/a//b"] {
            #expect(LocalOnly.unit(fromLine: line) == nil, "\(line)")
        }
        #expect(LocalOnly.unit(fromLine: "/.agents/skills/ok") == ".agents/skills/ok")
        for unit in ["a\nb", "a\rb", "a\r\nb", "../x", "/x", "", "a/../b"] { #expect(!LocalOnly.isSafe(unit), "\(unit)") }

        let entry = ProjectRecords.Lock.Entry(sha256: "x", link: nil, layers: ["task"])
        let lock = ProjectRecords.Lock(brainCommit: nil, brainDirty: false,
                                       files: ["AGENTS.md": entry, "evil\n/etc": entry, "../up.md": entry, ".agents/skills/../x/SKILL.md": entry])
        #expect(LocalOnly.candidates(of: lock) == ["AGENTS.md"])
        #expect(LocalOnly.skipped(of: lock) == ["../up.md", ".agents/skills/..", "evil\n/etc"])
        // A line break never becomes a line of the block.
        let text = String(decoding: LocalOnly.updated(Data(), units: ["ok", "evil\n/etc"]) ?? Data(), as: UTF8.self)
        #expect(text == "\(LocalOnly.startMarker)\n/ok\n\(LocalOnly.endMarker)\n")
    }

    @Test func theBlockListsTheFilesBeforeApplyWritesThem() async throws {
        let brain = try await f.setUpBrain()
        try await f.initRepo()
        let plan = f.plan(f.answers(), brain: brain)
        // git fails once the preview is done: Apply can't ask which files git tracks.
        let bin = f.home.appending(path: "broken-bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: bin.appending(path: "git"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appending(path: "git").path)
        let broken = HarnessEnvironment(homeDirectory: f.home, variables: f.env.variables, executableSearchPaths: [bin])
        let outcome = try await ProjectSetup.apply(plan, brain: brain, home: f.home, env: broken, trash: f.trash)
        #expect(outcome.notes.contains { $0.hasPrefix("git didn't run") }, "\(outcome.notes)")
        #expect(try await f.git("status", "--porcelain", "--untracked-files=all").isEmpty)
    }

    @Test func aFailedForgetLeavesTheBlock() async throws {
        let brain = try await f.setUpBrain()
        try await f.initRepo()
        try await f.apply(f.answers(), brain: brain)
        let block = f.exclude
        let preview = try #require(ProjectForget.preview(id: f.id, folder: f.project, forHome: false, brain: brain, store: f.store, env: f.env))
        await #expect(throws: (any Error).self) {
            try await ProjectForget.run(preview, keepFiles: true, brain: brain, home: f.home, env: f.env,
                                        trash: { _ in throw CocoaError(.fileWriteNoPermission) })
        }
        #expect(f.exclude == block, "the record stays, so the block stays")
    }
}
