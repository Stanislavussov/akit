import AKitFoundation
import Foundation

/// Which project a session folder belongs to, for lists of session files (the Sessions
/// screen's Project filter). Worktrees count as their repository, like in the index.
/// Never imports; reads the index only when there is one.
public enum SessionProjects {
    /// Project id per folder, keyed by the path as given; folders without a project are left out.
    /// A folder that still exists says it itself (its repository now). A folder that is gone takes
    /// the index's bindings, then, as the binder does without git, the worktree lists of the
    /// known repositories and the path templates.
    public static func projectIDs(ofFolders folders: [String], env: HarnessEnvironment, projectsRoot: URL,
                                  bindings: BindingSet = .default) -> [String: String] {
        let root = BindingPaths.canonical(projectsRoot.path)
        let home = BindingPaths.canonical(env.homeDirectory.path)
        let indexed = (try? indexed(env: env, bindings: bindings)) ?? Indexed()
        let live = LiveFolderResolver(projectsRoot: root)
        var found: [String: String] = [:]
        var commonDirs = indexed.commonDirs
        var waiting: [String] = []
        for folder in folders where folder.hasPrefix("/") {
            if let repository = live.repository(for: folder) {
                found[folder] = repository.projectID
                if let path = repository.repoPath { commonDirs.insert(path) }
            } else if let id = indexed.folders[BindingPaths.canonical(folder)] {
                found[folder] = id
            } else {
                waiting.append(folder)
            }
        }
        guard !waiting.isEmpty else { return found }
        // Known repositories as the binder takes them: also the ones directly under the projects
        // root, only ones that still exist, each with the id it has now (one id per repository).
        for child in FileWalk.children(of: URL(filePath: root, directoryHint: .isDirectory))
        where FileManager.default.fileExists(atPath: child.appending(path: ".git").path) {
            if let repository = RecordSession.repository(containing: child.path) { commonDirs.insert(repository.commonDir) }
        }
        var worktrees = WorktreeListResolver(excluded: [home, root])
        var repositories: [RepositoryMatch] = []
        for path in Set(commonDirs.map(BindingPaths.canonical)).sorted() where FileWalk.isDirectory(URL(filePath: path)) {
            let repository = RepositoryMatch(projectID: BindingPaths.projectID(commonDir: path, projectsRoot: root), repoPath: path)
            repositories.append(repository)
            worktrees.add(folders: WorktreeListResolver.folders(commonDir: path), repository: repository)
        }
        let templates = PathTemplateResolver(templates: ProjectBinder.pathTemplates(env: env), home: home, repositories: repositories)
        for folder in waiting {
            if let repository = worktrees.repository(for: folder) ?? templates.repository(for: folder) {
                found[folder] = repository.projectID
            }
        }
        return found
    }

    /// A short name per project id: the last part of the id (`github.com/me/app` → `app`),
    /// or the whole id where two projects share that part.
    public static func names(of ids: some Sequence<String>) -> [String: String] {
        let ids = Set(ids)
        func short(_ id: String) -> String { id.split(separator: "/").last.map(String.init) ?? id }
        let counts = Dictionary(ids.map { (short($0).lowercased(), 1) }, uniquingKeysWith: +)
        return Dictionary(uniqueKeysWithValues: ids.map { ($0, counts[short($0).lowercased()] == 1 ? short($0) : $0) })
    }

    private struct Indexed {
        /// Canonical session folder → the project most of its sessions are bound to.
        var folders: [String: String] = [:]
        /// Common git dirs of the bound repositories.
        var commonDirs: Set<String> = []
    }

    private static func indexed(env: HarnessEnvironment, bindings: BindingSet) throws -> Indexed {
        let url = InsightsPaths(env: env).database
        guard FileManager.default.fileExists(atPath: url.path) else { return Indexed() }
        let database = try IndexSchema.open(url)
        var result = Indexed()
        // One folder may be logged in several spellings (`/private/tmp`, `/tmp`): count per canonical path.
        var votes: [String: [String: Int]] = [:]
        for row in try database.rows("""
            SELECT s.cwd, b.project_id, b.repo_path, COUNT(*) FROM sessions s JOIN bindings b ON b.session_key = s.key
            WHERE s.cwd IS NOT NULL AND b.project_id IS NOT NULL AND b.confidence IN \(bindings.sqlList)
            GROUP BY s.cwd, b.project_id, b.repo_path
            """) {
            guard let cwd = row[0].text, let id = row[1].text else { continue }
            votes[BindingPaths.canonical(cwd), default: [:]][id, default: 0] += row[3].int ?? 0
            if let repo = row[2].text { result.commonDirs.insert(repo) }
        }
        for (folder, counts) in votes {
            result.folders[folder] = counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
        }
        return result
    }
}
