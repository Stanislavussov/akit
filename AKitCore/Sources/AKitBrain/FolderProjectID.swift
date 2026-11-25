import AKitFoundation
import Foundation

extension ProjectRecords {
    /// The project a folder lies in, read from `.git` files without running git (skill-modes.md,
    /// "The project id"): the repository's `origin` remote, normalized; without one, `local/…` of
    /// the main checkout (found through the git common dir, so every worktree of the repository
    /// gets the same id). nil outside git. `projectsRoot`: the projects folder for `local/` ids.
    /// The same id `LiveFolderResolver` gives a session's folder (a test keeps the two equal);
    /// `projectID(for:projectsRoot:env:)` uses a worktree's own path instead, so it isn't used here.
    public static func projectID(ofFolder folder: URL, projectsRoot: String) -> String? {
        guard let checkout = GitCheckout.containing(folder) else { return nil }
        if let remote = checkout.originURL.flatMap(normalizedRemote) { return remote }
        let common = canonicalPath(checkout.commonDir.path)
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
