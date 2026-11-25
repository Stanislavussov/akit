import AKitFoundation
import Foundation

extension ProjectRecords {
    /// The project a folder lies in, read from `.git` files without running git (skill-modes.md,
    /// "The project id"): the repository's `origin` remote, normalized; without one, `local/…` of
    /// the main checkout (found through the git common dir, so every worktree of the repository
    /// gets the same id). nil outside git. `projectsRoot`: the projects folder for `local/` ids.
    /// The same lookup and id `LiveFolderResolver` gives a session's folder (one implementation);
    /// `projectID(for:projectsRoot:env:)` uses a worktree's own path instead, so it isn't used here.
    public static func projectID(ofFolder folder: URL, projectsRoot: String) -> String? {
        GitCheckout.repositoryFolders(containing: folder.path).map { projectID(commonDir: $0.commonDir, projectsRoot: projectsRoot) }
    }

    /// The project id of the repository with this common git folder: its `origin` (the config's
    /// first 256 KB), else the `local/…` id of its main folder. Session binding uses it too, so a
    /// folder and a session there always get the same id.
    public static func projectID(commonDir: String, projectsRoot: String) -> String {
        if let remote = GitCheckout.metadata(commonDir + "/config").flatMap(GitCheckout.originURL(inConfig:)).flatMap(normalizedRemote) {
            return remote
        }
        let common = canonicalPath(commonDir)
        // `<repo>/.git` → `<repo>`; a bare repository is its own main folder.
        let main = (common as NSString).lastPathComponent == ".git" ? (common as NSString).deletingLastPathComponent : common
        return localID(path: main, projectsRoot: canonicalPath(projectsRoot))
    }

    /// Standardized, without the `/private` of macOS's `/var`, `/tmp` and `/etc` links, so
    /// `/private/tmp/x` and `/tmp/x` are one folder (whether or not it still exists).
    public static func canonicalPath(_ path: String) -> String {
        var path = (path as NSString).standardizingPath
        for linked in ["/private/var", "/private/tmp", "/private/etc"] where path == linked || path.hasPrefix(linked + "/") {
            path.removeFirst("/private".count)
        }
        return path
    }
}
