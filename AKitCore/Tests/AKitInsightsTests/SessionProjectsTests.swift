import Foundation
import Testing
import AKitBrain
@testable import AKitInsights
@testable import AKitFoundation

/// Session folders → projects for the Sessions screen. Real git repositories in a temporary
/// fake home; never touches the real home.
struct SessionProjectsTests {
    let home: URL
    let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "akit-session-projects-\(UUID().uuidString)")
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

    func projects(_ folders: [String]) -> [String: String] {
        SessionProjects.projectIDs(ofFolders: folders, env: env, projectsRoot: root)
    }

    @Test func liveFoldersAndWorktreesShareTheirRepository() async throws {
        let app = try await repository("Projects/app", remote: "git@github.com:me/app.git")
        try fm.createDirectory(at: app.appending(path: "Sources"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appending(path: "trees"), withIntermediateDirectories: true)
        try await git("worktree", "add", "-q", "-b", "feature", path("trees/feature"), in: app)
        try fm.createDirectory(at: root.appending(path: "notes"), withIntermediateDirectories: true)

        let found = projects([app.path, app.path + "/Sources", path("trees/feature"), path("Projects/notes"), home.path, "relative"])
        #expect(found[app.path] == "github.com/me/app")
        #expect(found[app.path + "/Sources"] == "github.com/me/app")
        #expect(found[path("trees/feature")] == "github.com/me/app")
        // A folder without git is a project only under the projects root.
        #expect(found[path("Projects/notes")] == ProjectRecords.localID(path: BindingPaths.canonical(path("Projects/notes")),
                                                                         projectsRoot: BindingPaths.canonical(root.path)))
        #expect(found[home.path] == nil)
        #expect(found["relative"] == nil)
    }

    @Test func deletedWorkspaceFolderTakesTheTemplatesRepositoryWithoutAnIndex() async throws {
        try await repository("Projects/app", remote: "git@github.com:me/app.git")
        let found = projects([path("orca/workspaces/app/bowhead"), path("orca/workspaces/unknown/loach"), path("gone/elsewhere")])
        #expect(found == [path("orca/workspaces/app/bowhead"): "github.com/me/app"])
        #expect(!fm.fileExists(atPath: InsightsPaths(home: home).database.path), "the index is never created")
    }

    @Test func deletedWorktreeStaysInItsRepositoryWithoutAnIndex() async throws {
        let app = try await repository("Projects/app", remote: "git@github.com:me/app.git")
        try fm.createDirectory(at: home.appending(path: "trees"), withIntermediateDirectories: true)
        try await git("worktree", "add", "-q", "-b", "feature", path("trees/feature"), in: app)
        // Deleted by hand: git still lists it until `git worktree prune`.
        try fm.removeItem(atPath: path("trees/feature"))

        let found = projects([path("trees/feature"), app.path + "/.claude/worktrees/pruned", path("trees/other")])
        #expect(found == [path("trees/feature"): "github.com/me/app", app.path + "/.claude/worktrees/pruned": "github.com/me/app"])
    }

    /// A session bound to `project` at `confidence`, written straight into the index.
    func addBound(_ id: String, cwd: String, project: String, confidence: String, repo: String? = nil, in db: IndexDatabase) throws {
        try db.run("""
            INSERT INTO sessions(key, harness, native_id, cwd, started, source_id, parser_version) VALUES(?, 'claude', ?, ?, 0, 0, 1)
            """, "claude:\(id)", id, cwd)
        try db.run("""
            INSERT INTO bindings(session_key, project_id, method, confidence, repo_path, decided_at, resolver_version)
            VALUES(?, ?, 'worktree', ?, ?, 0, 2)
            """, "claude:\(id)", project, confidence, repo)
    }

    @Test func aFolderThatExistsSaysItItselfWhateverOldBindingsSay() async throws {
        // Bound as `local/app` before the repository got its remote; most sessions still say so.
        let app = try await repository("Projects/app", remote: "git@github.com:me/app.git")
        let db = try IndexSchema.open(InsightsPaths(home: home).database)
        let common = BindingPaths.canonical(app.path + "/.git")
        try addBound("s1", cwd: app.path, project: "local/app", confidence: "exact", repo: common, in: db)
        try addBound("s2", cwd: app.path, project: "local/app", confidence: "exact", repo: common, in: db)
        try addBound("s3", cwd: app.path, project: "github.com/me/app", confidence: "exact", repo: common, in: db)

        // The repository has one id now, so a template folder still finds it.
        #expect(projects([app.path, path("orca/workspaces/app/bowhead")])
            == [app.path: "github.com/me/app", path("orca/workspaces/app/bowhead"): "github.com/me/app"])
    }

    @Test func indexBindingsDecideFoldersThatAreGone() throws {
        let db = try IndexSchema.open(InsightsPaths(home: home).database)
        func add(_ id: String, cwd: String, project: String, confidence: String) throws {
            try addBound(id, cwd: cwd, project: project, confidence: confidence, in: db)
        }
        // Three sessions say app, two say other, in several spellings of the path: the folder goes to app.
        try add("s1", cwd: path("gone/wt"), project: "github.com/me/app", confidence: "high")
        try add("s2", cwd: path("gone/wt"), project: "github.com/me/app", confidence: "medium")
        try add("s3", cwd: path("gone/wt") + "/", project: "github.com/me/other", confidence: "high")
        try add("s5", cwd: path("gone/wt"), project: "github.com/me/other", confidence: "high")
        try add("s6", cwd: path("gone/./wt"), project: "github.com/me/app", confidence: "high")
        // A low (unconfirmed sibling) binding is not in the default set.
        try add("s4", cwd: path("gone/guess"), project: "github.com/me/app", confidence: "low")

        #expect(projects([path("gone/wt"), path("gone/guess")]) == [path("gone/wt"): "github.com/me/app"])
    }

    @Test func namesAreShortUnlessTwoProjectsShareOne() {
        #expect(SessionProjects.names(of: ["github.com/me/app", "local/App", "github.com/me/tool", "github.com/me/tool"]) == [
            "github.com/me/app": "github.com/me/app", "local/App": "local/App", "github.com/me/tool": "tool",
        ])
    }
}
