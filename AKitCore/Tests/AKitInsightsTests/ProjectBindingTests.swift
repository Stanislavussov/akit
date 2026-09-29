import Foundation
import Testing
import AKitBrain
@testable import AKitInsights
@testable import AKitFoundation

/// Binding sessions to projects. Real git repositories in a temporary fake home; sessions and
/// hook events written straight into a temporary index. Never touches the real home.
struct ProjectBindingTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-binding-\(UUID().uuidString)")
        try fm.createDirectory(at: home.appending(path: "Projects"), withIntermediateDirectories: true)
    }

    var env: HarnessEnvironment {
        HarnessEnvironment(homeDirectory: home, variables: [
            "HOME": home.path, "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
            "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
        ], executableSearchPaths: [URL(filePath: "/usr/bin")])
    }

    var root: URL { home.appending(path: "Projects") }
    func path(_ relative: String) -> String { home.appending(path: relative).path }

    // MARK: Helpers

    @discardableResult
    func git(_ arguments: String..., in folder: URL) async throws -> String {
        let git = try #require(env.findExecutable("git"))
        let result = try #require(await ProcessRunner.run(git, arguments: arguments, directory: folder,
                                                          environment: env.variables.merging(["PATH": env.pathForChildProcesses]) { $1 },
                                                          timeout: 30))
        #expect(result.succeeded, "git \(arguments): \(result.output)")
        return result.output
    }

    /// A repository with one commit on `main` at `relative` (under the fake home).
    @discardableResult
    func repository(_ relative: String, remote: String? = nil) async throws -> URL {
        let folder = home.appending(path: relative)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try await git("init", "-q", "-b", "main", in: folder)
        try await git("commit", "-q", "--allow-empty", "-m", "start", in: folder)
        if let remote { try await git("remote", "add", "origin", remote, in: folder) }
        return folder
    }

    func database() throws -> IndexDatabase { try IndexSchema.open(InsightsPaths(home: home).database) }

    func addSession(_ id: String, cwd: String?, branch: String? = nil, harness: String = "claude", started: Date = Date(),
                    in db: IndexDatabase) throws {
        try db.run("""
            INSERT INTO sessions(key, harness, native_id, cwd, git_branch, started, source_id, parser_version)
            VALUES(?, ?, ?, ?, ?, ?, 0, 1)
            """, "\(harness):\(id)", harness, id, cwd, branch, started.timeIntervalSince1970)
    }

    /// A hook event as `RecordSession` writes it for a folder in a repository.
    func addHook(_ id: String, cwd: String, commonDir: String?, remote: String?, ts: Int64 = 1, in db: IndexDatabase) throws {
        try db.run("""
            INSERT INTO hook_events(harness, session_id, ts, cwd, common_dir, remote_id, source_id, parser_version)
            VALUES('claude', ?, ?, ?, ?, ?, 0, 1)
            """, id, ts, cwd, commonDir, remote)
    }

    struct Bound: Equatable {
        let project: String?
        let method: String
        let confidence: String?
    }

    func binding(_ id: String, in db: IndexDatabase) throws -> Bound? {
        try db.rows("SELECT project_id, method, confidence FROM bindings WHERE session_key = ?", "claude:\(id)").first.map {
            Bound(project: $0[0].text, method: $0[1].text ?? "", confidence: $0[2].text)
        }
    }

    func bind(_ db: IndexDatabase) async throws -> ProjectBinder.Report {
        try await ProjectBinder(env: env, projectsRoot: root).bind(database: db)
    }

    func writeSettings(_ object: [String: Any]) throws {
        let url = InsightsPaths(home: home).settings
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    // MARK: Hooks, live folders, worktrees

    @Test func hookBindingWinsOverEverything() async throws {
        let app = try await repository("Projects/app", remote: "git@github.com:me/app.git")
        let local = try await repository("Projects/tools/local")
        let db = try database()
        // The folder exists and is app, but the hook saw another repository: the hook wins.
        try addSession("s1", cwd: app.path, in: db)
        try addHook("s1", cwd: app.path, commonDir: app.path + "/.git", remote: "github.com/me/other", in: db)
        // Only the common dir of a repository without a remote: the id ProjectSetup gives it.
        try addSession("s2", cwd: path("gone/wt"), in: db)
        try addHook("s2", cwd: path("gone/wt"), commonDir: local.path + "/.git", remote: nil, in: db)
        // No hook: the live folder.
        try addSession("s3", cwd: app.appending(path: "Sources").path, in: db)
        try fm.createDirectory(at: app.appending(path: "Sources"), withIntermediateDirectories: true)

        let report = try await bind(db)
        #expect(report == .init(changed: 3, pending: 0))
        #expect(try binding("s1", in: db) == Bound(project: "github.com/me/other", method: "hook", confidence: "exact"))
        let localID = await ProjectRecords.projectID(for: local, projectsRoot: root, env: env)
        #expect(localID == "local/tools/local")
        #expect(try binding("s2", in: db) == Bound(project: localID, method: "hook", confidence: "exact"))
        #expect(try binding("s3", in: db) == Bound(project: "github.com/me/app", method: "live", confidence: "exact"))
        #expect(try db.value("SELECT repo_path FROM bindings WHERE session_key = 'claude:s2'")?.text
                == BindingPaths.canonical(local.path + "/.git"))
        // Nothing to decide again.
        #expect(try await bind(db) == .init(changed: 0, pending: 0))
    }

    /// With `worktree.useRelativePaths` (git 2.48+) a worktree's `gitdir` is relative to its entry in
    /// `<common>/worktrees/`; written by hand, as the test Mac's git may be older.
    @Test func relativeGitdirResolvesToTheWorktree() throws {
        let common = path("app/.git")
        try fm.createDirectory(atPath: common + "/worktrees/f", withIntermediateDirectories: true)
        try Data("../../../../wt/f/.git\n".utf8).write(to: URL(filePath: common + "/worktrees/f/gitdir"))
        let folders = WorktreeListResolver.folders(commonDir: common)
        #expect(folders.map(BindingPaths.canonical) == [path("app"), path("wt/f")].map(BindingPaths.canonical))
        var worktrees = WorktreeListResolver(excluded: [])
        let repository = RepositoryMatch(projectID: "local/app", repoPath: common)
        worktrees.add(folders: folders, repository: repository)
        #expect(worktrees.repository(for: path("wt/f/Sources")) == repository)
        #expect(worktrees.repository(for: path("wt/other")) == nil)
    }

    @Test func deletedWorktreeResolvesViaWorktreeListUntilPruned() async throws {
        let app = try await repository("Projects/app")
        try await git("worktree", "add", "-q", "-b", "feature", path("wt/feature"), in: app)
        try await git("worktree", "add", "-q", "-b", "other", path("elsewhere/other"), in: app)
        let db = try database()
        // Deleted, but git still lists it (prunable): high.
        try fm.removeItem(atPath: path("wt/feature"))
        try addSession("s1", cwd: path("wt/feature/Sources"), in: db)
        #expect(try await git("worktree", "list", "--porcelain", in: app).contains("prunable"))
        _ = try await bind(db)
        #expect(try binding("s1", in: db) == Bound(project: "local/app", method: "worktree", confidence: "high"))

        // Pruned: git no longer knows the folder; nothing else points to a repository.
        try fm.removeItem(atPath: path("elsewhere/other"))
        try await git("worktree", "prune", in: app)
        try addSession("s2", cwd: path("elsewhere/other"), in: db)
        _ = try await bind(db)
        #expect(try binding("s2", in: db) == Bound(project: nil, method: "none", confidence: nil))
        // A decided high binding stays after the prune.
        #expect(try binding("s1", in: db)?.method == "worktree")
    }

    @Test func unknownStaysNone() async throws {
        let db = try database()
        try addSession("gone", cwd: path("gone/somewhere"), in: db)
        try addSession("nocwd", cwd: nil, in: db)
        // Existing folders that are no project: the home folder, one outside the projects root.
        try fm.createDirectory(atPath: path("Downloads"), withIntermediateDirectories: true)
        try addSession("home", cwd: home.path, in: db)
        try addSession("downloads", cwd: path("Downloads"), in: db)
        #expect(try await bind(db) == .init(changed: 4, pending: 0))
        for id in ["gone", "nocwd", "home", "downloads"] {
            #expect(try binding(id, in: db) == Bound(project: nil, method: "none", confidence: nil), "\(id)")
        }
        // Unchanged next run (the gone one is looked at again, the existing folders wait for a hook).
        #expect(try await bind(db) == .init(changed: 0, pending: 0))
        // A plain folder inside the projects root is a project, as for akit apply.
        try fm.createDirectory(at: root.appending(path: "notes"), withIntermediateDirectories: true)
        try addSession("notes", cwd: root.appending(path: "notes").path, in: db)
        _ = try await bind(db)
        #expect(try binding("notes", in: db) == Bound(project: "local/notes", method: "live", confidence: "exact"))
    }

    // MARK: Siblings, templates, branches

    /// `Projects/app` with a live worktree in `ws/app/one` (a sibling source) and the template
    /// `~/orca/{repo}/*`. Branches: `two` (loose), `three` (packed only).
    func siblingsAndTemplate(_ db: IndexDatabase) async throws {
        let app = try await repository("Projects/app", remote: "https://github.com/me/app.git")
        try await git("worktree", "add", "-q", "-b", "one", path("ws/app/one"), in: app)
        try await git("branch", "two", in: app)
        try await git("branch", "three", in: app)
        try await git("pack-refs", "--all", in: app)
        #expect(!fm.fileExists(atPath: app.path + "/.git/refs/heads/three"))
        try writeSettings(["pathTemplates": ["~/orca/{repo}/*", "not/absolute/{repo}"]])
        try addSession("one", cwd: path("ws/app/one"), branch: "one", in: db)
    }

    @Test func branchConfirmsSiblingToMediumAndTemplateIsMedium() async throws {
        let db = try database()
        try await siblingsAndTemplate(db)
        try addSession("two", cwd: path("ws/app/two"), branch: "two", in: db)
        try addSession("three", cwd: path("orca/app/three/Sources"), branch: "three", in: db)
        _ = try await bind(db)
        #expect(try binding("one", in: db) == Bound(project: "github.com/me/app", method: "live", confidence: "exact"))
        #expect(try binding("two", in: db) == Bound(project: "github.com/me/app", method: "branchConfirmed", confidence: "medium"))
        #expect(try binding("three", in: db) == Bound(project: "github.com/me/app", method: "template", confidence: "medium"))
    }

    @Test func unconfirmedSiblingIsLowAndTemplateIsMedium() async throws {
        let db = try database()
        try await siblingsAndTemplate(db)
        try addSession("sibling", cwd: path("ws/app/gone"), branch: "never-pushed", in: db)
        try addSession("template", cwd: path("orca/app/gone"), in: db)
        // Every repository has main: it confirms nothing.
        try addSession("main", cwd: path("ws/app/main"), branch: "main", in: db)
        // The template names no known repository.
        try addSession("stranger", cwd: path("orca/stranger/x"), branch: "two", in: db)
        _ = try await bind(db)
        #expect(try binding("sibling", in: db) == Bound(project: "github.com/me/app", method: "sibling", confidence: "low"))
        #expect(try binding("template", in: db) == Bound(project: "github.com/me/app", method: "template", confidence: "medium"))
        #expect(try binding("main", in: db) == Bound(project: "github.com/me/app", method: "sibling", confidence: "low"))
        #expect(try binding("stranger", in: db) == Bound(project: nil, method: "none", confidence: nil))

        // Two repositories next to each other: ambiguous, no sibling.
        let other = try await repository("Projects/other")
        try await git("worktree", "add", "-q", "-b", "x", path("ws/app/x"), in: other)
        try addSession("x", cwd: path("ws/app/x"), in: db)
        try addSession("ambiguous", cwd: path("ws/app/gone2"), in: db)
        _ = try await bind(db)
        #expect(try binding("ambiguous", in: db) == Bound(project: nil, method: "none", confidence: nil))
    }

    /// Orca and herdr worktrees bind without settings; folders of an unknown workspace tool
    /// that name a bound repository come back as a suggested template.
    @Test func builtInTemplatesBindAndUnknownWorkspacesAreSuggested() async throws {
        let db = try database()
        let app = try await repository("Projects/app", remote: "https://github.com/me/app.git")
        try addSession("main", cwd: app.path, in: db)
        try addSession("orca", cwd: path("orca/workspaces/app/pleco"), in: db)
        try addSession("herdr", cwd: path(".herdr/worktrees/App/calm-forest"), in: db)
        try addSession("tool1", cwd: path(".tool/trees/app/a"), in: db)
        try addSession("tool2", cwd: path(".tool/trees/app/b/Sources"), in: db)
        try addSession("once", cwd: path("elsewhere/app/c"), in: db)
        // A removed worktree whose folder kept a tool's files: no repository, but the template knows it.
        try fm.createDirectory(atPath: path(".herdr/worktrees/app/left-over/.omc"), withIntermediateDirectories: true)
        try addSession("leftover", cwd: path(".herdr/worktrees/app/left-over"), in: db)
        _ = try await bind(db)
        #expect(try binding("orca", in: db) == Bound(project: "github.com/me/app", method: "template", confidence: "medium"))
        #expect(try binding("herdr", in: db) == Bound(project: "github.com/me/app", method: "template", confidence: "medium"))
        #expect(try binding("leftover", in: db) == Bound(project: "github.com/me/app", method: "template", confidence: "medium"))
        #expect(try binding("tool1", in: db)?.method == "none")

        let stats = try IndexQueries.bindingStats(db, set: .default, home: home.path, templates: ProjectBinder.pathTemplates(env: env))
        #expect(stats.suggestedTemplates == [.init(template: "~/.tool/trees/{repo}/*", sessions: 2, repositories: ["app"])])

        // Once added, the tool's folders bind and nothing is suggested.
        try writeSettings(["pathTemplates": ["~/.tool/trees/{repo}/*"]])
        _ = try await bind(db)
        #expect(try binding("tool2", in: db) == Bound(project: "github.com/me/app", method: "template", confidence: "medium"))
        #expect(try IndexQueries.bindingStats(db, set: .default, home: home.path,
                                              templates: ProjectBinder.pathTemplates(env: env)).suggestedTemplates.isEmpty)
    }

    @Test func rebindUpgradesLowToExactWhenHookArrives() async throws {
        let db = try database()
        try await siblingsAndTemplate(db)
        try addSession("late", cwd: path("ws/app/late"), in: db)
        _ = try await bind(db)
        #expect(try binding("late", in: db)?.confidence == "low")
        // The spool line comes in a later import.
        try addHook("late", cwd: path("ws/app/late"), commonDir: nil, remote: "github.com/me/elsewhere", in: db)
        #expect(try await bind(db) == .init(changed: 1, pending: 0))
        #expect(try binding("late", in: db) == Bound(project: "github.com/me/elsewhere", method: "hook", confidence: "exact"))
        // A live binding is upgraded too; an exact one never goes down when its folder is deleted.
        try addHook("one", cwd: path("ws/app/one"), commonDir: nil, remote: "github.com/me/app", in: db)
        _ = try await bind(db)
        #expect(try binding("one", in: db) == Bound(project: "github.com/me/app", method: "hook", confidence: "exact"))
        #expect(try await bind(db) == .init(changed: 0, pending: 0))
    }

    // MARK: Budget and binding sets

    /// Git calls a fake runner answered, on a fake clock each call moves forward.
    final class FakeGit: @unchecked Sendable {
        private let lock = NSLock()
        private var time = Date(timeIntervalSince1970: 1_000_000)
        private var log: [(folder: String, timeout: TimeInterval)] = []
        let duration: TimeInterval

        init(duration: TimeInterval) { self.duration = duration }

        var now: Date { lock.withLock { time } }
        var calls: [(folder: String, timeout: TimeInterval)] { lock.withLock { log } }
        func reset() { lock.withLock { log = [] } }

        func binder(env: HarnessEnvironment, root: URL, budget: TimeInterval) -> ProjectBinder {
            var binder = ProjectBinder(env: env, projectsRoot: root, run: { _, _, folder, timeout in
                self.lock.withLock {
                    self.log.append(((folder?.path as NSString?)?.lastPathComponent ?? "", timeout))
                    // A call that would take longer is killed at its timeout.
                    self.time += min(self.duration, timeout)
                }
                return ProcessRunner.Result(exitedNormally: true, status: 0, timedOut: false, output: "")
            })
            binder.gitBudget = budget
            binder.clock = { self.now }
            return binder
        }
    }

    @Test func gitTimeBudgetIsRespected() async throws {
        // Worktree lists come from the repositories' files; git runs only to read a branch of a
        // reftable repository for a sibling candidate. `.git/reftable` makes app one as far as that goes.
        let db = try database()
        try await siblingsAndTemplate(db)
        try fm.createDirectory(atPath: path("Projects/app/.git/reftable"), withIntermediateDirectories: true)
        for index in 0..<4 {
            try addSession("s\(index)", cwd: path("ws/app/gone\(index)"), branch: "b\(index)",
                           started: Date(timeIntervalSince1970: 2_000_000 - Double(index)), in: db)
        }
        let fake = FakeGit(duration: 4)

        let first = try await fake.binder(env: env, root: root, budget: 10).bind(database: db)
        // 4 + 4 + 2 s: the third call gets only what is left, the fourth none (that candidate stays low).
        #expect(fake.calls.map(\.folder) == ["app", "app", "app"] && fake.calls.map(\.timeout) == [5, 5, 2])
        #expect(first == .init(changed: 5, pending: 0))
        for id in ["s0", "s1", "s2"] { #expect(try binding(id, in: db)?.method == "branchConfirmed", "\(id)") }
        #expect(try binding("s3", in: db) == Bound(project: "github.com/me/app", method: "sibling", confidence: "low"))

        // The next run tries the low one again.
        fake.reset()
        let second = try await fake.binder(env: env, root: root, budget: 10).bind(database: db)
        #expect(fake.calls.count == 1 && second == .init(changed: 1, pending: 0))
        #expect(try binding("s3", in: db)?.method == "branchConfirmed")

        // A deadline (the 5 s of akit stats) that has passed: no git at all, the session waits.
        try addSession("s4", cwd: path("ws/app/gone4"), branch: "b4", started: Date(timeIntervalSince1970: 1_000_000), in: db)
        fake.reset()
        let late = try await fake.binder(env: env, root: root, budget: 10).bind(database: db, deadline: fake.now)
        #expect(fake.calls.isEmpty && late.pending == 1)
        #expect(try binding("s4", in: db) == nil)

        // Enough time: decided.
        fake.reset()
        let done = try await fake.binder(env: env, root: root, budget: 100).bind(database: db)
        #expect(fake.calls.count == 1 && done == .init(changed: 1, pending: 0))
        #expect(try binding("s4", in: db)?.method == "branchConfirmed")
    }

    @Test func noneInAnExistingFolderWaitsForAHookOrATemplate() async throws {
        let db = try database()
        let app = try await repository("Projects/app", remote: "https://github.com/me/app.git")
        try addSession("main", cwd: app.path, in: db)
        try fm.createDirectory(atPath: path(".tool/trees/app/a"), withIntermediateDirectories: true)
        try addSession("home", cwd: home.path, in: db)
        try addSession("tool", cwd: path(".tool/trees/app/a"), in: db)
        try addSession("gone", cwd: path("gone/somewhere"), in: db)
        func decidedAt(_ id: String) throws -> Double? {
            try db.value("SELECT decided_at FROM bindings WHERE session_key = ?", "claude:\(id)")?.double
        }
        let binder = ProjectBinder(env: env, projectsRoot: root)
        _ = try await binder.bind(database: db, now: Date(timeIntervalSince1970: 1000))
        #expect(try binding("tool", in: db)?.method == "none" && binding("home", in: db)?.method == "none")

        // Folders that exist are not looked at again; a gone one is (a worktree list may still know it).
        _ = try await binder.bind(database: db, now: Date(timeIntervalSince1970: 2000))
        #expect(try decidedAt("home") == 1000 && decidedAt("tool") == 1000 && decidedAt("gone") == 2000)

        // Another template list: all of them are decided again.
        try writeSettings(["pathTemplates": ["~/.tool/trees/{repo}/*"]])
        _ = try await binder.bind(database: db, now: Date(timeIntervalSince1970: 3000))
        #expect(try binding("tool", in: db) == Bound(project: "github.com/me/app", method: "template", confidence: "medium"))
        #expect(try decidedAt("home") == 3000)

        // A hook event.
        try addHook("home", cwd: home.path, commonDir: nil, remote: "github.com/me/dotfiles", in: db)
        _ = try await binder.bind(database: db, now: Date(timeIntervalSince1970: 4000))
        #expect(try binding("home", in: db) == Bound(project: "github.com/me/dotfiles", method: "hook", confidence: "exact"))
    }

    @Test func defaultBindingSetExcludesLow() async throws {
        #expect(try BindingSet.parse(nil) == .default)
        #expect(BindingSet.default.names == ["exact", "high", "medium"])
        #expect(!BindingSet.default.contains(.low) && !BindingSet.default.contains(nil))
        let all = try BindingSet.parse("low, exact,HIGH,medium")
        #expect(all.names == ["exact", "high", "medium", "low"] && all.sqlList == "('exact', 'high', 'medium', 'low')")
        #expect(throws: BindingSet.Failure.self) { try BindingSet.parse("exact,bogus") }
        #expect(throws: BindingSet.Failure.self) { try BindingSet.parse(" , ") }

        let db = try database()
        try await siblingsAndTemplate(db)
        try addSession("low", cwd: path("ws/app/gone"), in: db)
        try addSession("none", cwd: path("gone/x"), in: db)
        try addSession("old", cwd: path("gone/y"), started: Date().addingTimeInterval(-40 * 86_400), in: db)
        _ = try await bind(db)
        let stats = try IndexQueries.bindingStats(db, set: .default)
        #expect(stats.recent == .init(days: 30, sessions: 3, bound: 1, share: 1.0 / 3))
        #expect(stats.byMethod["live"] == 1 && stats.byMethod["sibling"] == 1 && stats.byMethod["none"] == 2)
        #expect(stats.byConfidence["exact"] == 1 && stats.byConfidence["low"] == 1 && stats.byConfidence["none"] == 2)
        #expect(Set(stats.unboundFolders) == [path("ws/app/gone"), path("gone/x")])
        let withLow = try IndexQueries.bindingStats(db, set: try BindingSet.parse("exact,high,medium,low"))
        #expect(withLow.recent.bound == 2 && withLow.unboundFolders == [path("gone/x")])
    }
}
